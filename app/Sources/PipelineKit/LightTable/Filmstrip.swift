import AppKit
import SwiftUI

/// Every frame of the burst, in shutter order, **nothing hidden** (§2.5.9).
///
/// An `NSCollectionView` inside an `NSViewRepresentable`, because a SwiftUI
/// `LazyHStack` drops frames at 200-plus items on scrub and the collection view
/// recycles — and a burst here is 100 to 300 frames.
///
/// The strip scrolls only when the cursor would leave it, and then by whole
/// pages: it does not slide under the pointer on every arrow press. Click
/// goes to the frame and **never decides**. Double-click is Full Image. ⌘-click
/// and ⇧-click build a Compare set. Drag-select is off — the strip is a place,
/// not a canvas. None of it takes the keyboard from the photograph.
@MainActor
public final class FilmstripView: NSView {

    let model: ViewerModel
    private let scroll = FilmstripScrollView()
    private let collection = FilmstripCollectionView()
    private var frames: [String] = []
    private var stacks: [Stack] = []
    private var loads: [String: Task<Void, Never>] = [:]
    private var lastPageStart = 0
    /// Where the last ⌘- or ⇧-click landed, which a ⇧-click extends from.
    private var compareAnchor: Int?
    /// The cursor was asked for before the strip had a width to page by.
    private var revealPending = false
    /// Increase Contrast, from the system unless a caller overrides it.
    public var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    /// Settings ▸ Choosing's "Show the cull's marks", as the strip last drew
    /// it, and the watch that draws it again the moment it changes rather
    /// than at his next press.
    private var cullMarksShown: Bool?
    private var cullMarksWatch: NSObjectProtocol?

    public init(model: ViewerModel) {
        self.model = model
        super.init(frame: .zero)
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: FilmstripItemView.thumb.width,
                                 height: FilmstripItemView.itemHeight)
        layout.minimumLineSpacing = Tokens.Metric.filmstripGap
        layout.minimumInteritemSpacing = Tokens.Metric.filmstripGap
        layout.sectionInset = NSEdgeInsets(top: 0, left: Tokens.Metric.windowMargin, bottom: 0,
                                           right: Tokens.Metric.windowMargin)

        collection.collectionViewLayout = layout
        collection.dataSource = self
        // No selection of the collection view's own: a press on a thumbnail
        // is the thumbnail's (`press(_:clicks:modifiers:)`). Selectable, the
        // strip took the keyboard at the first click — the arrows and Space
        // went to it, not the photograph — and a thumbnail it still held
        // selected ignored the next click on it: he clicked 5, arrowed to 9,
        // clicked 5 again, and stayed on 9.
        collection.isSelectable = false
        collection.backgroundColors = [.clear]
        collection.register(FilmstripItem.self, forItemWithIdentifier: FilmstripItem.identifier)

        scroll.documentView = collection
        // **No scroll bar** (§2.5.9). The strip pages itself to wherever the
        // cursor goes, a trackpad scrolls it sideways, and a wheel mouse turns
        // it a frame a notch (`FilmstripScrollView`). A scroller cost more
        // than it gave, three times over: the legacy style — a Mac with a
        // wheel mouse attached, his — took 11 pt out of the clip view for a
        // grey track under the frame numbers for good, laid the 90 pt item
        // out 5 pt above the band and sliced the top off the "4 similar" over
        // a run; and the overlay style's knob, even in the band's last few
        // points, still ran across the bottom of every number whenever it
        // showed.
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.onTile = { [weak self] in self?.fitItemToTheBand() }
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            // The scroll view is the whole band and its document stops 5 pt
            // short of the foot (the inset below).
            //
            // 5, not 6. The band is 96 pt and an item is exactly 90 (12
            // bracket + 60 thumb + 4 + 14 caption), so six points of padding
            // left the collection view exactly as tall as its own item, and
            // NSCollectionViewFlowLayout wants strictly taller: it logged
            // "the item height must be less than the height of the
            // collection view" on every layout pass and, in a long-lived
            // process, eventually raised inside a CATransaction flush — which
            // is what killed a whole-set snapshot render every time. One
            // point of padding buys the inequality; nothing moves that anyone
            // can see.
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Set by hand: left automatic, a strip under a title bar was pushed
        // down by the bar's height and lost its captions off the bottom.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 5, right: 0)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(Strings.LightTable.filmstrip)
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    public override var isFlipped: Bool { true }

