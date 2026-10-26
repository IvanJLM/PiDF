import AppKit
import PDFKit

/// The two marks PiDF makes on a page: a yellow highlight over selected
/// text and a yellow note. One colour, one font, no options; both are
/// ordinary PDF annotations, so they travel with the file and show in
/// Preview or any other viewer.
enum Marks {
    /// The yellow of a highlight and of a note's background: #FFE34D, the
    /// highlight yellow of the user's own training documents.
    static let yellow = NSColor(srgbRed: 1, green: 0xE3 / 255.0, blue: 0x4D / 255.0, alpha: 1)
    /// How close to the page edge a note can go.
    static let margin: CGFloat = 12
    /// A note's text size on a page without text, for an A4 page.
    static let defaultSize: CGFloat = 11
    /// PDFKit draws a note's text 2 points in from each side.
    static let textInset: CGFloat = 2

    /// Helvetica, at `size`: one of the fonts every PDF viewer has.
    static func helvetica(size: CGFloat) -> NSFont {
        NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
    }

    /// The type most of `page`'s text is set in, so a note reads like the
    /// document: its typeface when it is installed on this Mac (Helvetica
    /// otherwise), and its size, small in a dense manual, larger in slides.
    /// A page without text (a scan) gets 11-point Helvetica scaled to its
    /// width. PDFKit embeds the typeface in the note, so the note looks the
    /// same on a Mac without it.
    static func textFont(on page: PDFPage) -> NSFont {
        let fallback = helvetica(size: min(max((defaultSize * page.bounds(for: .cropBox).width / 595).rounded(), 6), 30))
        guard let text = page.attributedString, text.length > 0 else { return fallback }
        struct Style: Hashable { let name: String; let size: CGFloat }
        var characters: [Style: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? NSFont, font.pointSize >= 3 else { return }
            characters[Style(name: font.fontName, size: (font.pointSize * 2).rounded() / 2), default: 0] += range.length
        }
        guard let style = characters.max(by: { $0.value < $1.value })?.key else { return fallback }
        let size = min(max(style.size, 5), 30)
        // Only a typeface the page really uses: PDFKit names a stand-in
        // (Times) for one this Mac lacks. And only one that is installed,
        // under that very name.
        if typefaces(of: page).contains(style.name), let font = NSFont(name: style.name, size: size), font.fontName == style.name {
            return font
        }
        return helvetica(size: size)
    }

    /// The names of the typefaces `page` uses, from its fonts and those of
    /// the forms it draws, without the "ABCDEF+" of an embedded subset.
    static func typefaces(of page: PDFPage) -> Set<String> {
        guard let resources = page.pageRef?.dictionary.flatMap({ dictionary($0, "Resources") }) else { return [] }
        var names = Set<String>()
        func collect(_ resources: CGPDFDictionaryRef) {
            guard let fonts = dictionary(resources, "Font") else { return }
            CGPDFDictionaryApplyBlock(fonts, { _, object, _ in
                var font: CGPDFDictionaryRef?
                var name: UnsafePointer<CChar>?
                if CGPDFObjectGetValue(object, .dictionary, &font), let font, CGPDFDictionaryGetName(font, "BaseFont", &name), let name {
                    var typeface = String(cString: name)
                    if let plus = typeface.firstIndex(of: "+"), typeface.distance(from: typeface.startIndex, to: plus) == 6 {
                        typeface = String(typeface[typeface.index(after: plus)...])
                    }
                    names.insert(typeface)
                    names.insert(typeface.replacingOccurrences(of: "-Identity-H", with: ""))
                }
                return true
            }, nil)
        }
        collect(resources)
        if let forms = dictionary(resources, "XObject") {
            CGPDFDictionaryApplyBlock(forms, { _, object, _ in
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(object, .stream, &stream), let stream, let form = CGPDFStreamGetDictionary(stream),
                   let inner = dictionary(form, "Resources") {
                    collect(inner)
                }
                return true
            }, nil)
        }
        return names
    }

    private static func dictionary(_ parent: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var child: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(parent, key, &child) ? child : nil
    }

