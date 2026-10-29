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

    func testOneYellowForBoth() throws {
        let (controller, _) = try open()
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        try select("first", in: controller)
        controller.toggleHighlight(nil)
        let note = controller.add(note: "yellow", at: NSPoint(x: 100, y: 500), on: page)
        let hex = { (color: NSColor?) -> String? in
            color?.usingColorSpace(.sRGB).map { String(format: "%02X%02X%02X", Int(($0.redComponent * 255).rounded()),
                                                      Int(($0.greenComponent * 255).rounded()), Int(($0.blueComponent * 255).rounded())) }
        }
        XCTAssertEqual(hex(highlights(on: page).first?.color), "FFE34D")
        XCTAssertEqual(hex(note.backgroundColor), "FFE34D")
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
        let font = try XCTUnwrap(note.font)
        let textWidth = NSAttributedString(string: "Esto es una prueba de Nota", attributes: [.font: font]).size().width
        XCTAssertEqual(note.bounds.width, ceil(textWidth + 2 * Marks.padding * font.pointSize + 0.5), "as wide as its text")
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

    // MARK: Note type and lines

    func testNoteTakesTheTypeOfThePagesText() throws {
        let folder = try Fixtures.folder(self)
        let url = try Fixtures.pdf(at: folder.appendingPathComponent("times.pdf"), pages: ["set in Times, like the document"],
                                   font: try XCTUnwrap(NSFont(name: "TimesNewRomanPSMT", size: 13)))
        let controller = app.open([url], nextTo: nil)[0]
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        let note = controller.add(note: "typed", at: NSPoint(x: 100, y: 500), on: page)
        XCTAssertEqual(note.font?.fontName, "TimesNewRomanPSMT", "the document's typeface")
        XCTAssertEqual(note.font?.pointSize, 11, "and its size, at least 1.5 points smaller")

        controller.replace(note, with: "edited, same type")
        XCTAssertEqual(notes(on: page).first?.font?.fontName, "TimesNewRomanPSMT", "an edit keeps the note's type")
        XCTAssertEqual(notes(on: page).first?.font?.pointSize, 11)
    }

    func testPrivateOrMissingTypefacesBecomeHelvetica() throws {
        let (controller, _) = try open()  // set in the system font, at 18 points (16 in a note)
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        XCTAssertEqual(Marks.textFont(on: page).fontName, "Helvetica")
        XCTAssertEqual(Marks.textFont(on: page).pointSize, 16)
    }

    func testPageWithoutTextGetsASizeForItsWidth() {
        let a4 = PDFPage()
        a4.setBounds(NSRect(x: 0, y: 0, width: 595, height: 842), for: .mediaBox)
        XCTAssertEqual(Marks.textFont(on: a4).pointSize, 9)
        XCTAssertEqual(Marks.textFont(on: a4).fontName, "Helvetica")
        let slide = PDFPage()
        slide.setBounds(NSRect(x: 0, y: 0, width: 960, height: 540), for: .mediaBox)
        XCTAssertEqual(Marks.textFont(on: slide).pointSize, 16)
        XCTAssertEqual(Marks.noteSize(11.5), 10, "whole points, as PDFKit writes them")
    }

    func testLongNotesWrapAndKeepTheirLines() throws {
        let box = NSRect(x: 0, y: 0, width: 595, height: 842)
        let font = Marks.helvetica(size: 11)
        let one = Marks.note("first line", font: font, topLeft: NSPoint(x: 100, y: 500), in: box)
        let two = Marks.note("first line\nsecond line", font: font, topLeft: NSPoint(x: 100, y: 500), in: box)
        XCTAssertGreaterThan(two.bounds.height - one.bounds.height, 10, "a typed new line is a line")
        XCTAssertEqual(two.contents, "first line\nsecond line")
        XCTAssertEqual(two.bounds.maxY, 500, "its top where it was put")

        let long = String(repeating: "Golden Rules first: fly, navigate, communicate. ", count: 6)
        let wrapped = Marks.note(long, font: font, topLeft: NSPoint(x: 300, y: 500), in: box)
        XCTAssertLessThanOrEqual(wrapped.bounds.maxX, box.maxX - Marks.margin + 0.01, "up to the right margin")
        XCTAssertEqual(wrapped.bounds.minX, 300, "from the point")
        XCTAssertGreaterThan(wrapped.bounds.height, 4 * one.bounds.height, "and down as long as it takes")
    }

    /// The top and bottom of the ink `page` shows within `rect`, below the
    /// rect's top edge.
    private func ink(on page: PDFPage, in rect: NSRect) throws -> (top: CGFloat, bottom: CGFloat) {
        let scale: CGFloat = 4
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(rect.width * scale)), pixelsHigh: Int(ceil(rect.height * scale)),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.maxY + CGFloat(rep.pixelsHigh) / scale)
        page.draw(with: .mediaBox, to: context)
        let inked = (0..<rep.pixelsHigh).filter { y in (0..<rep.pixelsWide).contains { (rep.colorAt(x: $0, y: y)?.redComponent ?? 1) < 0.5 } }
        return (CGFloat(try XCTUnwrap(inked.first)) / scale, CGFloat(try XCTUnwrap(inked.last) + 1) / scale)
    }

    /// Whatever the type and size, the text sits inside the yellow with
    /// room above and below, and the file shows the note as PiDF drew it.
    func testNoteTextFitsItsBox() throws {
        let text = "Golden Rules first: fly, navigate, communicate. The PF trims until the AP can be engaged.\nSEC F-PLN for the EOSID of the day; ATC before ECAM actions, with no fire or severe damage."
        let folder = try Fixtures.folder(self)
        for name in ["Helvetica", "TimesNewRomanPSMT", "AvenirNext-Regular"] {
            for size: CGFloat in [6, 9, 11, 18] {
                let font = try XCTUnwrap(NSFont(name: name, size: size))
                let document = PDFDocument()
                let page = PDFPage()
                page.setBounds(NSRect(x: 0, y: 0, width: 595, height: 842), for: .mediaBox)
                document.insert(page, at: 0)
                let note = Marks.note(text, font: font, topLeft: NSPoint(x: 200, y: 800), in: page.bounds(for: .mediaBox))
                page.addAnnotation(note)
                let ink = try ink(on: page, in: note.bounds)
                XCTAssertGreaterThanOrEqual(ink.top, 0.15 * size, "\(name) \(size): room above the text")
                XCTAssertLessThanOrEqual(ink.bottom, note.bounds.height - 0.15 * size, "\(name) \(size): and below it")

                let url = folder.appendingPathComponent("\(name)-\(size).pdf")
                XCTAssertTrue(document.write(to: url))
                let written = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
                XCTAssertEqual(try self.ink(on: written, in: note.bounds).top, ink.top, accuracy: 0.25, "\(name) \(size): the same once written")
                XCTAssertEqual(try self.ink(on: written, in: note.bounds).bottom, ink.bottom, accuracy: 0.25)
            }
        }
    }

    /// One line is as tall as its capitals and descenders and the padding;
    /// each further line adds its leading.
    func testNoteIsAsTallAsItsLines() {
        let box = NSRect(x: 0, y: 0, width: 595, height: 842)
        let font = Marks.helvetica(size: 9)
        let one = Marks.note("Esto es una prueba de Nota", font: font, topLeft: NSPoint(x: 100, y: 500), in: box)
        XCTAssertEqual(one.bounds.height, 2 * Marks.padding * 9 + font.capHeight - font.descender, accuracy: 0.01)
        let three = Marks.note("Esto es\nuna prueba\nde Nota", font: font, topLeft: NSPoint(x: 100, y: 500), in: box)
        XCTAssertEqual(three.bounds.height, one.bounds.height + 2 * Marks.leading * 9, accuracy: 0.01)
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
