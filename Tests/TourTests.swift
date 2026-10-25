import AppKit
import XCTest
@testable import PiDF

/// Screenshots of the main states, for checking the look by eye. Runs only
/// with PIDF_TOUR set to a folder, while a script captures each window the
/// test asks for (see scripts/tour.sh).
@MainActor
final class TourTests: XCTestCase {
    private var app: AppDelegate { NSApp.delegate as! AppDelegate }

    /// Asks the script running the tour to capture `window`: writes a
    /// request file and waits until the script has taken the picture.
    private func shoot(_ window: NSWindow, _ name: String, into folder: String) async {
        await wait(0.6)
        let request = URL(fileURLWithPath: folder).appendingPathComponent("request")
        try? "\(window.windowNumber) \(name)".write(to: request, atomically: true, encoding: .utf8)
        await waitUntil(5) { !FileManager.default.fileExists(atPath: request.path) }
    }

    func testTour() async throws {
        guard let folder = ProcessInfo.processInfo.environment["PIDF_TOUR"] else { throw XCTSkip("PIDF_TOUR not set") }
        let stored = UserDefaults.standard.object(forKey: "TwoPages")
        defer { UserDefaults.standard.set(stored, forKey: "TwoPages") }
        ReadingPositions.defaults = UserDefaults(suiteName: "PiDFTests")!
        defer { ReadingPositions.defaults = UserDefaults(suiteName: "PiDFTests")! }
        let tmp = try Fixtures.folder(self)
        let pages = (1...8).map { "Page \($0): the quick brown fox jumps over the lazy dog" }
        let a = try Fixtures.pdf(at: tmp.appendingPathComponent("Report.pdf"), pages: pages)
        let b = try Fixtures.pdf(at: tmp.appendingPathComponent("Slides.pdf"), pages: pages, size: CGSize(width: 960, height: 540))
        let first = app.open([a], nextTo: nil)[0]
        let window = try XCTUnwrap(first.window)
        await shoot(window, "1-intro", into: folder)
        await wait(1.5)
        await shoot(window, "2-hidden", into: folder)
        let slides = app.open([b], nextTo: nil)[0]
        await shoot(try XCTUnwrap(slides.window), "3-tabs", into: folder)
        await wait(1.5)
        await shoot(try XCTUnwrap(slides.window), "3-tabs-hidden", into: folder)
        first.bringToFront()
        first.chrome.hide()
        first.showFind(nil)
        first.findBar?.field.stringValue = "fox"
        first.findBar?.search("fox")
        await shoot(window, "4-find", into: folder)
        first.closeFind(nil)
        first.toggleTwoPages(nil)
        await shoot(window, "5-two-pages", into: folder)
        first.toggleTwoPages(nil)
        first.showGoToPage(nil)
        await shoot(window, "6-go-to-page", into: folder)
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        let locked = try Fixtures.pdf(at: tmp.appendingPathComponent("Locked.pdf"), pages: ["Secret"], password: "fixture-pw")
        let lockedController = app.open([locked], nextTo: nil)[0]
        await shoot(try XCTUnwrap(lockedController.window), "7-password", into: folder)
        if let sheet = lockedController.window?.attachedSheet { lockedController.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        for controller in app.controllers { controller.close() }
    }
}
