import AppKit
import PDFKit
import XCTest
@testable import PiDF

/// ⌃D deletes the page on screen; ⌘Z puts it back while the window is open.
@MainActor
final class PageTests: XCTestCase {
    private var app: AppDelegate { NSApp.delegate as! AppDelegate }

    override func tearDown() async throws {
        for controller in app.controllers { controller.close() }
        await wait(0.1)
    }

    private func open(pages: Int, in folder: URL? = nil) throws -> (DocumentWindowController, URL) {
        let url = try Fixtures.pdf(in: try folder ?? Fixtures.folder(self), pageCount: pages)
        return (app.open([url], nextTo: nil)[0], url)
    }

    private func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }
    private var deleteItem: NSMenuItem { item(#selector(DocumentWindowController.deletePage(_:))) }

    private func texts(_ document: PDFDocument?) -> [String] {
        guard let document else { return [] }
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    func testDeletesThePageOnScreenAndUndoBringsItBack() throws {
        let (controller, _) = try open(pages: 3)
        let undo = try XCTUnwrap(controller.window?.undoManager)
        controller.go(toIndex: 1)
        let delete = deleteItem
        XCTAssertTrue(controller.validateMenuItem(delete))
        XCTAssertEqual(delete.title, "Delete Page 2", "the menu says which page goes")

        controller.deletePage(nil)
        XCTAssertEqual(texts(controller.pdf), ["Page 1", "Page 3"])
        XCTAssertEqual(controller.pageIndex, 1, "the next page takes its place on screen")
        XCTAssertEqual(controller.window?.subtitle, "Page 2 of 2")
        XCTAssertTrue(controller.hasUnsavedAnnotations)
        XCTAssertEqual(controller.window?.isDocumentEdited, true)
        // ⌘Z in the Edit menu reaches the window's undo.
        let window = try XCTUnwrap(controller.window)
        let undoItem = item(Selector(("undo:")))
        XCTAssertTrue(window.validateMenuItem(undoItem))
        XCTAssertEqual(undoItem.title, "Undo Delete Page")

        window.perform(Selector(("undo:")), with: nil)
        XCTAssertEqual(texts(controller.pdf), ["Page 1", "Page 2", "Page 3"])
        XCTAssertEqual(controller.pageIndex, 1, "back on screen")
        undo.redo()
        XCTAssertEqual(texts(controller.pdf), ["Page 1", "Page 3"])
    }

    func testDeletedPageLeavesTheFileAtSaveAndUndoStillWorksAfter() throws {
        let (controller, url) = try open(pages: 3)
        controller.go(toIndex: 0)
        controller.deletePage(nil)
        XCTAssertTrue(controller.saveAnnotations())
        XCTAssertEqual(texts(PDFDocument(url: url)), ["Page 2", "Page 3"])

        // The window now shows the file read again; the page goes into it.
        controller.window?.undoManager?.undo()
        XCTAssertEqual(texts(controller.pdf), ["Page 1", "Page 2", "Page 3"])
        XCTAssertTrue(controller.saveAnnotations())
        XCTAssertEqual(texts(PDFDocument(url: url)), ["Page 1", "Page 2", "Page 3"])
    }

    func testTheLastPageStays() throws {
        let (controller, _) = try open(pages: 1)
        XCTAssertFalse(controller.validateMenuItem(deleteItem))
        controller.deletePage(nil)
        XCTAssertEqual(controller.pdf?.pageCount, 1)
        XCTAssertFalse(controller.hasUnsavedAnnotations)
    }

    func testReadOnlyFilesAndTheFindFieldKeepTheirPages() throws {
        let folder = try Fixtures.folder(self)
        let (finding, _) = try open(pages: 3, in: folder)
        finding.showFind(nil)
        XCTAssertFalse(finding.validateMenuItem(deleteItem), "⌃D deletes forward in the field")

        let plain = try Fixtures.pdf(in: folder, name: "readonly.pdf", pageCount: 3)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: plain.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path) }
        let readOnly = app.open([plain], nextTo: nil)[0]
        XCTAssertFalse(readOnly.validateMenuItem(deleteItem))
    }

    func testAnotherAppsVersionForgetsTheDeletedPages() async throws {
        let (controller, url) = try open(pages: 3)
        var reloads = 0
        controller.onReload = { reloads += 1 }
        controller.deletePage(nil)
        XCTAssertEqual(controller.window?.undoManager?.canUndo, true)
        try Fixtures.pdf(at: url, pages: ["New 1", "New 2"])
        await waitUntil { reloads == 1 }
        XCTAssertEqual(texts(controller.pdf), ["New 1", "New 2"])
        XCTAssertEqual(controller.window?.undoManager?.canUndo, false)
    }
}