    private static func width(of text: String, _ font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    /// `text` broken into lines no wider than `width` (wider only for a
    /// word that is), at spaces and at the newlines typed, as PDFKit does.
    static func lines(of text: String, font: NSFont, width: CGFloat) -> [String] {
        text.components(separatedBy: "\n").flatMap { paragraph -> [String] in
            var lines: [String] = []
            var line = ""
            for word in paragraph.components(separatedBy: " ") {
                let candidate = line.isEmpty ? word : line + " " + word
                if line.isEmpty || Self.width(of: candidate, font) <= width {
                    line = candidate
                } else {
                    lines.append(line)
                    line = word
                }
            }
            return lines + [line]
        }
    }

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

    /// A note saying `text` in `font`, its top left corner at `topLeft` on
    /// a page whose box is `box`. As wide as its text, up to the page's
    /// right margin; longer text wraps and the note grows down.
    static func note(_ text: String, font: NSFont, topLeft: NSPoint, in box: NSRect) -> PDFAnnotation {
        let room = box.insetBy(dx: margin, dy: margin)
        let slack = 2 * textInset + 0.5
        // From the point to the margin, but never narrower than about
        // fifteen words' worth (the note then moves left), nor than a word.
        var limit = max(room.maxX - topLeft.x, min(room.width, font.pointSize * 16)) - slack
        let longestWord = text.components(separatedBy: .whitespacesAndNewlines).map { width(of: $0, font) }.max() ?? 0
        limit = max(limit, longestWord)
        let lines = lines(of: text, font: font, width: limit)
        let widest = lines.map { width(of: $0, font) }.max() ?? 0
        // PDFKit has no more room than `limit` on a line, so it never fits
        // more on one than counted here, and never wraps sooner.
        let noteWidth = min(ceil(widest + slack), limit + slack)
        let annotation = PDFAnnotation(bounds: NSRect(x: 0, y: 0, width: noteWidth, height: 10), forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = font
        annotation.fontColor = .black
        annotation.backgroundColor = yellow
        annotation.color = yellow
        annotation.border = PDFBorder()
        annotation.border?.lineWidth = 0
        annotation.userName = NSFullUserName()
        // As tall as PDFKit draws the text, with as much room below it as
        // above: each typeface spaces its lines its own way.
        var trial = CGFloat(lines.count + 2) * font.pointSize * 2
        var height = trial
        for _ in 0..<3 {
            guard let ink = inkRows(of: annotation, height: trial) else { break }
            height = ink.bottom + ink.top
            // Text reaching the bottom of the trial box may go on below it.
            if ink.bottom < trial - font.pointSize * 2 { break }
            trial *= 2
        }
        annotation.bounds = NSRect(x: topLeft.x, y: topLeft.y - height, width: noteWidth, height: height).kept(in: room)
        return annotation
    }

    /// Where the text of `note` starts and ends below its top edge, drawn
    /// by PDFKit in a box `height` points tall, to a quarter of a point. A
    /// small grey bitmap, once per note made or edited.
    static func inkRows(of note: PDFAnnotation, height: CGFloat) -> (top: CGFloat, bottom: CGFloat)? {
        let scale: CGFloat = 4
        let size = NSSize(width: note.bounds.width, height: height)
        let page = PDFPage()
        page.setBounds(NSRect(origin: .zero, size: size), for: .mediaBox)
        note.bounds = NSRect(origin: .zero, size: size)
        page.addAnnotation(note)
        defer { page.removeAnnotation(note) }
        guard let context = CGContext(data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Row 0 of the bitmap's memory is its top edge. The yellow is light
        // grey here; the text is black.
        var first: Int?, last: Int?
        for row in 0..<context.height {
            let line = data + row * context.bytesPerRow
            if (0..<context.width).contains(where: { line[$0] < 128 }) {
                if first == nil { first = row }
                last = row
            }
        }
        guard let first, let last else { return nil }
        return (CGFloat(first) / scale, CGFloat(last + 1) / scale)
    }
}

/// The text box of the Add Note and Edit Note sheets: several lines, so a
/// long note stays in view while it's written. Return adds the note,
/// ⌥Return starts a new line, Esc cancels.
final class NoteEditor: NSScrollView, NSTextViewDelegate {
    let textView = NSTextView()
    /// Return: what the sheet's first button does.
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    init(text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 92))
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .bezelBorder
        drawsBackground = false
        textView.frame = NSRect(origin: .zero, size: contentSize)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        textView.delegate = self
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The note's text, without spaces or empty lines around it.
    var text: String { textView.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onCommit?()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            // ⌥Return, ⌃Return: a plain new line (not a line separator,
            // which other PDF viewers don't break on).
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
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
