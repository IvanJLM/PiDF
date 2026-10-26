import AppKit
import PDFKit
import XCTest
@testable import PiDF

/// Highlights (⌃H) and notes (⌃N): one colour, kept in the file itself.
@MainActor
final class AnnotationTests: XCTestCase {
    private var app: AppDelegate { NSApp.delegate as! AppDelegate }

    override func tearDown() async throws {
        for controller in app.controllers { controller.close() }
        await wait(0.1)
    }

    private func open(_ pages: [String] = ["first page text", "second page text"],
                      name: String = "marks.pdf") throws -> (DocumentWindowController, URL) {
        let url = try Fixtures.pdf(at: try Fixtures.folder(self).appendingPathComponent(name), pages: pages)
        return (app.open([url], nextTo: nil)[0], url)
    }

    @discardableResult
    private func select(_ text: String, in controller: DocumentWindowController) throws -> PDFSelection {
        let selection = try XCTUnwrap(controller.pdf?.findString(text, withOptions: []).first)
        controller.pdfView.setCurrentSelection(selection, animate: false)
        return selection
    }

    private func highlights(on page: PDFPage?) -> [PDFAnnotation] { (page?.annotations ?? []).filter(Marks.isHighlight) }
    private func notes(on page: PDFPage?) -> [PDFAnnotation] { (page?.annotations ?? []).filter(Marks.isNote) }