    /// The one rule `NSCollectionViewFlowLayout` insists on: the item has to
    /// be **strictly shorter** than the view it is laid out in.
    ///
    /// Buying that with a constant is a guess about the chrome. The clip
    /// view's real height is not a guess, so the item is measured against it
    /// on every layout and the item's own 90 pt is a ceiling rather than a
    /// promise. Below 91 pt of band the item is shorter, and what gives up the
    /// difference is **the picture**: the bracket lane and the caption keep
    /// their 12 and 14 points, because they are what the frame's run and the
    /// frame's number are written in, and §2.5.9 is that nothing in the strip
    /// is ever hidden. `FilmstripItemView.draw` measures from its own bounds
    /// for that reason. It used to draw the picture at a fixed 60 pt from a
    /// fixed 12 pt down, which cut the caption off the bottom first — the
    /// opposite of what this comment said.
    ///
    /// From the moment the band has a height, the flow layout logs nothing.
    /// The one pass it still complains on is the one before that, where the
    /// clip view is 0 pt tall and no item height at all is less than it
    /// (measured: an item of 1 pt is refused there just as 90 is).
    public override func layout() {
        super.layout()
        fitItemToTheBand()
        // The first layout with a width, if the cursor was asked for before
        // there was one — which is every time the step opens.
        if revealPending { revealCursorIfItWouldLeave(animated: false) }
    }

    /// Also run whenever the scroll view re-tiles, which is when its clip
    /// view changes height: the strip's own `layout()` does not run again for
    /// that, and an item measured against the old clip was laid out above it.
    private func fitItemToTheBand() {
        guard let flow = collection.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let room = min(scroll.contentView.bounds.height, bounds.height)
        guard room > 1 else { return }
        let height = min(FilmstripItemView.itemHeight, room - 1)
        if abs(flow.itemSize.height - height) > 0.5 {
            flow.itemSize = CGSize(width: FilmstripItemView.thumb.width, height: height)
        }
    }

