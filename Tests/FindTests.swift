import AppKit
import PDFKit
import XCTest
@testable import PiDF

/// Finding text: every match highlighted, ⌘G walks through them.
@MainActor
final class FindTests: XCTestCase {
    private var app: AppDelegate { NSApp.delegate as! AppDelegate }

    override func tearDown() async throws {
        for controller in app.controllers { controller.close() }
        await wait(0.1)
    }

    private func open(_ pages: [String]) throws -> DocumentWindowController {
        let url = try Fixtures.pdf(at: try Fixtures.folder(self).appendingPathComponent("find.pdf"), pages: pages)
        return app.open([url], nextTo: nil)[0]
    }

    func testFindsEveryMatchAndWalksThroughThem() async throws {
        let controller = try open(["alpha", "the Needle here", "beta", "gamma", "needle again", "delta"])
        controller.showFind(nil)
        let bar = try XCTUnwrap(controller.findBar)
        XCTAssertTrue(controller.window?.firstResponder === bar.field.currentEditor(), "ready to type")
        bar.search("needle")
        await waitUntil { controller.pdf?.isFinding == false && bar.matches.count == 2 }
        XCTAssertEqual(bar.matches.count, 2, "case-insensitive")
        XCTAssertEqual(controller.pdfView.highlightedSelections?.count, 2, "every match highlighted")
        XCTAssertEqual(controller.pdfView.currentSelection?.pages.first.flatMap { controller.pdf?.index(for: $0) }, 1)
        controller.findNext(nil)
        XCTAssertEqual(controller.pdfView.currentSelection?.pages.first.flatMap { controller.pdf?.index(for: $0) }, 4)
        controller.findNext(nil)
        XCTAssertEqual(bar.current, 0, "wraps around")
        controller.findPrevious(nil)
        XCTAssertEqual(bar.current, 1)
    }

    func testClosingFindClearsHighlights() async throws {
        let controller = try open(["one needle", "two"])
        controller.showFind(nil)
        controller.findBar?.search("needle")
        await waitUntil { controller.findBar?.matches.count == 1 && controller.pdf?.isFinding == false }
        controller.closeFind(nil)
        XCTAssertNil(controller.findBar)
        XCTAssertTrue(controller.pdfView.highlightedSelections?.isEmpty ?? true)
        XCTAssertTrue(controller.window?.firstResponder === controller.pdfView, "back to the document")
    }

    func testNothingFound() async throws {
        let controller = try open(["one", "two"])
        controller.showFind(nil)
        let bar = try XCTUnwrap(controller.findBar)
        bar.search("absent")
        await waitUntil { controller.pdf?.isFinding == false }
        await wait(0.1)
        XCTAssertTrue(bar.matches.isEmpty)
    }

    func testSelectedTextIsWhatYouLookFor() async throws {
        let controller = try open(["first word", "second word"])
        let selection = try XCTUnwrap(controller.pdf?.findString("second", withOptions: []).first)
        controller.pdfView.setCurrentSelection(selection, animate: false)
        controller.showFind(nil)
        XCTAssertEqual(controller.findBar?.field.stringValue, "second")
    }

    func testSelectedTextIsWhatCopyCopies() throws {
        // PDFView's own Copy (⌘C) copies the current selection; the clipboard
        // itself is left alone here.
        let controller = try open(["copy me please"])
        let selection = try XCTUnwrap(controller.pdf?.findString("copy me", withOptions: []).first)
        controller.pdfView.setCurrentSelection(selection, animate: false)
        XCTAssertEqual(controller.pdfView.currentSelection?.string, "copy me")
        XCTAssertTrue(controller.pdfView.responds(to: #selector(NSText.copy(_:))))
        XCTAssertTrue(controller.validateMenuItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")))
    }
}
