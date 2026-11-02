import AppKit
import PDFKit

/// Finds text in a document: a small search field floating at the top right,
/// with the matches in view highlighted and the current one selected.
@MainActor
final class FindBar: NSVisualEffectView, NSSearchFieldDelegate {
    static let width: CGFloat = 300
    static let height: CGFloat = 36

    private weak var pdfView: PDFView?
    let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let arrows = NSSegmentedControl()
    /// In page order.
    private(set) var matches: [FindMatch] = []
    private(set) var current = -1
    private var searched = ""
    private var searchTask: DispatchWorkItem?
    /// The search running over the file, if any.
    private var offScreen: OffScreenSearch?
    /// Counts the searches: the pages of an earlier one are dropped.
    private var searchNumber = 0
    private(set) var isSearching = false
    /// Whether the last search went through the file (used by the tests).
    private(set) var searchedOffScreen = false
    /// A search stopped before its end, by the tab going to the background.
    private var interrupted = false
    /// The pages whose matches are highlighted.
    private var highlighted: ClosedRange<Int>?
    private var highlightsPending = false
    private weak var followedClipView: NSClipView?
    /// Called when the bar should close (Esc).
    var onClose: (() -> Void)?
    /// Opens the file for another thread, when the file is what's on screen.
    var fileOpener: (() -> (@Sendable () -> PDFDocument?)?)?

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        field.placeholderString = "Find"
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.delegate = self
        field.focusRingType = .none
        field.controlSize = .regular
        field.target = self
        field.action = #selector(fieldChanged(_:))

        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)

        arrows.segmentCount = 2
        arrows.trackingMode = .momentary
        arrows.segmentStyle = .separated
        arrows.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous"), forSegment: 0)
        arrows.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next"), forSegment: 1)
        arrows.setWidth(24, forSegment: 0)
        arrows.setWidth(24, forSegment: 1)
        arrows.controlSize = .small
        arrows.target = self
        arrows.action = #selector(arrowClicked(_:))

        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        count.translatesAutoresizingMaskIntoConstraints = false
        count.widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        let stack = NSStackView(views: [field, count, arrows])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)

    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Searching

    @objc private func fieldChanged(_ sender: Any?) {
        // Typing searches after a short pause, Return searches right away.
        searchTask?.cancel()
        let text = field.stringValue
        let task = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.search(text) } }
        searchTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }

    /// Searches the whole document, on other threads when the file is what's
    /// on screen. The first match is shown as soon as it is found.
    func search(_ text: String) {
        stopSearching()
        searched = text
        matches = []
        current = -1
        interrupted = false
        highlighted = nil
        pdfView?.highlightedSelections = nil
        guard !text.isEmpty else {
            count.stringValue = ""
            return
        }
        guard let document = pdfView?.document else {
            interrupted = true
            return
        }
        count.stringValue = "…"
        isSearching = true
        searchNumber += 1
        let number = searchNumber
        if let open = fileOpener?() {
            searchedOffScreen = true
            let search = OffScreenSearch(text: text, pageCount: document.pageCount, open: open) { [weak self] found, last in
                guard let self, number == self.searchNumber else { return }
                self.add(found, last: last)
            }
            offScreen = search
            search.start()
        } else {
            searchedOffScreen = false
            searchShown(document, from: 0, number: number)
        }
    }

    /// The document on screen has what the file hasn't (changes not saved yet,
    /// text recognized in a scan): its pages are read on this thread, a few
    /// milliseconds per turn of the run loop.
    private func searchShown(_ document: PDFDocument, from first: Int, number: Int) {
        let started = CFAbsoluteTimeGetCurrent()
        var index = first
        var found: [FindMatch] = []
        while index < document.pageCount, CFAbsoluteTimeGetCurrent() - started < 0.008 {
            found += TextSearch.matches(of: searched, onPageAt: index, of: document)
            index += 1
        }
        let last = index >= document.pageCount
        add(found, last: last)
        guard !last else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, number == self.searchNumber else { return }
                self.searchShown(document, from: index, number: number)
            }
        }
    }

    private func add(_ found: [FindMatch], last: Bool) {
        matches += found
        if last {
            isSearching = false
            offScreen = nil
        }
        if let first = found.first, let last = found.last, highlighted?.overlaps(first.page...last.page) == true {
            highlighted = nil
            updateHighlightsSoon()
        }
        if current < 0, !matches.isEmpty { select(0) }
        updateCount()
    }

    private func stopSearching() {
        searchNumber += 1
        offScreen?.cancel()
        offScreen = nil
        isSearching = false
    }

    /// Searches again, after the document was reloaded.
    func refresh() {
        if !searched.isEmpty { search(searched) }
    }

    /// The tab is going to the background, and nothing may read its document
    /// from now on: another thread may be writing it. It goes on when it's back.
    func interrupt() {
        guard isSearching else { return }
        stopSearching()
        interrupted = true
    }

    private func updateCount() {
        if matches.isEmpty {
            count.stringValue = searched.isEmpty ? "" : (isSearching ? "…" : "Not found")
        } else {
            count.stringValue = "\(current + 1) of \(matches.count)"
        }
    }

    private func select(_ index: Int) {
        guard !matches.isEmpty, let pdfView else { return }
        current = (index + matches.count) % matches.count
        if let selection = selection(for: matches[current]) {
            pdfView.setCurrentSelection(selection, animate: false)
            pdfView.go(to: selection)
        }
        updateHighlightsSoon()
        updateCount()
    }

    /// Nil for a match the page's text doesn't have (a file read while
    /// another app was changing it).
    private func selection(for match: FindMatch) -> PDFSelection? {
        guard let page = pdfView?.document?.page(at: match.page), NSMaxRange(match.range) <= page.numberOfCharacters else { return nil }
        return page.selection(for: match.range)
    }

    /// PDFView's own notification doesn't tell when scrolling brings in a page.
    private func followScrolling() {
        guard let clipView = pdfView?.documentView?.enclosingScrollView?.contentView, clipView !== followedClipView else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: followedClipView)
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: clipView)
        followedClipView = clipView
    }

    @objc private func scrolled(_ notification: Notification) { updateHighlightsSoon() }

    /// Once PDFView has finished moving, and only once however far it moved.
    private func updateHighlightsSoon() {
        guard !highlightsPending else { return }
        highlightsPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.highlightsPending = false
                self?.updateHighlights()
            }
        }
    }

    /// From the corners of the view: PDFView's own `visiblePages` is empty for
    /// a while after each move.
    private var pagesInView: ClosedRange<Int>? {
        guard let pdfView, let document = pdfView.document else { return nil }
        let corners = [NSPoint(x: pdfView.bounds.minX, y: pdfView.bounds.maxY), NSPoint(x: pdfView.bounds.maxX, y: pdfView.bounds.minY)]
        let indexes = corners.compactMap { pdfView.page(for: $0, nearest: true).map(document.index(for:)) }
        guard let first = indexes.min(), let last = indexes.max() else { return nil }
        return first...last
    }

    /// Each costs PDFKit almost a millisecond, and a page full of highlights
    /// (one letter searched) shows nothing more.
    private static let mostHighlights = 150

    /// Only the matches in view have a selection, made as they come into view.
    private func updateHighlights() {
        guard let pdfView, let document = pdfView.document else { return }
        followScrolling()
        let pages = pagesInView
        guard pages != highlighted else { return }
        highlighted = pages
        var selections: [PDFSelection] = []
        for index in pages.map(Array.init) ?? [] {
            guard let page = document.page(at: index) else { continue }
            var match = firstMatch(onPageAt: index)
            while match < matches.count, matches[match].page == index, selections.count < Self.mostHighlights {
                if NSMaxRange(matches[match].range) <= page.numberOfCharacters, let selection = page.selection(for: matches[match].range) {
                    selection.color = .findHighlightColor
                    selections.append(selection)
                }
                match += 1
            }
        }
        pdfView.highlightedSelections = selections
    }

    /// Where the matches of a page start: a binary search, there may be many.
    private func firstMatch(onPageAt page: Int) -> Int {
        var low = 0, high = matches.count
        while low < high {
            let middle = (low + high) / 2
            if matches[middle].page < page { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Shows the matches again, after the tab came back from the background.
    func reapply() {
        if interrupted { return refresh() }
        guard !matches.isEmpty else { return }
        highlighted = nil
        updateHighlightsSoon()
        if matches.indices.contains(current), let selection = selection(for: matches[current]) {
            pdfView?.setCurrentSelection(selection, animate: false)
        }
    }

    func next() { select(current + 1) }
    func previous() { select(current - 1) }

    /// Clears the highlights and stops any search still running.
    func clear() {
        searchTask?.cancel()
        stopSearching()
        interrupted = false
        highlighted = nil
        pdfView?.highlightedSelections = nil
        matches = []
        current = -1
    }

    @objc private func arrowClicked(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? previous() : next()
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if field.stringValue != searched {
                searchTask?.cancel()
                search(field.stringValue)
            } else if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                previous()
            } else {
                next()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
