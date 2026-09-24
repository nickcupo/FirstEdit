import SwiftUI
import AppKit
import QuartzCore

/// One frame drawn at a **shared** zoom and pan but aligned on **its own** aim.
///
/// This is the whole point of Compare (§2.5.12): one zoom factor and one pan
/// offset for every tile, each tile aligned on its own face, so the same eye
/// sits in the same place in every tile. 81 of 156 close calls on his gym shoot
/// are sharpness calls and no side-by-side exists today (DUP-7).
@MainActor
public final class AlignedFrameView: NSView {
    private let image = CALayer()
    private var task: Task<Void, Never>?
    private var link: CADisplayLink?
    private var committedAtFrame = -1
    private var frameCount = 0
    private var committed: (stem: String, rank: Int)?
    private var reported: (stem: String, generation: Int)?

    public var shoot = ""
    public var stem = ""
    public var generation = 0
    public var zoom = ZoomModel()
    public var aim = Aim.centre
    public var framePixels = CGSize(width: 6024, height: 4024)
    public var pump: ImagePump?
    public var onDisplay: ((String) -> Void)?
    /// The light table, whose one zoom every tile shares: a pinch, a scroll
    /// or a drag on any tile moves all of them, each on its own aim.
    public weak var model: ViewerModel?
    /// A click on the tile: the ring, the frame and the bar go to it.
    public var onSelect: (() -> Void)?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        image.actions = ["contents": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(image)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }
    public override var isFlipped: Bool { true }

    public func refresh() {
        layoutImage()
        load()
        startLink()
    }

    public override func layout() {
        super.layout()
        layoutImage()
        // A tile is laid out after it is made, so the first ask for pixels has
        // to happen here as well — otherwise Compare opens on empty boxes.
        load()
    }

