import AppKit
import PDFKit
import XCTest
@testable import PiDF

/// Opening documents: tabs in one window, sized to the page, back at the
/// page they were left at, following changes on disk, unlocking.
@MainActor
final class DocumentTests: XCTestCase {
    private var app: AppDelegate { NSApp.delegate as! AppDelegate }
    private var positions: UserDefaults!

    override func setUp() async throws {
        UserDefaults.standard.removePersistentDomain(forName: "PiDFTests")
        positions = UserDefaults(suiteName: "PiDFTests")
        ReadingPositions.defaults = positions
    }

    override func tearDown() async throws {
        for controller in app.controllers { controller.close() }
        await wait(0.1)
        ReadingPositions.defaults = UserDefaults(suiteName: "PiDFTests")!
    }

    func testMacOSNeverQuitsPiDFBehindAHiddenWindow() {
        // With automatic termination, macOS may kill an app whose windows are
        // hidden or on another space.
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSSupportsAutomaticTermination"))
    }

    func testDocumentsOpenAsTabsOfOneWindow() throws {
        let folder = try Fixtures.folder(self)
        let a = try Fixtures.pdf(in: folder, name: "a.pdf", pageCount: 2)
        let b = try Fixtures.pdf(in: folder, name: "b.pdf", pageCount: 3)
        let c = try Fixtures.pdf(in: folder, name: "c.pdf", pageCount: 1)
        let opened = app.open([a, b], nextTo: nil)
        XCTAssertEqual(opened.count, 2)
        app.open([c], nextTo: nil)
        let windows = try XCTUnwrap(opened[0].window?.tabbedWindows)
        XCTAssertEqual(windows.count, 3, "every document is a tab of the same window")
        XCTAssertEqual(windows.map(\.title), ["a.pdf", "b.pdf", "c.pdf"], "tabs in the order they were opened")
    }

    func testOpeningAnOpenDocumentSelectsItsTab() throws {
        let folder = try Fixtures.folder(self)
        let a = try Fixtures.pdf(in: folder, name: "a.pdf", pageCount: 2)
        let b = try Fixtures.pdf(in: folder, name: "b.pdf", pageCount: 2)
        let first = app.open([a, b], nextTo: nil)[0]
        XCTAssertTrue(app.open([a], nextTo: nil).isEmpty, "not opened twice")
        XCTAssertEqual(app.controllers.count, 2)
        XCTAssertTrue(first.window?.tabGroup?.selectedWindow === first.window)
    }

    func testFilesThatAreNotPDFsAreNotOpened() throws {
        let folder = try Fixtures.folder(self)
        let fake = folder.appendingPathComponent("fake.pdf")
        try Data("not a pdf".utf8).write(to: fake)
        XCTAssertNil(PDFDocument(url: fake), "PiDF reports these instead of opening an empty window")
    }

    func testNewWindowShowsAWholePage() throws {
        let folder = try Fixtures.folder(self)
        let portrait = app.open([try Fixtures.pdf(in: folder, name: "p.pdf", pageCount: 2)], nextTo: nil)[0]
        let frame = try XCTUnwrap(portrait.window?.frame)
        let visible = try XCTUnwrap(portrait.window?.screen?.visibleFrame)
        XCTAssertEqual(frame.height, (visible.height * 0.92).rounded(), accuracy: 1)
        // The page's shape, within the minimum width (a small screen, as on CI).
        let shaped = (frame.height - 16) * 595 / 842 + 16
        XCTAssertEqual(frame.width, min(max(shaped, 480), visible.width * 0.92).rounded(), accuracy: 1,
                       "the window has the page's shape")
        XCTAssertTrue(portrait.pdfView.autoScales, "pages fit the width of the window")
    }

    func testDocumentFillsTheWindowUnderTheTitleBar() throws {
        let folder = try Fixtures.folder(self)
        let controller = app.open([try Fixtures.pdf(in: folder, pageCount: 2)], nextTo: nil)[0]
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(controller.pdfView.frame, window.contentView?.bounds)
        let scroll = try XCTUnwrap(controller.pdfView.documentView?.enclosingScrollView)
        XCTAssertEqual(scroll.contentInsets.top, 0, "no empty band where the hidden title bar is")
    }

