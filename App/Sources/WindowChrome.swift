import AppKit

/// Hides the title bar, tabs included, into the document: it shows while the
/// pointer is over the top of the window and fades out half a second after
/// the pointer leaves. Nothing runs while it is hidden: no timers, no
/// mouse-moved events, only one tracking area at the top edge.
@MainActor
final class WindowChrome: NSResponder {
    static let hideDelay: TimeInterval = 0.5
    /// How long the title bar stays when a document opens, so it's found.
    static let introDelay: TimeInterval = 1.5
    /// Extra room under the title bar that still counts as "over it".
    static let slack: CGFloat = 6

    private weak var window: NSWindow?
    private let zone = HoverZone()
    /// The title bar is transparent, so its buttons and tabs sit on this
    /// material instead of on the page. It fades with them.
    private let backdrop = NSVisualEffectView()
    private(set) var hideTimer: Timer?
    private(set) var isShown = true
    /// True in full screen, where macOS manages the title bar itself.
    private var isSuspended = false
    private var layoutObservation: NSKeyValueObservation?

    init(window: NSWindow) {
        self.window = window
        super.init()
        guard let content = window.contentView else { return }
        backdrop.material = .titlebar
        backdrop.blendingMode = .withinWindow
        backdrop.state = .followsWindowActiveState
        backdrop.autoresizingMask = [.width, .minYMargin]
        content.addSubview(backdrop)
        zone.autoresizingMask = [.width, .minYMargin]
        content.addSubview(zone)
        zone.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        updateZone()
        // The title bar grows when the tab bar appears.
        layoutObservation = window.observe(\.contentLayoutRect) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateZone() } }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The title bar with its tab bar.
    private var bar: NSView? { window?.standardWindowButton(.closeButton)?.superview?.superview }

    /// Height of the title bar, tab bar included, over the content.
    var barHeight: CGFloat {
        guard let window, let content = window.contentView else { return 0 }
        return max(0, content.bounds.height - window.contentLayoutRect.maxY)
    }

    var zoneFrame: NSRect { zone.frame }

    private func updateZone() {
        guard let content = window?.contentView else { return }
        backdrop.frame = NSRect(x: 0, y: content.bounds.height - barHeight, width: content.bounds.width, height: barHeight)
        let height = max(barHeight, 28) + Self.slack
        zone.frame = NSRect(x: 0, y: content.bounds.height - height, width: content.bounds.width, height: height)
    }

    /// A document opened: the title bar shows for a moment, then goes.
    func introduce() {
        reveal()
        scheduleHide(after: Self.introDelay)
    }

    func reveal() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard !isShown, !isSuspended else { return }
        isShown = true
        bar?.isHidden = false
        backdrop.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            bar?.animator().alphaValue = 1
            backdrop.animator().alphaValue = 1
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard isShown, !isSuspended else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            bar?.animator().alphaValue = 0
            backdrop.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.bar?.isHidden = true  // clicks go to the document, not to invisible buttons
                self.backdrop.isHidden = true  // nothing left to draw
            }
        })
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideIfAway() }
        }
        timer.tolerance = 0.1  // lets macOS group the wake-up with others
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func hideIfAway() {
        hideTimer = nil
        guard let window else { return }
        let point = zone.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        // The pointer rests on the title bar: it stays until the pointer leaves.
        if zone.bounds.contains(point) || window.attachedSheet != nil { return }
        hide()
    }

    /// Full screen: macOS shows the title bar when the pointer reaches the top.
    func suspend() {
        hideTimer?.invalidate()
        hideTimer = nil
        isSuspended = true
        isShown = true
        bar?.isHidden = false
        bar?.alphaValue = 1
        backdrop.isHidden = true  // macOS draws its own title bar in full screen
    }

    func resume() {
        isSuspended = false
        backdrop.isHidden = false
        backdrop.alphaValue = 1
        updateZone()
        introduce()
    }

    /// The window is closing: no timer outlives it.
    func stop() {
        hideTimer?.invalidate()
        hideTimer = nil
        layoutObservation = nil
    }

    override func mouseEntered(with event: NSEvent) { reveal() }
    override func mouseExited(with event: NSEvent) { scheduleHide(after: Self.hideDelay) }
}

/// The band at the top of the window that brings the title bar back. It
/// only tracks the pointer; clicks go through to the document.
private final class HoverZone: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
