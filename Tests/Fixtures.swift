import AppKit
import CoreText
import XCTest

/// Writes small test PDFs with Core Graphics, so the repository needs no
/// binary fixtures.
enum Fixtures {
    static func folder(_ test: XCTestCase) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PiDFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// A PDF with one page per string, each page showing its string.
    /// `size` is the page size in points (A4 portrait by default).
    @discardableResult
    static func pdf(at url: URL, pages: [String], size: CGSize = CGSize(width: 595, height: 842),
                    password: String? = nil) throws -> URL {
        var box = CGRect(origin: .zero, size: size)
        var info: [CFString: Any] = [kCGPDFContextTitle: "Fixture"]
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
        }
        // Written next to the target and moved in place, as editors save.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        guard let context = CGContext(temporary as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for text in pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)]))
            context.textPosition = CGPoint(x: 60, y: size.height - 100)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        return url
    }

    static func pdf(in folder: URL, name: String = "doc.pdf", pageCount: Int, size: CGSize = CGSize(width: 595, height: 842)) throws -> URL {
        try pdf(at: folder.appendingPathComponent(name), pages: (1...pageCount).map { "Page \($0)" }, size: size)
    }
}

extension XCTestCase {
    /// Lets the run loop work for `seconds` (animations, timers, layout).
    @MainActor
    func wait(_ seconds: Double) async {
        let idle = expectation(description: "wait")
        idle.isInverted = true
        await fulfillment(of: [idle], timeout: seconds)
    }

    /// Waits until `condition` holds, up to `timeout` seconds.
    @MainActor
    func waitUntil(_ timeout: Double = 5, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { await wait(0.05) }
    }
}
