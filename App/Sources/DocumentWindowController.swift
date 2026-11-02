import AppKit
import PDFKit

/// The windows PiDF shows documents in, so they can be told from panels.
final class DocumentWindow: NSWindow {
    /// ← and → turn a whole page; ↑ and ↓ still scroll a little. ⌃← and ⌃→
    /// rotate the page, where macOS lets them through (out of the box they
    /// change Spaces; ⌃⌥← and ⌃⌥→ in the menu always work). Caught here,
    /// before PDFKit's own views see the key, so it works wherever the click
    /// left the focus, except while typing in a text field.
    override func sendEvent(_ event: NSEvent) {
        followSelectorKeys(event)
        // A click on a note, and the drag that may follow, are the note's
        // (select, move, edit), not PDFKit's.
        if let controller = windowController as? DocumentWindowController {
            if event.type == .keyDown, controller.handlePageSelectorKey(event) { return }
            switch event.type {
            case .leftMouseDown where controller.pdfView.handleClick(event): return
            case .leftMouseDragged where controller.pdfView.handleDrag(event): return
            case .leftMouseUp where controller.pdfView.handleRelease(event): return
            default: break
            }
        }
        if event.type == .keyDown, !(firstResponder is NSText),
           let controller = windowController as? DocumentWindowController, controller.pageSelector == nil,
           let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }) {
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch (key, modifiers) {
            case (NSLeftArrowFunctionKey, []):
                controller.goToPreviousPage(nil)
                return
            case (NSRightArrowFunctionKey, []):
                controller.goToNextPage(nil)
                return
            case (NSLeftArrowFunctionKey, .control):
                controller.rotatePageLeft(nil)
                return
            case (NSRightArrowFunctionKey, .control):
                controller.rotatePageRight(nil)
                return
            case (0x7F, []), (NSDeleteFunctionKey, []):  // Delete, forward delete
                if controller.deleteSelectedNote() { return }
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    /// ⌃ and ⌥ held together, then let go with nothing else in between.
    private var selectorKeysHeld = false

    /// The keys held were part of a shortcut the menu took: ⌃⌥← and ⌃⌥→ may
    /// never reach this window as key events.
    func forgetSelectorKeys() { selectorKeysHeld = false }

    /// ⌃⌥ alone opens and closes the page selector, when the keys go up: on
    /// the way down they may be the start of another shortcut. Only the events
    /// the window gets anyway: nothing runs while no key is pressed.
    private func followSelectorKeys(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if held == [.control, .option] {
                selectorKeysHeld = true
            } else if held.isEmpty, selectorKeysHeld {
                selectorKeysHeld = false
                if !(firstResponder is NSText), attachedSheet == nil {
                    (windowController as? DocumentWindowController)?.togglePageSelector(nil)
                }
            } else if !held.isSubset(of: [.control, .option]) {
                selectorKeysHeld = false
            }
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            selectorKeysHeld = false
        default:
            break
        }
    }
}

