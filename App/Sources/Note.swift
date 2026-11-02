import AppKit
import PDFKit

/// A note made in PiDF: a FreeText annotation PiDF draws itself, so the
/// yellow fits its text closely (PDFKit puts the first line well below the
/// top edge, the lower the larger the typeface's ascender). PDFKit writes
/// this drawing into the file as the note's appearance, which Preview,
/// other viewers and PiDF itself show from then on, also when the note is
/// moved.
final class Note: PDFAnnotation {
    /// Its text, broken into the lines it was laid out in.
    var lines: [String] = []
    /// How many degrees its page was turned when it was made.
    var rotation = 0

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        Marks.draw(self, in: context)
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
