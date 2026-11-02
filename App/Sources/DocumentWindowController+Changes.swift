import AppKit
import PDFKit

/// What the person reading changes in the document: highlights, notes, and
/// pages deleted or turned. All of it goes into the file as the marks do.
extension DocumentWindowController {
    // MARK: Highlights and notes

    /// Marks can be made while the document is on screen, not protected,
    /// and in a file PiDF can write back. A protected document would be
    /// written without its protection.
    var canAnnotate: Bool {
        guard !isParked, let document = pdfView.document, !document.isLocked, !document.isEncrypted else { return false }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    /// The boxes of the lines of `selection`, page by page, in one pass: a
    /// whole manual selected has a hundred thousand lines.
    private func lines(of selection: PDFSelection) -> [(PDFPage, [NSRect])] {
        var boxes: [ObjectIdentifier: [NSRect]] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages { boxes[ObjectIdentifier(page), default: []].append(line.bounds(for: page)) }
        }
        return selection.pages.map { ($0, boxes[ObjectIdentifier($0)] ?? []) }
    }

    /// The highlights under the lines of `selection`, with their pages.
    func highlights(under selection: PDFSelection) -> [(PDFPage, PDFAnnotation)] {
        lines(of: selection).flatMap { page, boxes -> [(PDFPage, PDFAnnotation)] in
            let marked = page.annotations.filter(Marks.isHighlight)
            guard !marked.isEmpty else { return [] }
            // The middle of each line, so a line next to a highlight doesn't count.
            let rects = boxes.map { $0.insetBy(dx: 0, dy: $0.height / 4) }
            return marked
                .filter { annotation in Marks.rects(of: annotation).contains { rect in rects.contains { $0.intersects(rect) } } }
                .map { (page, $0) }
        }
    }

    /// ⌃H: highlights the selected text, or removes the highlights under it.
    @objc func toggleHighlight(_ sender: Any?) {
        guard canAnnotate, let selection = pdfView.currentSelection, !selection.pages.isEmpty else { return }
        let under = highlights(under: selection)
        if !under.isEmpty {
            for (page, annotation) in under { page.removeAnnotation(annotation) }
        } else {
            for (page, rects) in lines(of: selection) where !rects.isEmpty {
                page.addAnnotation(Marks.highlight(lines: rects))
            }
            pdfView.clearSelection()
        }
        documentChanged()
    }

