import AppKit
import PDFKit

/// The two marks PiDF makes on a page: a yellow highlight over selected
/// text and a yellow note. One colour, one font, no options; both are
/// ordinary PDF annotations, so they travel with the file and show in
/// Preview or any other viewer.
enum Marks {
    /// The yellow of a highlight and of a note's background.
    static let yellow = NSColor(srgbRed: 0.973, green: 0.906, blue: 0.463, alpha: 1)
    /// Helvetica is one of the fonts every PDF viewer has.
    static let font = NSFont(name: "Helvetica", size: 11) ?? .systemFont(ofSize: 11)
    /// Room around a note's text.
    static let padding = NSSize(width: 8, height: 4)
    /// How close to the page edge a note can go.
    static let margin: CGFloat = 12

    static func isHighlight(_ annotation: PDFAnnotation) -> Bool { annotation.type == "Highlight" }
    static func isNote(_ annotation: PDFAnnotation) -> Bool { annotation.type == "FreeText" }

    /// The lines a highlight covers, in page space (its bounds when it has
    /// no quadrilaterals).
    static func rects(of highlight: PDFAnnotation) -> [NSRect] {
        let points = (highlight.quadrilateralPoints ?? []).map(\.pointValue)
        guard points.count >= 4 else { return [highlight.bounds] }
        let origin = highlight.bounds.origin
        return stride(from: 0, to: points.count - 3, by: 4).map { i in
            let quad = points[i..<i + 4]
            let xs = quad.map(\.x), ys = quad.map(\.y)
            return NSRect(x: xs.min()! + origin.x, y: ys.min()! + origin.y, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    /// One highlight covering `lines`, the rectangles of the selected lines
    /// on one page, in page space.
    static func highlight(lines: [NSRect]) -> PDFAnnotation {
        let bounds = lines.reduce(NSRect.null) { $0.union($1) }
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.color = yellow
        // PDFKit takes the quadrilaterals relative to the bounds' origin.
        annotation.quadrilateralPoints = lines.flatMap { line -> [NSValue] in
            let rect = line.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            return [NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY),
                    NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY)].map(NSValue.init(point:))
        }
        annotation.userName = NSFullUserName()
        return annotation
    }

    /// A note saying `text`, its top left corner at `topLeft` on a page
    /// whose box is `box`, as wide as its text up to the page's width.
    static func note(_ text: String, topLeft: NSPoint, in box: NSRect) -> PDFAnnotation {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let room = box.insetBy(dx: margin, dy: margin)
        let width = min(ceil(attributed.size().width) + padding.width, max(room.width, 40))
        let textHeight = attributed.boundingRect(with: NSSize(width: width - padding.width, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin]).height
        let height = ceil(textHeight) + padding.height
        var frame = NSRect(x: topLeft.x, y: topLeft.y - height, width: width, height: height)
        frame = frame.kept(in: room)
        let annotation = PDFAnnotation(bounds: frame, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = font
        annotation.fontColor = .black
        annotation.backgroundColor = yellow
        annotation.color = yellow
        annotation.border = PDFBorder()
        annotation.border?.lineWidth = 0
        annotation.userName = NSFullUserName()
        return annotation
    }
}

extension NSRect {
    /// Moved, not resized, to lie within `room` (as far as it fits).
    func kept(in room: NSRect) -> NSRect {
        var frame = self
        if frame.maxX > room.maxX { frame.origin.x = room.maxX - frame.width }
        if frame.minX < room.minX { frame.origin.x = room.minX }
        if frame.maxY > room.maxY { frame.origin.y = room.maxY - frame.height }
        if frame.minY < room.minY { frame.origin.y = room.minY }
        return frame
    }
}

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
        super.init(frame: frame)
        outline.wantsLayer = true
        outline.layer?.borderWidth = 1.5
        outline.layer?.cornerRadius = 2
        outline.isHidden = true
        for name in [NSNotification.Name.PDFViewScaleChanged, .PDFViewDisplayModeChanged, .PDFViewDocumentChanged] {
            layoutObservers.append(NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeOutline() }
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
