import AppKit
import XCTest
@testable import PiDF

/// What the tests keep outside the project folder, and its removal: when a
/// run ends, nothing of it stays on the Mac, also when tests fail. A new
/// test takes its preferences and its folders from here, never from
/// `UserDefaults(suiteName:)` or the temporary folder directly.
///
/// The tests run inside PiDF itself, so `UserDefaults.standard` holds the
/// settings of the real app. Reading positions and the window frame are
/// kept in memory instead (`defaults()`); a setting a test has to change in
/// the app's own is put back (`restore(setting:after:)`).
enum Scratch {
    /// Every folder of the tests is in this one, in the temporary folder.
    private static let root = FileManager.default.temporaryDirectory.appendingPathComponent("PiDFTests")
    private static let app = Bundle.main.bundleIdentifier ?? "com.ivanjlm.pidf"
    /// The settings of the real app as the run found them.
    nonisolated(unsafe) private static var settings: [String: Any]?

    /// Empty preferences for reading positions and the window frame. They
    /// live in memory: a suite on disk leaves an empty file behind even when
    /// it is removed.
    @discardableResult
    static func defaults() -> UserDefaults {
        let defaults = MemoryDefaults()
        ReadingPositions.defaults = defaults
        WindowFrame.defaults = defaults
        return defaults
    }

    /// A folder of its own for `test`, removed when the test ends.
    static func folder(_ test: XCTestCase) throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Lets `test` change the setting `key` of the app itself: it is back as
    /// it was when the test ends.
    static func restore(setting key: String, after test: XCTestCase) {
        let stored = UserDefaults.standard.object(forKey: key)
        test.addTeardownBlock { UserDefaults.standard.set(stored, forKey: key) }
    }

    /// Before the first test.
    fileprivate static func begin() {
        settings = UserDefaults.standard.persistentDomain(forName: app) ?? [:]
        defaults()
    }

    /// After the last test: the Mac as the run found it.
    fileprivate static func end() {
        // AppKit keeps settings of its own among the app's (the folder of
        // the last save panel): back as they were. Positions and the frame
        // are never written there by the tests, and PiDF itself may be
        // running and saving them meanwhile.
        if let before = settings {
            let now = UserDefaults.standard.persistentDomain(forName: app) ?? [:]
            let kept = [ReadingPositions.key, WindowFrame.key]
            for key in Set(before.keys).union(now.keys).subtracting(kept)
            where before[key] as? NSObject != now[key] as? NSObject {
                UserDefaults.standard.set(before[key], forKey: key)
            }
            // Written before the tests' process goes, not a few seconds later.
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        }
        try? FileManager.default.removeItem(at: root)
        // Where AppKit keeps the state of the windows of a test run.
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("\(app).savedState"))
    }
}

/// Preferences that never reach the disk.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func object(forKey key: String) -> Any? { values[key] }
    override func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}

/// The run itself: XCTest creates it before the first test, as the principal
/// class of the test bundle (see project.yml), and tells it when the last
/// one is done.
@objc(PiDFTestRun)
final class TestRun: NSObject, XCTestObservation {
    override init() {
        super.init()
        Scratch.begin()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        Scratch.end()
    }
}
