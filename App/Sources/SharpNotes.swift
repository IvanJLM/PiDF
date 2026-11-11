import AppKit
import ObjectiveC

/// Keeps notes as sharp as the page around them.
///
/// PDFView draws each note (any FreeText, also one from another app) into
/// a layer of its own, `PDFPageLayerAnnotationEffect`, whose resolution
/// should be the zoom times the screen's. macOS 27.0 leaves it at one pixel
/// per point whatever the zoom and screen, so notes come out blurred: five
/// times too coarse at 250 % on a Retina screen. Here every such layer is
/// raised to the resolution it is shown at, before it draws and whenever
/// the zoom or the screen changes. Where PDFKit already gets it right
/// (macOS 26) nothing changes: a layer is only ever raised, never lowered.
/// The class is private to PDFKit; without it this does nothing.
@MainActor
enum SharpNotes {
    nonisolated static let layerClass: AnyClass? = NSClassFromString("PDFPageLayerAnnotationEffect")

    /// Hooks the note layers once, before the first page is shown.
    static func install() {
        guard !installed, let layerClass else { return }
        installed = true
        // Before a layer draws, so it draws at the right resolution.
        hook(layerClass, #selector(CALayer.display), after: false) { layer in raise(layer, redraw: false) }
        // After PDFKit places it again (zoom, screen, a moved note).
        let update = NSSelectorFromString("update")
        if class_getInstanceMethod(layerClass, update) != nil {
            hook(layerClass, update, after: true) { layer in raise(layer, redraw: true) }
        }
    }

    private static var installed = false

    /// Raises every note layer of `view` to the resolution it's shown at,
    /// and redraws those that were too coarse.
    static func refresh(in view: NSView) {
        guard let layerClass, let root = view.layer else { return }
        func walk(_ layer: CALayer) {
            if layer.isKind(of: layerClass) { raise(layer, redraw: true) }
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
        }
        walk(root)
    }

    /// Pixels per point `layer` needs: how large one of its points is in
    /// the window, times the screen's pixels per point. Nil off screen.
    static func wantedScale(of layer: CALayer) -> CGFloat? {
        var current: CALayer? = layer
        while let candidate = current, !(candidate.delegate is NSView) { current = candidate.superlayer }
        guard let host = current, let view = host.delegate as? NSView, let window = view.window else { return nil }
        let inHost = layer.convert(CGRect(x: 0, y: 0, width: 1, height: 1), to: host)
        let inWindow = view.convert(inHost, to: nil)
        let points = max(abs(inWindow.width), abs(inWindow.height))
        guard points.isFinite, points > 0 else { return nil }
        return points * window.backingScaleFactor
    }

    /// Sets `layer` to the resolution it is shown at if it is coarser than
    /// that by more than a little; `redraw` draws it again at once.
    private static func raise(_ layer: CALayer, redraw: Bool) {
        guard let wanted = wantedScale(of: layer), layer.contentsScale < wanted * 0.95 else { return }
        layer.contentsScale = wanted
        if redraw { layer.setNeedsDisplay() }
    }

    /// Runs `extra` before or after `selector` on every instance of `cls`,
    /// a method that takes no arguments and returns nothing.
    private static func hook(_ cls: AnyClass, _ selector: Selector, after: Bool, _ extra: @escaping @MainActor (CALayer) -> Void) {
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        // The implementation this class runs now, its own or inherited.
        let original = unsafeBitCast(method_getImplementation(method), to: Function.self)
        let block: @convention(block) (AnyObject) -> Void = { object in
            // Only on the main thread, where the window may be asked.
            let layer = Thread.isMainThread ? object as? CALayer : nil
            if !after, let layer { MainActor.assumeIsolated { extra(layer) } }
            original(object, selector)
            if after, let layer { MainActor.assumeIsolated { extra(layer) } }
        }
        let replacement = imp_implementationWithBlock(block)
        // An inherited method gets an override in this class only.
        if !class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(method, replacement)
        }
    }
}
