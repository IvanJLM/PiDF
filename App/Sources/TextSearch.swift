import PDFKit

/// One match of a search: where it is. A selection is made only for what is
/// on screen: a long manual can have hundreds of thousands of matches.
struct FindMatch: Equatable, Sendable {
    let page: Int
    let range: NSRange
}

/// Looks for text in a document's pages, with what PDFKit's own find matches:
/// the same text, accents and case ignored, within a page.
enum TextSearch {
    nonisolated static func matches(of text: String, onPageAt index: Int, of document: PDFDocument) -> [FindMatch] {
        guard let string = document.page(at: index)?.string as NSString? else { return [] }
        var found: [FindMatch] = []
        var start = 0
        while start < string.length {
            let range = string.range(of: text, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: NSRange(location: start, length: string.length - start))
            guard range.location != NSNotFound else { break }
            found.append(FindMatch(page: index, range: range))
            start = range.location + max(range.length, 1)
        }
        return found
    }
}

/// A search over the file, on other threads. PDFKit keeps the text of every
/// page it has read for as long as the document lives (over a gigabyte for
/// 3,000 pages), so each stretch of pages is read through a copy of the
/// document that goes when the stretch is done.
final class OffScreenSearch: @unchecked Sendable {
    private static let pagesPerCopy = 25
    private static let threads = 4

    private let lock = NSLock()
    private var cancelled = false
    private var nextStretch = 0
    private var nextToDeliver = 0
    private var finished: [Int: [FindMatch]] = [:]

    private let text: String
    private let pageCount: Int
    private let open: @Sendable () -> PDFDocument?
    /// Called on the main thread, in page order; true with the last matches.
    private let deliver: @MainActor @Sendable ([FindMatch], Bool) -> Void

    private var stretches: Int { (pageCount + Self.pagesPerCopy - 1) / Self.pagesPerCopy }

    init(text: String, pageCount: Int, open: @escaping @Sendable () -> PDFDocument?,
         deliver: @escaping @MainActor @Sendable ([FindMatch], Bool) -> Void) {
        self.text = text
        self.pageCount = pageCount
        self.open = open
        self.deliver = deliver
    }

    func start() {
        let threads = min(stretches, Self.threads)
        guard threads > 0 else {
            let deliver = self.deliver
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver([], true) } }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: threads) { _ in self.work() }
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    private func work() {
        while let stretch = claimStretch() {
            let first = stretch * Self.pagesPerCopy
            var found: [FindMatch] = []
            autoreleasepool {
                guard let document = open() else { return }
                for index in first..<min(first + Self.pagesPerCopy, pageCount) where !isCancelled {
                    found += TextSearch.matches(of: text, onPageAt: index, of: document)
                }
            }
            finish(stretch, found)
        }
    }

    private func claimStretch() -> Int? {
        lock.withLock {
            guard !cancelled, nextStretch < stretches else { return nil }
            defer { nextStretch += 1 }
            return nextStretch
        }
    }

    /// Hands over what is ready, in page order, whichever thread got there
    /// first. Queued for the main thread under the lock, so two threads can't
    /// queue their stretches the other way round.
    private func finish(_ stretch: Int, _ found: [FindMatch]) {
        lock.withLock {
            guard !cancelled else { return }
            finished[stretch] = found
            var matches: [FindMatch] = []
            let first = nextToDeliver
            while let next = finished.removeValue(forKey: nextToDeliver) {
                matches += next
                nextToDeliver += 1
            }
            guard nextToDeliver != first else { return }
            let last = nextToDeliver == stretches, deliver = self.deliver
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(matches, last) } }
        }
    }
}