    func testPageNumberInTheTitleBar() async throws {
        let folder = try Fixtures.folder(self)
        let controller = app.open([try Fixtures.pdf(in: folder, pageCount: 12)], nextTo: nil)[0]
        XCTAssertEqual(controller.window?.subtitle, "Page 1 of 12")
        controller.go(toIndex: 6)
        await waitUntil { controller.window?.subtitle == "Page 7 of 12" }
        XCTAssertEqual(controller.window?.subtitle, "Page 7 of 12")
        controller.go(toIndex: 99)
        XCTAssertEqual(controller.pageIndex, 11, "past the end: the last page")
    }

    func testReopensAtThePageItWasLeftAt() async throws {
        let folder = try Fixtures.folder(self)
        let url = try Fixtures.pdf(in: folder, pageCount: 20)
        let first = app.open([url], nextTo: nil)[0]
        first.go(toIndex: 13)
        first.close()
        await wait(0.1)
        XCTAssertEqual(ReadingPositions.page(for: url), 13)
        let again = app.open([url], nextTo: nil)[0]
        await wait(0.2)
        XCTAssertEqual(again.pageIndex, 13)
    }

    func testReadingPositionsAreBounded() {
        for index in 0..<(ReadingPositions.limit + 30) {
            ReadingPositions.save(3, for: URL(fileURLWithPath: "/tmp/\(index).pdf"))
        }
        XCTAssertEqual((positions.array(forKey: ReadingPositions.key) ?? []).count, ReadingPositions.limit)
        XCTAssertEqual(ReadingPositions.page(for: URL(fileURLWithPath: "/tmp/\(ReadingPositions.limit + 29).pdf")), 3, "newest kept")
        XCTAssertNil(ReadingPositions.page(for: URL(fileURLWithPath: "/tmp/0.pdf")), "oldest forgotten")
        ReadingPositions.save(0, for: URL(fileURLWithPath: "/tmp/5.pdf"))
        XCTAssertNil(ReadingPositions.page(for: URL(fileURLWithPath: "/tmp/5.pdf")), "the first page needs no entry")
    }

    func testFollowsChangesMadeByOtherApps() async throws {
        let folder = try Fixtures.folder(self)
        let url = try Fixtures.pdf(in: folder, pageCount: 6)
        let controller = app.open([url], nextTo: nil)[0]
        controller.go(toIndex: 4)
        var reloads = 0
        controller.onReload = { reloads += 1 }
        try Fixtures.pdf(at: url, pages: (1...9).map { "New page \($0)" })
        await waitUntil { reloads > 0 }
        XCTAssertEqual(controller.pdf?.pageCount, 9)
        XCTAssertEqual(controller.pageIndex, 4, "still at the same page")
        // Saved again: still followed after the file was replaced.
        try Fixtures.pdf(at: url, pages: ["Only page"])
        await waitUntil { reloads > 1 }
        XCTAssertEqual(controller.pdf?.pageCount, 1)
    }

    func testTwoPagesKeepsThePage() async throws {
        let stored = UserDefaults.standard.object(forKey: "TwoPages")
        defer { UserDefaults.standard.set(stored, forKey: "TwoPages") }
        let folder = try Fixtures.folder(self)
        let controller = app.open([try Fixtures.pdf(in: folder, pageCount: 30)], nextTo: nil)[0]
        controller.go(toIndex: 17)
        controller.toggleTwoPages(nil)
        XCTAssertEqual(controller.pdfView.displayMode, .twoUpContinuous)
        await wait(0.1)
        XCTAssertEqual(controller.pageIndex / 2, 17 / 2, "same spread")
        controller.toggleTwoPages(nil)
        XCTAssertEqual(controller.pdfView.displayMode, .singlePageContinuous)
    }

