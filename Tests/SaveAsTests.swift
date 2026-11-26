import AppKit
import PDFKit
import XCTest
@testable import PiDF

/// ⇧⌘S: the document as it is on screen, in another file, which the tab
/// then shows. The original stays as it was last saved.
@MainActor
final class SaveAsTests: XCTestCase {
    private var app: AppDelegate { NSApp.delegate as! AppDelegate }
    private typealias Doc = DocumentWindowController

    override func setUp() async throws {
        UserDefaults.standard.removePersistentDomain(forName: "PiDFTests")
        ReadingPositions.defaults = UserDefaults(suiteName: "PiDFTests")!
    }

    override func tearDown() async throws {
        for controller in app.controllers { controller.close() }
        await wait(0.1)
    }

    private func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }
    private func notes(on page: PDFPage?) -> [PDFAnnotation] { (page?.annotations ?? []).filter(Marks.isNote) }

    private func secureField(in view: NSView?) -> NSSecureTextField? {
        guard let view else { return nil }
        if let field = view as? NSSecureTextField { return field }
        return view.subviews.lazy.compactMap { self.secureField(in: $0) }.first
    }

    func testTheMenuKeyIsShiftCommandS() throws {
        let file = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "File")?.submenu)
        let saveAs = try XCTUnwrap(file.item(withTitle: "Save As…"))
        XCTAssertEqual(saveAs.action, #selector(Doc.saveDocumentAs(_:)))
        XCTAssertEqual(saveAs.keyEquivalent, "s")
        XCTAssertEqual(saveAs.keyEquivalentModifierMask, [.command, .shift])
        let save = try XCTUnwrap(file.item(withTitle: "Save"))
        XCTAssertEqual(file.index(of: saveAs), file.index(of: save) + 1, "right below Save")
    }

    func testOfferedWithOrWithoutChanges() throws {
        let folder = try Fixtures.folder(self)
        let controller = app.open([try Fixtures.pdf(in: folder, pageCount: 2)], nextTo: nil)[0]
        XCTAssertFalse(controller.validateMenuItem(item(#selector(Doc.saveDocument(_:)))), "Save: nothing to save")
        XCTAssertTrue(controller.validateMenuItem(item(#selector(Doc.saveDocumentAs(_:)))), "Save As: a copy anyway")
        controller.togglePageSelector(nil)
        XCTAssertTrue(controller.validateMenuItem(item(#selector(Doc.saveDocumentAs(_:)))), "also from the page selector")
    }

    func testTheMarksGoToTheNewFileAndTheTabShowsIt() async throws {
        let folder = try Fixtures.folder(self)
        let original = try Fixtures.pdf(at: folder.appendingPathComponent("original.pdf"), pages: ["one", "two", "three"])
        let controller = app.open([original], nextTo: nil)[0]
        controller.add(note: "only in the copy", at: NSPoint(x: 80, y: 400), on: try XCTUnwrap(controller.pdf?.page(at: 1)))
        controller.deletePage(nil)  // the page on screen, the first
        controller.go(toIndex: 1)
        let copy = folder.appendingPathComponent("copy.pdf")

        try controller.save(as: copy)

        let written = try XCTUnwrap(PDFDocument(url: copy))
        XCTAssertEqual(written.pageCount, 2, "the page deleted isn't there")
        XCTAssertEqual(written.page(at: 0)?.string?.contains("two"), true)
        XCTAssertEqual(notes(on: written.page(at: 0)).first?.contents, "only in the copy")
        let untouched = try XCTUnwrap(PDFDocument(url: original))
        XCTAssertEqual(untouched.pageCount, 3, "the original stays as it was last saved")
        XCTAssertTrue((0..<3).allSatisfy { notes(on: untouched.page(at: $0)).isEmpty })

        XCTAssertEqual(controller.url, copy.standardizedFileURL)
        XCTAssertEqual(controller.window?.title, "copy.pdf")
        XCTAssertEqual(controller.window?.representedURL, copy.standardizedFileURL)
        XCTAssertFalse(controller.hasUnsavedChanges)
        XCTAssertEqual(controller.window?.isDocumentEdited, false)
        XCTAssertEqual(controller.pageIndex, 1, "at the same page")

        // ⌘Z still puts the page back, now into the copy.
        controller.window?.undoManager?.undo()
        XCTAssertEqual(controller.pdf?.pageCount, 3)
        XCTAssertTrue(controller.saveChanges())
        XCTAssertEqual(PDFDocument(url: copy)?.pageCount, 3)
        XCTAssertEqual(PDFDocument(url: original)?.pageCount, 3)

        // The copy is the document open; the original opens in a tab of its own.
        XCTAssertTrue(app.open([copy], nextTo: nil).isEmpty, "already open")
        XCTAssertEqual(app.open([original], nextTo: nil).count, 1)
    }

    func testWithNothingChangedTheFileIsCopiedAsItIs() throws {
        let folder = try Fixtures.folder(self)
        let original = try Fixtures.pdf(in: folder, pageCount: 3)
        let controller = app.open([original], nextTo: nil)[0]
        let copy = folder.appendingPathComponent("same.pdf")
        try controller.save(as: copy)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: original), "byte for byte")
        XCTAssertEqual(controller.url, copy.standardizedFileURL)
    }

    func testAProtectedDocumentKeepsItsPassword() async throws {
        let folder = try Fixtures.folder(self)
        let locked = try Fixtures.pdf(at: folder.appendingPathComponent("locked.pdf"), pages: ["Secret"], password: "fixture-pw")
        let controller = app.open([locked], nextTo: nil)[0]
        await waitUntil { controller.window?.attachedSheet != nil }
        // The password typed in its sheet, and Open.
        let sheet = try XCTUnwrap(controller.window?.attachedSheet)
        let field = try XCTUnwrap(secureField(in: sheet.contentView))
        field.stringValue = "fixture-pw"
        controller.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        await waitUntil { controller.window?.attachedSheet == nil }
        XCTAssertEqual(controller.pdf?.isLocked, false)
        let copy = folder.appendingPathComponent("still-locked.pdf")
        try controller.save(as: copy)
        XCTAssertEqual(PDFDocument(url: copy)?.isLocked, true, "the copy asks for the password too")
        XCTAssertEqual(controller.pdf?.isLocked, false, "but the tab shows it open")
        XCTAssertEqual(controller.pdf?.page(at: 0)?.string?.contains("Secret"), true)
    }

    func testTheNewFileIsFollowedAndTheOriginalNoLonger() async throws {
        let folder = try Fixtures.folder(self)
        let original = try Fixtures.pdf(in: folder, pageCount: 2)
        let controller = app.open([original], nextTo: nil)[0]
        let copy = folder.appendingPathComponent("followed.pdf")
        try controller.save(as: copy)
        var reloads = 0
        controller.onReload = { reloads += 1 }
        try Fixtures.pdf(at: original, pages: ["changed"])
        await wait(0.8)
        XCTAssertEqual(reloads, 0, "the original isn't shown any more")
        try Fixtures.pdf(at: copy, pages: ["a", "b", "c", "d"])
        await waitUntil { reloads == 1 }
        XCTAssertEqual(controller.pdf?.pageCount, 4)
    }

    func testBothFilesReopenWhereTheyWereLeft() throws {
        let folder = try Fixtures.folder(self)
        let original = try Fixtures.pdf(in: folder, pageCount: 10)
        let controller = app.open([original], nextTo: nil)[0]
        controller.go(toIndex: 6)
        let copy = folder.appendingPathComponent("positions.pdf")
        try controller.save(as: copy)
        XCTAssertEqual(ReadingPositions.page(for: original), 6)
        XCTAssertEqual(ReadingPositions.page(for: copy.standardizedFileURL), 6)
    }

    func testAnExistingFileIsReplaced() throws {
        let folder = try Fixtures.folder(self)
        let original = try Fixtures.pdf(in: folder, name: "a.pdf", pageCount: 2)
        let other = try Fixtures.pdf(in: folder, name: "b.pdf", pageCount: 7)
        let controller = app.open([original], nextTo: nil)[0]
        try controller.save(as: other)
        XCTAssertEqual(PDFDocument(url: other)?.pageCount, 2)
    }

    func testAFileOpenInAnotherTabIsLeftAlone() throws {
        let folder = try Fixtures.folder(self)
        let a = try Fixtures.pdf(in: folder, name: "a.pdf", pageCount: 2)
        let b = try Fixtures.pdf(in: folder, name: "b.pdf", pageCount: 5)
        let opened = app.open([a, b], nextTo: nil)
        let first = opened[0], second = opened[1]
        XCTAssertThrowsError(try first.save(as: b)) { error in
            XCTAssertEqual(error as? Doc.SaveAsFailure, .openInAnotherTab)
        }
        XCTAssertEqual(PDFDocument(url: b)?.pageCount, 5)
        XCTAssertEqual(first.url, a)
        XCTAssertEqual(second.pdf?.pageCount, 5)
    }

    func testOverItselfItIsASave() throws {
        let folder = try Fixtures.folder(self)
        let url = try Fixtures.pdf(at: folder.appendingPathComponent("self.pdf"), pages: ["one"])
        let controller = app.open([url], nextTo: nil)[0]
        controller.add(note: "saved", at: NSPoint(x: 80, y: 400), on: try XCTUnwrap(controller.pdf?.page(at: 0)))
        try controller.save(as: url)
        XCTAssertFalse(controller.hasUnsavedChanges)
        XCTAssertEqual(notes(on: PDFDocument(url: url)?.page(at: 0)).first?.contents, "saved")
    }

    func testAFolderThatCantBeWrittenLeavesEverythingAsItWas() throws {
        let folder = try Fixtures.folder(self)
        let original = try Fixtures.pdf(in: folder, pageCount: 2)
        let closed = folder.appendingPathComponent("closed", isDirectory: true)
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: closed.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path) }
        let controller = app.open([original], nextTo: nil)[0]
        controller.add(note: "kept", at: NSPoint(x: 80, y: 400), on: try XCTUnwrap(controller.pdf?.page(at: 0)))
        XCTAssertThrowsError(try controller.save(as: closed.appendingPathComponent("nope.pdf"))) { error in
            XCTAssertEqual(error as? Doc.SaveAsFailure, .notWritten)
        }
        XCTAssertEqual(controller.url, original)
        XCTAssertEqual(controller.window?.title, original.lastPathComponent)
        XCTAssertTrue(controller.hasUnsavedChanges, "the marks are still waiting for the original")
    }

    func testTheSaveAsPanelOpensAsASheet() async throws {
        let folder = try Fixtures.folder(self)
        let controller = app.open([try Fixtures.pdf(in: folder, name: "panel.pdf", pageCount: 1)], nextTo: nil)[0]
        let window = try XCTUnwrap(controller.window)
        controller.saveDocumentAs(nil)
        await waitUntil { window.attachedSheet != nil }
        let panel = try XCTUnwrap(window.attachedSheet as? NSSavePanel)
        XCTAssertEqual(panel.nameFieldStringValue, "panel.pdf")
        XCTAssertEqual(panel.directoryURL?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertFalse(controller.validateMenuItem(item(#selector(Doc.saveDocumentAs(_:)))), "not twice")
        window.endSheet(panel, returnCode: .cancel)
        await waitUntil { window.attachedSheet == nil }
        XCTAssertEqual(controller.url.lastPathComponent, "panel.pdf", "cancelled: nothing changes")
    }

    func testSaveInThePanelWritesWhereItSays() async throws {
        let folder = try Fixtures.folder(self)
        let url = try Fixtures.pdf(at: folder.appendingPathComponent("panel.pdf"), pages: ["one"])
        let controller = app.open([url], nextTo: nil)[0]
        controller.add(note: "from the panel", at: NSPoint(x: 80, y: 400), on: try XCTUnwrap(controller.pdf?.page(at: 0)))
        let window = try XCTUnwrap(controller.window)
        controller.saveDocumentAs(nil)
        await waitUntil { window.attachedSheet != nil }
        // Its own name and folder (the panel's fields live in another
        // process, out of the test's reach): the same file, saved.
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .OK)
        await waitUntil { !controller.hasUnsavedChanges }
        XCTAssertFalse(controller.hasUnsavedChanges)
        XCTAssertEqual(notes(on: PDFDocument(url: url)?.page(at: 0)).first?.contents, "from the panel")
    }
}