    private func layoutImage() {
        let scale = window?.backingScaleFactor ?? 2
        let f = zoom.factor(framePixels: framePixels, viewport: bounds.size, scale: scale)
        let size = CGSize(width: framePixels.width * f / scale, height: framePixels.height * f / scale)
        let visible = zoom.visibleRect(aim: aim, framePixels: framePixels, viewport: bounds.size, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.frame = CGRect(x: bounds.midX - visible.midX * size.width,
                             y: bounds.midY - visible.midY * size.height,
                             width: size.width, height: size.height)
        CATransaction.commit()
    }

    private func load() {
        guard let pump, !stem.isEmpty, bounds.width > 0 else { return }
        if let (k, img) = pump.best(shoot: shoot, stem: stem) {
            commit(img, rank: k.tier.rank)
        } else if committed?.stem != stem {
            image.contents = nil
            committed = nil
        }
        let scale = window?.backingScaleFactor ?? 2
        let px = LightTableSeams.current.fullPixels(forPoints: image.frame.size, scale: scale)
        let key = ImagePump.Key(shoot: shoot, stem: stem, tier: .thumb)
        let wanted = stem
        task?.cancel()
        task = Task { [weak self] in
            // Never capped at `/large`. Compare is where he decides which of
            // four near-identical frames is the sharp one, which is the one
            // question the camera's JPEG cannot answer (§3.5).
            for tier in ImagePump.ladder(toFullPixels: px, stopsAtLarge: false) {
                if Task.isCancelled { return }
                guard let img = try? await pump.image(key.with(tier), priority: .userInitiated) else { continue }
                guard let self, self.stem == wanted else { return }
                self.commit(img, rank: tier.rank)
            }
        }
    }

    private func commit(_ img: CGImage, rank: Int) {
        if let c = committed, c.stem == stem, c.rank > rank { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        image.contents = img
        CATransaction.commit()
        committed = (stem, rank)
        committedAtFrame = frameCount
        startLink()
    }

    private func startLink() {
        guard link == nil, window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    public func tearDown() {
        task?.cancel()
        stopLink()
    }

    // MARK: - the hand on the trackpad (§2.5.12)
    //
    // Compare had Z, ⌘+ / ⌘− and ⇧-arrows and nothing else: a pinch, a
    // double-click and a scroll on a tile did nothing, and a click moved the
    // ring but left the bar and the filmstrip naming the frame before.

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    public override func magnify(with e: NSEvent) {
        guard let model else { return }
        let p = convert(e.locationInWindow, from: nil)
        let whole = image.frame
        let under = whole.width > 0 && whole.height > 0
            ? CGPoint(x: (p.x - whole.minX) / whole.width, y: (p.y - whole.minY) / whole.height) : nil
        let spot = bounds.width > 0 && bounds.height > 0
            ? CGPoint(x: p.x / bounds.width, y: p.y / bounds.height) : nil
        if model.zoom.magnify(by: Double(e.magnification), framePixels: framePixels,
                              viewport: bounds.size, scale: scale) {
            model.haptic(.alignment)
        }
        if !model.zoom.isFit, let under, let spot {
            model.zoom.anchor(under, at: spot, aim: aim, framePixels: framePixels,
                              viewport: bounds.size, scale: scale)
        }
        window?.invalidateCursorRects(for: self)
    }

    public override func smartMagnify(with e: NSEvent) {
        toggleZoom(at: convert(e.locationInWindow, from: nil))
    }

    public override func scrollWheel(with e: NSEvent) {
        guard let model, !model.zoom.isFit else { return super.scrollWheel(with: e) }
        pan(by: ScrollInput.points(e))
    }

    private var lastDrag: CGPoint?
    private var dragged = false

    public override func mouseDown(with e: NSEvent) {
        lastDrag = convert(e.locationInWindow, from: nil)
        dragged = false
        if e.clickCount == 2 { toggleZoom(at: convert(e.locationInWindow, from: nil)) }
    }

    public override func mouseDragged(with e: NSEvent) {
        let here = convert(e.locationInWindow, from: nil)
        defer { lastDrag = here }
        guard let model, !model.zoom.isFit, let last = lastDrag else { return }
        dragged = true
        pan(by: CGVector(dx: here.x - last.x, dy: here.y - last.y))
    }

    public override func mouseUp(with e: NSEvent) {
        if !dragged && e.clickCount == 1 { onSelect?() }
        lastDrag = nil
        dragged = false
    }

    private func pan(by d: CGVector) {
        guard let model else { return }
        let f = model.zoom.factor(framePixels: framePixels, viewport: bounds.size, scale: scale)
        model.zoom.pan(by: d, aim: aim, framePixels: framePixels, viewport: bounds.size,
                       factor: f, scale: scale)
    }

    /// Fit ⇄ 1:1 at the point he double-clicked, on every tile at once.
    private func toggleZoom(at p: CGPoint) {
        guard let model else { return }
        let whole = image.frame
        if model.zoom.isFit, whole.width > 0, whole.height > 0 {
            model.zoom.goToOneToOne()
            model.zoom.anchor(on: CGPoint(x: (p.x - whole.minX) / whole.width,
                                          y: (p.y - whole.minY) / whole.height), aim: aim)
            model.zoom.clampPan(aim: aim, framePixels: framePixels, viewport: bounds.size, scale: scale)
        } else {
            model.zoom.goToFit()
        }
        model.haptic(.alignment)
        window?.invalidateCursorRects(for: self)
    }

    public override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: (model?.zoom.isFit ?? true) ? .arrow : .openHand)
    }

    @objc private func tick(_ l: CADisplayLink) {
        frameCount += 1
        guard let c = committed, c.stem == stem, frameCount >= committedAtFrame + 2 else { return }
        if reported?.stem != stem || reported?.generation != generation {
            reported = (stem, generation)
            onDisplay?(stem)
        }
        // Reported, and nothing sharper is coming: stop. `refresh()` and
        // `commit()` start it again. Compare shows up to eight of these at
        // once, and every one of them was running a main-thread callback at
        // the display's refresh rate for as long as Compare was open.
        stopLink()
    }
}

struct AlignedFrame: NSViewRepresentable {
    let shoot: String
    let stem: String
    let generation: Int
    let zoom: ZoomModel
    let aim: Aim.Point
    let framePixels: CGSize
    let pump: ImagePump
    let model: ViewerModel?
    let onSelect: () -> Void
    let onDisplay: (String) -> Void

