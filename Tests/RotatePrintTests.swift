import AppKit
import PDFKit
import XCTest
@testable import PiDF

/// ⌃⇧← / ⌃⇧→ (and ⌃← / ⌃→) rotate the page on screen; ⌘P prints.
@MainActor
final class RotatePrintTests: XCTestCase {
    private var app: AppDelegate { NSApp.delegate as! AppDelegate }
    private typealias Doc = DocumentWindowController

    override func tearDown() async throws {
        for controller in app.controllers { controller.close() }
        await wait(0.1)
    }

    private func open(pages: Int, in folder: URL? = nil) throws -> (Doc, URL) {
        let url = try Fixtures.pdf(in: try folder ?? Fixtures.folder(self), pageCount: pages)
        return (app.open([url], nextTo: nil)[0], url)
    }

    private func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }

    private func key(_ key: Int, _ modifiers: NSEvent.ModifierFlags, code: UInt16) throws -> NSEvent {
        let characters = String(Character(UnicodeScalar(UInt16(key))!))
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers.union([.numericPad, .function]), timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func rotation(_ controller: Doc, _ index: Int) -> Int? { controller.pdf?.page(at: index)?.rotation }

    func testRotatesOnlyThePageOnScreenBothWays() throws {
        let (controller, _) = try open(pages: 3)
        controller.go(toIndex: 1)
        controller.rotatePageRight(nil)
        XCTAssertEqual(rotation(controller, 1), 90)
        XCTAssertEqual(rotation(controller, 0), 0)
        XCTAssertEqual(rotation(controller, 2), 0)
        XCTAssertEqual(controller.pageIndex, 1, "the rotated page stays on screen")
        XCTAssertTrue(controller.hasUnsavedAnnotations)
        controller.rotatePageLeft(nil)
        controller.rotatePageLeft(nil)
        XCTAssertEqual(rotation(controller, 1), 270)
    }

    func testTwoPagesRotateThePageTheTitleBarShows() throws {
        let (controller, _) = try open(pages: 6)
        controller.pdfView.displayMode = .twoUpContinuous
        controller.go(toIndex: 2)
        let index = controller.pageIndex
        controller.rotatePageRight(nil)
        XCTAssertEqual(rotation(controller, index), 90)
        XCTAssertEqual(controller.pageIndex, index)
    }

    func testControlArrowsRotateWhereMacOSLetsThemThrough() throws {
        let (controller, _) = try open(pages: 2)
        let window = try XCTUnwrap(controller.window)
        window.sendEvent(try key(NSRightArrowFunctionKey, .control, code: 124))
        XCTAssertEqual(rotation(controller, 0), 90)
        window.sendEvent(try key(NSLeftArrowFunctionKey, .control, code: 123))
        XCTAssertEqual(rotation(controller, 0), 0)
        XCTAssertEqual(controller.pageIndex, 0, "not a page turn")
    }

    func testTheMenuKeysAreControlShiftArrows() throws {
        let edit = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "Edit")?.submenu)
        let left = try XCTUnwrap(edit.item(withTitle: "Rotate Page Left"))
        let right = try XCTUnwrap(edit.item(withTitle: "Rotate Page Right"))
        XCTAssertEqual(left.action, #selector(Doc.rotatePageLeft(_:)))
        XCTAssertEqual(right.action, #selector(Doc.rotatePageRight(_:)))
        XCTAssertEqual(left.keyEquivalent, String(Character(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)))
        XCTAssertEqual(right.keyEquivalent, String(Character(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)))
        XCTAssertEqual(left.keyEquivalentModifierMask, [.control, .shift])
        XCTAssertEqual(right.keyEquivalentModifierMask, [.control, .shift])
    }

    func testRotationReachesTheFileAndUndoWorksAfterASave() throws {
        let (controller, url) = try open(pages: 3)
        controller.go(toIndex: 1)
        controller.rotatePageRight(nil)
        XCTAssertTrue(controller.saveAnnotations())
        XCTAssertEqual(PDFDocument(url: url)?.page(at: 1)?.rotation, 90)
        XCTAssertEqual(PDFDocument(url: url)?.page(at: 0)?.rotation, 0)
        XCTAssertEqual(controller.pageIndex, 1, "still there after the file is read again")

        controller.window?.undoManager?.undo()
        XCTAssertEqual(rotation(controller, 1), 0)
        controller.window?.undoManager?.redo()
        XCTAssertEqual(rotation(controller, 1), 90)
        controller.window?.undoManager?.undo()
        XCTAssertTrue(controller.saveAnnotations())
        XCTAssertEqual(PDFDocument(url: url)?.page(at: 1)?.rotation, 0)
    }

    func testEverySaveWritesTheRotationOnScreen() throws {
        let (controller, url) = try open(pages: 3)
        func saved() throws -> Int? {
            XCTAssertTrue(controller.saveAnnotations())
            return PDFDocument(url: url)?.page(at: 0)?.rotation
        }
        for expected in [90, 180, 270, 0] {
            controller.rotatePageRight(nil)
            XCTAssertEqual(try saved(), expected)
        }
        controller.rotatePageRight(nil)
        XCTAssertEqual(try saved(), 90)
        controller.rotatePageLeft(nil)
        controller.rotatePageLeft(nil)
        XCTAssertEqual(try saved(), 270)
        controller.window?.undoManager?.undo()
        XCTAssertEqual(try saved(), 0, "the last turn left goes back")
    }

    func testUndoNamesTheRotation() throws {
        let (controller, _) = try open(pages: 2)
        let window = try XCTUnwrap(controller.window)
        controller.rotatePageLeft(nil)
        let undo = item(Selector(("undo:")))
        XCTAssertTrue(window.validateMenuItem(undo))
        XCTAssertEqual(undo.title, "Undo Rotate Page")
    }

    func testReadOnlyFilesAndTheFindFieldKeepTheirRotation() throws {
        let folder = try Fixtures.folder(self)
        let (finding, _) = try open(pages: 2, in: folder)
        finding.showFind(nil)
        XCTAssertFalse(finding.validateMenuItem(item(#selector(Doc.rotatePageLeft(_:)))), "the keys select text in the field")
        let window = try XCTUnwrap(finding.window)
        window.sendEvent(try key(NSRightArrowFunctionKey, .control, code: 124))
        XCTAssertEqual(rotation(finding, 0), 0)

        let plain = try Fixtures.pdf(in: folder, name: "readonly.pdf", pageCount: 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: plain.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path) }
        let readOnly = app.open([plain], nextTo: nil)[0]
        XCTAssertFalse(readOnly.validateMenuItem(item(#selector(Doc.rotatePageRight(_:)))))
        readOnly.rotatePageRight(nil)
        XCTAssertEqual(rotation(readOnly, 0), 0)
        XCTAssertFalse(readOnly.hasUnsavedAnnotations)
    }

    func testAnotherAppsVersionForgetsTheRotations() async throws {
        let (controller, url) = try open(pages: 2)
        var reloads = 0
        controller.onReload = { reloads += 1 }
        controller.rotatePageRight(nil)
        try Fixtures.pdf(at: url, pages: ["New 1", "New 2"])
        await waitUntil { reloads == 1 }
        XCTAssertEqual(controller.window?.undoManager?.canUndo, false)
        XCTAssertEqual(rotation(controller, 0), 0)
    }

    // MARK: Notes on a rotated page

    /// The box of the ink of the note's yellow on `page`, drawn as seen on
    /// screen, with y up.
    private func yellowBox(on page: PDFPage) throws -> NSRect {
        let image = page.thumbnail(of: page.bounds(for: .cropBox).size.applying(page.rotation % 180 == 0 ? .identity : CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)), for: .cropBox)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        var box = NSRect.null
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.redComponent > 0.9, color.blueComponent < 0.5 else { continue }
                box = box.union(NSRect(x: x, y: bitmap.pixelsHigh - y - 1, width: 1, height: 1))
            }
        }
        return box
    }

    func testANoteOnARotatedPageIsLaidOutAsItIsSeen() throws {
        let box = NSRect(x: 0, y: 0, width: 595, height: 842)
        let font = try XCTUnwrap(NSFont(name: "Helvetica", size: 12))
        let flat = Marks.note("Upright", font: font, topLeft: NSPoint(x: 100, y: 500), in: box)
        for rotation in [90, 180, 270] {
            let note = Marks.note("Upright", font: font, topLeft: NSPoint(x: 100, y: 500), in: box, rotation: rotation)
            let sideways = rotation % 180 != 0
            XCTAssertEqual(note.bounds.width, sideways ? flat.bounds.height : flat.bounds.width, accuracy: 0.01, "\(rotation)°")
            XCTAssertEqual(note.bounds.height, sideways ? flat.bounds.width : flat.bounds.height, accuracy: 0.01, "\(rotation)°")
            let corner = Marks.topLeft(of: note.bounds, in: box, rotation: rotation)
            XCTAssertEqual(corner.x, 100, accuracy: 0.01, "\(rotation)°: starts at the pointer")
            XCTAssertEqual(corner.y, 500, accuracy: 0.01, "\(rotation)°: starts at the pointer")
        }
    }

    func testANoteStaysWithinARotatedPage() throws {
        let box = NSRect(x: 0, y: 0, width: 595, height: 842)
        let font = try XCTUnwrap(NSFont(name: "Helvetica", size: 12))
        let long = String(repeating: "word ", count: 40)
        for rotation in [90, 180, 270] {
            let note = Marks.note(long, font: font, topLeft: NSPoint(x: 590, y: 5), in: box, rotation: rotation)
            XCTAssertTrue(box.contains(note.bounds), "\(rotation)°: \(note.bounds)")
        }
    }

    func testARotatedPagesNoteIsWideOnScreenInTheSavedFile() throws {
        let (controller, url) = try open(pages: 1)
        controller.rotatePageRight(nil)
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        controller.add(note: "A note wider than it is high", at: NSPoint(x: 100, y: 300), on: page, font: NSFont(name: "Helvetica", size: 12))
        XCTAssertTrue(controller.saveAnnotations())
        let saved = try yellowBox(on: try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)))
        XCTAssertGreaterThan(saved.width, 3 * saved.height)
    }

    func testEditingANoteOnARotatedPageKeepsItsCorner() throws {
        let (controller, _) = try open(pages: 1)
        controller.rotatePageRight(nil)
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        let box = page.bounds(for: .cropBox)
        let note = controller.add(note: "First", at: NSPoint(x: 100, y: 300), on: page, font: NSFont(name: "Helvetica", size: 12))
        controller.replace(note, with: "Second, a good deal longer")
        let edited = try XCTUnwrap(page.annotations.first)
        XCTAssertEqual(edited.contents, "Second, a good deal longer")
        let corner = Marks.topLeft(of: edited.bounds, in: box, rotation: 90)
        XCTAssertEqual(corner.x, 100, accuracy: 0.01)
        XCTAssertEqual(corner.y, 300, accuracy: 0.01)
    }

    // MARK: Printing

    func testPrintIsOfferedForAnOpenDocument() throws {
        let (controller, _) = try open(pages: 2)
        XCTAssertTrue(controller.validateMenuItem(item(#selector(Doc.printDocument(_:)))))
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let file = try XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let print = try XCTUnwrap(file.item(withTitle: "Print…"))
        XCTAssertEqual(print.keyEquivalent, "p")
        XCTAssertEqual(print.keyEquivalentModifierMask, .command)
    }

    func testPrintIsNotOfferedForALockedDocument() throws {
        let url = try Fixtures.pdf(at: try Fixtures.folder(self).appendingPathComponent("locked.pdf"), pages: ["Secret"], password: "fixture-pw")
        let controller = app.open([url], nextTo: nil)[0]
        XCTAssertFalse(controller.validateMenuItem(item(#selector(Doc.printDocument(_:)))))
        if let window = controller.window, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
    }

    /// Prints to a PDF, without the sheet: every page comes out, with the
    /// marks the file doesn't have yet.
    func testPrintsTheDocumentAsItIsOnScreen() throws {
        let folder = try Fixtures.folder(self)
        let (controller, _) = try open(pages: 3, in: folder)
        controller.rotatePageRight(nil)
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        controller.add(note: "On paper too", at: NSPoint(x: 60, y: 300), on: page)

        let output = folder.appendingPathComponent("printed.pdf")
        let operation = try XCTUnwrap(controller.printOperation())
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.printInfo.jobDisposition = .save
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        XCTAssertTrue(operation.run())

        let printed = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(printed.pageCount, 3)
        XCTAssertEqual(printed.page(at: 1)?.string?.contains("Page 2"), true)
        XCTAssertEqual(printed.page(at: 0)?.string?.contains("On paper too"), true)
    }
}
