import AppKit
import PDFKit
import XCTest
@testable import PiDF

/// ← and → turn whole pages; ↑ and ↓ are left to PDFKit's small scroll.
@MainActor
final class KeyTests: XCTestCase {
    private var app: AppDelegate { NSApp.delegate as! AppDelegate }

    override func tearDown() async throws {
        for controller in app.controllers { controller.close() }
        await wait(0.1)
    }

    private func press(_ key: Int, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws {
        let characters = String(Character(UnicodeScalar(UInt16(key))!))
        let codes = [NSLeftArrowFunctionKey: 123, NSRightArrowFunctionKey: 124, NSDownArrowFunctionKey: 125, NSUpArrowFunctionKey: 126]
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers.union([.numericPad, .function]), timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(codes[key] ?? 0)))
        window.sendEvent(event)
    }

    private func open(pages: Int) throws -> (DocumentWindowController, NSWindow) {
        let url = try Fixtures.pdf(in: try Fixtures.folder(self), pageCount: pages)
        let controller = app.open([url], nextTo: nil)[0]
        return (controller, try XCTUnwrap(controller.window))
    }

    func testRightAndLeftArrowsTurnWholePages() async throws {
        let (controller, window) = try open(pages: 10)
        XCTAssertEqual(controller.pageIndex, 0)
        try press(NSRightArrowFunctionKey, in: window)
        await waitUntil { controller.pageIndex == 1 }
        XCTAssertEqual(controller.pageIndex, 1)
        try press(NSRightArrowFunctionKey, in: window)
        await waitUntil { controller.pageIndex == 2 }
        XCTAssertEqual(controller.pageIndex, 2)
        try press(NSLeftArrowFunctionKey, in: window)
        await waitUntil { controller.pageIndex == 1 }
        XCTAssertEqual(controller.pageIndex, 1)
    }

    func testArrowsWorkWhereverTheFocusIs() async throws {
        let (controller, window) = try open(pages: 10)
        window.makeFirstResponder(controller.pdfView.documentView)
        try press(NSRightArrowFunctionKey, in: window)
        await waitUntil { controller.pageIndex == 1 }
        XCTAssertEqual(controller.pageIndex, 1, "focus inside PDFKit's own view")
    }

    func testArrowsWithModifiersAreLeftAlone() async throws {
        let (controller, window) = try open(pages: 10)
        try press(NSRightArrowFunctionKey, in: window, modifiers: .shift)
        await wait(0.2)
        XCTAssertEqual(controller.pageIndex, 0)
    }

    func testArrowsMoveTheCaretWhileFinding() async throws {
        let (controller, window) = try open(pages: 10)
        controller.showFind(nil)
        let bar = try XCTUnwrap(controller.findBar)
        bar.field.stringValue = "abc"
        window.makeFirstResponder(bar.field)
        try press(NSRightArrowFunctionKey, in: window)
        await wait(0.2)
        XCTAssertEqual(controller.pageIndex, 0, "typing in the find field: the arrow is the field's")
    }

    func testUpAndDownStillScrollALittle() async throws {
        let (controller, window) = try open(pages: 10)
        let clip = try XCTUnwrap(controller.pdfView.documentView?.enclosingScrollView?.contentView)
        let before = clip.bounds.origin.y
        window.makeFirstResponder(controller.pdfView)
        try press(NSDownArrowFunctionKey, in: window)
        await wait(0.3)
        XCTAssertNotEqual(clip.bounds.origin.y, before, "↓ scrolls")
        XCTAssertEqual(controller.pageIndex, 0, "but only a little")
    }
}