    func makeNSView(context: Context) -> AlignedFrameView {
        let v = AlignedFrameView(frame: .zero)
        apply(v)
        v.refresh()
        return v
    }

    func updateNSView(_ v: AlignedFrameView, context: Context) {
        apply(v)
        v.refresh()
    }

    static func dismantleNSView(_ v: AlignedFrameView, coordinator: ()) { v.tearDown() }

    private func apply(_ v: AlignedFrameView) {
        v.shoot = shoot; v.stem = stem; v.generation = generation
        v.zoom = zoom; v.aim = aim; v.framePixels = framePixels
        v.pump = pump; v.onDisplay = onDisplay
        v.model = model; v.onSelect = onSelect
    }
}

// MARK: -

/// Compare, which is a **mode of the viewer** and not a sheet: the same
/// toolbar, the same control bar, and Esc returns to the frame that had focus.
///
/// It never opens by itself. A view change arriving under a moving hand is how
/// a keystroke lands in the wrong place, so a stack is an invitation printed
/// under the picture and C is how it is taken (§2.5.12).
public struct CompareView: View {
    @Bindable var model: ViewerModel
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.increaseContrastOverride) private var contrastOverride
    /// Increase Contrast, from the system unless the harness overrides it.
    private var increased: Bool { contrastOverride ?? (systemContrast == .increased) }

    public init(model: ViewerModel) { self.model = model }

    private var members: [String] { model.compareSelection }

    /// Where each tile stands on the cull's focus figure, among all the
    /// frames compared — every page of them, not just the six in view.
    private var sharpness: [String: Sharpness.Standing] {
        Sharpness.standings(members, rows: model.session.rows)
    }

    private var page: [String] {
        let grid = LightTableGeometry.compareGrid(count: members.count)
        let start = model.comparePage * grid.perPage
        return Array(members.dropFirst(start).prefix(grid.perPage))
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                grid(in: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .padding(Tokens.Metric.relatedGap)
            // The captions under the tiles are written straight onto the
            // surround: in Light they were near-black on #3A3A3A.
            .onViewerSurround()
        }
        .background(Tokens.Palette.viewerBackground)
        .accessibilityElement(children: .contain)
    }

