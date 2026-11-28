import AppKit
import PDFKit
import XCTest
@testable import PiDF

/// A link to another page leaves a way back: the box at the bottom left and
/// ⌘[ return to where it was clicked, ⌘] to where it went.
@MainActor
final class LinkTests: XCTestCase {
    private var app: AppDelegate { NSApp.delegate as! AppDelegate }
    private typealias Doc = DocumentWindowController

    override func tearDown() async throws {
        for controller in app.controllers { controller.close() }
        await wait(0.1)
    }

    /// Where the links are on their pages.
    private let toSeven = NSRect(x: 60, y: 600, width: 200, height: 40)
    private let toNine = NSRect(x: 60, y: 300, width: 200, height: 40)

    /// Ten pages; page 1 links to page 7, page 7 to page 9.
    private func open() async throws -> Doc {
        let url = try Fixtures.pdf(in: try Scratch.folder(self), pageCount: 10)
        let document = try XCTUnwrap(PDFDocument(url: url))
        func link(on from: Int, at bounds: NSRect, to page: Int) throws {
            let link = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
            link.destination = PDFDestination(page: try XCTUnwrap(document.page(at: page)), at: NSPoint(x: 0, y: 500))
            try XCTUnwrap(document.page(at: from)).addAnnotation(link)
        }
        try link(on: 0, at: toSeven, to: 6)
        try link(on: 6, at: toNine, to: 8)
        XCTAssertTrue(document.write(to: url))
        let controller = app.open([url], nextTo: nil)[0]
        await wait(0.3)
        return controller
    }

    /// A real click, followed by PDFKit itself. The test window is never key,
    /// so it would keep a click to itself: the click goes to the view under
    /// it, which tracks the mouse up to the mouse-up queued before.
    private func click(_ rect: NSRect, onPage index: Int, in controller: Doc) async throws {
        await wait(0.1)
        let view = controller.pdfView
        let window = try XCTUnwrap(controller.window)
        let page = try XCTUnwrap(controller.pdf?.page(at: index))
        let point = view.convert(view.convert(NSPoint(x: rect.midX, y: rect.midY), from: page), to: nil)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let content = try XCTUnwrap(window.contentView)
        let hit = try XCTUnwrap(content.hitTest(try XCTUnwrap(content.superview).convert(point, from: nil)))
        XCTAssertTrue(hit.isDescendant(of: view), "the link is on screen")
        NSApp.postEvent(try mouse(.leftMouseUp), atStart: false)
        hit.mouseDown(with: try mouse(.leftMouseDown))
    }

