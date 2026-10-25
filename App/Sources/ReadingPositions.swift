import Foundation

/// Remembers the page each document was left at, for the last 200 documents.
enum ReadingPositions {
    static let key = "ReadingPositions"
    static let limit = 200
    /// Where positions are kept; the tests use their own.
    nonisolated(unsafe) static var defaults = UserDefaults.standard

    /// The page index `url` was left at, if it was not the first.
    static func page(for url: URL, defaults: UserDefaults = ReadingPositions.defaults) -> Int? {
        let entries = defaults.array(forKey: key) as? [[String: Any]] ?? []
        return entries.first { $0["path"] as? String == url.path }?["page"] as? Int
    }

    static func save(_ page: Int, for url: URL, defaults: UserDefaults = ReadingPositions.defaults) {
        var entries = (defaults.array(forKey: key) as? [[String: Any]] ?? []).filter { $0["path"] as? String != url.path }
        if page > 0 { entries.insert(["path": url.path, "page": page], at: 0) }
        defaults.set(Array(entries.prefix(limit)), forKey: key)
    }
}
