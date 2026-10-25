// Writes a long test document: A4 pages of text, headings and simple vector
// drawings, so the benchmark and manual tests need no binary files.
// Usage: swift scripts/make-test-pdf.swift out.pdf [pages]
import AppKit
import CoreText

let arguments = CommandLine.arguments
guard arguments.count > 1 else { print("Usage: swift scripts/make-test-pdf.swift out.pdf [pages]"); exit(1) }
let url = URL(fileURLWithPath: arguments[1])
let pages = arguments.count > 2 ? Int(arguments[2]) ?? 300 : 300
var box = CGRect(x: 0, y: 0, width: 595, height: 842)
guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: "PiDF test document"] as CFDictionary) else { exit(1) }

let words = """
lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna \
aliqua ut enim ad minim veniam quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat \
duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur excepteur sint \
occaecat cupidatat non proident sunt in culpa qui officia deserunt mollit anim id est laborum
""".split(separator: " ")
var seed: UInt64 = 42
func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }

for page in 1...pages {
    context.beginPDFPage(nil)
    let text = NSMutableAttributedString(string: "Chapter \(page)\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 22)])
    for _ in 0..<7 {
        let sentence = (0..<(60 + random(40))).map { _ in String(words[random(words.count)]) }.joined(separator: " ")
        text.append(NSAttributedString(string: sentence.prefix(1).uppercased() + sentence.dropFirst() + ".\n\n",
                                       attributes: [.font: NSFont(name: "Times New Roman", size: 11.5) ?? NSFont.systemFont(ofSize: 11.5)]))
    }
    let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(),
                                         CGPath(rect: CGRect(x: 60, y: 260, width: 475, height: 520), transform: nil), nil)
    CTFrameDraw(frame, context)
    // A small chart.
    for bar in 0..<12 {
        context.setFillColor(CGColor(red: 0.86, green: 0.35 + Double(bar) * 0.04, blue: 0.46, alpha: 1))
        context.fill(CGRect(x: 60 + bar * 39, y: 80, width: 28, height: 30 + random(130)))
    }
    let footer = CTLineCreateWithAttributedString(NSAttributedString(string: "\(page)", attributes: [.font: NSFont.systemFont(ofSize: 9)]))
    context.textPosition = CGPoint(x: 292, y: 40)
    CTLineDraw(footer, context)
    context.endPDFPage()
}
context.closePDF()
print("Wrote \(pages) pages to \(url.path)")