    // MARK: - keeping up with the cursor

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = cullMarksWatch { NotificationCenter.default.removeObserver(w) }
        cullMarksWatch = nil
        guard window != nil else { return }
        cullMarksWatch = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: model.settings.defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.cullMarksShown != self.model.settings.showCullMarks else { return }
                self.refresh()
            }
        }
    }

    public func refresh() {
        fitItemToTheBand()
        let f = model.frames
        let newBurst = f != frames
        if newBurst {
            frames = f
            stacks = model.stacks
            lastPageStart = 0
            compareAnchor = nil
            collection.reloadData()
        } else {
            stacks = model.stacks
            for item in collection.visibleItems() {
                if let i = collection.indexPath(for: item)?.item { decorate(item, at: i) }
            }
        }
        // Into another burst the strip jumps: sliding across a burst he has
        // just left is motion that means nothing.
        revealCursorIfItWouldLeave(animated: !newBurst)
    }

    /// Whole pages, not a slide under the pointer.
    ///
    /// Where the cursor's thumbnail is comes from the flow's own arithmetic —
    /// the margin, then 90 + 6 a frame — not from the layout's attributes.
    /// Straight after `reloadData`, and before the strip's first layout, the
    /// layout had no attributes to give, and the reveal gave up: on the last
    /// frame of a 32-frame burst reached with ←, on a light table reopened on
    /// frame 20, and after ⌘Z into another burst, the strip showed frames 1
    /// to 11 and no ring anywhere. With no width yet to page by, it waits for
    /// the first layout that has one.
    /// Whether a page turn inside a burst slides. Off in the tests: an
    /// offscreen window never runs the slide, so the page never arrived.
    static var slides = true

    private func revealCursorIfItWouldLeave(animated: Bool) {
        let i = model.frameIndex
        guard frames.indices.contains(i) else { revealPending = false; return }
        let clip = scroll.contentView
        let visible = clip.bounds
        let thumb = FilmstripItemView.thumb.width
        guard visible.width > thumb else { revealPending = true; return }
        revealPending = false
        let pitch = thumb + Tokens.Metric.filmstripGap
        let minX = Tokens.Metric.windowMargin + CGFloat(i) * pitch
        if minX >= visible.minX + thumb / 2 - Tokens.Metric.windowMargin,
           minX + thumb <= visible.maxX - thumb / 2 { return }
        let perPage = max(1, Int(visible.width / pitch))
        let page = i / perPage
        // The strip is as wide as its frames; the last page is the strip's
        // end, not a page of empty band.
        let content = Tokens.Metric.windowMargin * 2 + CGFloat(frames.count) * pitch
            - Tokens.Metric.filmstripGap
        let x = min(CGFloat(page * perPage) * pitch, max(0, content - visible.width))
        let to = NSPoint(x: max(0, x), y: visible.minY)
        lastPageStart = page * perPage
        // The document may not have grown to the new burst yet; it is given
        // its width now rather than clamping the scroll to the old one.
        if collection.frame.width < content {
            collection.setFrameSize(NSSize(width: content, height: collection.frame.height))
        }
        // Under Reduce Motion the page turns without sliding (§2.14).
        if animated && Self.slides && !Motion.reduced {
            clip.animator().setBoundsOrigin(to)
        } else {
            clip.setBoundsOrigin(to)
        }
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: - the data

    private func decorate(_ item: NSCollectionViewItem, at index: Int) {
        guard let cell = item as? FilmstripItem, frames.indices.contains(index) else { return }
        let stem = frames[index]
        let row = model.session.rows[stem]
        var marks = FilmstripItemView.Marks()
        marks.number = ShootSession.shortStem(stem)
        marks.isCurrent = index == model.frameIndex
        marks.cullRating = row?.rating ?? 0
        // Settings ▸ Choosing: off, the cull's own marks are not drawn.
        let showCull = model.settings.showCullMarks
        cullMarksShown = showCull
        marks.showCull = showCull
        if let row {
            marks.his = VerdictValue.his(row)
            // Agreed is only true inside a burst he has actually been through.
            marks.agreed = marks.his == .unmarked && (model.currentBurst?.seen ?? false)
            // The triangle, the half strength and the two words are the
            // cull's named fault (§2.5.9) — never his reason, which is his
            // red cross and his line, not the machine's.
            if showCull, let fault = ViewerModel.cullFault(row) {
                marks.fault = fault
                marks.faultCaption = fault
            }
        }
        if let stack = Stacks.stack(for: stem, in: stacks) {
            marks.inStack = true
            marks.isStackTop = stack.top == stem
            marks.stackCount = stack.count
            marks.stackStart = index == stack.start
            marks.stackEnd = index == stack.range.upperBound - 1
        }
        marks.selectedForCompare = model.compareSelection.contains(stem)
        cell.thumb.increaseContrast = increaseContrast
        cell.thumb.onPress = { [weak self] clicks, modifiers in
            self?.press(index, clicks: clicks, modifiers: modifiers)
        }
        cell.thumb.marks = marks
        cell.thumb.toolTip = row.map { r in
            [VerdictValue.his(r) == .out && !r.label.isEmpty ? model.hisLine(for: r) : nil,
             marks.fault.map(Strings.LightTable.cullFault)].compactMap { $0 }.joined(separator: "\n")
        }.flatMap { $0.isEmpty ? nil : $0 }
        cell.thumb.setAccessibilityLabel(
            Strings.LightTable.frameAnnouncement(frame: marks.number, n: index + 1, of: frames.count,
                                                 burst: model.burstIndex + 1,
                                                 his: model.hisLine(for: row), cull: model.cullLine(for: row),
                                                 stack: marks.inStack ? Stacks.stack(for: stem, in: stacks)?.count : nil))

        let pump = model.session.pump
        let shoot = model.session.name
        cell.thumb.stem = stem
        // The thumbnail tier, which every frame in the strip is drawn from.
        // Until it is here, any picture of the frame already decoded stands
        // in for it — the stage's full-size one included, which is far more
        // to draw into 90 × 60 on every redraw than the strip needs.
        let key = ImagePump.Key(shoot: shoot, stem: stem, tier: .thumb)
        if let thumb = pump.cached(key) {
            cell.thumb.image = thumb
        } else {
            cell.thumb.image = pump.best(shoot: shoot, stem: stem)?.1
            guard loads[stem] == nil else { return }     // already on its way
            loads[stem] = Task { [weak self] in
                let image = try? await pump.image(key, priority: .utility)
                guard let self else { return }
                self.loads[stem] = nil
                guard let image else { return }
                // Whichever cell shows this frame **now**. The one that asked
                // may have been handed to another frame while the picture was
                // on its way — turning to the cursor's page recycles the first
                // page's cells before their pictures arrive — and checking
                // only that the frame was still at its index put a first-page
                // frame's picture under the ring on the last frame.
                for thumb in self.collection.subviews.compactMap({ $0 as? FilmstripItemView })
                where thumb.stem == stem {
                    thumb.image = image
                }
            }
        }
    }

}

