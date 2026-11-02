import AppKit
import PDFKit

/// All the pages of a document in a grid, over the document, to go to one of
/// them: a double click or Return goes there. It exists only while it is on
/// screen, and it draws only the pages in view, so it costs nothing until it
/// is asked for and lets everything go when it closes.
@MainActor
final class PageSelector: NSView, NSCollectionViewDataSource {
    /// The room for a page in the grid; a page keeps its shape within it.
    nonisolated static let thumbnail = NSSize(width: 170, height: 240)
    /// The thumbnails kept for scrolling back, a screen or two's worth.
    static let keptThumbnails = 64
    private nonisolated static let drawing = DispatchQueue(label: "PiDF.thumbnails", qos: .userInitiated)

    let grid = PageGrid()
    private let scroll = NSScrollView()
    private let layoutGrid = NSCollectionViewFlowLayout()
    /// The document shown, for this thread: how many pages, how big.
    private var document: PDFDocument
    /// The file read by the grid alone, for the drawing queue: a document
    /// can't be used from two threads at once. Nil with changes not saved yet,
    /// which only the document shown has: its pages are drawn on this thread.
    private var copy: OffThread<PDFDocument>?
    private let kept = NSCache<NSNumber, NSImage>()

    /// A cell waiting for its page.
    private struct Wanted {
        let index: Int
        weak var item: PageItem?
    }

    /// One page is drawn at a time, so the cells that move on before their
    /// turn cost nothing.
    private var waiting: [Wanted] = []
    private var isDrawing = false
    /// Counts the documents shown: a page drawn from an earlier one is dropped.
    private var version = 0

    /// How many thumbnails have been drawn (used by the tests).
    private(set) var drawn = 0
    /// Whether the pages are drawn on another thread (used by the tests).
    var drawsOffThread: Bool { copy != nil }

    /// A page was chosen: its index.
    var onChoose: ((Int) -> Void)?

    init(frame: NSRect, document: PDFDocument, copy: PDFDocument?, topInset: CGFloat, background: NSColor) {
        self.document = document
        self.copy = copy.map(OffThread.init)
        super.init(frame: frame)
        kept.countLimit = Self.keptThumbnails
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        autoresizingMask = [.width, .height]

        layoutGrid.itemSize = NSSize(width: Self.thumbnail.width + 20, height: Self.thumbnail.height + 30)
        layoutGrid.minimumInteritemSpacing = 12
        layoutGrid.minimumLineSpacing = 16
        layoutGrid.sectionInset = NSEdgeInsets(top: topInset, left: 24, bottom: 24, right: 24)
        grid.collectionViewLayout = layoutGrid
        grid.dataSource = self
        grid.isSelectable = true
        grid.allowsEmptySelection = false
        grid.backgroundColors = [.clear]
        grid.register(PageItem.self, forItemWithIdentifier: PageItem.identifier)
        grid.onChoose = { [weak self] index in self?.onChoose?(index) }

        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = grid
        addSubview(scroll)

        grid.reloadData()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var selectedIndex: Int? { grid.selectionIndexPaths.first?.item }
    var pageCount: Int { document.pageCount }

    /// The indexes of the pages in view.
    var visibleIndexes: [Int] { grid.indexPathsForVisibleItems().map(\.item).sorted() }

    func select(_ index: Int, scrollingToIt: Bool) {
        let path = IndexPath(item: min(max(index, 0), max(document.pageCount - 1, 0)), section: 0)
        grid.selectionIndexPaths = [path]
        guard scrollingToIt else { return }
        // In a window by now, so the grid knows its width and its columns.
        layoutSubtreeIfNeeded()
        grid.layoutSubtreeIfNeeded()
        grid.scrollToItems(at: [path], scrollPosition: .centeredVertically)
    }

    /// The document changed: a page went, came back or turned, or the file
    /// was read again.
    func reload(_ document: PDFDocument, copy: PDFDocument?) {
        let selected = selectedIndex ?? 0
        self.document = document
        self.copy = copy.map(OffThread.init)
        version += 1
        waiting = []
        kept.removeAllObjects()
        grid.reloadData()
        select(selected, scrollingToIt: false)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        document.pageCount
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PageItem.identifier, for: indexPath)
        guard let item = item as? PageItem, let page = document.page(at: indexPath.item) else { return item }
        let index = indexPath.item
        item.show(number: index + 1, size: Self.shownSize(of: page), image: kept.object(forKey: index as NSNumber))
        if item.image == nil {
            waiting.append(Wanted(index: index, item: item))
            drawNext()
        }
        return item
    }

    /// Draws the next page some cell still wants, one per turn of the run loop
    /// on this thread, so scrolling and keys get theirs in between.
    private func drawNext() {
        guard !isDrawing else { return }
        while !waiting.isEmpty {
            let wanted = waiting.removeFirst()
            // A cell that has moved on to another page doesn't draw this one.
            guard let item = wanted.item, item.number == wanted.index + 1, item.image == nil else { continue }
            if let image = kept.object(forKey: wanted.index as NSNumber) {
                item.image = image  // it went and came back
                continue
            }
            isDrawing = true
            return draw(wanted)
        }
    }

