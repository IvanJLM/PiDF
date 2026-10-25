import AppKit
import PDFKit
import XCTest
@testable import PiDF

/// The title bar: hidden into the document, back while the pointer is over
/// the top of the window, and nothing running while it is hidden.
@MainActor
final class ChromeTests: XCTestCase {
    private var app: AppDelegate { NSApp.delegate as! AppDelegate }

    override func tearDown() async throws {
        for controller in app.controllers { controller.close() }
        await wait(0.1)
    }

    private var titlebar: (NSWindow) -> NSView? = { $0.standardWindowButton(.closeButton)?.superview?.superview }

    func testTitleBarShowsBrieflyThenHides() async throws {
        let folder = try Fixtures.folder(self)
        let controller = app.open([try Fixtures.pdf(in: folder, pageCount: 3)], nextTo: nil)[0]
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(controller.chrome.isShown, "shown when the document opens")
        XCTAssertNotNil(controller.chrome.hideTimer)
        await waitUntil(4) { self.titlebar(window)?.isHidden == true }
        XCTAssertFalse(controller.chrome.isShown)
        XCTAssertEqual(titlebar(window)?.isHidden, true, "hidden, so clicks reach the document")
        XCTAssertNil(controller.chrome.hideTimer, "nothing runs while it is hidden")
    }

    func testPointerOverTheTopBringsItBack() async throws {
        let folder = try Fixtures.folder(self)
        let controller = app.open([try Fixtures.pdf(in: folder, pageCount: 3)], nextTo: nil)[0]
        let window = try XCTUnwrap(controller.window)
        let chrome = controller.chrome!
        chrome.hide()
        await wait(0.5)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                          trackingNumber: 0, userData: nil))
        chrome.mouseEntered(with: event)
        XCTAssertTrue(chrome.isShown)
        XCTAssertEqual(titlebar(window)?.isHidden, false)
        XCTAssertNil(chrome.hideTimer, "stays while the pointer is over it")
        chrome.mouseExited(with: event)
        let timer = try XCTUnwrap(chrome.hideTimer, "the pointer left: it goes shortly after")
        XCTAssertEqual(timer.fireDate.timeIntervalSinceNow, WindowChrome.hideDelay, accuracy: 0.2)
        XCTAssertGreaterThan(timer.tolerance, 0, "the wake-up may be grouped with others")
        chrome.stop()
        XCTAssertNil(chrome.hideTimer, "no timer outlives the window")
    }

    func testHoverZoneCoversTitleBarAndTabs() async throws {
        let folder = try Fixtures.folder(self)
        let first = app.open([try Fixtures.pdf(in: folder, name: "a.pdf", pageCount: 3)], nextTo: nil)[0]
        let content = try XCTUnwrap(first.window?.contentView)
        let alone = first.chrome.barHeight
        XCTAssertGreaterThan(alone, 20)
        XCTAssertEqual(first.chrome.zoneFrame.maxY, content.bounds.maxY, "at the very top")
        XCTAssertEqual(first.chrome.zoneFrame.height, alone + WindowChrome.slack, accuracy: 1)

        app.open([try Fixtures.pdf(in: folder, name: "b.pdf", pageCount: 3)], nextTo: nil)
        await wait(0.2)
        XCTAssertGreaterThan(first.chrome.barHeight, alone + 15, "the tab bar makes the title bar taller")
        XCTAssertEqual(first.chrome.zoneFrame.height, first.chrome.barHeight + WindowChrome.slack, accuracy: 1,
                       "the pointer over the tabs keeps them shown")
    }

    func testFullScreenLeavesTheTitleBarToMacOS() throws {
        let folder = try Fixtures.folder(self)
        let controller = app.open([try Fixtures.pdf(in: folder, pageCount: 3)], nextTo: nil)[0]
        let chrome = controller.chrome!
        chrome.suspend()
        XCTAssertNil(chrome.hideTimer)
        chrome.hide()
        XCTAssertTrue(chrome.isShown, "macOS shows it at the top of the screen")
        chrome.resume()
        XCTAssertNotNil(chrome.hideTimer)
    }
}