    private func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }

    func testALinkLeavesAWayBackToTheSpotItWasClickedAt() async throws {
        let controller = try await open()
        controller.pdfView.scaleFactor = 1.5
        controller.pdfView.layoutDocumentView()
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        controller.pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: 700)))
        let origin = controller.spot
        XCTAssertNil(controller.backBox)
        XCTAssertFalse(controller.validateMenuItem(item(#selector(Doc.goBack(_:)))))

        try await click(toSeven, onPage: 0, in: controller)
        XCTAssertEqual(controller.pageIndex, 6, "PDFKit followed the link")
        let box = try XCTUnwrap(controller.backBox)
        XCTAssertEqual(box.backButton.title, "Back to page 1")
        XCTAssertFalse(box.isHidden)
        XCTAssertEqual(box.frame.origin, NSPoint(x: BackBox.margin, y: BackBox.margin), "at the bottom left")
        XCTAssertTrue(controller.validateMenuItem(item(#selector(Doc.goBack(_:)))))

        // Zoomed out on the way: back is as it was.
        controller.pdfView.autoScales = true
        box.backButton.performClick(nil)
        XCTAssertEqual(controller.pageIndex, 0)
        XCTAssertEqual(controller.pdfView.scaleFactor, 1.5, accuracy: 0.001)
        XCTAssertFalse(controller.pdfView.autoScales)
        let back = try XCTUnwrap(controller.spot.point)
        let clicked = try XCTUnwrap(origin.point)
        XCTAssertEqual(back.y, clicked.y, accuracy: 1, "the same spot, not only the page")
        XCTAssertNil(controller.backBox, "nothing more to go back to")
        XCTAssertNil(box.superview)

        // ⌘] goes where the link went, and the way back is there again.
        XCTAssertTrue(controller.validateMenuItem(item(#selector(Doc.goForward(_:)))))
        controller.goForward(nil)
        XCTAssertEqual(controller.pageIndex, 6)
        XCTAssertEqual(controller.backBox?.backButton.title, "Back to page 1")
    }

    func testLinksAfterLinksGoBackOneByOne() async throws {
        let controller = try await open()
        try await click(toSeven, onPage: 0, in: controller)
        try await click(toNine, onPage: 6, in: controller)
        XCTAssertEqual(controller.pageIndex, 8)
        XCTAssertEqual(controller.backBox?.backButton.title, "Back to page 7")
        controller.goBack(nil)  // ⌘[ does what the box does
        XCTAssertEqual(controller.pageIndex, 6)
        XCTAssertEqual(controller.backBox?.backButton.title, "Back to page 1")
        controller.backBox?.backButton.performClick(nil)
        XCTAssertEqual(controller.pageIndex, 0)
        XCTAssertNil(controller.backBox)
    }

    func testTurningPagesLeavesNoWayBack() async throws {
        let controller = try await open()
        controller.goToNextPage(nil)
        controller.go(toIndex: 5)
        controller.togglePageSelector(nil)
        controller.choosePage(3)
        XCTAssertEqual(controller.pageIndex, 3)
        XCTAssertNil(controller.backBox)
        XCTAssertFalse(controller.validateMenuItem(item(#selector(Doc.goBack(_:)))), "Back is for links only")
        controller.goBack(nil)
        XCTAssertEqual(controller.pageIndex, 3)
    }

    func testTheWayBackStaysThroughOtherMoves() async throws {
        let controller = try await open()
        try await click(toSeven, onPage: 0, in: controller)
        controller.goToNextPage(nil)
        controller.go(toIndex: 2)
        XCTAssertEqual(controller.backBox?.backButton.title, "Back to page 1")
        controller.goBack(nil)
        XCTAssertEqual(controller.pageIndex, 0)
    }

    func testTheCrossStaysWhereTheLinkWent() async throws {
        let controller = try await open()
        try await click(toSeven, onPage: 0, in: controller)
        controller.backBox?.closeButton.performClick(nil)
        XCTAssertEqual(controller.pageIndex, 6)
        XCTAssertNil(controller.backBox)
        XCTAssertFalse(controller.validateMenuItem(item(#selector(Doc.goBack(_:)))))
    }

    func testALinkToWhereTheDocumentIsLeavesNoBox() async throws {
        let controller = try await open()
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        controller.pdfView.go(to: page)
        await wait(0.1)
        let here = try XCTUnwrap(controller.spot.point)
        controller.pdfView.perform(PDFActionGoTo(destination: PDFDestination(page: page, at: here)))
        XCTAssertNil(controller.backBox)
    }

    func testTheDocumentsOwnBackButtonsUseTheWayBack() async throws {
        let controller = try await open()
        try await click(toSeven, onPage: 0, in: controller)
        controller.pdfView.perform(PDFActionNamed(name: .goBack))
        XCTAssertEqual(controller.pageIndex, 0)
        controller.pdfView.perform(PDFActionNamed(name: .goForward))
        XCTAssertEqual(controller.pageIndex, 6)
    }

    func testTheBoxStaysOutOfThePageSelector() async throws {
        let controller = try await open()
        try await click(toSeven, onPage: 0, in: controller)
        controller.togglePageSelector(nil)
        XCTAssertEqual(controller.backBox?.isHidden, true)
        controller.togglePageSelector(nil)
        XCTAssertEqual(controller.backBox?.isHidden, false)
    }

    func testDeletingAPageForgetsTheWayBack() async throws {
        let controller = try await open()
        try await click(toSeven, onPage: 0, in: controller)
        controller.deletePage(nil)
        XCTAssertNil(controller.backBox, "page 1 may not be page 1 any more")
    }

    func testTheWayBackIsKeptByEachTab() async throws {
        let controller = try await open()
        try await click(toSeven, onPage: 0, in: controller)
        let other = app.open([try Fixtures.pdf(in: try Scratch.folder(self), pageCount: 3)], nextTo: nil)[0]
        XCTAssertNil(other.backBox)
        XCTAssertFalse(other.validateMenuItem(item(#selector(Doc.goBack(_:)))))
        XCTAssertEqual(controller.links.back.count, 1)
    }
}
