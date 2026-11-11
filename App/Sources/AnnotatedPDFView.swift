import AppKit
import PDFKit

/// PDFView plus what notes need: a click selects one, a drag moves it, a
/// double click edits it. Text selection and everything else stay PDFKit's.
/// The window hands clicks over before PDFKit's own views see them.
final class AnnotatedPDFView: PDFView {
    /// The note the last click landed on, outlined; Delete removes it and
    /// ⌃N edits it.
    private(set) var selectedNote: PDFAnnotation?
    var onNoteMoved: (() -> Void)?
    var onNoteDoubleClicked: ((PDFAnnotation) -> Void)?
    /// The outline around the selected note, scrolling with the pages.
    private let outline = NSView()
    private var layoutObservers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        SharpNotes.install()
        super.init(frame: frame)
        outline.wantsLayer = true
        outline.layer?.borderWidth = 1.5
        outline.layer?.cornerRadius = 2
        outline.isHidden = true
        for name in [NSNotification.Name.PDFViewScaleChanged, .PDFViewDisplayModeChanged, .PDFViewDocumentChanged] {
            layoutObservers.append(NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.placeOutline()
                    if let self, name == .PDFViewScaleChanged { SharpNotes.refresh(in: self) }
                }
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        for observer in layoutObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func select(_ note: PDFAnnotation?) {
        selectedNote = note
        placeOutline()
    }

    /// Moved to a screen with other pixels per point.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        SharpNotes.refresh(in: self)
    }

    override func layout() {
        super.layout()
        placeOutline()
    }

    /// Puts the outline around the selected note, in the scrolling view
    /// that holds the pages, so it moves with them.
    private func placeOutline() {
        guard let note = selectedNote, let page = note.page, page.document === document, let documentView else {
            outline.isHidden = true
            return
        }
        if outline.superview !== documentView { documentView.addSubview(outline) }
        outline.layer?.borderColor = NSColor.controlAccentColor.cgColor
        outline.frame = documentView.convert(convert(note.bounds, from: page), from: self).insetBy(dx: -2, dy: -2)
        outline.isHidden = false
    }

    /// A drag in progress: the note, its page, where the mouse last was
    /// on the page, and whether the note moved at all.
    private var dragging: (note: PDFAnnotation, page: PDFPage, last: NSPoint, moved: Bool)?

    /// A click in the window, before any view sees it: true if it landed
    /// on a note, which is then selected and follows the mouse or, on a
    /// double click, is edited. Any other click lets the selected note go.
    func handleClick(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, let content = window.contentView, let frame = content.superview,
              let hit = content.hitTest(frame.convert(event.locationInWindow, from: nil)), hit.isDescendant(of: self) else { return false }
        let inView = convert(event.locationInWindow, from: nil)
        if let page = page(for: inView, nearest: false) {
            let inPage = convert(inView, to: page)
            if let note = page.annotation(at: inPage), Marks.isNote(note) {
                window.makeFirstResponder(self)
                select(note)
                if event.clickCount == 2 {
                    onNoteDoubleClicked?(note)
                } else {
                    dragging = (note, page, inPage, false)
                }
                return true
            }
        }
        if selectedNote != nil { select(nil) }
        return false
    }

    /// The mouse moved with the button down: the note follows, kept on its page.
    func handleDrag(_ event: NSEvent) -> Bool {
        guard var drag = dragging else { return false }
        let inPage = convert(convert(event.locationInWindow, from: nil), to: drag.page)
        let room = drag.page.bounds(for: .cropBox).insetBy(dx: Marks.margin, dy: Marks.margin)
        let frame = drag.note.bounds.offsetBy(dx: inPage.x - drag.last.x, dy: inPage.y - drag.last.y).kept(in: room)
        drag.last = inPage
        if frame != drag.note.bounds {
            drag.note.bounds = frame
            drag.moved = true
            annotationsChanged(on: drag.page)
            placeOutline()
        }
        dragging = drag
        return true
    }

    /// The button went up: the drag is over.
    func handleRelease(_ event: NSEvent) -> Bool {
        guard let drag = dragging else { return false }
        dragging = nil
        if drag.moved { onNoteMoved?() }
        return true
    }
}