    /// ⌃N: a note where the pointer is (or in the middle of the window when
    /// the pointer is elsewhere); with a note selected, edits it.
    @objc func addNote(_ sender: Any?) {
        guard canAnnotate else { return }
        if let note = pdfView.selectedNote { return editNote(note) }
        var inView = pdfView.convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        if !pdfView.bounds.contains(inView) { inView = NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY) }
        guard let page = pdfView.page(for: inView, nearest: true) else { return }
        let inPage = pdfView.convert(inView, to: page)
        askForNoteText(initial: "") { [weak self] text in
            guard let self, let text, !text.isEmpty else { return }
            self.add(note: text, at: inPage, on: page)
        }
    }

    /// Puts a note saying `text` on `page`, its top left corner at `point`,
    /// in `font` (the type of the page's text when not given).
    @discardableResult
    func add(note text: String, at point: NSPoint, on page: PDFPage, font: NSFont? = nil) -> PDFAnnotation {
        let note = Marks.note(text, font: font ?? Marks.textFont(on: page), topLeft: point, in: page.bounds(for: .cropBox), rotation: page.rotation)
        page.addAnnotation(note)
        pdfView.select(note)
        documentChanged()
        return note
    }

    func editNote(_ note: PDFAnnotation) {
        askForNoteText(initial: note.contents ?? "") { [weak self] text in
            guard let self, let text else { return }
            self.replace(note, with: text)
        }
    }

    /// A note with new text is a new annotation, in the same place and
    /// type: PDFKit goes on drawing the saved look of one whose text
    /// changed. Empty text removes the note.
    func replace(_ note: PDFAnnotation, with text: String) {
        guard let page = note.page else { return }
        let topLeft = Marks.topLeft(of: note.bounds, in: page.bounds(for: .cropBox), rotation: page.rotation)
        let font = note.font
        pdfView.select(nil)
        page.removeAnnotation(note)
        if text.isEmpty {
            documentChanged()
        } else {
            add(note: text, at: topLeft, on: page, font: font)
        }
    }

    /// Delete with a note selected; false when there was none.
    @discardableResult
    func deleteSelectedNote() -> Bool {
        guard let note = pdfView.selectedNote, let page = note.page else { return false }
        pdfView.select(nil)
        page.removeAnnotation(note)
        documentChanged()
        return true
    }

    // MARK: Deleting pages

    /// ⌃D: takes the page on screen out of the document. It leaves the file
    /// at the next save, as the marks do; ⌘Z puts it back while the window
    /// is open. The last page stays.
    @objc func deletePage(_ sender: Any?) {
        guard canAnnotate, let document = pdf, document.pageCount > 1 else { return }
        removePage(at: pageIndex)
    }

    /// Each undo registers its redo, so ⌘Z and ⇧⌘Z go back and forth.
    private func removePage(at index: Int) {
        guard !isParked, let page = pdf?.page(at: index) else { return }
        pdfView.select(nil)
        pdf?.removePage(at: index)
        window?.undoManager?.registerUndo(withTarget: self) { $0.insert(page, at: index) }
        window?.undoManager?.setActionName("Delete Page")
        pagesChanged(showing: index)
    }

    /// The page goes into the document shown, also when that is the file
    /// read again after a save.
    private func insert(_ page: PDFPage, at index: Int) {
        guard !isParked, let document = pdf else { return }
        document.insert(page, at: min(index, document.pageCount))
        window?.undoManager?.registerUndo(withTarget: self) { $0.removePage(at: index) }
        window?.undoManager?.setActionName("Delete Page")
        pagesChanged(showing: index)
    }

    private func pagesChanged(showing index: Int) {
        documentChanged()
        go(toIndex: index)
        findBar?.refresh()
        reloadPageSelector()
    }

    // MARK: Rotating pages

    /// ⌃⌥← / ⌃⌥→ (and ⌃← / ⌃→, see DocumentWindow): turns the page on screen
    /// a quarter turn. Saved in the file as the marks are; ⌘Z turns it back.
    @objc func rotatePageLeft(_ sender: Any?) { rotateCurrentPage(by: -90) }
    @objc func rotatePageRight(_ sender: Any?) { rotateCurrentPage(by: 90) }

    private func rotateCurrentPage(by degrees: Int) {
        (window as? DocumentWindow)?.forgetSelectorKeys()
        guard canAnnotate, pageSelector == nil else { return }
        rotatePage(at: pageIndex, by: degrees)
    }

    /// By index, not by page: the document may have been read again after a
    /// save when an undo comes. The find matches stay valid, so they aren't
    /// looked for again (that reads the text of every page).
    private func rotatePage(at index: Int, by degrees: Int) {
        guard !isParked, let page = pdf?.page(at: index) else { return }
        pdfView.select(nil)
        page.rotation = (page.rotation + degrees + 360) % 360
        window?.undoManager?.registerUndo(withTarget: self) { $0.rotatePage(at: index, by: -degrees) }
        window?.undoManager?.setActionName("Rotate Page")
        documentChanged()
        pdfView.layoutDocumentView()
        if pdfView.autoScales { pdfView.autoScales = true }
        go(toIndex: index)
        reloadPageSelector()
    }

    private func askForNoteText(initial: String, completion: @escaping (String?) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = initial.isEmpty ? "Add Note" : "Edit Note"
        alert.addButton(withTitle: initial.isEmpty ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.informativeText = initial.isEmpty ? "Return adds it; ⌥Return starts a new line." : "Return saves it; ⌥Return starts a new line."
        let editor = NoteEditor(text: initial)
        editor.onCommit = { [weak alert] in alert?.buttons.first?.performClick(nil) }
        editor.onCancel = { [weak alert] in alert?.buttons.last?.performClick(nil) }
        alert.accessoryView = editor
        alert.window.initialFirstResponder = editor.textView
        noteEditor = editor
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.noteEditor = nil
                guard response == .alertFirstButtonReturn else { return completion(nil) }
                completion(editor.text)
            }
        }
    }
}
