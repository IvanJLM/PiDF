import AppKit
import PDFKit

/// Where the links clicked in a document went from, and where Back came
/// from. Only links count: turning pages, scrolling, Go to Page or the page
/// selector leave no way back, so Back always returns to a link.
struct LinkHistory {
    /// More than anyone follows in one reading, few bytes each.
    static let limit = 50
    /// Where each link was clicked, the last one at the end.
    var back: [DocumentWindowController.Spot] = []
    /// Where Back left, for Forward.
    var forward: [DocumentWindowController.Spot] = []
}

extension DocumentWindowController {
    /// A link clicked in the document. One to another page or spot of it
    /// leaves the way back: the box at the bottom left, and ⌘[. Links to the
    /// web or to another file leave the document where it is, so no box.
    func follow(_ action: PDFAction) {
        if let named = action as? PDFActionNamed {
            switch named.name {
            case .goBack: return goBack(nil)
            case .goForward: return goForward(nil)
            default: break
            }
        }
        let origin = spot
        pdfView.follow(action)
        if hasMoved(from: origin) { followed(from: origin); return }
        // In case PDFKit ever goes there a moment later.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hasMoved(from: origin) else { return }
                self.followed(from: origin)
            }
        }
    }

    /// PDFKit's own way of going to a spot can shift it by a few points:
    /// less than a line isn't a link that went somewhere.
    private func hasMoved(from origin: Spot) -> Bool {
        let now = spot
        guard now.pageIndex == origin.pageIndex, abs(now.scale - origin.scale) < 0.001 else { return true }
        switch (now.point, origin.point) {
        case let (now?, origin?): return hypot(now.x - origin.x, now.y - origin.y) > 10
        case (nil, nil): return false
        default: return true
        }
    }

    private func followed(from origin: Spot) {
        links.back.append(origin)
        if links.back.count > LinkHistory.limit { links.back.removeFirst() }
        links.forward.removeAll()
        showWayBack()
    }

    /// ⌘[ and the box: back to where the last link was clicked, at the same
    /// spot and zoom.
    @objc func goBack(_ sender: Any?) {
        guard !isParked, let origin = links.back.popLast() else { return }
        links.forward.append(spot)
        move(to: origin)
        showWayBack()
    }

    /// ⌘]: where Back came from.
    @objc func goForward(_ sender: Any?) {
        guard !isParked, let next = links.forward.popLast() else { return }
        links.back.append(spot)
        move(to: next)
        showWayBack()
    }

    /// The box's ×, a page deleted, another app's version: no way back.
    func forgetLinks() {
        links = LinkHistory()
        showWayBack()
    }

    /// The box shows while there is a way back, with the page it goes to.
    func showWayBack() {
        guard let origin = links.back.last, let content = window?.contentView else {
            backBox?.removeFromSuperview()
            backBox = nil
            return
        }
        if let backBox { return backBox.show(page: origin.pageIndex + 1) }
        let box = BackBox()
        box.onBack = { [weak self] in self?.goBack(nil) }
        box.onClose = { [weak self] in self?.forgetLinks() }
        box.show(page: origin.pageIndex + 1)
        box.setFrameOrigin(NSPoint(x: BackBox.margin, y: BackBox.margin))
        box.autoresizingMask = [.maxXMargin, .maxYMargin]
        box.isHidden = pageSelector != nil
        box.alphaValue = 0
        content.addSubview(box)
        backBox = box
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            box.animator().alphaValue = 1
        }
    }
}

/// After a link, at the bottom left of the window: “Back to page 12” takes
/// the document back to where the link was clicked, the × stays where the
/// link went.
@MainActor
final class BackBox: NSVisualEffectView {
    static let margin: CGFloat = 12

    let backButton = NSButton(title: "", target: nil, action: nil)
    let closeButton = NSButton(title: "", target: nil, action: nil)
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        backButton.isBordered = false
        backButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.imageHugsTitle = true
        backButton.font = .systemFont(ofSize: NSFont.systemFontSize)
        backButton.contentTintColor = .labelColor
        backButton.toolTip = "Back to where you clicked the link (⌘[)"
        backButton.target = self
        backButton.action = #selector(back(_:))

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Stay Here")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Stay here"
        closeButton.target = self
        closeButton.action = #selector(stay(_:))

        addSubview(backButton)
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(page: Int) {
        backButton.title = "Back to page \(page)"
        backButton.sizeToFit()
        closeButton.sizeToFit()
        let back = backButton.frame.size, close = closeButton.frame.size
        let height = max(back.height, close.height) + 12
        backButton.setFrameOrigin(NSPoint(x: 10, y: ((height - back.height) / 2).rounded()))
        closeButton.setFrameOrigin(NSPoint(x: 10 + back.width + 8, y: ((height - close.height) / 2).rounded()))
        setFrameSize(NSSize(width: 10 + back.width + 8 + close.width + 8, height: height))
    }

    @objc private func back(_ sender: Any?) { onBack?() }
    @objc private func stay(_ sender: Any?) { onClose?() }
}
