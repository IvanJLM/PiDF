import AppKit
import PDFKit

/// Finds text in a document: a small search field floating at the top right,
/// with every match highlighted and the current one selected.
@MainActor
final class FindBar: NSVisualEffectView, NSSearchFieldDelegate {
    static let width: CGFloat = 300
    static let height: CGFloat = 36

    private weak var pdfView: PDFView?
    let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let arrows = NSSegmentedControl()
    private(set) var matches: [PDFSelection] = []
    private(set) var current = -1
    private var searched = ""
    private var searchTask: DispatchWorkItem?
    /// Called when the bar should close (Esc).
    var onClose: (() -> Void)?

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

        NotificationCenter.default.addObserver(self, selector: #selector(found(_:)), name: .PDFDocumentDidFindMatch, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(finished(_:)), name: .PDFDocumentDidEndFind, object: nil)
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

    /// Searches the whole document. The search runs in the background and
    /// the first match is shown as soon as it is found.
    func search(_ text: String) {
        guard let document = pdfView?.document else { return }
        if document.isFinding { document.cancelFindString() }
        searched = text
        matches = []
        current = -1
        pdfView?.highlightedSelections = nil
        guard !text.isEmpty else {
            count.stringValue = ""
            return
        }
        count.stringValue = "…"
        document.beginFindString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    /// Searches again, after the document was reloaded.
    func refresh() {
        if !searched.isEmpty { search(searched) }
    }

    @objc private func found(_ notification: Notification) {
        guard let document = notification.object as? PDFDocument, document === pdfView?.document,
              let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
        matches.append(selection)
        if current < 0 { select(0) } else { updateCount() }
    }

    @objc private func finished(_ notification: Notification) {
        guard let document = notification.object as? PDFDocument, document === pdfView?.document else { return }
        for match in matches { match.color = .findHighlightColor }
        pdfView?.highlightedSelections = matches
        if let current = matches.indices.contains(current) ? matches[current] : nil {
            pdfView?.setCurrentSelection(current, animate: false)
        }
        updateCount()
    }

    private func updateCount() {
        if matches.isEmpty {
            count.stringValue = searched.isEmpty ? "" : (pdfView?.document?.isFinding == true ? "…" : "Not found")
        } else {
            count.stringValue = "\(current + 1) of \(matches.count)"
        }
    }

    private func select(_ index: Int) {
        guard !matches.isEmpty, let pdfView else { return }
        current = (index + matches.count) % matches.count
        let match = matches[current]
        pdfView.setCurrentSelection(match, animate: false)
        pdfView.go(to: match)
        updateCount()
    }

    /// Shows the matches again, after the tab came back from the background.
    func reapply() {
        guard !matches.isEmpty else { return }
        pdfView?.highlightedSelections = matches
        if matches.indices.contains(current) { pdfView?.setCurrentSelection(matches[current], animate: false) }
    }

    func next() { select(current + 1) }
    func previous() { select(current - 1) }

    /// Clears the highlights and stops any search still running.
    func clear() {
        searchTask?.cancel()
        if let document = pdfView?.document, document.isFinding { document.cancelFindString() }
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