extension FilmstripView: NSCollectionViewDataSource {
    public func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        frames.count
    }

    public func collectionView(_ cv: NSCollectionView,
                               itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: FilmstripItem.identifier, for: indexPath)
        decorate(item, at: indexPath.item)
        return item
    }
}

extension FilmstripView {
    /// A press on thumbnail `index`. It is never a verdict — that is the whole
    /// of the rule — and it never keeps the keyboard: the photograph has K, D,
    /// N, the arrows and Space back before his hand is off the mouse.
    ///
    /// * A click goes to the frame, every time, the same thumbnail twice
    ///   included, and lets go of any Compare set.
    /// * A double-click is Full Image, on the frame the first click went to.
    /// * ⌘-click and ⇧-click build a Compare set, which C opens; nothing opens
    ///   it by itself. Not while Compare or All Bursts is up, where the set is
    ///   what is on screen.
    func press(_ index: Int, clicks: Int, modifiers: NSEvent.ModifierFlags) {
        guard frames.indices.contains(index) else { return }
        let building = modifiers.contains(.command) || modifiers.contains(.shift)
        if building {
            if model.mode == .single {
                model.compareSelection = Self.compareSet(
                    model.compareSelection, frames: frames, cursor: model.frameIndex, pressed: index,
                    extendingFrom: compareAnchor, extend: modifiers.contains(.shift))
                compareAnchor = index
            }
        } else if clicks >= 2 {
            if !model.fullImage { model.perform(.toggleFullImage) }
        } else {
            if model.mode == .single, !model.compareSelection.isEmpty {
                model.compareSelection = []
            }
            compareAnchor = nil
            model.goToFrame(index)
        }
        KeyFocus.restoreSoon(in: window)
    }

