import Foundation

/// Remembers where each document was left, for the last 200 documents: the
/// page, the spot on it and the zoom.
enum ReadingPositions {
    static let key = "ReadingPositions"
    static let limit = 200
    /// Where positions are kept; the tests use their own.
    nonisolated(unsafe) static var defaults = UserDefaults.standard

    struct Position: Equatable {
        var page: Int
        /// The spot on the page at the top of the window; nil for its top.
        var point: CGPoint? = nil
        /// The zoom; nil when the pages fit the window.
        var scale: CGFloat? = nil
    }

    /// Where `url` was left, if not at the start with the pages fitted.
    static func position(for url: URL, defaults: UserDefaults = ReadingPositions.defaults) -> Position? {
        let entries = defaults.array(forKey: key) as? [[String: Any]] ?? []
        guard let entry = entries.first(where: { $0["path"] as? String == url.path }),
              let page = entry["page"] as? Int else { return nil }
        var position = Position(page: page)
        if let x = entry["x"] as? Double, let y = entry["y"] as? Double { position.point = CGPoint(x: x, y: y) }
        if let scale = entry["scale"] as? Double, scale > 0 { position.scale = scale }
        return position
    }

    static func page(for url: URL, defaults: UserDefaults = ReadingPositions.defaults) -> Int? {
        position(for: url, defaults: defaults)?.page
    }

    static func save(_ position: Position, for url: URL, defaults: UserDefaults = ReadingPositions.defaults) {
        var entries = (defaults.array(forKey: key) as? [[String: Any]] ?? []).filter { $0["path"] as? String != url.path }
        if position != Position(page: 0) {
            var entry: [String: Any] = ["path": url.path, "page": position.page]
            if let point = position.point { entry["x"] = Double(point.x); entry["y"] = Double(point.y) }
            if let scale = position.scale { entry["scale"] = Double(scale) }
            entries.insert(entry, at: 0)
        }
        defaults.set(Array(entries.prefix(limit)), forKey: key)
    }

    static func save(_ page: Int, for url: URL, defaults: UserDefaults = ReadingPositions.defaults) {
        save(Position(page: page), for: url, defaults: defaults)
    }
}
