import AppKit
import PDFKit
import XCTest
@testable import PiDF

/// ⌃⌥ shows all the pages; ⌃⌥ or Esc goes back, a double click or Return to
/// the page chosen.
@MainActor
final class PageSelectorTests: XCTestCase {
    private var app: AppDelegate { NSApp.delegate as! AppDelegate }
    private typealias Doc = DocumentWindowController

    override func tearDown() async throws {
        for controller in app.controllers { controller.close() }
        await wait(0.1)
    }

    private func open(pages: Int) throws -> (Doc, NSWindow, URL) {
        let url = try Fixtures.pdf(in: try Fixtures.folder(self), pageCount: pages)
        let controller = app.open([url], nextTo: nil)[0]
        return (controller, try XCTUnwrap(controller.window), url)
    }

    private func flags(_ modifiers: NSEvent.ModifierFlags, in window: NSWindow) throws {
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59)))
    }

    private func tap(in window: NSWindow) throws {
        try flags(.control, in: window)
        try flags([.control, .option], in: window)
        try flags(.option, in: window)
        try flags([], in: window)
    }

    private func key(_ code: UInt16, _ characters: String, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws {
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
    }

    private func arrow(_ key: Int) -> String { String(Character(UnicodeScalar(UInt16(key))!)) }

    private func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }

    // MARK: The keys

    func testControlOptionAloneOpensAndCloses() throws {
        let (controller, window, _) = try open(pages: 5)
        XCTAssertNil(controller.pageSelector)
        try tap(in: window)
        XCTAssertNotNil(controller.pageSelector)
        XCTAssertEqual(controller.pdfView.isHidden, true, "nothing to draw underneath")
        try tap(in: window)
        XCTAssertNil(controller.pageSelector)
        XCTAssertEqual(controller.pdfView.isHidden, false)
    }

    func testItWaitsForTheKeysToGoUp() throws {
        let (controller, window, _) = try open(pages: 5)
        try flags([.control, .option], in: window)
        XCTAssertNil(controller.pageSelector, "may still become another shortcut")
        try flags([], in: window)
        XCTAssertNotNil(controller.pageSelector)
    }

    func testAnotherKeyOrAClickInBetweenIsAnotherShortcut() throws {
        let (controller, window, _) = try open(pages: 5)
        try flags([.control, .option], in: window)
        try key(0, "a", in: window, modifiers: [.control, .option])
        try flags([], in: window)
        XCTAssertNil(controller.pageSelector, "⌃⌥A")

        try flags([.control, .option], in: window)
        try flags([.control, .option, .command], in: window)
        try flags([], in: window)
        XCTAssertNil(controller.pageSelector, "⌃⌥⌘")

        // The click lands on a note, which PiDF handles itself: PDFView would
        // take a ⌃-click for a right click and wait in its context menu.
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        let note = controller.add(note: "Click here", at: NSPoint(x: 100, y: 600), on: page)
        controller.pdfView.select(nil)
        let inWindow = controller.pdfView.convert(controller.pdfView.convert(NSPoint(x: note.bounds.midX, y: note.bounds.midY), from: page), to: nil)
        try flags([.control, .option], in: window)
        window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: inWindow, modifierFlags: [.control, .option], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        XCTAssertTrue(controller.pdfView.selectedNote === note, "the click went to the note")
        window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: inWindow, modifierFlags: [.control, .option], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))
        try flags([], in: window)
        XCTAssertNil(controller.pageSelector, "⌃⌥ click")
    }

    func testRotatingWithControlOptionArrowDoesNotOpenIt() throws {
        let (controller, window, _) = try open(pages: 5)
        try flags([.control, .option], in: window)
        controller.rotatePageRight(nil)  // what the menu does with ⌃⌥→, without the window seeing the key
        try flags([], in: window)
        XCTAssertNil(controller.pageSelector)
        XCTAssertEqual(controller.pdf?.page(at: 0)?.rotation, 90)
    }

    func testOneModifierAloneDoesNothing() throws {
        let (controller, window, _) = try open(pages: 5)
        try flags(.control, in: window)
        try flags([], in: window)
        try flags(.option, in: window)
        try flags([], in: window)
        XCTAssertNil(controller.pageSelector)
    }

    func testTheFindFieldKeepsItsKeys() throws {
        let (controller, window, _) = try open(pages: 5)
        controller.showFind(nil)
        try tap(in: window)
        XCTAssertNil(controller.pageSelector)
    }

    // MARK: Going back and going to a page

    func testEscGoesBackToExactlyWhereTheDocumentWas() async throws {
        let (controller, window, _) = try open(pages: 20)
        controller.go(toIndex: 7)
        let clip = try XCTUnwrap(controller.pdfView.documentView?.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + 40))
        await wait(0.2)
        let spot = clip.bounds.origin
        let page = controller.pageIndex

        controller.togglePageSelector(nil)
        await wait(0.2)
        try key(53, "\u{1B}", in: window)
        XCTAssertNil(controller.pageSelector)
        await wait(0.2)
        XCTAssertEqual(controller.pageIndex, page)
        XCTAssertEqual(clip.bounds.origin, spot)
        XCTAssertTrue(window.firstResponder === controller.pdfView, "the keys are the document's again")
    }

    func testItOpensAtThePageOnScreen() async throws {
        let (controller, _, _) = try open(pages: 200)
        controller.go(toIndex: 150)
        controller.togglePageSelector(nil)
        let selector = try XCTUnwrap(controller.pageSelector)
        XCTAssertEqual(selector.selectedIndex, controller.pageIndex)
        await wait(0.2)
        XCTAssertTrue(selector.visibleIndexes.contains(controller.pageIndex), "in view: \(selector.visibleIndexes)")
    }

    func testReturnGoesToTheSelectedPage() async throws {
        let (controller, window, _) = try open(pages: 20)
        controller.togglePageSelector(nil)
        let selector = try XCTUnwrap(controller.pageSelector)
        selector.select(12, scrollingToIt: true)
        try key(36, "\r", in: window)
        XCTAssertNil(controller.pageSelector)
        await waitUntil { controller.pageIndex == 12 }
        XCTAssertEqual(controller.pageIndex, 12)
        XCTAssertEqual(controller.window?.subtitle, "Page 13 of 20")
    }

    func testADoubleClickGoesToThatPageAndOneClickOnlySelects() async throws {
        let (controller, window, _) = try open(pages: 20)
        controller.togglePageSelector(nil)
        let selector = try XCTUnwrap(controller.pageSelector)
        selector.layoutSubtreeIfNeeded()
        await wait(0.2)
        let frame = try XCTUnwrap(selector.grid.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))?.frame)
        let point = selector.grid.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ count: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0))
        }
        // Straight to the grid: the test host's window never becomes key, so
        // the window takes a first click as activating it.
        func click(_ count: Int) throws {
            selector.grid.mouseDown(with: try event(.leftMouseDown, count))
        }
        XCTAssertTrue(selector.grid.hitTest(selector.grid.convert(NSPoint(x: frame.midX, y: frame.midY), to: selector.grid.superview)) === selector.grid,
                      "clicks on a page reach the grid")
        try click(1)
        await wait(0.2)
        XCTAssertEqual(selector.selectedIndex, 2)
        XCTAssertNotNil(controller.pageSelector, "one click only selects")
        XCTAssertEqual(controller.pageIndex, 0)
        try click(2)
        await waitUntil { controller.pageIndex == 2 }
        XCTAssertNil(controller.pageSelector)
        XCTAssertEqual(controller.pageIndex, 2)
    }

    func testArrowsMoveTheSelectionNotTheDocument() async throws {
        let (controller, window, _) = try open(pages: 20)
        controller.togglePageSelector(nil)
        let selector = try XCTUnwrap(controller.pageSelector)
        await wait(0.2)
        try key(124, arrow(NSRightArrowFunctionKey), in: window, modifiers: [.numericPad, .function])
        await wait(0.1)
        XCTAssertEqual(selector.selectedIndex, 1)
        XCTAssertEqual(controller.pageIndex, 0, "the document stays")
        try key(123, arrow(NSLeftArrowFunctionKey), in: window, modifiers: [.numericPad, .function])
        await wait(0.1)
        XCTAssertEqual(selector.selectedIndex, 0)
    }

    // MARK: The thumbnails

    /// The box of a note's yellow in `image`.
    private func yellowBox(in image: NSImage) throws -> NSRect {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        var box = NSRect.null
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.redComponent > 0.9, color.blueComponent < 0.5 else { continue }
                box = box.union(NSRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return box
    }

    func testATurnedPageIsDrawnAsItIsShownWithItsNotesInShape() throws {
        let (controller, _, _) = try open(pages: 2)
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        controller.rotatePageRight(nil)
        controller.add(note: "A note wider than it is high", at: NSPoint(x: 100, y: 300), on: page, font: NSFont(name: "Helvetica", size: 12))
        let image = try XCTUnwrap(PageSelector.image(of: page, scale: 2))
        XCTAssertGreaterThan(image.size.width, image.size.height, "A4 turned: landscape")
        let shown = try yellowBox(in: image)
        XCTAssertGreaterThan(shown.width, 3 * shown.height, "not stretched: \(shown)")
        // The note is the same share of the page as on screen.
        XCTAssertEqual(shown.width / CGFloat(image.size.width * 2), page.annotations[0].bounds.height / 842, accuracy: 0.02)
        XCTAssertEqual(page.annotations[0].shouldDisplay, true, "still shown on the page")
    }

    func testAHighlightOnATurnedPageTurnsWithIt() throws {
        let (controller, _, _) = try open(pages: 2)
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        controller.rotatePageRight(nil)
        page.addAnnotation(Marks.highlight(lines: [NSRect(x: 60, y: 700, width: 300, height: 20)]))
        let shown = try yellowBox(in: try XCTUnwrap(PageSelector.image(of: page, scale: 2)))
        XCTAssertGreaterThan(shown.height, 3 * shown.width, "across the page, as on screen: \(shown)")
    }

    // MARK: Cost

    func testItDrawsOnlyThePagesInViewAndGoesWhenClosed() async throws {
        let (controller, _, _) = try open(pages: 300)
        controller.togglePageSelector(nil)
        weak var closed = controller.pageSelector
        var drawn = 0
        await waitUntil { (controller.pageSelector?.drawn ?? 0) > 0 }
        await wait(0.3)
        drawn = controller.pageSelector?.drawn ?? 0
        XCTAssertGreaterThan(drawn, 0)
        XCTAssertLessThan(drawn, 60, "not the 300 pages")
        controller.closePageSelector()
        XCTAssertNil(controller.pageSelector)
        await waitUntil { closed == nil }
        XCTAssertNil(closed, "nothing holds on to it")
    }

    func testAMarkNotSavedYetShowsInTheGrid() throws {
        let (controller, _, _) = try open(pages: 3)
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        controller.add(note: "Not saved", at: NSPoint(x: 100, y: 300), on: page)
        controller.go(toIndex: 1)
        controller.deletePage(nil)
        controller.togglePageSelector(nil)
        XCTAssertEqual(controller.pageSelector?.pageCount, 2, "the deleted page isn't in the file's copy yet")
    }

    // MARK: With everything else

    func testPageActionsWaitWhileItIsOpen() throws {
        let (controller, window, _) = try open(pages: 5)
        controller.togglePageSelector(nil)
        for action in [#selector(Doc.deletePage(_:)), #selector(Doc.rotatePageRight(_:)), #selector(Doc.goToNextPage(_:)),
                       #selector(Doc.showFind(_:)), #selector(Doc.zoomIn(_:))] {
            XCTAssertFalse(controller.validateMenuItem(item(action)), "\(action)")
        }
        let toggle = item(#selector(Doc.togglePageSelector(_:)))
        XCTAssertTrue(controller.validateMenuItem(toggle))
        XCTAssertEqual(toggle.state, .on)
        XCTAssertTrue(controller.validateMenuItem(item(#selector(Doc.printDocument(_:)))))
        try key(124, arrow(NSRightArrowFunctionKey), in: window, modifiers: [.control, .numericPad, .function])
        XCTAssertEqual(controller.pdf?.page(at: 0)?.rotation, 0, "⌃→ doesn't turn a page you can't see")
    }

    func testAnUndoShowsInTheGrid() throws {
        let (controller, _, _) = try open(pages: 5)
        controller.go(toIndex: 1)
        controller.deletePage(nil)
        controller.togglePageSelector(nil)
        let selector = try XCTUnwrap(controller.pageSelector)
        XCTAssertEqual(selector.pageCount, 4)
        controller.window?.undoManager?.undo()
        XCTAssertEqual(selector.pageCount, 5)
        XCTAssertNotNil(selector.selectedIndex)
    }

    func testAnotherAppsVersionShowsInTheGrid() async throws {
        let (controller, _, url) = try open(pages: 5)
        var reloads = 0
        controller.onReload = { reloads += 1 }
        controller.togglePageSelector(nil)
        let selector = try XCTUnwrap(controller.pageSelector)
        try Fixtures.pdf(at: url, pages: ["New 1", "New 2"])
        await waitUntil { reloads == 1 }
        XCTAssertEqual(selector.pageCount, 2)
        XCTAssertEqual(controller.pdfView.isHidden, true, "still open")
    }

    func testGoingToTheBackgroundClosesIt() throws {
        let (controller, _, _) = try open(pages: 5)
        controller.togglePageSelector(nil)
        controller.park()
        XCTAssertNil(controller.pageSelector)
        XCTAssertTrue(controller.isParked)
        controller.unpark()
        XCTAssertEqual(controller.pdfView.isHidden, false)
    }

    func testTheFindBarComesBackWithIt() throws {
        let (controller, _, _) = try open(pages: 5)
        controller.showFind(nil)
        controller.window?.makeFirstResponder(controller.pdfView)
        controller.togglePageSelector(nil)
        XCTAssertEqual(controller.findBar?.isHidden, true)
        controller.togglePageSelector(nil)
        XCTAssertEqual(controller.findBar?.isHidden, false)
    }

    func testALockedDocumentHasNoGrid() throws {
        let url = try Fixtures.pdf(at: try Fixtures.folder(self).appendingPathComponent("locked.pdf"), pages: ["Secret"], password: "fixture-pw")
        let controller = app.open([url], nextTo: nil)[0]
        XCTAssertFalse(controller.validateMenuItem(item(#selector(Doc.togglePageSelector(_:)))))
        controller.togglePageSelector(nil)
        XCTAssertNil(controller.pageSelector)
        if let window = controller.window, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
    }
}