    /// The Compare set after a ⌘- or ⇧-click, in shutter order, at most eight.
    ///
    /// The frame he is on starts the set — it is the photograph in front of
    /// him, and the one anything is being compared with — so one ⌘-click on
    /// another frame is already a pair. ⌘ adds the pressed frame or takes it
    /// away; ⇧ takes in every frame from the last one pressed (or the one he is
    /// on) to this one.
    static func compareSet(_ current: [String], frames: [String], cursor: Int, pressed: Int,
                           extendingFrom anchor: Int?, extend: Bool) -> [String] {
        guard frames.indices.contains(pressed) else { return current }
        var set = Set(current.filter(frames.contains))
        if set.isEmpty, frames.indices.contains(cursor) { set.insert(frames[cursor]) }
        if extend {
            let from = anchor.flatMap { frames.indices.contains($0) ? $0 : nil } ?? cursor
            for i in min(from, pressed)...max(from, pressed) where frames.indices.contains(i) {
                set.insert(frames[i])
            }
        } else if set.contains(frames[pressed]) {
            set.remove(frames[pressed])
        } else {
            set.insert(frames[pressed])
        }
        return Array(frames.filter(set.contains).prefix(8))
    }
}

extension ViewerModel {
    /// The frames he ⌘- or ⇧-clicked in the strip, when two or more of them
    /// are in the burst he is on: what C, the Compare button and Frame ▸
    /// Compare open instead of the stack (§2.5.12). Nothing otherwise.
    var pickedForCompare: [String]? {
        guard mode == .single else { return nil }
        let picked = compareSelection.filter(frames.contains)
        return picked.count >= 2 ? picked : nil
    }
}

/// The strip's collection view: never the keyboard's. A click in the gap
/// between two thumbnails landed here and took the keyboard off the
/// photograph just as a click on one did.
@MainActor
final class FilmstripCollectionView: NSCollectionView {
    override var acceptsFirstResponder: Bool { false }
}

/// The strip's scroll view: no scroll bar, and a mouse wheel that turns only
/// one way still moves a strip that only goes the other (§2.5.9).
@MainActor
final class FilmstripScrollView: NSScrollView {
    /// Called after every tile, which is when the clip view's height moves.
    var onTile: (() -> Void)?

    /// Always off. Set once, it did not stay set: the collection view turns
    /// its scroll view's scroller back on for a sideways flow, and the
    /// system's scroller style then decides how much of the band it takes.
    override var hasHorizontalScroller: Bool {
        get { false }
        set { super.hasHorizontalScroller = false }
    }

    override func tile() {
        super.tile()
        onTile?()
    }

    /// A wheel mouse only turns up and down, and this strip only goes left
    /// and right; with no scroll bar there would be nothing left on a mouse
    /// to move it by. One notch is one frame. A trackpad already scrolls
    /// sideways and is left exactly as it is.
    override func scrollWheel(with e: NSEvent) {
        guard !e.hasPreciseScrollingDeltas, e.scrollingDeltaX == 0, e.scrollingDeltaY != 0 else {
            super.scrollWheel(with: e)
            return
        }
        let clip = contentView
        var origin = clip.bounds.origin
        origin.x -= e.scrollingDeltaY * (FilmstripItemView.thumb.width + Tokens.Metric.filmstripGap)
        let to = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        clip.scroll(to: NSPoint(x: to.x, y: clip.bounds.origin.y))
        reflectScrolledClipView(clip)
    }
}

/// The filmstrip, in SwiftUI. 96 pt: 12 pad + 60 thumb + 4 + 14 caption + 6.
public struct Filmstrip: NSViewRepresentable {
    let model: ViewerModel
    /// Changes whenever anything the strip draws changes, so SwiftUI calls
    /// `updateNSView`.
    let token: Int
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.increaseContrastOverride) private var contrastOverride

    public init(model: ViewerModel, token: Int) {
        self.model = model
        self.token = token
    }

    public func makeNSView(context: Context) -> FilmstripView {
        let v = FilmstripView(model: model)
        v.increaseContrast = increased
        v.refresh()
        return v
    }

    public func updateNSView(_ v: FilmstripView, context: Context) {
        v.increaseContrast = increased
        v.refresh()
    }

    private var increased: Bool {
        contrastOverride ?? (systemContrast == .increased
                             || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }
}
