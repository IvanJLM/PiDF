import AppKit

/// Remembers where the last document window was and how big it was, so a new
/// window opens the way the last one was left.
enum WindowFrame {
    static let key = "WindowFrame"
    /// Where the frame is kept; the tests use their own.
    nonisolated(unsafe) static var defaults = UserDefaults.standard

    static func save(_ frame: NSRect, defaults: UserDefaults = WindowFrame.defaults) {
        defaults.set(NSStringFromRect(frame), forKey: key)
    }

    /// The saved frame, moved and shrunk to fit the screen it is mostly on.
    /// None when it was never saved or its screen is gone.
    @MainActor
    static func saved(on screens: [NSScreen] = NSScreen.screens, defaults: UserDefaults = WindowFrame.defaults) -> NSRect? {
        guard let string = defaults.string(forKey: key) else { return nil }
        let frame = NSRectFromString(string)
        guard frame.width > 0, frame.height > 0 else { return nil }
        return fit(frame, in: screens.map(\.visibleFrame))
    }

    /// `frame` inside the area it overlaps most, or nil when less than a
    /// quarter of it is on any of them (a display that was disconnected).
    static func fit(_ frame: NSRect, in areas: [NSRect]) -> NSRect? {
        let overlap = { (area: NSRect) in area.intersection(frame).width * area.intersection(frame).height }
        guard let area = areas.max(by: { overlap($0) < overlap($1) }),
              overlap(area) >= frame.width * frame.height / 4 else { return nil }
        var fitted = frame
        fitted.size.width = min(frame.width, area.width)
        fitted.size.height = min(frame.height, area.height)
        fitted.origin.x = min(max(frame.minX, area.minX), area.maxX - fitted.width)
        fitted.origin.y = min(max(frame.minY, area.minY), area.maxY - fitted.height)
        return fitted
    }
}
