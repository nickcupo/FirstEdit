#if canImport(AppKit)
import AppKit
import QuartzCore

/// The Whole Burst: every frame in shutter order, nothing hidden, his marks and
/// the cull's drawn exactly as §2.5.9 draws them, the frame at the cursor
/// ringed, auto-scrolled to keep it visible.
///
/// "How did that burst go" without leaving the frame he is on — and the right
/// thing to have up when someone is standing behind him.
///
/// An `NSCollectionView` because a burst is a hundred to three hundred frames
/// and its cells are recycled; a lazy stack of three hundred image views on a
/// 5K is a memory figure, not a view.
@MainActor
public final class ContactSheetView: NSView {

    public var onPick: ((String) -> Void)?
    public var pump: ImagePump?
    public var surround: ViewerBackground = .neutralGrey {
        didSet { source.surround = surround }
    }

    private let scroll = NSScrollView()
    private let collection = NSCollectionView()
    private let flow = NSCollectionViewFlowLayout()
    private var source = Source()

    public private(set) var shoot = ""
    public private(set) var cells: [BurstCell] = []
    public private(set) var cursor = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        flow.itemSize = NSSize(width: DisplayMetric.cellWidth,
                                 height: DisplayMetric.cellHeight(forWidth: DisplayMetric.cellWidth))
        flow.minimumInteritemSpacing = DisplayMetric.cellGap
        flow.minimumLineSpacing = DisplayMetric.cellGap
        flow.sectionInset = NSEdgeInsets(top: DisplayMetric.pictureInset,
                                           left: DisplayMetric.pictureInset,
                                           bottom: DisplayMetric.pictureInset,
                                           right: DisplayMetric.pictureInset)

        collection.collectionViewLayout = flow
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.register(BurstCellItem.self,
                            forItemWithIdentifier: BurstCellItem.identifier)
        collection.dataSource = source
        collection.delegate = source
        source.owner = self

        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    public override func layout() {
        super.layout()
        sizeCells()
    }

    /// The cells grow to fill the glass for the burst he is in.
    private func sizeCells() {
        let width = DisplayMetric.cellWidth(forFrames: cells.count, in: bounds)
        let size = NSSize(width: width, height: DisplayMetric.cellHeight(forWidth: width))
        guard flow.itemSize != size else { return }
        flow.itemSize = size
        source.cellWidth = width
        flow.invalidateLayout()
    }

    public func show(shoot: String, cells: [BurstCell], cursor: Int) {
        let sameFrames = self.cells.map(\.stem) == cells.map(\.stem) && self.shoot == shoot
        self.shoot = shoot
        self.cells = cells
        self.cursor = cursor
        source.cells = cells
        source.shoot = shoot
        source.pump = pump
        source.cursor = cursor
        source.surround = surround
        sizeCells()
        if sameFrames {
            // Marks and the ring move without the whole sheet being rebuilt.
            for item in collection.visibleItems() {
                guard let item = item as? BurstCellItem,
                      let path = collection.indexPath(for: item),
                      cells.indices.contains(path.item) else { continue }
                item.apply(cells[path.item], isCursor: path.item == cursor)
            }
        } else {
            collection.reloadData()
        }
        scrollToCursor()
    }

    private func scrollToCursor() {
        guard cells.indices.contains(cursor) else { return }
        let path = IndexPath(item: cursor, section: 0)
        // Under Reduce Motion the sheet moves to the cursor without sliding
        // (DESIGN.md §2.14).
        if Motion.reduced {
            collection.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        } else {
            collection.animator().scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        }
    }

    // MARK: - the data source, kept off the view itself

    private final class Source: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        weak var owner: ContactSheetView?
        var cells: [BurstCell] = []
        var shoot = ""
        var cursor = 0
        var cellWidth = DisplayMetric.cellWidth
        var surround: ViewerBackground = .neutralGrey
        var pump: ImagePump?

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(_ collectionView: NSCollectionView,
                            numberOfItemsInSection section: Int) -> Int { cells.count }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: BurstCellItem.identifier, for: indexPath)
            guard let cell = item as? BurstCellItem, cells.indices.contains(indexPath.item) else {
                return item
            }
            cell.pump = pump
            cell.shoot = shoot
            cell.cellWidth = cellWidth
            cell.surround = surround
            cell.apply(cells[indexPath.item], isCursor: indexPath.item == cursor)
            return cell
        }

        /// A click moves the cursor, exactly as a filmstrip click does. Never a
        /// verdict.
        func collectionView(_ collectionView: NSCollectionView,
                            didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard let first = indexPaths.first, cells.indices.contains(first.item) else { return }
            owner?.onPick?(cells[first.item].stem)
        }
    }
}

