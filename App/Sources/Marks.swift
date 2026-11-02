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
    /// A note's text size on a page without text, for an A4 page, before
    /// `noteSize`.
    static let defaultSize: CGFloat = 11
    /// How many points a note's text is at least smaller than the page's: a
    /// note is a comment beside the text, not more of it.
    static let smaller: CGFloat = 1.5
    /// The yellow around a note's text, as a share of the text size: to
    /// the left and right of its lines, above its capitals and below its
    /// descenders.
    static let padding: CGFloat = 0.35
    /// The distance between a note's lines, as a share of the text size.
    static let leading: CGFloat = 1.2

    /// Helvetica, at `size`: one of the fonts every PDF viewer has.
    static func helvetica(size: CGFloat) -> NSFont {
        NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
    }

    /// The size of a note's text for a page whose text is `size`: `smaller`
    /// less, down to whole points, since PDFKit writes a note's size in
    /// whole points (11 gives 9, 13 gives 11, 11.5 gives 10).
    static func noteSize(_ size: CGFloat) -> CGFloat {
        min(max((size - smaller).rounded(.down), 5), 30)
    }

    /// The type most of `page`'s text is set in, so a note reads like the
    /// document: its typeface when it is installed on this Mac (Helvetica
    /// otherwise), and its size, small in a dense manual, larger in slides,
    /// made a little smaller by `noteSize`. A page without text (a scan)
    /// takes 11-point Helvetica scaled to its width. PDFKit embeds the
    /// typeface in the note, so the note looks the same on a Mac without it.
    static func textFont(on page: PDFPage) -> NSFont {
        let fallback = helvetica(size: noteSize((defaultSize * page.bounds(for: .cropBox).width / 595).rounded()))
        guard let text = page.attributedString, text.length > 0 else { return fallback }
        struct Style: Hashable { let name: String; let size: CGFloat }
        var characters: [Style: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? NSFont, font.pointSize >= 3 else { return }
            characters[Style(name: font.fontName, size: (font.pointSize * 2).rounded() / 2), default: 0] += range.length
        }
        guard let style = characters.max(by: { $0.value < $1.value })?.key else { return fallback }
        let size = noteSize(style.size)
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

    /// From a page's own space to the page as it is seen, turned `rotation`
    /// degrees clockwise: x to the right and y up on screen.
    private static func seen(box: NSRect, rotation: Int) -> CGAffineTransform {
        switch rotation {
        case 90: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -box.minY, ty: box.maxX)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: box.maxX, ty: box.maxY)
        case 270: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: box.maxY, ty: -box.minX)
        default: .identity
        }
    }

    /// The corner of `bounds` that is seen as its top left, on a page turned
    /// `rotation` degrees whose box is `box`.
    static func topLeft(of bounds: NSRect, in box: NSRect, rotation: Int) -> NSPoint {
        let turn = seen(box: box, rotation: rotation)
        let frame = bounds.applying(turn)
        return NSPoint(x: frame.minX, y: frame.maxY).applying(turn.inverted())
    }

    /// A note saying `text` in `font`, its top left corner at `topLeft` on
    /// a page whose box is `box`. As wide as its text, up to the page's
    /// right margin; longer text wraps and the note grows down. On a page
    /// turned `rotation` degrees all of that is as seen on screen, so the
    /// note reads upright while the page is shown that way.
    static func note(_ text: String, font: NSFont, topLeft: NSPoint, in box: NSRect, rotation: Int = 0) -> PDFAnnotation {
        let turn = seen(box: box, rotation: rotation)
        let topLeft = topLeft.applying(turn)
        let room = box.applying(turn).insetBy(dx: margin, dy: margin)
        let inset = padding * font.pointSize
        let slack = 2 * inset + 0.5
        // From the point to the margin, but never narrower than about
        // fifteen words' worth (the note then moves left), nor than a word.
        var limit = max(room.maxX - topLeft.x, min(room.width, font.pointSize * 16)) - slack
        let longestWord = text.components(separatedBy: .whitespacesAndNewlines).map { width(of: $0, font) }.max() ?? 0
        limit = max(limit, longestWord)
        let lines = lines(of: text, font: font, width: limit)
        let widest = lines.map { width(of: $0, font) }.max() ?? 0
        // Rounded up, but never past the margin.
        let noteWidth = min(ceil(widest + slack), limit + slack)
        let annotation = Note(bounds: NSRect(x: 0, y: 0, width: noteWidth, height: 10), forType: .freeText, withProperties: nil)
        annotation.lines = lines
        annotation.rotation = rotation
        annotation.contents = text
        annotation.font = font
        annotation.fontColor = .black
        annotation.backgroundColor = yellow
        annotation.color = yellow
        annotation.border = PDFBorder()
        annotation.border?.lineWidth = 0
        annotation.userName = NSFullUserName()
        // From the top of the capitals of the first line to the bottom of
        // the descenders of the last, and the padding above and below.
        let height = 2 * inset + font.capHeight - font.descender + CGFloat(lines.count - 1) * leading * font.pointSize
        annotation.bounds = NSRect(x: topLeft.x, y: topLeft.y - height, width: noteWidth, height: height).kept(in: room).applying(turn.inverted())
        return annotation
    }

    /// `note` in yellow with its lines in black, as `note(_:font:topLeft:in:)`
    /// laid it out.
    static func draw(_ note: Note, in context: CGContext) {
        guard let font = note.font else { return }
        context.saveGState()
        context.setFillColor(yellow.cgColor)
        context.fill(note.bounds)
        // The text is set around the note's middle, turned back by as much
        // as its page was turned when the note was made.
        let sideways = note.rotation % 180 != 0
        let width = sideways ? note.bounds.height : note.bounds.width
        let height = sideways ? note.bounds.width : note.bounds.height
        context.translateBy(x: note.bounds.midX, y: note.bounds.midY)
        context.rotate(by: CGFloat(note.rotation) * .pi / 180)
        context.textMatrix = .identity
        var baseline = height / 2 - padding * font.pointSize - font.capHeight
        for line in note.lines {
            let text = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.black])
            context.textPosition = CGPoint(x: -width / 2 + padding * font.pointSize, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            baseline -= leading * font.pointSize
        }
        context.restoreGState()
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
