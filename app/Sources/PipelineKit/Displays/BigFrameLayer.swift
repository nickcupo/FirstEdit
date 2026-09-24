#if canImport(AppKit)
import AppKit
import QuartzCore
import CoreGraphics

/// One photograph, as big as the glass allows, on its own display clock.
///
/// **Double-buffered.** Two sublayers, A visible and B hidden, where B's
/// contents were assigned when the prefetch landed — so the picture has already
/// been composited once and its texture is already resident. The swap at
/// key-down is two property changes, not a 44.7 MB upload on the critical path.
/// Without this, uploading the 4096 px image on the external's compositor is
/// the one plausible way to miss the swap budget.
///
/// **Never blank.** It shows whatever size it already has — thumbnail, then
/// `/large`, then its own — and upgrades in place with no crossfade. A scale
/// change, a screen change and a resolution change all keep drawing the old
/// picture until the new one lands: a blank window during a drag between
/// displays reads as a crash.
@MainActor
public final class BigFrameView: NSView {

    /// Reported from this window's own display link. It goes to the HUD and to
    /// the measurement stream and **nowhere else** — a unit test asserts it
    /// cannot satisfy the verdict display gate (§2.6).
    public var onDisplay: ((String, Int) -> Void)?

    public var pump: ImagePump?
    public var inset: CGFloat = DisplayMetric.pictureInset

    public private(set) var shoot = ""
    public private(set) var stem = ""
    public private(set) var generation = 0

    private let a = CALayer()
    private let b = CALayer()
    private var frontIsA = true
    private var front: CALayer { frontIsA ? a : b }
    private var back: CALayer { frontIsA ? b : a }

    private var loadTask: Task<Void, Never>?
    private var link: CADisplayLink?
    private var committedRank = -1
    private var committedAtFrame = -1
    private var frameCount = 0
    private var reported: (stem: String, generation: Int)?
    private var requestedPixels = 0
    private var isFrozen = false
    private var isDrawing = true

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.isOpaque = true
        for l in [a, b] {
            l.contentsGravity = .resizeAspect
            // The default minification filter on a 4096 px image drawn into a
            // 2076 pt box on a 1× screen aliases visibly on high-frequency
            // detail — hair, netting, fabric — which is precisely what he is
            // judging.
            l.magnificationFilter = .trilinear
            l.minificationFilter = .trilinear
            l.isOpaque = true
            l.actions = ["contents": NSNull(), "bounds": NSNull(),
                         "position": NSNull(), "opacity": NSNull()]
            layer?.addSublayer(l)
        }
        b.opacity = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }

    /// The box the photograph is fitted into, inset so it never touches the
    /// bezel.
    public var pictureBox: CGRect { bounds.insetBy(dx: inset, dy: inset) }

    // MARK: - showing a frame

    public func show(shoot: String, stem: String) {
        guard shoot != self.shoot || stem != self.stem else { layoutLayers(); return }
        self.shoot = shoot
        self.stem = stem
        generation &+= 1
        committedRank = -1
        reported = nil
        requestedPixels = 0
        setAccessibilityLabel(ShootSession.shortStem(stem))
        drawBestAlreadyHere()
        load()
    }

    public func setFrozen(_ on: Bool) {
        isFrozen = on
        if on { loadTask?.cancel() } else { load() }
    }

    /// Asleep or covered: the display link stops, the ring drops to one and
    /// prefetch pauses. Nothing is announced — a sleeping display is not an
    /// event.
    public func setDrawing(_ on: Bool) {
        isDrawing = on
        if on { startLink(); load() } else { stopLink(); loadTask?.cancel() }
    }

    public func tearDown() {
        loadTask?.cancel()
        stopLink()
    }

    // MARK: - geometry and scale

    public override func layout() {
        super.layout()
        layoutLayers()
        if neededPixels() > requestedPixels { load() }
    }

    /// Fires for both a scale change and a colour-space change. It recomputes
    /// the size and requests it **without clearing what is on screen**.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        backingChanged()
    }

    public func backingChanged() {
        // The **window's** backing scale, never the screen's: a window
        // straddling a 2× and a 1× screen is composited at the higher scale
        // for its whole surface, and reading the screen gives the wrong answer
        // for exactly the case — a window being dragged between his two
        // displays — where the wrong answer is visible.
        let scale = window?.backingScaleFactor ?? 2
        a.contentsScale = scale
        b.contentsScale = scale
        if neededPixels() > requestedPixels { load() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { backingChanged(); startLink() } else { stopLink() }
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let box = pictureBox
        a.frame = box
        b.frame = box
        CATransaction.commit()
    }

    /// The pixels this window wants, from its own point size and its own
    /// backing scale.
    public func neededPixels() -> Int {
        let scale = window?.backingScaleFactor ?? 2
        let box = pictureBox
        guard box.width > 0 else { return PixelTier.ladder.first ?? 1440 }
        return PixelTier.px(forPointWidth: box.width, scale: scale)
    }

    // MARK: - the pictures

    private func drawBestAlreadyHere() {
        guard let pump, let (key, image) = pump.best(shoot: shoot, stem: stem) else { return }
        commit(image, rank: key.tier.rank)
    }

    private func load() {
        guard !isFrozen, isDrawing, let pump, !stem.isEmpty else { return }
        loadTask?.cancel()
        let px = neededPixels()
        requestedPixels = px
        let shoot = self.shoot, stem = self.stem, gen = self.generation
        let base = ImagePump.Key(shoot: shoot, stem: stem, tier: .thumb)
        loadTask = Task { [weak self] in
            for tier in [ImagePump.Tier.thumb, .large, .full(px: px)] {
                if Task.isCancelled { return }
                guard let image = try? await pump.image(base.with(tier), priority: .userInitiated) else {
                    continue
                }
                guard let self, self.generation == gen, self.stem == stem else { return }
                self.commit(image, rank: tier.rank)
            }
        }
    }

    /// Put a picture into the hidden layer without swapping to it, so the swap
    /// on the next key press is two property changes.
    public func preload(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        back.contents = DisplayColor.tagged(image)
        CATransaction.commit()
    }

    private func commit(_ image: CGImage, rank: Int) {
        guard rank >= committedRank else { return }
        // Tagged once, at the boundary: an untagged picture assigned to a
        // layer is treated as already being in the display's own space, and no
        // conversion happens.
        let tagged = DisplayColor.tagged(image)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        back.contents = tagged
        back.frame = pictureBox
        back.opacity = 1
        front.opacity = 0
        frontIsA.toggle()
        CATransaction.commit()
        committedRank = rank
        committedAtFrame = frameCount
        startLink()
    }

    // MARK: - this window's own clock

    private func startLink() {
        guard link == nil, window != nil, isDrawing else { return }
        // `displayLink(target:selector:)` retargets itself when the view's
        // window moves to another screen, so the per-window frame clock is
        // correct on both displays with no extra work.
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ l: CADisplayLink) {
        frameCount += 1
        guard committedRank >= 0, frameCount >= committedAtFrame + 2 else { return }
        if reported?.stem != stem || reported?.generation != generation {
            reported = (stem, generation)
            onDisplay?(stem, generation)
        }
        if committedRank >= 2 { stopLink() }
    }
}
#endif