/// One cell: the frame, his mark filled, the cull's hollow, the stack bracket,
/// and the cursor's ring.
@MainActor
final class BurstCellItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("displays.burstCell")

    var pump: ImagePump?
    var shoot = ""
    var cellWidth = DisplayMetric.cellWidth
    /// The cells sit on the surround, so the number and the cull's marks take
    /// their contrast from it rather than from light or dark.
    var surround: ViewerBackground = .neutralGrey
    private let picture = CALayer()
    private let ring = CALayer()
    private let bracket = CALayer()
    private let hisMark = NSImageView()
    private let cullMark = NSImageView()
    private let number = NSTextField(labelWithString: "")
    private var load: Task<Void, Never>?
    private var stem = ""

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: DisplayMetric.cellWidth, height: 178))
        v.wantsLayer = true
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let layer = view.layer else { return }
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        picture.cornerRadius = 4
        picture.minificationFilter = .trilinear
        picture.backgroundColor = DisplaySurround.greyDark.cgColor
        layer.addSublayer(picture)

        ring.borderColor = NSColor.controlAccentColor.cgColor
        ring.borderWidth = DisplayMetric.cursorRing
        ring.cornerRadius = 5
        ring.opacity = 0
        layer.addSublayer(ring)

        bracket.backgroundColor = NSColor(DisplaySurround.ink(.neutralGrey, wide: true,
                                                              opacity: 0.45)).cgColor
        bracket.opacity = 0
        layer.addSublayer(bracket)

        for mark in [hisMark, cullMark] {
            mark.imageScaling = .scaleProportionallyUpOrDown
            mark.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(mark)
        }
        number.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        number.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(number)

        NSLayoutConstraint.activate([
            hisMark.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            hisMark.bottomAnchor.constraint(equalTo: number.topAnchor, constant: -4),
            hisMark.widthAnchor.constraint(equalToConstant: 18),
            hisMark.heightAnchor.constraint(equalToConstant: 18),
            cullMark.leadingAnchor.constraint(equalTo: hisMark.trailingAnchor, constant: 4),
            cullMark.centerYAnchor.constraint(equalTo: hisMark.centerYAnchor),
            cullMark.widthAnchor.constraint(equalToConstant: 16),
            cullMark.heightAnchor.constraint(equalToConstant: 16),
            number.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            number.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let h = view.bounds.height - DisplayMetric.cellCaption
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = CGRect(x: 0, y: DisplayMetric.cellCaption,
                               width: view.bounds.width, height: max(0, h))
        ring.frame = picture.frame.insetBy(dx: -1, dy: -1)
        // The stack this frame belongs to, drawn under the picture and clear of
        // the number, so it groups without writing anything over the frame.
        bracket.frame = CGRect(x: 6, y: DisplayMetric.cellCaption - 3,
                               width: max(0, view.bounds.width - 12), height: 2)
        picture.contentsScale = view.window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    func apply(_ cell: BurstCell, isCursor: Bool) {
        let ink = NSColor(DisplaySurround.ink(surround, wide: true, opacity: 0.7))
        number.stringValue = cell.shortStem
        number.textColor = ink
        // His marks are filled. The machine's are outlines. They never share a
        // field and neither ever falls back to the other.
        switch cell.his {
        case .kept:
            hisMark.image = NSImage(systemSymbolName: Symbols.hisKeep, accessibilityDescription: nil)
            hisMark.contentTintColor = .systemGreen
        case .out:
            hisMark.image = NSImage(systemSymbolName: Symbols.hisDrop, accessibilityDescription: nil)
            hisMark.contentTintColor = .systemRed
        case .unmarked:
            hisMark.image = nil
        }
        switch cell.cull {
        case .none: cullMark.image = nil
        case .forward: cullMark.image = NSImage(systemSymbolName: Symbols.cullForward, accessibilityDescription: nil)
        case .aside: cullMark.image = NSImage(systemSymbolName: Symbols.cullAside, accessibilityDescription: nil)
        case .fault: cullMark.image = NSImage(systemSymbolName: Symbols.cullFault, accessibilityDescription: nil)
        }
        // The machine's mark is hollow and quiet, and it is never in the same
        // field as his.
        cullMark.contentTintColor = ink
        bracket.opacity = cell.stack == nil ? 0 : 1
        ring.opacity = isCursor ? 1 : 0

        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel(cell.shortStem)

        guard cell.stem != stem else { return }
        stem = cell.stem
        picture.contents = nil
        let scale = view.window?.backingScaleFactor ?? 2
        let tier = PixelTier.cellTier(forPointWidth: cellWidth, scale: scale)
        let key = ImagePump.Key(shoot: shoot, stem: cell.stem, tier: tier)
        load?.cancel()
        if let already = pump?.cached(key) {
            picture.contents = DisplayColor.tagged(already)
            return
        }
        let pump = self.pump
        load = Task { [weak self] in
            guard let image = try? await pump?.image(key, priority: .utility) else { return }
            guard let self, self.stem == cell.stem else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.picture.contents = DisplayColor.tagged(image)
            CATransaction.commit()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        load?.cancel()
        stem = ""
        picture.contents = nil
    }
}
#endif
