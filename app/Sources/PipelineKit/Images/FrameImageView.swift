import SwiftUI
import AppKit
import QuartzCore

/// How a frame sits in its box.
public enum Fit: Sendable, Equatable {
    /// The whole frame, inset by `inset` points on every side.
    case fit(inset: CGFloat)
    /// The box filled, the frame cropped to it — a cover thumbnail.
    case fill

    public static let standard = Fit.fit(inset: Tokens.Metric.viewerInset)
}

/// What a box of pixels is **for**, which is what decides how sharp a picture
/// it is allowed to ask the engine for (§3.5).
public enum Showing: Sendable, Equatable {
    /// A cover, a cell, a tile: a picture *of* the frame. It stops at
    /// `/large`, the camera's own JPEG, rather than putting a 650–720 ms cold
    /// RAW decode in front of the photograph he is looking at.
    case aThumbnail
    /// The frame itself, at the size he is judging it at. It climbs to
    /// `/full`, the RAW decode, whatever size that turns out to be —
    /// `/large` is too soft to call a missed focus on.
    case aPhotograph

    var stopsAtLarge: Bool { self == .aThumbnail }
}

/// One frame drawn in a `CALayer`, with no chrome.
///
/// It shows whatever tier it already has — thumb, then large, then full — and
/// upgrades in place with no crossfade: a crossfade on every keystroke is
/// noise. It is never empty while any tier of the frame exists.
///
/// `onDisplay(stem, generation)` is the display gate DESIGN.md §2.5.4 rests
/// on. It is called from the display link only after a picture for that
/// `(stem, generation)` has been committed to the layer *and* one refresh has
/// passed. "Loaded", "requested" and "complete" do not count. `generation`
/// increments every time the frame changes, so a late picture for a frame he
/// has already left can never satisfy it.
public struct FrameImageView: NSViewRepresentable {
    public let shoot: String
    public let stem: String
    public let fit: Fit
    public let showing: Showing
    public let pump: ImagePump
    public let onDisplay: (String, Int) -> Void

    public init(shoot: String, stem: String, fit: Fit, showing: Showing, pump: ImagePump,
                onDisplay: @escaping (String, Int) -> Void) {
        self.shoot = shoot
        self.stem = stem
        self.fit = fit
        self.showing = showing
        self.pump = pump
        self.onDisplay = onDisplay
    }

    public func makeNSView(context: Context) -> FrameLayerView {
        let v = FrameLayerView(pump: pump, showing: showing)
        v.onDisplay = onDisplay
        v.show(shoot: shoot, stem: stem, fit: fit)
        return v
    }

    public func updateNSView(_ v: FrameLayerView, context: Context) {
        v.onDisplay = onDisplay
        v.show(shoot: shoot, stem: stem, fit: fit)
    }

    public static func dismantleNSView(_ v: FrameLayerView, coordinator: ()) {
        v.tearDown()
    }
}

/// The AppKit side of `FrameImageView`, public so the light table's own stage
/// can host it or subclass the same drawing.
@MainActor
public final class FrameLayerView: NSView {
    private let pump: ImagePump
    /// What this box is for. Fixed at birth: a cover never becomes a viewer.
    private let showing: Showing
    private let imageLayer = CALayer()
    private var loadTask: Task<Void, Never>?
    private var link: CADisplayLink?

    public private(set) var shoot = ""
    public private(set) var stem = ""
    public private(set) var generation = 0
    private var fit: Fit = .standard

    /// What is actually on the layer now, and at which tier.
    public private(set) var committed: (stem: String, generation: Int, rank: Int)?
    /// Set once a refresh has passed with `committed` on screen.
    private var reported: (stem: String, generation: Int)?
    private var committedAtFrame: Int = -1
    private var frameCount = 0
    private var requestedPixels = 0

    var onDisplay: ((String, Int) -> Void)?

    init(pump: ImagePump, showing: Showing) {
        self.pump = pump
        self.showing = showing
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.masksToBounds = true
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }

    public func show(shoot: String, stem: String, fit: Fit) {
        let changed = shoot != self.shoot || stem != self.stem
        self.fit = fit
        imageLayer.contentsGravity = fit == .fill ? .resizeAspectFill : .resizeAspect
        guard changed else { layoutImageLayer(); return }
        self.shoot = shoot
        self.stem = stem
        generation += 1
        committed = nil
        reported = nil
        requestedPixels = 0
        setAccessibilityLabel(stem)
        drawBestCached()
        load()
    }

    public override func layout() {
        super.layout()
        layoutImageLayer()
        // A bigger box may need a sharper tier; a smaller one never asks for
        // less than it already has.
        if neededFullPixels() > requestedPixels { load() }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        if neededFullPixels() > requestedPixels { load() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startLink() } else { stopLink() }
    }

    func tearDown() {
        loadTask?.cancel()
        stopLink()
    }

    // MARK: - drawing

    private func layoutImageLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch fit {
        case .fit(let inset): imageLayer.frame = bounds.insetBy(dx: inset, dy: inset)
        case .fill: imageLayer.frame = bounds
        }
        CATransaction.commit()
    }

    private func neededFullPixels() -> Int {
        let scale = window?.backingScaleFactor ?? 2
        return ImagePump.fullPixels(forPoints: imageLayer.bounds.size == .zero ? bounds.size : imageLayer.bounds.size,
                                    scale: scale)
    }

    private func drawBestCached() {
        if let (k, img) = pump.best(shoot: shoot, stem: stem) {
            commit(img, rank: k.tier.rank)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = nil
            CATransaction.commit()
        }
    }

    private func commit(_ image: CGImage, rank: Int) {
        if let c = committed, c.stem == stem, c.generation == generation, c.rank > rank { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
        committed = (stem, generation, rank)
        committedAtFrame = frameCount
        startLink()
    }

    private func load() {
        loadTask?.cancel()
        let pump = self.pump
        let shoot = self.shoot, stem = self.stem, gen = self.generation
        let px = neededFullPixels()
        requestedPixels = px
        let base = ImagePump.Key(shoot: shoot, stem: stem, tier: .thumb)
        let stopsAtLarge = showing.stopsAtLarge
        loadTask = Task { [weak self] in
            // A cover or a cell that needs no more than `/large` stops at
            // `/large`; a photograph he is judging climbs to the RAW decode
            // whatever size it draws at. See `ImagePump.ladder`.
            for tier in ImagePump.ladder(toFullPixels: px, stopsAtLarge: stopsAtLarge) {
                if Task.isCancelled { return }
                guard let img = try? await pump.image(base.with(tier), priority: .userInitiated) else { continue }
                guard let self, self.generation == gen, self.stem == stem else { return }
                self.commit(img, rank: tier.rank)
            }
        }
    }

    // MARK: - the display gate

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

    @objc private func tick(_ l: CADisplayLink) {
        frameCount += 1
        guard let c = committed, c.stem == stem, c.generation == generation else { return }
        // One whole refresh with the picture on the layer, then it counts.
        guard frameCount >= committedAtFrame + 2 else { return }
        if reported?.stem != c.stem || reported?.generation != c.generation {
            reported = (c.stem, c.generation)
            onDisplay?(c.stem, c.generation)
        }
        // Nothing more to report until the frame changes or sharpens.
        if c.rank >= 2 { stopLink() }
    }
}