    func testProtectedDocumentsAskForThePassword() async throws {
        let folder = try Fixtures.folder(self)
        let url = try Fixtures.pdf(at: folder.appendingPathComponent("locked.pdf"), pages: ["Secret", "More"], password: "fixture-pw")
        let controller = app.open([url], nextTo: nil)[0]
        XCTAssertEqual(controller.pdf?.isLocked, true)
        await waitUntil { controller.window?.attachedSheet != nil }
        XCTAssertNotNil(controller.window?.attachedSheet, "a password sheet")
        XCTAssertFalse(controller.unlock(with: "wrong"))
        XCTAssertTrue(controller.unlock(with: "fixture-pw"))
        XCTAssertEqual(controller.pdf?.isLocked, false)
        XCTAssertEqual(controller.pdf?.page(at: 0)?.string?.contains("Secret"), true)
        if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
    }
}

/// Live Text only where it is needed: it doubles the memory of a window.
@MainActor
final class TextRecognitionTests: XCTestCase {
    private var app: AppDelegate { NSApp.delegate as! AppDelegate }

    override func tearDown() async throws {
        for controller in app.controllers { controller.close() }
        await wait(0.1)
    }

    func testDocumentsWithTextSkipRecognition() throws {
        let url = try Fixtures.pdf(in: try Fixtures.folder(self), pageCount: 3)
        let controller = app.open([url], nextTo: nil)[0]
        XCTAssertFalse(controller.recognizesText)
    }

    func testScannedDocumentsKeepRecognition() throws {
        let url = try Fixtures.pdf(at: try Fixtures.folder(self).appendingPathComponent("scan.pdf"), pages: ["", "", ""])
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(DocumentWindowController.needsTextRecognition(document), "no text: a scan")
        let controller = app.open([url], nextTo: nil)[0]
        XCTAssertTrue(controller.recognizesText)
    }
}

/// Tabs behind others let go of their rendered pages, and come back where
/// they were.
@MainActor
final class BackgroundTabTests: XCTestCase {
    private var app: AppDelegate { NSApp.delegate as! AppDelegate }

    override func setUp() async throws {
        UserDefaults.standard.removePersistentDomain(forName: "PiDFTests")
        ReadingPositions.defaults = UserDefaults(suiteName: "PiDFTests")!
    }

    override func tearDown() async throws {
        for controller in app.controllers { controller.close() }
        await wait(0.1)
        ReadingPositions.defaults = UserDefaults(suiteName: "PiDFTests")!
    }

    func testTabsInTheBackgroundLetGoOfTheirPages() async throws {
        let folder = try Fixtures.folder(self)
        let first = app.open([try Fixtures.pdf(in: folder, name: "a.pdf", pageCount: 20)], nextTo: nil)[0]
        first.go(toIndex: 12)
        first.actualSize(nil)
        let second = app.open([try Fixtures.pdf(in: folder, name: "b.pdf", pageCount: 5)], nextTo: nil)[0]
        await waitUntil { first.isParked }
        XCTAssertTrue(first.isParked, "behind the new tab")
        XCTAssertNil(first.pdfView.document, "nothing left to render")
        XCTAssertEqual(first.pdf?.pageCount, 20, "the document itself is kept")
        XCTAssertEqual(first.pageIndex, 12)
        XCTAssertFalse(second.isParked)

        first.bringToFront()
        await waitUntil { !first.isParked && second.isParked }
        XCTAssertNotNil(first.pdfView.document)
        XCTAssertEqual(first.pageIndex, 12, "back at the same page")
        XCTAssertEqual(first.pdfView.scaleFactor, 1, accuracy: 0.01, "and the same zoom")
        XCTAssertTrue(second.isParked)
    }

    func testBackgroundTabFollowsChangesToo() async throws {
        let folder = try Fixtures.folder(self)
        let url = try Fixtures.pdf(in: folder, name: "a.pdf", pageCount: 8)
        let first = app.open([url], nextTo: nil)[0]
        first.go(toIndex: 6)
        app.open([try Fixtures.pdf(in: folder, name: "b.pdf", pageCount: 2)], nextTo: nil)
        await waitUntil { first.isParked }
        var reloaded = false
        first.onReload = { reloaded = true }
        try Fixtures.pdf(at: url, pages: ["1", "2", "3"])
        await waitUntil { reloaded }
        XCTAssertEqual(first.pdf?.pageCount, 3)
        first.bringToFront()
        await waitUntil { !first.isParked }
        XCTAssertEqual(first.pageIndex, 2, "the new last page")
    }
}