    private func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }

    private func pressDelete(in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51))
        window.sendEvent(event)
    }

    // MARK: Highlights

    func testHighlightCoversTheSelectedTextAndTogglesOff() throws {
        let (controller, _) = try open()
        let selection = try select("page text", in: controller)
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        let bounds = selection.bounds(for: page)
        let item = item(#selector(DocumentWindowController.toggleHighlight(_:)))
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.title, "Highlight")

        controller.toggleHighlight(nil)
        let made = highlights(on: page)
        XCTAssertEqual(made.count, 1)
        let covered = try XCTUnwrap(Marks.rects(of: made[0]).first)
        XCTAssertEqual(covered.minX, bounds.minX, accuracy: 0.5)
        XCTAssertEqual(covered.width, bounds.width, accuracy: 0.5)
        XCTAssertEqual(covered.midY, bounds.midY, accuracy: 0.5)
        XCTAssertTrue((controller.pdfView.currentSelection?.string ?? "").isEmpty, "the selection goes, the highlight stays")
        XCTAssertTrue(controller.hasUnsavedAnnotations)
        XCTAssertEqual(controller.window?.isDocumentEdited, true)

        // Part of it selected again: ⌃H removes it.
        try select("text", in: controller)
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.title, "Remove Highlight")
        controller.toggleHighlight(nil)
        XCTAssertTrue(highlights(on: page).isEmpty)
    }

    func testHighlightKeepsEachLine() {
        let lines = [NSRect(x: 60, y: 700, width: 400, height: 12), NSRect(x: 60, y: 688, width: 150, height: 12)]
        let highlight = Marks.highlight(lines: lines)
        XCTAssertEqual(highlight.bounds, NSRect(x: 60, y: 688, width: 400, height: 24))
        XCTAssertEqual(Marks.rects(of: highlight), lines, "not the whole box: the short line stays short")
    }

    func testNothingSelectedNothingToHighlight() throws {
        let (controller, _) = try open()
        controller.pdfView.clearSelection()
        XCTAssertFalse(controller.validateMenuItem(item(#selector(DocumentWindowController.toggleHighlight(_:)))))
        controller.toggleHighlight(nil)
        XCTAssertTrue(highlights(on: controller.pdf?.page(at: 0)).isEmpty)
        XCTAssertFalse(controller.hasUnsavedAnnotations)
    }

    // MARK: Notes

    func testNoteSitsAtThePointIsEditedAndDeleted() throws {
        let (controller, _) = try open()
        let window = try XCTUnwrap(controller.window)
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        let item = item(#selector(DocumentWindowController.addNote(_:)))
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.title, "Add Note…")

        let note = controller.add(note: "Esto es una prueba de Nota", at: NSPoint(x: 100, y: 500), on: page)
        XCTAssertEqual(notes(on: page).count, 1)
        XCTAssertEqual(note.bounds.minX, 100, "its top left corner is where the pointer was")
        XCTAssertEqual(note.bounds.maxY, 500)
        XCTAssertEqual(note.contents, "Esto es una prueba de Nota")
        XCTAssertEqual(note.font?.fontName, "Helvetica")
        let textWidth = NSAttributedString(string: "Esto es una prueba de Nota", attributes: [.font: try XCTUnwrap(note.font)]).size().width
        XCTAssertEqual(note.bounds.width, ceil(textWidth + 2 * Marks.textInset + 0.5), "as wide as its text")
        XCTAssertTrue(controller.pdfView.selectedNote === note, "a new note is the selected one")
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.title, "Edit Note…")

        controller.replace(note, with: "Changed")
        let edited = try XCTUnwrap(notes(on: page).first)
        XCTAssertEqual(notes(on: page).count, 1)
        XCTAssertEqual(edited.contents, "Changed")
        XCTAssertEqual(edited.bounds.minX, 100, "same corner")
        XCTAssertEqual(edited.bounds.maxY, 500)
        XCTAssertLessThan(edited.bounds.width, note.bounds.width, "shorter text, narrower note")
        XCTAssertTrue(controller.pdfView.selectedNote === edited)

        try pressDelete(in: window)
        XCTAssertTrue(notes(on: page).isEmpty, "Delete removes the selected note")
        XCTAssertNil(controller.pdfView.selectedNote)
        try pressDelete(in: window)  // nothing selected: nothing happens
        XCTAssertTrue(notes(on: page).isEmpty)
    }

    func testNoteStaysOnThePage() throws {
        let (controller, _) = try open()
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        let box = page.bounds(for: .cropBox)
        let note = controller.add(note: "A note put almost off the page", at: NSPoint(x: box.maxX - 5, y: 5), on: page)
        XCTAssertLessThanOrEqual(note.bounds.maxX, box.maxX - Marks.margin + 0.01)
        XCTAssertGreaterThanOrEqual(note.bounds.minY, box.minY + Marks.margin - 0.01)
    }

    func testDraggingMovesTheNote() throws {
        let (controller, _) = try open()
        let window = try XCTUnwrap(controller.window)
        let view = controller.pdfView
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        let note = controller.add(note: "drag me", at: NSPoint(x: 100, y: 500), on: page)
        view.layoutDocumentView()
        let startPage = NSPoint(x: note.bounds.midX, y: note.bounds.midY)
        let startWindow = view.convert(view.convert(startPage, from: page), to: nil)
        let endWindow = NSPoint(x: startWindow.x + 40, y: startWindow.y - 30)
        let endPage = view.convert(view.convert(endWindow, from: nil), to: page)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        window.sendEvent(try mouse(.leftMouseDown, startWindow))
        window.sendEvent(try mouse(.leftMouseDragged, endWindow))
        window.sendEvent(try mouse(.leftMouseUp, endWindow))
        let moved = try XCTUnwrap(notes(on: page).first)
        XCTAssertTrue(moved === note, "the same note, moved")
        XCTAssertEqual(moved.bounds.minX, 100 + (endPage.x - startPage.x), accuracy: 0.5)
        XCTAssertEqual(moved.bounds.maxY, 500 + (endPage.y - startPage.y), accuracy: 0.5)
        XCTAssertTrue(view.selectedNote === note)
        XCTAssertTrue(controller.hasUnsavedAnnotations)
    }

    // MARK: Note size and lines

    func testNoteTakesTheSizeOfThePagesText() throws {
        let (controller, _) = try open()  // pages set in 18-point type
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        XCTAssertEqual(Marks.textSize(on: page), 18)
        let note = controller.add(note: "sized", at: NSPoint(x: 100, y: 500), on: page)
        XCTAssertEqual(note.font?.pointSize, 18)
        XCTAssertEqual(note.bounds.height, Marks.lineHeight(size: 18) + 2 * Marks.textInset)

        controller.replace(note, with: "edited, same size")
        XCTAssertEqual(notes(on: page).first?.font?.pointSize, 18, "an edit keeps the note's size")
    }

    func testPageWithoutTextGetsASizeForItsWidth() {
        let a4 = PDFPage()
        a4.setBounds(NSRect(x: 0, y: 0, width: 595, height: 842), for: .mediaBox)
        XCTAssertEqual(Marks.textSize(on: a4), 11)
        let slide = PDFPage()
        slide.setBounds(NSRect(x: 0, y: 0, width: 960, height: 540), for: .mediaBox)
        XCTAssertEqual(Marks.textSize(on: slide), 18)
    }

    func testLongNotesWrapAndKeepTheirLines() throws {
        let box = NSRect(x: 0, y: 0, width: 595, height: 842)
        let two = Marks.note("first line\nsecond line", size: 11, topLeft: NSPoint(x: 100, y: 500), in: box)
        XCTAssertEqual(two.bounds.height, 2 * Marks.lineHeight(size: 11) + 2 * Marks.textInset, "a typed new line is a line")
        XCTAssertEqual(two.contents, "first line\nsecond line")

        let long = String(repeating: "Golden Rules first: fly, navigate, communicate. ", count: 6)
        let wrapped = Marks.note(long, size: 11, topLeft: NSPoint(x: 300, y: 500), in: box)
        XCTAssertLessThanOrEqual(wrapped.bounds.maxX, box.maxX - Marks.margin + 0.01, "up to the right margin")
        XCTAssertEqual(wrapped.bounds.minX, 300, "from the point")
        XCTAssertGreaterThan(wrapped.bounds.height, 4 * Marks.lineHeight(size: 11), "and down as long as it takes")
    }

    /// PDFKit draws the note's text where PiDF counted it: nothing below
    /// the yellow box. Rendered in a far taller note of the same width.
    func testNoteTextFitsItsBox() throws {
        let text = "Golden Rules first: fly, navigate, communicate. The PF trims until the AP can be engaged.\nSEC F-PLN for the EOSID of the day; ATC before ECAM actions, with no fire or severe damage."
        for size: CGFloat in [7, 11, 18] {
            let box = NSRect(x: 0, y: 0, width: 595, height: 842)
            let note = Marks.note(text, size: size, topLeft: NSPoint(x: 200, y: 800), in: box)
            let tall = PDFAnnotation(bounds: NSRect(x: 0, y: 0, width: note.bounds.width, height: note.bounds.height + 200),
                                     forType: .freeText, withProperties: nil)
            tall.contents = text
            tall.font = note.font
            tall.fontColor = .black
            tall.backgroundColor = .white
            tall.border = PDFBorder()
            tall.border?.lineWidth = 0
            let page = PDFPage()
            page.setBounds(tall.bounds, for: .mediaBox)
            page.addAnnotation(tall)
            let scale: CGFloat = 3
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(tall.bounds.width * scale), pixelsHigh: Int(tall.bounds.height * scale),
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            var lowest = 0
            for y in 0..<rep.pixelsHigh where (0..<rep.pixelsWide).contains(where: { (rep.colorAt(x: $0, y: y)?.redComponent ?? 1) < 0.5 }) { lowest = y }
            let inkBottom = CGFloat(lowest + 1) / scale
            XCTAssertLessThanOrEqual(inkBottom, note.bounds.height, "\(size)-point text inside its note")
            XCTAssertGreaterThan(inkBottom, note.bounds.height - Marks.lineHeight(size: size) - Marks.textInset, "\(size)-point: no empty line at the end")
        }
    }

    func testNoteSheetTakesSeveralLines() throws {
        let editor = NoteEditor(text: "")
        var committed = false, cancelled = false
        editor.onCommit = { committed = true }
        editor.onCancel = { cancelled = true }
        editor.textView.insertText("first", replacementRange: editor.textView.selectedRange())
        XCTAssertTrue(editor.textView(editor.textView, doCommandBy: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))), "⌥Return")
        editor.textView.insertText("second  ", replacementRange: editor.textView.selectedRange())
        XCTAssertEqual(editor.text, "first\nsecond")
        XCTAssertFalse(committed)
        XCTAssertTrue(editor.textView(editor.textView, doCommandBy: #selector(NSResponder.insertNewline(_:))), "Return")
        XCTAssertTrue(committed, "Return adds the note")
        XCTAssertEqual(editor.text, "first\nsecond", "without a new line")
        XCTAssertTrue(editor.textView(editor.textView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(cancelled, "Esc cancels")
        XCTAssertGreaterThan(editor.frame.height, 3 * NSFont.systemFontSize * 1.2, "room for several lines")
    }

    func testNoteSheetShowsTheNotesText() async throws {
        let (controller, _) = try open()
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        controller.add(note: "line one\nline two", at: NSPoint(x: 100, y: 500), on: page)
        controller.addNote(nil)  // a note is selected: edit it
        await waitUntil { controller.window?.attachedSheet != nil }
        XCTAssertEqual(controller.noteEditor?.textView.string, "line one\nline two")
        if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
    }

    func testEmptyTextRemovesTheNote() throws {
        let (controller, _) = try open()
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        let note = controller.add(note: "gone soon", at: NSPoint(x: 100, y: 500), on: page)
        controller.replace(note, with: "")
        XCTAssertTrue(notes(on: page).isEmpty)
        XCTAssertNil(controller.pdfView.selectedNote)
    }

    func testEscLetsTheNoteGo() throws {
        let (controller, _) = try open()
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        controller.add(note: "selected", at: NSPoint(x: 100, y: 500), on: page)
        controller.cancelOperation(nil)
        XCTAssertNil(controller.pdfView.selectedNote)
        XCTAssertEqual(notes(on: page).count, 1, "still there")
    }

    // MARK: Saving

    func testSaveWritesTheMarksIntoTheFile() async throws {
        let (controller, url) = try open()
        var reloads = 0
        controller.onReload = { reloads += 1 }
        let shown = try XCTUnwrap(controller.pdf)
        try select("first", in: controller)
        controller.toggleHighlight(nil)
        controller.add(note: "kept", at: NSPoint(x: 80, y: 400), on: try XCTUnwrap(shown.page(at: 0)))
        XCTAssertTrue(controller.validateMenuItem(item(#selector(DocumentWindowController.saveDocument(_:)))))

        XCTAssertTrue(controller.saveAnnotations())
        XCTAssertFalse(controller.hasUnsavedAnnotations)
        XCTAssertEqual(controller.window?.isDocumentEdited, false)
        XCTAssertFalse(controller.validateMenuItem(item(#selector(DocumentWindowController.saveDocument(_:)))))

        let written = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(written.pageCount, 2)
        let page = try XCTUnwrap(written.page(at: 0))
        XCTAssertEqual(highlights(on: page).count, 1)
        XCTAssertEqual(notes(on: page).first?.contents, "kept")
        XCTAssertEqual(page.string?.contains("first page text"), true, "the text is still there")
        XCTAssertEqual(written.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Fixture", "and its metadata")

        // What is shown is the file as written (a lazy document, not the one
        // PDFKit filled up to write it), at the same place.
        XCTAssertFalse(controller.pdf === shown)
        XCTAssertEqual(controller.pageIndex, 0)
        XCTAssertEqual(notes(on: controller.pdf?.page(at: 0)).first?.contents, "kept")

        // PiDF's own write is no change to follow; another app's still is.
        await wait(0.8)
        XCTAssertEqual(reloads, 0)
        try Fixtures.pdf(at: url, pages: ["new"])
        await waitUntil { reloads == 1 }
        XCTAssertEqual(reloads, 1)
    }

    func testBackgroundTabWritesItsMarksAndKeepsThem() async throws {
        let folder = try Fixtures.folder(self)
        let a = try Fixtures.pdf(in: folder, name: "a.pdf", pageCount: 3)
        let b = try Fixtures.pdf(in: folder, name: "b.pdf", pageCount: 1)
        let first = app.open([a], nextTo: nil)[0]
        first.go(toIndex: 2)
        first.add(note: "behind", at: NSPoint(x: 80, y: 400), on: try XCTUnwrap(first.pdf?.page(at: 2)))
        _ = app.open([b], nextTo: nil)[0]
        await waitUntil { first.isParked }
        XCTAssertTrue(first.isParked)
        await waitUntil { !first.hasUnsavedAnnotations }
        XCTAssertFalse(first.hasUnsavedAnnotations, "written while in the background")
        XCTAssertEqual(notes(on: PDFDocument(url: a)?.page(at: 2)).first?.contents, "behind")
        first.bringToFront()
        await waitUntil { !first.isParked }
        XCTAssertEqual(first.pageIndex, 2, "back at its page")
        XCTAssertEqual(notes(on: first.pdf?.page(at: 2)).first?.contents, "behind")
    }

    func testClosingSavesFirst() async throws {
        let (controller, url) = try open()
        controller.add(note: "closing", at: NSPoint(x: 80, y: 400), on: try XCTUnwrap(controller.pdf?.page(at: 0)))
        controller.window?.performClose(nil)
        await waitUntil { self.app.controllers.isEmpty }
        XCTAssertTrue(app.controllers.isEmpty)
        XCTAssertEqual(notes(on: PDFDocument(url: url)?.page(at: 0)).first?.contents, "closing")
    }

    // MARK: Where marks can't be made

    func testProtectedAndReadOnlyDocumentsTakeNoMarks() async throws {
        let folder = try Fixtures.folder(self)
        let locked = try Fixtures.pdf(at: folder.appendingPathComponent("locked.pdf"), pages: ["Secret"], password: "fixture-pw")
        let protected = app.open([locked], nextTo: nil)[0]
        await wait(0.2)
        XCTAssertFalse(protected.canAnnotate)
        XCTAssertTrue(protected.unlock(with: "fixture-pw"))
        XCTAssertFalse(protected.canAnnotate, "it would be written without its protection")
        if let sheet = protected.window?.attachedSheet { protected.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }

        let plain = try Fixtures.pdf(at: folder.appendingPathComponent("readonly.pdf"), pages: ["x"])
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: plain.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path) }
        let readOnly = app.open([plain], nextTo: nil)[0]
        XCTAssertFalse(readOnly.canAnnotate)
        XCTAssertFalse(readOnly.validateMenuItem(item(#selector(DocumentWindowController.addNote(_:)))))
    }

    func testShortcutsAreTheFieldsWhileFinding() throws {
        let (controller, _) = try open()
        try select("first", in: controller)
        controller.showFind(nil)
        XCTAssertFalse(controller.validateMenuItem(item(#selector(DocumentWindowController.toggleHighlight(_:)))), "⌃H deletes backward in the field")
        XCTAssertFalse(controller.validateMenuItem(item(#selector(DocumentWindowController.addNote(_:)))))
    }
}