/// One document, in its own window or as one tab of a window.
///
/// Highlights and notes are made in the document's own PDFAnnotations and
/// written back into the file: on ⌘S, when the tab goes behind another one,
/// when it closes and when PiDF quits.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    static let tabbingIdentifier = "PiDF"
    private static let twoPagesKey = "TwoPages"

    let url: URL
    let pdfView = AnnotatedPDFView(frame: NSRect(x: 0, y: 0, width: 640, height: 820))
    private(set) var chrome: WindowChrome!
    private(set) var findBar: FindBar?
    private var watcher: FileWatcher?
    private var pageObserver: NSObjectProtocol?
    /// The password that unlocked the document, so a new version of the file
    /// opens without asking again. Never saved.
    private var password: String?

    var onClose: ((DocumentWindowController) -> Void)?
    /// PDFs dropped on the window, to open as tabs next to it.
    var onDrop: (([URL], NSWindow) -> Void)?
    /// Called after the document was reloaded from disk (used by the tests).
    var onReload: (() -> Void)?

    init(url: URL, document: PDFDocument) {
        self.url = url
        let window = DocumentWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 820),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: true)
        window.tabbingMode = .preferred
        window.titlebarAppearsTransparent = true
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.isRestorable = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 240)
        window.title = url.lastPathComponent
        window.representedURL = url

        let content = DropView(frame: pdfView.frame)
        pdfView.autoresizingMask = [.width, .height]
        pdfView.displayMode = UserDefaults.standard.bool(forKey: Self.twoPagesKey) ? .twoUpContinuous : .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.acceptsDraggedFiles = false
        pdfView.autoScales = true
        content.addSubview(pdfView)
        window.contentView = content
        window.initialFirstResponder = pdfView
        super.init(window: window)
        window.delegate = self

        show(document)
        // The document fills the window up to its top edge, under the hidden
        // title bar, instead of starting below it.
        if let scroll = pdfView.documentView?.enclosingScrollView {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets()
        }
        content.onDrop = { [weak self, weak window] urls in
            guard let self, let window else { return }
            self.onDrop?(urls, window)
        }
        chrome = WindowChrome(window: window)
        pdfView.onNoteMoved = { [weak self] in self?.annotationsChanged() }
        pdfView.onNoteDoubleClicked = { [weak self] note in self?.editNote(note) }
        pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePageNumber() }
        }
        watcher = FileWatcher(url: url) { [weak self] in self?.reload() }
        updatePageNumber()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var pdf: PDFDocument? { pdfView.document ?? parked?.document }

    // MARK: Text recognition

    /// PDFKit runs Live Text on every page it shows, which loads the Vision
    /// models and doubles the memory PiDF needs (about 90 MB more for one
    /// document). Only scanned pages need it: their text can then be selected
    /// and found. Documents that have text keep it off.
    ///
    /// Five pages spread over the document are looked at (first, quarters,
    /// last), not only the first ones: a cover, a blank page and an
    /// illustration at the start don't make a text document a scan.
    static func needsTextRecognition(_ document: PDFDocument) -> Bool {
        guard !document.isLocked, document.pageCount > 0 else { return false }
        let last = document.pageCount - 1
        let samples = Set((0...4).map { last * $0 / 4 })
        return !samples.contains { index in
            !(document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Whether PDFKit recognizes text in the pages it shows.
    var recognizesText: Bool {
        guard pdfView.responds(to: NSSelectorFromString("isDocumentAnalysisEnabled")) else { return true }
        return pdfView.value(forKey: "documentAnalysisEnabled") as? Bool ?? true
    }

    /// Shows `document`, with text recognition only if it needs it. The
    /// setting has no public API; without it, PDFKit's default stays.
    private func show(_ document: PDFDocument?) {
        if let document, pdfView.responds(to: NSSelectorFromString("setDocumentAnalysisEnabled:")) {
            pdfView.setValue(Self.needsTextRecognition(document), forKey: "documentAnalysisEnabled")
        }
        pdfView.document = document
        guard let document, !document.isLocked else { return closePageSelector() }
        reloadPageSelector()
    }

    // MARK: Showing

    /// Shows the document as a tab of `host`, or in a new window where the
    /// last one was left, or sized to its first page the first time.
    func present(nextTo host: NSWindow?) {
        guard let window else { return }
        if let host, host.isVisible {
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
            (host.windowController as? DocumentWindowController)?.scheduleParking()
        } else {
            window.setFrame(WindowFrame.saved() ?? initialFrame(), display: false)
            showWindow(nil)
        }
        window.makeFirstResponder(pdfView)
        restorePosition()
        chrome.introduce()
        if pdf?.isLocked == true { askForPassword() }
        Self.returnFreedMemory()  // what opening the document used
    }

    func bringToFront() {
        guard let window else { return }
        let previous = window.tabGroup?.selectedWindow
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        scheduleParking()
        (previous?.windowController as? DocumentWindowController)?.scheduleParking()
    }

    /// Tall enough for most of the screen, wide enough for a whole page.
    private func initialFrame() -> NSRect {
        let visible = (NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        var page = CGSize(width: 612, height: 792)  // US Letter until the document says otherwise
        if let first = pdf?.page(at: 0) {
            let box = first.bounds(for: .cropBox).size
            page = first.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
        }
        let pages: CGFloat = pdfView.displayMode == .twoUpContinuous ? 2 : 1
        let height = (visible.height * 0.92).rounded()
        let margin: CGFloat = 16
        let width = min(max(((height - margin) * page.width / max(page.height, 1)) * pages + margin, 480), visible.width * 0.92).rounded()
        return NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
    }

    // MARK: Tabs in the background

    /// What a tab in the background keeps: the document, already read, and
    /// where it was. Its rendered pages, most of a window's memory, go.
    private struct Parked {
        var document: PDFDocument
        var destination: PDFDestination?
        var pageIndex: Int
        var scale: CGFloat
        var autoScales: Bool
        /// The document was read again while in the background, another
        /// app's version or PiDF's own write: its matches have to be found again.
        var reloaded = false
        /// Another app saved the file while changes wait to be written here:
        /// the question comes when the tab does.
        var newVersionWaiting = false
    }

    private var parked: Parked?
    private var isClosed = false
    var isParked: Bool { parked != nil }

    /// Behind another tab, or minimized.
    private var isInBackground: Bool {
        guard let window else { return false }
        if window.isMiniaturized { return true }
        guard let group = window.tabGroup, group.windows.count > 1 else { return false }
        return group.selectedWindow !== window
    }

    /// Called whenever the window may have gone to or come back from the
    /// background; checked once AppKit has finished switching tabs.
    func scheduleParking() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if self.isInBackground {
                    self.park()
                } else {
                    self.unpark()
                    self.followTwoPagesSetting()
                }
            }
        }
    }

    func park() {
        guard parked == nil, let document = pdfView.document, window?.attachedSheet == nil else { return }
        closePageSelector()
        findBar?.interrupt()
        parked = Parked(document: document, destination: pdfView.currentDestination, pageIndex: pageIndex,
                        scale: pdfView.scaleFactor, autoScales: pdfView.autoScales)
        rememberPosition()  // kept even if the app never gets to quit normally
        pdfView.document = nil
        Self.returnFreedMemory()
        saveAnnotationsInBackground()
    }

    /// PDFKit frees what it decoded to draw the pages (in the background,
    /// a moment later), but the allocator keeps that memory for reuse. Give
    /// it back to macOS once PDFKit is done, so it shows as free.
    static func returnFreedMemory() {
        reliefTask?.cancel()
        let task = DispatchWorkItem { malloc_zone_pressure_relief(nil, 0) }
        reliefTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: task)
    }

    private static var reliefTask: DispatchWorkItem?

    func unpark() {
        guard parked != nil else { return }
        waitForBackgroundSave()  // never shown while another thread writes it
        guard let saved = parked else { return }
        parked = nil
        show(saved.document)
        if saved.autoScales { pdfView.autoScales = true } else { pdfView.scaleFactor = saved.scale }
        pdfView.layoutDocumentView()
        // The exact spot on the page, unless it lies on another page than the
        // one the title bar showed (the top of the window can show the end of
        // the page before).
        if let destination = saved.destination, let page = destination.page, page.document === saved.document,
           saved.document.index(for: page) == saved.pageIndex {
            pdfView.go(to: destination)
        } else {
            go(toIndex: saved.pageIndex)
        }
        if saved.reloaded { findBar?.refresh() } else { findBar?.reapply() }
        updatePageNumber()
        if saved.document.isLocked && window?.attachedSheet == nil { askForPassword() }
        if saved.newVersionWaiting { reload() }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { scheduleParking() }
    func windowDidBecomeKey(_ notification: Notification) { scheduleParking() }
    func windowDidResignKey(_ notification: Notification) { scheduleParking() }
    func windowDidMiniaturize(_ notification: Notification) { scheduleParking() }
    func windowDidDeminiaturize(_ notification: Notification) { scheduleParking() }

    // MARK: Page number and reading position

    var pageIndex: Int {
        if let parked { return parked.pageIndex }
        guard let document = pdf, let page = pdfView.currentPage else { return 0 }
        return document.index(for: page)
    }

    private func updatePageNumber() {
        guard let document = pdf else { return }
        window?.subtitle = document.pageCount > 1 ? "Page \(pageIndex + 1) of \(document.pageCount)" : ""
    }

    private func restorePosition() {
        guard let saved = ReadingPositions.page(for: url) else { return }
        go(toIndex: saved)
    }

    func rememberPosition() {
        guard pdf?.isLocked == false else { return }
        ReadingPositions.save(pageIndex, for: url)
    }

    func go(toIndex index: Int) {
        guard let document = pdf, document.pageCount > 0 else { return }
        let index = min(max(index, 0), document.pageCount - 1)
        if parked != nil {
            parked?.pageIndex = index
            parked?.destination = nil
            return
        }
        guard let page = document.page(at: index) else { return }
        pdfView.layoutDocumentView()
        pdfView.go(to: page)
        updatePageNumber()
    }

    // MARK: Changes made by other apps

    /// Shows the new version of the file at the same page and zoom. Changes
    /// not written yet exist only in the document shown: the answer comes first.
    func reload() {
        guard let fresh = PDFDocument(url: url) else { return }  // still being written: wait for the next change
        if hasUnsavedAnnotations { return askAboutNewVersion() }
        // A deleted page put back into another app's version would land among other pages.
        window?.undoManager?.removeAllActions()
        if fresh.isLocked, let password { _ = fresh.unlock(withPassword: password) }
        if parked != nil {
            // In the background: shown when the tab comes back.
            let index = min(pageIndex, max(fresh.pageCount - 1, 0))
            parked?.document = fresh
            parked?.destination = nil
            parked?.pageIndex = index
            parked?.reloaded = true
            parked?.newVersionWaiting = false
            onReload?()
            return
        }
        let index = pageIndex
        let autoScales = pdfView.autoScales
        let scale = pdfView.scaleFactor
        findBar?.clear()
        show(fresh)
        if fresh.isLocked {
            if window?.attachedSheet == nil { askForPassword() }
        } else {
            if autoScales { pdfView.autoScales = true } else { pdfView.scaleFactor = scale }
            go(toIndex: index)
            findBar?.refresh()
        }
        onReload?()
    }

    private var isAskingAboutNewVersion = false

    /// Another app saved the file and the marks made here aren't in it. Either
    /// version would be lost, so that is for the person reading to say.
    private func askAboutNewVersion() {
        if parked != nil {
            parked?.newVersionWaiting = true
            return
        }
        guard let window, !isAskingAboutNewVersion else { return }
        isAskingAboutNewVersion = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Another app changed “\(url.lastPathComponent)”."
        alert.informativeText = "Your highlights, notes and page changes aren’t saved yet. Keeping them replaces the other app’s version; the new file doesn’t have them."
        alert.addButton(withTitle: "Keep My Marks")
        alert.addButton(withTitle: "Use the New File")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAskingAboutNewVersion = false
                guard !self.isClosed else { return }
                if response == .alertSecondButtonReturn {
                    self.savedChangeCount = self.changeCount
                    window.isDocumentEdited = false
                    self.reload()
                } else {
                    self.saveDocument(nil)
                }
            }
        }
    }

    // MARK: Password

    private func askForPassword(wrong: Bool = false) {
        guard let window, let document = pdf, document.isLocked else { return }
        let alert = NSAlert()
        alert.messageText = wrong ? "Wrong password. Try again." : "“\(url.lastPathComponent)” is protected with a password."
        alert.informativeText = "Type the password to open it."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard response == .alertFirstButtonReturn else {
                    self.close()
                    return
                }
                if self.unlock(with: field.stringValue) { return }
                self.askForPassword(wrong: true)
            }
        }
    }

    /// Unlocks the document; false if the password is wrong.
    func unlock(with password: String) -> Bool {
        guard let document = pdf, document.unlock(withPassword: password) else { return false }
        self.password = password  // kept in memory only, to reopen the file when it changes
        // PDFView lays out a locked document as empty: show it again.
        pdfView.document = nil
        show(document)
        pdfView.autoScales = true
        restorePosition()
        updatePageNumber()
        return true
    }

    // MARK: Window

    /// ⌘W, the tab's close button: the marks go into the file first.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if saveAnnotations(showingResult: false) { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The highlights and notes couldn’t be saved in “\(url.lastPathComponent)”."
        alert.informativeText = "Closing loses them."
        alert.addButton(withTitle: "Close Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        rememberFrame()
        isClosed = true
        closePageSelector()
        waitForBackgroundSave()
        rememberPosition()
        chrome.stop()
        watcher?.stop()
        watcher = nil
        findBar?.clear()
        window?.undoManager?.removeAllActions()  // lets the deleted pages go
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        pageObserver = nil
        pdfView.document = nil
        parked = nil
        onClose?(self)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        chrome.suspend()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        chrome.resume()
    }

    /// True from the start of going full screen to the end of coming back:
    /// the frames in between are not the window's own.
    private var isFullScreen = false

    func windowDidMove(_ notification: Notification) { rememberFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { rememberFrame() }
    func windowDidResize(_ notification: Notification) {
        if window?.inLiveResize == false { rememberFrame() }  // Zoom, tiling
    }

    /// The next new window opens with this one's place and size.
    func rememberFrame() {
        guard let window, window.isVisible, !isClosed, !isFullScreen,
              !window.styleMask.contains(.fullScreen) else { return }
        WindowFrame.save(window.frame)
    }

    // MARK: Zoom and layout

    @objc func zoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc func actualSize(_ sender: Any?) { pdfView.scaleFactor = 1 }
    @objc func zoomToFit(_ sender: Any?) { pdfView.autoScales = true }

    @objc func toggleTwoPages(_ sender: Any?) {
        let twoPages = pdfView.displayMode != .twoUpContinuous
        UserDefaults.standard.set(twoPages, forKey: Self.twoPagesKey)
        show(twoPages: twoPages)
    }

    /// Two Pages is one setting for the whole app: a tab or window that
    /// comes to the front shows it as it was last chosen.
    private func followTwoPagesSetting() {
        let twoPages = UserDefaults.standard.bool(forKey: Self.twoPagesKey)
        if parked == nil, (pdfView.displayMode == .twoUpContinuous) != twoPages { show(twoPages: twoPages) }
    }

    private func show(twoPages: Bool) {
        let index = pageIndex
        pdfView.displayMode = twoPages ? .twoUpContinuous : .singlePageContinuous
        if pdfView.autoScales { pdfView.autoScales = true }
        go(toIndex: index)
    }

    // MARK: Go

    @objc func goToFirstPage(_ sender: Any?) { pdfView.goToFirstPage(sender) }
    @objc func goToLastPage(_ sender: Any?) { pdfView.goToLastPage(sender) }
    @objc func goToNextPage(_ sender: Any?) { pdfView.goToNextPage(sender) }
    @objc func goToPreviousPage(_ sender: Any?) { pdfView.goToPreviousPage(sender) }
    @objc func goBack(_ sender: Any?) { pdfView.goBack(sender) }
    @objc func goForward(_ sender: Any?) { pdfView.goForward(sender) }

    @objc func showGoToPage(_ sender: Any?) {
        guard let window, let document = pdf else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Page"
        alert.informativeText = "Page 1 to \(document.pageCount):"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "\(pageIndex + 1)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn,
                      let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
                self?.go(toIndex: number - 1)
            }
        }
    }

    // MARK: Page selector

    /// The grid of all the pages, while it is on screen.
    private(set) var pageSelector: PageSelector?

    /// ⌃⌥: the grid opens at the page on screen; ⌃⌥ again or Esc goes back
    /// to exactly where the document was, a double click or Return to the
    /// page chosen. The document stays as it is underneath.
    @objc func togglePageSelector(_ sender: Any?) {
        if pageSelector != nil { return closePageSelector() }
        guard parked == nil, let document = pdfView.document, !document.isLocked, let content = window?.contentView else { return }
        let current = pageIndex
        let selector = PageSelector(frame: content.bounds, document: document, copy: selectorCopy(),
                                    topInset: max(chrome.barHeight, 28) + 8, background: pdfView.backgroundColor)
        selector.onChoose = { [weak self] index in self?.choosePage(index) }
        content.addSubview(selector, positioned: .above, relativeTo: pdfView)
        selector.select(current, scrollingToIt: true)
        pageSelector = selector
        pdfView.select(nil)
        pdfView.isHidden = true
        findBar?.isHidden = true
        window?.makeFirstResponder(selector.grid)
    }

    /// PDFKit keeps what it decodes to draw a page for as long as the document
    /// lives, so the grid reads the file through a copy of its own that goes
    /// with it, on another thread. Changes not saved yet are only in the
    /// document shown: nil.
    private func selectorCopy() -> PDFDocument? {
        guard !hasUnsavedAnnotations, let copy = PDFDocument(url: url) else { return nil }
        if copy.isLocked, let password { _ = copy.unlock(withPassword: password) }
        return copy.isLocked || copy.pageCount != pdf?.pageCount ? nil : copy
    }

    private func reloadPageSelector() {
        guard let selector = pageSelector, let document = pdf else { return }
        selector.reload(document, copy: selectorCopy())
    }

    func closePageSelector() {
        guard let selector = pageSelector else { return }
        pageSelector = nil
        selector.removeFromSuperview()
        pdfView.isHidden = false
        findBar?.isHidden = false
        window?.makeFirstResponder(pdfView)
        Self.returnFreedMemory()  // the thumbnails
    }

    func choosePage(_ index: Int) {
        closePageSelector()
        go(toIndex: index)
    }

    /// With the grid open, Esc leaves it and Return goes to the page selected;
    /// any other key is the grid's. False when the key isn't for the selector.
    func handlePageSelectorKey(_ event: NSEvent) -> Bool {
        guard let selector = pageSelector else { return false }
        switch event.keyCode {
        case 53:  // Esc
            closePageSelector()
        case 36, 76:  // Return, Enter
            if let index = selector.selectedIndex { choosePage(index) }
        default:
            return false
        }
        return true
    }

    // MARK: Find

    @objc func showFind(_ sender: Any?) {
        if findBar == nil, let content = window?.contentView {
            let bar = FindBar(pdfView: pdfView)
            bar.onClose = { [weak self] in self?.closeFind(nil) }
            bar.fileOpener = { [weak self] in self?.fileOpenerForFind }
            let top = content.bounds.height - max(chrome.barHeight, 28) - 10
            bar.frame = NSRect(x: content.bounds.width - FindBar.width - 12, y: top - FindBar.height,
                               width: FindBar.width, height: FindBar.height)
            bar.autoresizingMask = [.minXMargin, .minYMargin]
            content.addSubview(bar)
            findBar = bar
            // Selected text is what you look for.
            if let selected = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !selected.isEmpty, !selected.contains("\n"), selected.count < 100 {
                bar.field.stringValue = selected
                bar.search(selected)
            }
        }
        window?.makeFirstResponder(findBar?.field)
        findBar?.field.selectText(nil)
    }

    /// Reads the file for find on other threads, so the document shown never
    /// holds the text of all its pages. Not when the document shown has what
    /// the file hasn't: changes not saved yet, or text recognized in a scan.
    private var fileOpenerForFind: (@Sendable () -> PDFDocument?)? {
        guard !hasUnsavedAnnotations, !recognizesText else { return nil }
        let url = self.url, password = self.password
        return {
            guard let copy = PDFDocument(url: url) else { return nil }
            if copy.isLocked, let password { _ = copy.unlock(withPassword: password) }
            return copy
        }
    }

    @objc func findNext(_ sender: Any?) {
        guard let findBar else { return showFind(sender) }
        findBar.next()
    }

    @objc func findPrevious(_ sender: Any?) {
        guard let findBar else { return showFind(sender) }
        findBar.previous()
    }

    @objc func closeFind(_ sender: Any?) {
        guard let findBar else { return }
        findBar.clear()
        findBar.removeFromSuperview()
        self.findBar = nil
        window?.makeFirstResponder(pdfView)
    }

    /// Esc in the document lets a note go, then closes the find bar.
    override func cancelOperation(_ sender: Any?) {
        if pdfView.selectedNote != nil {
            pdfView.select(nil)
        } else if findBar != nil {
            closeFind(sender)
        }
    }

    // MARK: Highlights and notes

    /// Marks can be made while the document is on screen, not protected,
    /// and in a file PiDF can write back. A protected document would be
    /// written without its protection.
    var canAnnotate: Bool {
        guard parked == nil, let document = pdfView.document, !document.isLocked, !document.isEncrypted else { return false }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    /// The highlights under the lines of `selection`, with their pages.
    private func highlights(under selection: PDFSelection) -> [(PDFPage, PDFAnnotation)] {
        let lines = selection.selectionsByLine()
        return selection.pages.flatMap { page -> [(PDFPage, PDFAnnotation)] in
            // The middle of each line, so a line next to a highlight doesn't count.
            let rects = lines.filter { $0.pages.contains(page) }.map { $0.bounds(for: page) }.map { $0.insetBy(dx: 0, dy: $0.height / 4) }
            return page.annotations
                .filter { annotation in Marks.isHighlight(annotation) && Marks.rects(of: annotation).contains { rect in rects.contains { $0.intersects(rect) } } }
                .map { (page, $0) }
        }
    }

    /// ⌃H: highlights the selected text, or removes the highlights under it.
    @objc func toggleHighlight(_ sender: Any?) {
        guard canAnnotate, let selection = pdfView.currentSelection, !selection.pages.isEmpty else { return }
        let under = highlights(under: selection)
        if !under.isEmpty {
            for (page, annotation) in under { page.removeAnnotation(annotation) }
        } else {
            let lines = selection.selectionsByLine()
            for page in selection.pages {
                let rects = lines.filter { $0.pages.contains(page) }.map { $0.bounds(for: page) }
                if !rects.isEmpty { page.addAnnotation(Marks.highlight(lines: rects)) }
            }
            pdfView.clearSelection()
        }
        annotationsChanged()
    }

    /// ⌃N: a note where the pointer is (or in the middle of the window when
    /// the pointer is elsewhere); with a note selected, edits it.
    @objc func addNote(_ sender: Any?) {
        guard canAnnotate else { return }
        if let note = pdfView.selectedNote { return editNote(note) }
        var inView = pdfView.convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        if !pdfView.bounds.contains(inView) { inView = NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY) }
        guard let page = pdfView.page(for: inView, nearest: true) else { return }
        let inPage = pdfView.convert(inView, to: page)
        askForNoteText(initial: "") { [weak self] text in
            guard let self, let text, !text.isEmpty else { return }
            self.add(note: text, at: inPage, on: page)
        }
    }

    /// Puts a note saying `text` on `page`, its top left corner at `point`,
    /// in `font` (the type of the page's text when not given).
    @discardableResult
    func add(note text: String, at point: NSPoint, on page: PDFPage, font: NSFont? = nil) -> PDFAnnotation {
        let note = Marks.note(text, font: font ?? Marks.textFont(on: page), topLeft: point, in: page.bounds(for: .cropBox), rotation: page.rotation)
        page.addAnnotation(note)
        pdfView.select(note)
        annotationsChanged()
        return note
    }

    func editNote(_ note: PDFAnnotation) {
        askForNoteText(initial: note.contents ?? "") { [weak self] text in
            guard let self, let text else { return }
            self.replace(note, with: text)
        }
    }

    /// A note with new text is a new annotation, in the same place and
    /// type: PDFKit goes on drawing the saved look of one whose text
    /// changed. Empty text removes the note.
    func replace(_ note: PDFAnnotation, with text: String) {
        guard let page = note.page else { return }
        let topLeft = Marks.topLeft(of: note.bounds, in: page.bounds(for: .cropBox), rotation: page.rotation)
        let font = note.font
        pdfView.select(nil)
        page.removeAnnotation(note)
        if text.isEmpty {
            annotationsChanged()
        } else {
            add(note: text, at: topLeft, on: page, font: font)
        }
    }

    /// Delete with a note selected; false when there was none.
    @discardableResult
    func deleteSelectedNote() -> Bool {
        guard let note = pdfView.selectedNote, let page = note.page else { return false }
        pdfView.select(nil)
        page.removeAnnotation(note)
        annotationsChanged()
        return true
    }

    // MARK: Deleting pages

    /// ⌃D: takes the page on screen out of the document. It leaves the file
    /// at the next save, as the marks do; ⌘Z puts it back while the window
    /// is open. The last page stays.
    @objc func deletePage(_ sender: Any?) {
        guard canAnnotate, let document = pdf, document.pageCount > 1 else { return }
        removePage(at: pageIndex)
    }

    /// Each undo registers its redo, so ⌘Z and ⇧⌘Z go back and forth.
    private func removePage(at index: Int) {
        guard parked == nil, let page = pdf?.page(at: index) else { return }
        pdfView.select(nil)
        pdf?.removePage(at: index)
        window?.undoManager?.registerUndo(withTarget: self) { $0.insert(page, at: index) }
        window?.undoManager?.setActionName("Delete Page")
        pagesChanged(showing: index)
    }

    /// The page goes into the document shown, also when that is the file
    /// read again after a save.
    private func insert(_ page: PDFPage, at index: Int) {
        guard parked == nil, let document = pdf else { return }
        document.insert(page, at: min(index, document.pageCount))
        window?.undoManager?.registerUndo(withTarget: self) { $0.removePage(at: index) }
        window?.undoManager?.setActionName("Delete Page")
        pagesChanged(showing: index)
    }

    private func pagesChanged(showing index: Int) {
        annotationsChanged()
        go(toIndex: index)
        findBar?.refresh()
        reloadPageSelector()
    }

    // MARK: Rotating pages

    /// ⌃⌥← / ⌃⌥→ (and ⌃← / ⌃→, see DocumentWindow): turns the page on screen
    /// a quarter turn. Saved in the file as the marks are; ⌘Z turns it back.
    @objc func rotatePageLeft(_ sender: Any?) { rotateCurrentPage(by: -90) }
    @objc func rotatePageRight(_ sender: Any?) { rotateCurrentPage(by: 90) }

    private func rotateCurrentPage(by degrees: Int) {
        (window as? DocumentWindow)?.forgetSelectorKeys()
        guard canAnnotate, pageSelector == nil else { return }
        rotatePage(at: pageIndex, by: degrees)
    }

    /// By index, not by page: the document may have been read again after a
    /// save when an undo comes. The find matches stay valid, so they aren't
    /// looked for again (that reads the text of every page).
    private func rotatePage(at index: Int, by degrees: Int) {
        guard parked == nil, let page = pdf?.page(at: index) else { return }
        pdfView.select(nil)
        page.rotation = (page.rotation + degrees + 360) % 360
        window?.undoManager?.registerUndo(withTarget: self) { $0.rotatePage(at: index, by: -degrees) }
        window?.undoManager?.setActionName("Rotate Page")
        annotationsChanged()
        pdfView.layoutDocumentView()
        if pdfView.autoScales { pdfView.autoScales = true }
        go(toIndex: index)
        reloadPageSelector()
        Self.returnFreedMemory()  // the pages drawn at the old size
    }

    /// The text box of the note sheet on screen, if any.
    private(set) var noteEditor: NoteEditor?

    private func askForNoteText(initial: String, completion: @escaping (String?) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = initial.isEmpty ? "Add Note" : "Edit Note"
        alert.addButton(withTitle: initial.isEmpty ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.informativeText = initial.isEmpty ? "Return adds it; ⌥Return starts a new line." : "Return saves it; ⌥Return starts a new line."
        let editor = NoteEditor(text: initial)
        editor.onCommit = { [weak alert] in alert?.buttons.first?.performClick(nil) }
        editor.onCancel = { [weak alert] in alert?.buttons.last?.performClick(nil) }
        alert.accessoryView = editor
        alert.window.initialFirstResponder = editor.textView
        noteEditor = editor
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.noteEditor = nil
                guard response == .alertFirstButtonReturn else { return completion(nil) }
                completion(editor.text)
            }
        }
    }

    // MARK: Saving the marks into the file

    /// How many marks have been made and how many the file has, so a save
    /// knows which state it wrote.
    private var changeCount = 0
    private var savedChangeCount = 0
    var hasUnsavedAnnotations: Bool { changeCount != savedChangeCount }
    /// A write running on another thread while the tab is in the background.
    private var saveInFlight: SaveInFlight?

    /// Hands the document to the writing thread and brings the result back;
    /// nothing else touches it meanwhile (see waitForBackgroundSave).
    private final class SaveInFlight: @unchecked Sendable {
        let group = DispatchGroup()
        let version: Int
        let document: PDFDocument
        var fresh: PDFDocument?
        init(version: Int, document: PDFDocument) {
            self.version = version
            self.document = document
        }
    }

    private func annotationsChanged() {
        changeCount += 1
        window?.isDocumentEdited = true
    }

    /// Writes the marks into the file now, on this thread (⌘S, closing,
    /// quitting), and shows the file as written unless the window is going
    /// anyway. False if the file couldn't be written.
    @discardableResult
    func saveAnnotations(showingResult: Bool = true) -> Bool {
        waitForBackgroundSave()
        guard hasUnsavedAnnotations else { return true }
        guard let document = pdf else { return false }
        let version = changeCount
        watcher?.expectOwnChange()
        guard let fresh = Self.write(document, to: url) else {
            watcher?.cancelExpectedChange()
            return false
        }
        savedChangeCount = version
        window?.isDocumentEdited = false
        if showingResult { replace(with: fresh) }
        return true
    }

    @objc func saveDocument(_ sender: Any?) {
        guard !saveAnnotations(), let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The highlights and notes couldn’t be saved in “\(url.lastPathComponent)”."
        alert.informativeText = "Check that the file can be written, then save again."
        alert.beginSheetModal(for: window)
    }

    /// The tab went to the background and its document is off screen: the
    /// write (seconds, for a long manual) runs on another thread.
    private func saveAnnotationsInBackground() {
        guard saveInFlight == nil, hasUnsavedAnnotations, let document = parked?.document else { return }
        let save = SaveInFlight(version: changeCount, document: document)
        saveInFlight = save
        watcher?.expectOwnChange()
        let url = self.url
        save.group.enter()
        DispatchQueue.global(qos: .utility).async {
            save.fresh = Self.write(save.document, to: url)
            save.group.leave()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(save) } }
        }
    }

    private func finish(_ save: SaveInFlight) {
        guard saveInFlight === save else { return }
        saveInFlight = nil
        guard let fresh = save.fresh else {
            watcher?.cancelExpectedChange()
            return
        }
        savedChangeCount = save.version
        window?.isDocumentEdited = hasUnsavedAnnotations
        // Marks made since the write began stay in the document shown; the
        // next save writes them.
        if !hasUnsavedAnnotations { replace(with: fresh) }
    }

    /// Nothing touches the document while another thread writes it.
    private func waitForBackgroundSave() {
        guard let save = saveInFlight else { return }
        save.group.wait()
        finish(save)
    }

    /// Writes `document` to a temporary file on the same volume and puts it
    /// in the place of `url`, so a failure leaves the original as it was.
    /// Returns the written file opened again: PDFKit keeps a document's
    /// every object in memory once it has written it, a fresh one is lazy.
    nonisolated static func write(_ document: PDFDocument, to url: URL) -> PDFDocument? {
        let manager = FileManager.default
        guard let folder = try? manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true) else {
            return nil
        }
        defer { try? manager.removeItem(at: folder) }
        let temporary = folder.appendingPathComponent(url.lastPathComponent)
        guard document.write(to: temporary), (try? manager.replaceItemAt(url, withItemAt: temporary)) != nil else { return nil }
        return PDFDocument(url: url)
    }

    /// Shows `fresh`, the same document read again from disk, where the
    /// current one is, at the same spot and zoom.
    private func replace(with fresh: PDFDocument) {
        pdfView.select(nil)
        if parked != nil {
            if let old = parked?.destination, let page = old.page, let document = page.document,
               let samePage = fresh.page(at: document.index(for: page)) {
                parked?.destination = PDFDestination(page: samePage, at: old.point)
            } else {
                parked?.destination = nil
            }
            parked?.document = fresh
            parked?.reloaded = true
            return
        }
        let index = pageIndex
        let point = pdfView.currentDestination?.point
        let autoScales = pdfView.autoScales
        let scale = pdfView.scaleFactor
        show(fresh)
        if autoScales { pdfView.autoScales = true } else { pdfView.scaleFactor = scale }
        pdfView.layoutDocumentView()
        if let page = fresh.page(at: min(index, max(fresh.pageCount - 1, 0))) {
            if let point { pdfView.go(to: PDFDestination(page: page, at: point)) } else { pdfView.go(to: page) }
        }
        findBar?.refresh()
        updatePageNumber()
        Self.returnFreedMemory()
    }

    // MARK: File

    /// ⌘P: macOS's own print sheet, for the document as it is on screen
    /// (marks and rotations not yet saved included). Costs nothing until asked.
    @objc func printDocument(_ sender: Any?) {
        guard let window, let operation = printOperation() else { return }
        operation.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Self.returnFreedMemory()  // what the sheet's previews used
    }

    func printOperation() -> NSPrintOperation? {
        pdf?.printOperation(for: .shared, scalingMode: .pageScaleToFit, autoRotate: true)
    }

    @objc func showInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func openInPreview(_ sender: Any?) {
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Menus

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let unlocked = pdf?.isLocked == false
        // With the grid open no page is "on screen": what acts on one waits.
        if pageSelector != nil {
            switch menuItem.action {
            case #selector(togglePageSelector(_:)), #selector(saveDocument(_:)), #selector(printDocument(_:)),
                 #selector(showInFinder(_:)), #selector(openInPreview(_:)):
                break
            default:
                return false
            }
        }
        switch menuItem.action {
        case #selector(togglePageSelector(_:)):
            menuItem.state = pageSelector == nil ? .off : .on
            return unlocked
        case #selector(zoomIn(_:)): return unlocked && pdfView.canZoomIn
        case #selector(zoomOut(_:)): return unlocked && pdfView.canZoomOut
        case #selector(zoomToFit(_:)):
            menuItem.state = pdfView.autoScales ? .on : .off
            return unlocked
        case #selector(toggleTwoPages(_:)):
            menuItem.state = pdfView.displayMode == .twoUpContinuous ? .on : .off
            return unlocked
        case #selector(goToFirstPage(_:)), #selector(goToPreviousPage(_:)): return unlocked && pdfView.canGoToPreviousPage
        case #selector(goToLastPage(_:)), #selector(goToNextPage(_:)): return unlocked && pdfView.canGoToNextPage
        case #selector(goBack(_:)): return unlocked && pdfView.canGoBack
        case #selector(goForward(_:)): return unlocked && pdfView.canGoForward
        case #selector(findNext(_:)), #selector(findPrevious(_:)): return unlocked && findBar?.matches.isEmpty == false
        case #selector(toggleHighlight(_:)):
            // In the find field ⌃H is the field's own (delete backward).
            guard !(window?.firstResponder is NSText), canAnnotate,
                  let selection = pdfView.currentSelection, !selection.pages.isEmpty else { return false }
            menuItem.title = highlights(under: selection).isEmpty ? "Highlight" : "Remove Highlight"
            return true
        case #selector(addNote(_:)):
            menuItem.title = pdfView.selectedNote == nil ? "Add Note…" : "Edit Note…"
            return !(window?.firstResponder is NSText) && canAnnotate
        case #selector(deletePage(_:)):
            // In the find field ⌃D is the field's own (delete forward).
            menuItem.title = "Delete Page \(pageIndex + 1)"
            return !(window?.firstResponder is NSText) && canAnnotate && (pdf?.pageCount ?? 0) > 1
        case #selector(rotatePageLeft(_:)), #selector(rotatePageRight(_:)):
            // In the find field these keys select text.
            return !(window?.firstResponder is NSText) && canAnnotate
        case #selector(printDocument(_:)): return unlocked && pdf?.allowsPrinting == true
        case #selector(saveDocument(_:)): return hasUnsavedAnnotations
        case #selector(showInFinder(_:)), #selector(openInPreview(_:)): return true
        default: return unlocked
        }
    }
}

/// The window's content: a target for dropped PDFs.
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func documents(in info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ["com.adobe.pdf"],
        ]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        documents(in: sender).isEmpty ? [] : .generic
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = documents(in: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