    private func draw(_ wanted: Wanted) {
        let index = wanted.index, version = self.version, scale = window?.backingScaleFactor ?? 2
        if let copy {
            Self.drawing.async { [weak self] in
                let image = OffThread(copy.value.page(at: index).flatMap { Self.quickImage(of: $0, scale: scale) })
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finish(wanted, image.value, version) }
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let current = version == self.version
                    self.finish(wanted, current ? self.document.page(at: index).flatMap { Self.image(of: $0, scale: scale) } : nil, version)
                }
            }
        }
    }

    private func finish(_ wanted: Wanted, _ image: NSImage?, _ drawnVersion: Int) {
        isDrawing = false
        if drawnVersion == version, let image {
            kept.setObject(image, forKey: wanted.index as NSNumber)
            drawn += 1
            if let item = wanted.item, item.number == wanted.index + 1 { item.image = image }
        }
        drawNext()
    }

    /// The size a page takes in the grid, turned as it is shown.
    private nonisolated static func shownSize(of page: PDFPage) -> NSSize {
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
        let scale = min(thumbnail.width / max(size.width, 1), thumbnail.height / max(size.height, 1))
        return NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// `page` drawn small from the file as it was read: PDFPage's thumbnail
    /// takes about a quarter of the time of drawing the page.
    nonisolated static func quickImage(of page: PDFPage, scale: CGFloat) -> NSImage? {
        let size = shownSize(of: page)
        return page.thumbnail(of: NSSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
    }

    /// `page` drawn small, as it is shown. PDFKit, drawing a turned page off
    /// screen, doesn't turn the Notes made since the file was read (PDFPage's
    /// thumbnail even stretches them), so those are drawn here.
    static func image(of page: PDFPage, scale: CGFloat) -> NSImage? {
        let size = shownSize(of: page)
        var box = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { box = NSSize(width: box.height, height: box.width) }
        guard box.width > 0, box.height > 0,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: CGFloat(context.width) / box.width, y: CGFloat(context.height) / box.height)
        let notes = page.rotation == 0 ? [] : page.annotations.filter { $0 is Note && $0.shouldDisplay }
        for note in notes { note.shouldDisplay = false }
        page.draw(with: .cropBox, to: context)
        for note in notes { note.shouldDisplay = true }
        if !notes.isEmpty {
            context.concatenate(page.transform(for: .cropBox))
            for note in notes { note.draw(with: .cropBox, in: context) }
        }
        return context.makeImage().map { NSImage(cgImage: $0, size: size) }
    }
}

/// Hands a value to another thread, which alone touches it from then on.
private struct OffThread<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// The grid itself: a click on a page selects it, a double click chooses it.
final class PageGrid: NSCollectionView {
    var onChoose: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathsForVisibleItems().first(where: { layoutAttributesForItem(at: $0)?.frame.contains(point) == true }) else { return }
        window?.makeFirstResponder(self)
        selectionIndexPaths = [path]
        if event.clickCount == 2 { onChoose?(path.item) }
    }
}

/// One page in the grid, with its number below it.
final class PageItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PageItem")

    private let sheet = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private(set) var number = 0
    private var size = NSSize.zero

    var image: NSImage? {
        get { sheet.image }
        set { sheet.image = newValue }
    }

    /// Clicks go through to the grid, which selects and chooses.
    private final class Cell: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    override func loadView() {
        view = Cell(frame: NSRect(origin: .zero, size: NSSize(width: PageSelector.thumbnail.width + 20, height: PageSelector.thumbnail.height + 30)))
        sheet.imageScaling = .scaleProportionallyUpOrDown
        sheet.wantsLayer = true
        sheet.layer?.backgroundColor = NSColor.white.cgColor
        view.addSubview(sheet)
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        view.addSubview(label)
        updateSelection()
    }

    func show(number: Int, size: NSSize, image: NSImage?) {
        self.number = number
        self.size = size
        sheet.image = image
        label.stringValue = "\(number)"
        view.needsLayout = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let room = view.bounds
        sheet.frame = NSRect(x: ((room.width - size.width) / 2).rounded(), y: 26 + ((room.height - 30 - size.height) / 2).rounded(),
                             width: size.width, height: size.height)
        let width = max(label.intrinsicContentSize.width + 12, 28)
        label.frame = NSRect(x: ((room.width - width) / 2).rounded(), y: 3, width: width, height: 17)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        sheet.image = nil
        number = 0
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        sheet.layer?.borderWidth = isSelected ? 3 : 0
        sheet.layer?.borderColor = NSColor.controlAccentColor.cgColor
        label.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        label.textColor = isSelected ? .white : .secondaryLabelColor
    }
}
