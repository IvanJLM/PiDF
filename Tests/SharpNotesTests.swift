import AppKit
import PDFKit
import XCTest
@testable import PiDF

/// Notes stay as sharp as the page, also where PDFKit draws them at one
/// pixel per point (macOS 27.0).
@MainActor
final class SharpNotesTests: XCTestCase {
    private var app: AppDelegate { NSApp.delegate as! AppDelegate }

    override func tearDown() async throws {
        for controller in app.controllers { controller.close() }
        await wait(0.1)
    }

    /// PDFKit as on macOS 27.0: it works out one pixel per point for every
    /// note layer. Returns what puts it back.
    private func breakNoteLayers() throws -> () -> Void {
        let selector = NSSelectorFromString("convertRectToRootView:fromPageLayer:")
        let method = try XCTUnwrap(class_getInstanceMethod(PDFView.self, selector), "PDFKit changed: the test can't simulate the bug")
        let original = method_getImplementation(method)
        let unit: @convention(block) (AnyObject, CGRect, AnyObject) -> CGRect = { _, _, _ in CGRect(x: 0, y: 0, width: 1, height: 1) }
        method_setImplementation(method, imp_implementationWithBlock(unit))
        return { method_setImplementation(method, original) }
    }

    /// The resolution of every note layer of `view`, in pixels per point.
    private func noteScales(in view: PDFView) throws -> [CGFloat] {
        let layerClass: AnyClass = try XCTUnwrap(SharpNotes.layerClass)
        var scales: [CGFloat] = []
        func walk(_ layer: CALayer) {
            if layer.isKind(of: layerClass) { scales.append(layer.contentsScale) }
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
        }
        walk(try XCTUnwrap(view.layer))
        return scales
    }

    private func assertSharp(_ controller: DocumentWindowController, _ moment: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let view = controller.pdfView
        // The note on screen, whatever the size of the test machine's screen.
        let page = try XCTUnwrap(controller.pdf?.page(at: 0), file: file, line: line)
        let note = try XCTUnwrap(page.annotations.first(where: Marks.isNote), "no note \(moment)", file: file, line: line)
        view.go(to: note.bounds, on: page)
        let wanted = view.scaleFactor * (controller.window?.backingScaleFactor ?? 1)
        // A document read again builds its note layers a little later.
        await waitUntil(5) {
            let scales = (try? self.noteScales(in: view)) ?? []
            return !scales.isEmpty && scales.allSatisfy { abs($0 - wanted) < 0.01 }
        }
        let scales = try noteScales(in: view)
        XCTAssertFalse(scales.isEmpty, "no note layer \(moment)", file: file, line: line)
        for scale in scales { XCTAssertEqual(scale, wanted, accuracy: 0.01, moment, file: file, line: line) }
    }

    func testNotesAreDrawnAtTheResolutionTheyAreShownAt() async throws {
        let restore = try breakNoteLayers()
        defer { restore() }
        let url = try Fixtures.pdf(at: try Fixtures.folder(self).appendingPathComponent("sharp.pdf"), pages: ["first page text"])
        let controller = app.open([url], nextTo: nil)[0]
        controller.pdfView.scaleFactor = 2.5
        let page = try XCTUnwrap(controller.pdf?.page(at: 0))
        controller.add(note: "A note that must stay sharp", at: NSPoint(x: 60, y: 760), on: page)
        try await assertSharp(controller, "when added")

        controller.pdfView.scaleFactor = 1.6
        try await assertSharp(controller, "after zooming out")
        controller.pdfView.scaleFactor = 4
        try await assertSharp(controller, "after zooming in")

        XCTAssertTrue(controller.saveChanges())
        try await assertSharp(controller, "read again from the saved file")
    }
}