    /// Tiles at equal size, laid out to maximise tile area. Rows and columns
    /// are computed and the tiles are placed, rather than handed to a lazy grid
    /// that can decide to wrap: Compare is a measurement instrument and its
    /// tiles have to be the same size as each other, exactly.
    private func grid(in box: CGSize) -> some View {
        let count = members.count
        let g = LightTableGeometry.compareGrid(count: count)
        let gutter = Tokens.Metric.relatedGap
        let caption: CGFloat = 20
        let rows = Int((Double(page.count) / Double(g.columns)).rounded(.up))
        let tile = LightTableGeometry.compareTile(in: box, count: count, rows: rows,
                                                  aspect: model.aspect, gutter: gutter, caption: caption)
        return VStack(spacing: gutter) {
            ForEach(0..<max(1, rows), id: \.self) { row in
                HStack(spacing: gutter) {
                    ForEach(page.dropFirst(row * g.columns).prefix(g.columns), id: \.self) { stem in
                        tileView(stem, size: tile)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: Tokens.Metric.relatedGap) {
            Text(model.compareHeader)
                .font(.callout)
            if members.count > LightTableGeometry.compareGrid(count: members.count).perPage {
                Text(Strings.LightTable.comparePage(page.count, members.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(Strings.LightTable.backToOneFrame) { model.perform(.single) }
                .buttonStyle(.link)
                // Esc: S in Compare is the tile before, beside F (§2.5.3).
                .help(Strings.LightTable.withKey(Strings.LightTable.backToOneFrame, "⎋"))
        }
        .padding(.horizontal, Tokens.Metric.windowMargin)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private func tileView(_ stem: String, size: CGSize) -> some View {
        let row = model.session.rows[stem]
        let isFocus = model.compareFocus == stem
        let isTop = model.currentStack?.top == stem
        VStack(spacing: 2) {
            AlignedFrame(shoot: model.session.name, stem: stem,
                         generation: model.session.cursor.generation,
                         zoom: model.zoom, aim: Aim.resolve(row),
                         framePixels: pixels(row), pump: model.session.pump,
                         model: model, onSelect: { model.focusTile(stem) }) { s in
                model.didDisplayTile(s)
            }
            .frame(width: size.width, height: size.height)
            .background(Color.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isFocus ? Color.accentColor : Color.clear,
                                  lineWidth: increased ? 4 : 3)
            }
            .overlay(alignment: .topLeading) {
                if isTop {
                    // "the cull's guess", never "the best" — measured, the
                    // quality top holds a keeper in 30 of 57 stacks against
                    // 25.7 by chance (DUP-11).
                    // A chip, not glass. §2.2 gives Liquid Glass to four
                    // places and this is none of them, and Contrast.swift
                    // already says why: a translucent chip over a bright sky
                    // is a sentence he cannot read. In a snapshot the glass
                    // drew nothing at all and this line came out as grey type
                    // lying straight on the photograph.
                    Text(Strings.LightTable.cullsGuess)
                        .font(.footnote)
                        .foregroundStyle(Tokens.Palette.machine)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .viewerChip(Capsule())
                        .padding(6)
                }
            }

            caption(stem, row: row, standing: sharpness[stem])
                .frame(width: size.width)
        }
        .accessibilityElement(children: .ignore)
        // Every tile says which frame it is and what has been decided about
        // it. Before this it was an image with a role and no name, and four of
        // them sounded identical (§2.15).
        .accessibilityLabel(Strings.LightTable.compareTile + ". " + model.announcement(for: stem))
        .accessibilityAddTraits(isFocus ? [.isSelected] : [])
    }

    /// Frame number, where the cull's focus figure puts it among the tiles,
    /// and his verdict (§2.5.12). The sharpest is named, in the surround's
    /// full ink with a mark of its own; the rest say how far under it they
    /// measure. They were "focus 61" and "focus 161" in the same faint 10 pt
    /// grey, with what the numbers meant only in a hover — and sharpness is
    /// what he opens Compare to settle.
    private func caption(_ stem: String, row: Row?, standing: Sharpness.Standing?) -> some View {
        HStack(spacing: Tokens.Metric.relatedGap) {
            Text(ShootSession.shortStem(stem))
                .font(.frameNumber)
            if let standing, let focus = row?.focus {
                Group {
                    if standing.sharpest {
                        Label(Strings.LightTable.compareSharpest(of: standing.of), systemImage: Symbols.sharpest)
                            .fontWeight(.semibold)
                    } else {
                        Text(Strings.LightTable.compareSofter(standing.under))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .help(Strings.LightTable.compareFocusHelp(Int(focus), best: Int(standing.best),
                                                          bestFrame: ShootSession.shortStem(standing.bestStem),
                                                          of: standing.of))
            } else if let focus = row?.focus {
                Text("\(Strings.LightTable.focusLabel) \(Int(focus))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            verdictBadge(row)
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func verdictBadge(_ row: Row?) -> some View {
        if let row {
            switch VerdictValue.his(row) {
            case .kept:
                Label(Strings.Verdict.keep, systemImage: Symbols.hisKeep)
                    .font(.footnote).foregroundStyle(Tokens.Palette.kept).labelStyle(.iconOnly)
            case .out:
                Label(Strings.Verdict.drop, systemImage: Symbols.hisDrop)
                    .font(.footnote).foregroundStyle(Tokens.Palette.out).labelStyle(.iconOnly)
            case .unmarked:
                if row.rating >= VerdictValue.inThreshold {
                    CullSuggestionBadge().fixedSize().help(Strings.LightTable.suggestionHelp)
                }
            }
        }
    }

    private func pixels(_ row: Row?) -> CGSize {
        guard let w = row?.dw, let h = row?.dh, w > 0, h > 0 else {
            return CGSize(width: 6024, height: 4024)
        }
        return CGSize(width: w, height: h)
    }
}
