import AppKit
import CoreText
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
        await waitUntil { !bar.isSearching }
        XCTAssertEqual(bar.matches.count, 2, "case-insensitive")
        XCTAssertTrue(bar.searchedOffScreen, "the file is what's on screen")
        XCTAssertEqual(controller.pdfView.highlightedSelections?.isEmpty, false, "the matches in view highlighted")
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
        await waitUntil { controller.findBar?.matches.count == 1 && controller.findBar?.isSearching == false }
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
        await waitUntil { !bar.isSearching }
        XCTAssertTrue(bar.matches.isEmpty)
    }

    /// Text that a plain comparison gets wrong, in a font with ligatures.
    private func awkwardDocument() throws -> URL {
        let url = try Fixtures.folder(self).appendingPathComponent("awkward.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        let pages = [["Café crème à la carte, CAFÉ fort", "the office offers efficient flow fluid"],
                     ["two words split", "over lines here: alpha", "beta gamma", "an exam-", "ple of hyphen, co-operate"],
                     ["STRASSE und Straße", "non\u{A0}breaking space and double  space", "1,5 kg; 50 % — dash – end", "NFD Cafe\u{301} here", "ﬁne ligature char ﬂow"],
                     ["Next page start of a sentence that"],
                     ["continues on the following page", "İstanbul ISTANBUL istanbul", "Ñandú nandu"],
                     [],
                     ["repeat repeat repeat repeatrepeat", "aaaa"]]
        for lines in pages {
            context.beginPDFPage(nil)
            for (number, text) in lines.enumerated() {
                let attributes: [NSAttributedString.Key: Any] = [.font: try XCTUnwrap(NSFont(name: "Times New Roman", size: 14)), .ligature: 2]
                context.textPosition = CGPoint(x: 60, y: 780 - CGFloat(number) * 18)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    func testFindsWhatPDFKitsOwnFindFinds() throws {
        let document = try XCTUnwrap(PDFDocument(url: try awkwardDocument()))
        for text in ["cafe", "CAFÉ", "creme", "office", "efficient", "flow", "fi", "two words", "split over", "alpha beta", "example", "exam-",
                     "co-operate", "strasse", "straße", "non breaking", "double space", "double  space", "50 %", "dash – end", "dash - end", "fine",
                     "that continues", "istanbul", "ñandu", "repeat", "aa", "e", " "] {
            let theirs = document.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
            let ours = (0..<document.pageCount).flatMap { TextSearch.matches(of: text, onPageAt: $0, of: document) }
            XCTAssertEqual(ours.map(\.page), theirs.map { document.index(for: $0.pages[0]) }, "“\(text)”: same pages")
            let selected = ours.map { document.page(at: $0.page)?.selection(for: $0.range)?.string }
            XCTAssertEqual(selected, theirs.map(\.string), "“\(text)”: same text")
        }
    }

    func testBothWaysOfSearchingFindTheSame() async throws {
        let controller = try open((1...130).map { $0 % 3 == 0 ? "needle \($0) and Needle" : "nothing \($0)" })
        controller.showFind(nil)
        let bar = try XCTUnwrap(controller.findBar)
        bar.search("needle")
        await waitUntil { !bar.isSearching }
        XCTAssertTrue(bar.searchedOffScreen)
        let offScreen = bar.matches
        XCTAssertEqual(offScreen.count, 86)
        XCTAssertEqual(offScreen.map(\.page), offScreen.map(\.page).sorted(), "in page order, over several copies")

        controller.add(note: "not saved", at: NSPoint(x: 80, y: 400), on: try XCTUnwrap(controller.pdf?.page(at: 0)))
        bar.search("needle")
        XCTAssertFalse(bar.searchedOffScreen, "the file doesn't have the note")
        await waitUntil { !bar.isSearching }
        XCTAssertEqual(bar.matches, offScreen)
    }

    func testAPageDeletedAndNotSavedYetIsNotLookedFor() async throws {
        let controller = try open(["needle one", "two", "needle three"])
        controller.deletePage(nil)
        controller.showFind(nil)
        let bar = try XCTUnwrap(controller.findBar)
        bar.search("needle")
        await waitUntil { !bar.isSearching }
        XCTAssertEqual(bar.matches, [FindMatch(page: 1, range: NSRange(location: 0, length: 6))])
    }

    func testAProtectedDocumentIsSearchedWithItsPassword() async throws {
        let url = try Fixtures.pdf(at: try Fixtures.folder(self).appendingPathComponent("locked.pdf"), pages: ["secret needle"], password: "fixture-pw")
        let controller = app.open([url], nextTo: nil)[0]
        await waitUntil { controller.window?.attachedSheet != nil }
        XCTAssertTrue(controller.unlock(with: "fixture-pw"))
        controller.showFind(nil)
        let bar = try XCTUnwrap(controller.findBar)
        bar.search("needle")
        XCTAssertTrue(bar.searchedOffScreen)
        await waitUntil { !bar.isSearching }
        XCTAssertEqual(bar.matches.count, 1)
        if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
    }

    func testANewSearchDropsThePagesOfTheLastOne() async throws {
        let controller = try open((1...200).map { "alpha \($0)" } + ["beta"])
        controller.showFind(nil)
        let bar = try XCTUnwrap(controller.findBar)
        bar.search("alpha")
        bar.search("beta")
        await waitUntil { !bar.isSearching }
        await wait(0.2)
        XCTAssertEqual(bar.matches.map(\.page), [200])
        XCTAssertEqual(controller.pageIndex, 200, "at its match")
    }

    func testHighlightsFollowThePagesInView() async throws {
        let controller = try open((1...40).map { "needle on page \($0)" })
        controller.showFind(nil)
        let bar = try XCTUnwrap(controller.findBar)
        bar.search("needle")
        await waitUntil { !bar.isSearching }
        XCTAssertEqual(bar.matches.count, 40)
        let shown = try XCTUnwrap(controller.pdf)
        func highlightedPages() -> Set<Int> { Set((controller.pdfView.highlightedSelections ?? []).compactMap { $0.pages.first.map(shown.index(for:)) }) }
        XCTAssertLessThan(controller.pdfView.highlightedSelections?.count ?? 99, 10, "not the 40")
        XCTAssertTrue(highlightedPages().contains(0))
        controller.go(toIndex: 30)
        await waitUntil { highlightedPages().contains(30) }
        XCTAssertTrue(highlightedPages().contains(30), "made as they come into view")
        XCTAssertFalse(highlightedPages().contains(0))
        let clipView = try XCTUnwrap(controller.pdfView.documentView?.enclosingScrollView?.contentView)
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: clipView.bounds.minY + 3 * 842))
        await waitUntil { !highlightedPages().contains(30) }
        XCTAssertFalse(highlightedPages().contains(30), "and scrolling brings in others")
        XCTAssertFalse(highlightedPages().isEmpty)
    }

    func testMatchesFoundAfterAScrollAreHighlightedToo() async throws {
        let controller = try open(["needle one", "needle two"])
        controller.showFind(nil)
        let bar = try XCTUnwrap(controller.findBar)
        let clipView = try XCTUnwrap(controller.pdfView.documentView?.enclosingScrollView?.contentView)
        bar.search("needle")
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: clipView.bounds.minY + 1))  // before any match
        await waitUntil { !bar.isSearching }
        await waitUntil { controller.pdfView.highlightedSelections?.isEmpty == false }
        XCTAssertEqual(controller.pdfView.highlightedSelections?.isEmpty, false)
    }

    func testASearchCutShortByAnotherTabGoesOnWhenItComesBack() async throws {
        let folder = try Fixtures.folder(self)
        let url = try Fixtures.pdf(at: folder.appendingPathComponent("a.pdf"), pages: (1...400).map { "needle \($0)" })
        let first = app.open([url], nextTo: nil)[0]
        first.add(note: "not saved", at: NSPoint(x: 80, y: 400), on: try XCTUnwrap(first.pdf?.page(at: 0)))
        first.showFind(nil)
        let bar = try XCTUnwrap(first.findBar)
        bar.search("needle")
        XCTAssertTrue(bar.isSearching)
        first.park()
        XCTAssertFalse(bar.isSearching, "another thread writes the document now")
        await waitUntil { !first.hasUnsavedAnnotations }
        first.unpark()
        await waitUntil { !bar.isSearching }
        XCTAssertEqual(bar.matches.count, 400)
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
