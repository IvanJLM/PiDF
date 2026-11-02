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
