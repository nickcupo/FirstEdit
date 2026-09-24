import AppKit
import SwiftUI
import QuartzCore

/// The photograph, and everything that happens on it.
///
/// An `NSView` rather than a SwiftUI view because the same surface needs
/// `magnify(with:)`, `smartMagnify(with:)`, `pressureChange(with:)`,
/// `scrollWheel(with:)` and a display link. Keys no longer depend on it
/// having the keyboard: `LightTableKeys` hands every key pressed in the
/// window to the model, so K, D and N work on the first press of every launch
/// and every ⌘-tab back (NAT-01) whatever was clicked last. The stage spends
/// held arrows, one per refresh (`HeldMoves`).
///
/// Drawing is two layers and no crossfade: `base` holds whatever tier of the
/// whole frame is already decoded, `tile` holds the `/crop` cut at 1:1 and sits
/// exactly over the part of the frame it covers. The picture is never empty and
/// never waits; it sharpens in place.
@MainActor
public final class StageLayerView: NSView, HeldMoves {

    public let model: ViewerModel

    /// Which stage this is: the light table's own, or Full Image's over it.
    public enum Role { case table, fullImage }
    public var role: Role = .table

    /// Whether this is the stage he is looking at: the table's while Full
    /// Image is down, Full Image's while it is up.
    ///
    /// Full Image puts a second stage over the table's, and **the covered one
    /// is kept, and waits**. It keeps the picture it has and does nothing
    /// else: it measures nothing into the model, loads nothing, reports
    /// nothing to the display gate, says nothing to VoiceOver and holds no
    /// display link, until it is uncovered. Both used to measure themselves
    /// into the one `model.viewport`, each write redrawing the other, which
    /// never settled. Taking the table's stage down instead cured that and
    /// made the switch jump: the photograph vanished at once and Full Image
    /// faded in over the bare background, and on the way back the new stage
    /// had no picture for the first few frames of the fade — the grey dip
    /// in the middle of a key pressed dozens of times a burst.
    ///
    /// Read from the model at the moment of asking, not from a value SwiftUI
    /// last handed over: the overlay fades out for a fifth of a second after
    /// Full Image has ended, and for that fifth of a second it must already
    /// be the covered one.
    public var inCharge: Bool { window != nil && model.fullImage == (role == .fullImage) }
    private var wasInCharge = false

    /// Whether it is in charge, taking over or standing down when that
    /// changed. In charge but not the view the window gives the keyboard
    /// back to: the other stage took it while this one was covered, which is
    /// exactly what coming back from Full Image is.
    @discardableResult
    private func checkCharge() -> Bool {
        let now = inCharge
        if now != wasInCharge || (now && (KeyFocus.preferred !== self || model.heldMoves !== self)) {
            wasInCharge = now
            if now { claim() } else { release() }
        }
        return now
    }

    /// Ready the instant it is the one he sees: the stage has the keyboard
    /// before the first frame paints (NAT-01), and says so — `KeyFocus` is
    /// how the window gives it back after a click in the toolbar.
    private func claim() {
        startLink()
        KeyFocus.preferred = self
        if !MenuValidation.isTextEditing(in: window) { window?.makeFirstResponder(self) }
        // Keys do not depend on first responder any more (`LightTableKeys`),
        // but held arrows are spent by the stage he is looking at.
        model.heldMoves = self
        setAccessibilityElement(true)
    }

    private func release() {
        if KeyFocus.preferred === self { KeyFocus.preferred = nil }
        if model.heldMoves === self { model.heldMoves = nil }
        stopLink()
        pendingMove = 0
        loadTask?.cancel()
        tileTask?.cancel()
        loading = nil
        loadRunning = false
        loadReachedFull = false
        setAccessibilityElement(false)
    }

    private let base = CALayer()
    private let tile = CALayer()

    private var loadTask: Task<Void, Never>?
    private var tileTask: Task<Void, Never>?
    private var link: CADisplayLink?

    /// What is on the base layer now: the frame, the move it belongs to and
    /// how sharp it is.
    private var committed: (stem: String, generation: Int, rank: Int)?
    private var reported: (stem: String, generation: Int)?
    private var committedAtFrame = -1
    private var frameCount = 0
    private var shownTile: (stem: String, box: CropBox)?

    /// Arrow repeats are coalesced in the display link: repeats accumulate a
    /// pending delta and one move is applied per refresh (§2.5.3).
    private var pendingMove = 0

    /// What the last `load()` asked for, whether its ladder is still climbing,
    /// and whether it reached the top. A SwiftUI update that changes none of
    /// these has nothing to load, and cancelling the ladder to start the same
    /// one again costs three actor hops and a cancelled request every time.
    private var loading: (stem: String, generation: Int, px: Int)?
    private var loadRunning = false
    private var loadReachedFull = false

    public init(model: ViewerModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
        for l in [base, tile] {
            l.contentsGravity = .resize
            l.magnificationFilter = .linear
            l.minificationFilter = .trilinear
            l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                         "frame": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(l)
        }
        tile.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(Strings.LightTable.viewer)
        setAccessibilityCustomActions(verdictActions())
        announceIfChanged()
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - the picture

    /// How big the viewport is and what screen it is on — said only by the
    /// stage in charge (see `inCharge`).
    private func reportViewport() {
        let scale = window?.backingScaleFactor ?? 2
        if model.backingScale != scale { model.backingScale = scale }
        if model.viewport != bounds.size { model.viewport = bounds.size }
    }

    public func refresh() {
        guard checkCharge() else { return }
        reportViewport()
        layoutLayers()
        load()
        startLink()
        // A refresh is a cursor change as often as not, and VoiceOver should
        // not have to wait for the next display-link tick to hear about it.
        announceIfChanged()
    }

    public override func layout() {
        super.layout()
        guard checkCharge() else { return }
        reportViewport()
        layoutLayers()
        load()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        base.contentsScale = scale
        tile.contentsScale = scale
        guard checkCharge() else { return }
        reportViewport()
        load()
    }

    /// `KeyFocus.preferred` had no writer anywhere in shipping code once, so
    /// `KeyFocus.restore(in:)` always returned false and one click on the
    /// toolbar's mode picker left K, D and N dead until he clicked the
    /// photograph; `claim()` is that writer.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if checkCharge() { reportViewport() }
    }

    public func tearDown() {
        release()
        wasInCharge = false
        loadTask?.cancel()
        tileTask?.cancel()
        stopLink()
    }

    /// Where the whole frame sits in the view, at the current zoom and pan.
    private func wholeFrameRect() -> CGRect {
        let px = model.framePixels
        let scale = window?.backingScaleFactor ?? 2
        let f = model.zoom.factor(framePixels: px, viewport: bounds.size, scale: scale)
        let size = CGSize(width: px.width * f / scale, height: px.height * f / scale)
        let visible = model.zoom.visibleRect(aim: model.aim, framePixels: px,
                                             viewport: bounds.size, scale: scale)
        let c = CGPoint(x: visible.midX, y: visible.midY)
        return CGRect(x: bounds.midX - c.x * size.width,
                      y: bounds.midY - c.y * size.height,
                      width: size.width, height: size.height)
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let whole = wholeFrameRect()
        base.frame = whole
        if let t = shownTile, t.stem == model.currentStem, !model.zoom.isFit {
            let cover = TileFetcher.coverage(of: t.box, framePixels: model.framePixels)
            tile.frame = CGRect(x: whole.minX + cover.minX * whole.width,
                                y: whole.minY + cover.minY * whole.height,
                                width: cover.width * whole.width,
                                height: cover.height * whole.height)
            tile.isHidden = false
        } else {
            tile.isHidden = true
        }
        CATransaction.commit()
    }

    private func commit(_ image: CGImage, rank: Int, stem: String, generation: Int) {
        if let c = committed, c.stem == stem, c.generation == generation, c.rank > rank { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.contents = image
        CATransaction.commit()
        committed = (stem, generation, rank)
        committedAtFrame = frameCount
        startLink()
    }

    /// Whatever tier is already decoded goes up at once — thumb, then large,
    /// then full, upgraded in place with no crossfade, because a crossfade on
    /// every keystroke is noise.
    private func load() {
        guard let stem = model.currentStem, bounds.width > 0 else { return }
        let generation = model.session.cursor.generation
        let shoot = model.session.name
        let scale = window?.backingScaleFactor ?? 2
        let drawn = wholeFrameRect().size
        let px = LightTableSeams.current.fullPixels(forPoints: drawn, scale: scale)
        let pump = model.session.pump

        if let (k, img) = pump.best(shoot: shoot, stem: stem, full: px) {
            commit(img, rank: k.tier.rank, stem: stem, generation: generation)
        } else if committed?.stem != stem {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            base.contents = nil
            CATransaction.commit()
            committed = nil
        }
        layoutLayers()

        // The same frame, the same move and the same size, already climbing or
        // already at the top: leave it alone. `updateNSView` calls `refresh()`
        // on every SwiftUI update of the viewer — and the viewer's body reads
        // the mode, the resume note, the stack invitation and the tally — so
        // this used to cancel a decode in flight and start an identical one
        // whenever a caption changed.
        if let l = loading, l.stem == stem, l.generation == generation, l.px == px,
           loadRunning || loadReachedFull {
            loadTile()
            return
        }

        loadTask?.cancel()
        loading = (stem, generation, px)
        loadRunning = true
        loadReachedFull = false
        let key = ImagePump.Key(shoot: shoot, stem: stem, tier: .thumb)
        // Never capped at `/large`: this is the picture he calls a missed
        // focus on, and `/large` is the camera's JPEG (§3.5).
        let ladder = ImagePump.ladder(toFullPixels: px, stopsAtLarge: false)
        let top = ladder.last?.rank ?? 2
        loadTask = Task { [weak self] in
            for tier in ladder {
                if Task.isCancelled { return }
                guard let img = try? await pump.image(key.with(tier), priority: .userInitiated) else { continue }
                guard let self, self.model.currentStem == stem,
                      self.model.session.cursor.generation == generation else { return }
                self.commit(img, rank: tier.rank, stem: stem, generation: generation)
                self.layoutLayers()
                if tier.rank >= top { self.loadReachedFull = true }
            }
            // The ladder is off this frame's back. A later refresh may climb
            // it again if a tier was refused on the way up.
            guard let self, self.loading?.stem == stem,
                  self.loading?.generation == generation, self.loading?.px == px else { return }
            self.loadRunning = false
        }
        loadTile()
    }

    /// At 1:1 the app cuts a tile 1.6 × the viewport around the aim, so small
    /// pans are local work. A new cut is asked for only as the pan comes near
    /// the tile's edge, and while it is in flight the fitted picture is shown
    /// scaled at the new offset with a small indicator in the corner — never a
    /// blank frame, never a spinner over the photograph.
    private func loadTile() {
        guard !model.zoom.isFit, let stem = model.currentStem, bounds.width > 0 else {
            tileTask?.cancel(); tile.isHidden = true; shownTile = nil
            // Guarded: this runs on every refresh while the zoom is Fit, which
            // is the ordinary state, and `@Observable` does not compare before
            // it notifies. `model.sharpening` is read by the very body that
            // builds this view.
            if model.sharpening { model.sharpening = false }
            return
        }
        let px = model.framePixels
        let scale = window?.backingScaleFactor ?? 2
        let visible = model.zoom.visibleRect(aim: model.aim, framePixels: px, viewport: bounds.size, scale: scale)
        if let t = shownTile, t.stem == stem {
            let cover = TileFetcher.coverage(of: t.box, framePixels: px)
            if !TileFetcher.needsNewTile(viewport: visible, tile: cover) { return }
        }
        let viewportPixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let box = TileFetcher.tile(aim: CGPoint(x: visible.midX, y: visible.midY), viewportPixels: viewportPixels)
        let shoot = model.session.name
        let pump = model.session.pump
        model.sharpening = true
        tileTask?.cancel()
        tileTask = Task { [weak self] in
            let key = ImagePump.Key(shoot: shoot, stem: stem, tier: .crop(box))
            let image = try? await pump.image(key, priority: .userInitiated)
            guard let self, self.model.currentStem == stem else { return }
            self.model.sharpening = false
            guard let image else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.tile.contents = image
            CATransaction.commit()
            self.shownTile = (stem, box)
            self.layoutLayers()
            // The same box on the next two frames, so arrowing through a burst
            // at 1:1 is instant instead of one cold decode per frame (PERF-01).
            let frames = self.model.frames
            let i = self.model.frameIndex
            let ahead = [i + 1, i + 2].filter { frames.indices.contains($0) }
                .map { ImagePump.Key(shoot: shoot, stem: frames[$0], tier: .crop(box)) }
            await pump.prefetch(ahead, priority: .utility)
        }
    }

    // MARK: - the display gate (§2.5.4)

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
        guard checkCharge() else { stopLink(); return }
        frameCount += 1

        // VoiceOver hears the frame he is on, every time it changes (§2.15).
        announceIfChanged()

        // One move per refresh, however fast the key repeats.
        if pendingMove != 0 {
            let step = pendingMove > 0 ? 1 : -1
            pendingMove -= step
            model.performHeld(step > 0 ? .nextFrame : .previousFrame)
        }

        guard let c = committed, c.stem == model.currentStem,
              c.generation == model.session.cursor.generation else { return }
        // A whole refresh with the picture on the layer, and only then does it
        // count as displayed. "Loaded", "requested" and "complete" do not.
        guard frameCount >= committedAtFrame + 2 else { return }
        if reported?.stem != c.stem || reported?.generation != c.generation {
            reported = (c.stem, c.generation)
            model.didDisplay(stem: c.stem, generation: c.generation)
        }
        // Nothing left to watch for: this frame has been reported and no key
        // is waiting to move. `startLink()` is called again from `refresh()`,
        // `commit()` and `keyDown`, so the next thing that happens starts it.
        //
        // Without this the link ran at the display's refresh rate for as long
        // as Choose Keepers was on screen — 120 main-actor callouts a second
        // on a ProMotion display, each building an announcement key and
        // comparing it, with nothing moving. `FrameLayerView.tick` has had the
        // same exit since it was written; the stage never got one.
        if pendingMove == 0 && (c.rank >= 2 || loadReachedFull) { stopLink() }
    }

    // MARK: - keys (§2.5.3)

    // Keys reach the light table through `LightTableKeys`, whatever has the
    // keyboard. These two are what is left for a stage with no light table
    // round it — a test, the bench — and they go the same way.

    public override func keyDown(with e: NSEvent) {
        if !model.key(KeyMap.Press(event: e), at: e.timestamp) { super.keyDown(with: e) }
    }

    public override func keyUp(with e: NSEvent) {
        model.keyReleased(KeyMap.Press(event: e), at: e.timestamp)
        super.keyUp(with: e)
    }

    /// Arrow repeats are coalesced rather than queued one per event. The
    /// link is what spends them, one per refresh, so it has to be running
    /// before the first one is put down.
    public func hold(_ delta: Int) {
        pendingMove = min(8, max(-8, pendingMove + delta))
        startLink()
    }

    public func letGo() { pendingMove = 0 }

    // MARK: - trackpad and Magic Mouse (§2.5.8)

    public override func magnify(with e: NSEvent) {
        let scale = window?.backingScaleFactor ?? 2
        // Where his fingers are, in the photograph and in the viewport, before
        // the factor changes — §2.5.8 asks for the zoom to be anchored under
        // them, and `e.locationInWindow` was being thrown away.
        let p = convert(e.locationInWindow, from: nil)
        let whole = wholeFrameRect()
        let under = whole.width > 0 && whole.height > 0
            ? CGPoint(x: (p.x - whole.minX) / whole.width, y: (p.y - whole.minY) / whole.height)
            : nil
        let spot = bounds.width > 0 && bounds.height > 0
            ? CGPoint(x: (p.x - bounds.minX) / bounds.width, y: (p.y - bounds.minY) / bounds.height)
            : nil

        let snapped = model.zoom.magnify(by: Double(e.magnification), framePixels: model.framePixels,
                                         viewport: bounds.size, scale: scale)
        if snapped { model.haptic(.alignment) }
        if !model.zoom.isFit, let under, let spot {
            model.zoom.anchor(under, at: spot, aim: model.aim, framePixels: model.framePixels,
                              viewport: bounds.size, scale: scale)
        }
        zoomChanged()
    }

    /// Everything a change of zoom has to do: redraw, ask for the right cut,
    /// and tell AppKit the pointer means something else now. `resetCursorRects`
    /// is only called when cursor rects are invalidated — on a frame change, a
    /// window resize, or this — and none of the four things that change the
    /// zoom changes the view's frame, so the cursor stayed as it was until he
    /// left the view and came back.
    private func zoomChanged() {
        layoutLayers()
        loadTile()
        window?.invalidateCursorRects(for: self)
    }

    /// Two-finger double-tap: Fit ⇄ 100 % at that point, aimed at the face.
    public override func smartMagnify(with e: NSEvent) {
        toggleZoom(at: convert(e.locationInWindow, from: nil))
    }

    public override func mouseDown(with e: NSEvent) {
        // A click selects and focuses. It is **never** a verdict.
        window?.makeFirstResponder(self)
        let here = convert(e.locationInWindow, from: nil)
        // In Full Image the picture fills the window and the margin round it
        // is the background: a click there returns, as §2.5.7 says. The
        // background's own tap handler sat under this view and never saw one.
        if model.fullImage, e.clickCount == 1, !wholeFrameRect().contains(here) {
            model.setFullImage(false)
            return
        }
        lastDrag = here
        if e.clickCount == 2 { toggleZoom(at: convert(e.locationInWindow, from: nil)) }
    }

    /// Drag to pan while zoomed, which is what the open hand has been
    /// promising. `resetCursorRects` showed `.openHand` over a zoomed frame
    /// and nothing implemented `mouseDragged`, so the one pointer shape in the
    /// app that says "you can move this" moved nothing — and a wheel mouse,
    /// which has no two-finger scroll, had no other way to pan at all.
    ///
    /// The delta comes from the converted location rather than from
    /// `e.deltaY`, so it is in this view's own flipped coordinates and the
    /// picture goes exactly where his hand goes.
    public override func mouseDragged(with e: NSEvent) {
        let here = convert(e.locationInWindow, from: nil)
        defer { lastDrag = here }
        guard !model.zoom.isFit, let last = lastDrag else { return }
        if !dragging {
            dragging = true
            NSCursor.closedHand.push()
        }
        let scale = window?.backingScaleFactor ?? 2
        let f = model.zoom.factor(framePixels: model.framePixels, viewport: bounds.size, scale: scale)
        model.zoom.pan(by: CGVector(dx: here.x - last.x, dy: here.y - last.y), aim: model.aim,
                       framePixels: model.framePixels, viewport: bounds.size, factor: f, scale: scale)
        layoutLayers()
        loadTile()
    }

    public override func mouseUp(with e: NSEvent) {
        lastDrag = nil
        if dragging {
            dragging = false
            NSCursor.pop()
        }
        super.mouseUp(with: e)
    }

    private var dragging = false
    private var lastDrag: CGPoint?

    /// Force click: a spring-loaded 100 % peek while held — the fastest focus
    /// check that exists on a trackpad.
    private var peeking = false
    public override func pressureChange(with e: NSEvent) {
        if e.stage >= 2 && !peeking {
            peeking = true
            peekZoom = model.zoom
            toggleZoom(at: convert(e.locationInWindow, from: nil), force: true)
        } else if e.stage < 2 && peeking {
            peeking = false
            if let z = peekZoom { model.zoom = z; peekZoom = nil }
            zoomChanged()
        }
    }
    private var peekZoom: ZoomModel?

    private func toggleZoom(at point: CGPoint, force: Bool = false) {
        let px = model.framePixels
        let scale = window?.backingScaleFactor ?? 2
        let whole = wholeFrameRect()
        if whole.width > 0, whole.height > 0 {
            let normalised = CGPoint(x: (point.x - whole.minX) / whole.width,
                                     y: (point.y - whole.minY) / whole.height)
            if model.zoom.isFit || force {
                model.zoom.goToOneToOne()
                model.zoom.anchor(on: normalised, aim: model.aim)
                model.zoom.clampPan(aim: model.aim, framePixels: px, viewport: bounds.size, scale: scale)
            } else {
                model.zoom.goToFit()
            }
        } else {
            model.zoom.toggle(framePixels: px, viewport: bounds.size, scale: scale)
        }
        model.haptic(.alignment)
        zoomChanged()
    }

    private var frameScroll = ScrollInput.FrameScroll()

    public override func scrollWheel(with e: NSEvent) {
        // In points, whatever sent it: a wheel mouse counts lines and carries
        // no phase, so the raw deltas made the same movement of his hand mean
        // two different distances (ScrollInput).
        let d = ScrollInput.points(e)
        if !model.zoom.isFit {
            // Pan, bounded by the picture's own edge — the clamp is inside
            // `pan(by:)` now, so scrolling into an edge cannot build up an
            // invisible surplus that has to be paid back before the picture
            // moves again.
            let scale = window?.backingScaleFactor ?? 2
            let f = model.zoom.factor(framePixels: model.framePixels, viewport: bounds.size, scale: scale)
            model.zoom.pan(by: d, aim: model.aim, framePixels: model.framePixels,
                           viewport: bounds.size, factor: f, scale: scale)
            layoutLayers()
            loadTile()
            return
        }
        let option = e.modifierFlags.contains(.option)
        // A swipe the system is tracking is the whole of its gesture: none of
        // the scrolls still arriving while it runs also steps below, or one
        // swipe could move two frames and record a burst on the way.
        if swiping { return }
        // Sideways, the swipe the system tracks when it can run. When it
        // cannot, the scroll is not dropped: it steps below, one frame for
        // one firm swipe.
        if abs(d.dx) > abs(d.dy), !option, e.phase == .began, beginSwipe(with: e) { return }
        // Never on momentum: one flick of a trackpad would run through a burst.
        guard !ScrollInput.isMomentum(e) else { return }
        // Frame by frame, as the arrows go, on across the end of a burst;
        // with ⌥, the cull's picks (§2.5.8). The first step of a gesture is
        // a press and may cross into the next burst, recording the one he
        // leaves as → does; the steps after it are a key held down and stop
        // at the end of the burst with one bounce. At most three per event,
        // with the surplus carried, so the same movement of his hand moves
        // the same distance however the device chops it up.
        let across = ScrollInput.points(precise: e.hasPreciseScrollingDeltas, deltaX: e.scrollingDeltaX,
                                        deltaY: 0, inverted: false).dx
        for step in frameScroll.steps(down: d.dy, across: across, precise: e.hasPreciseScrollingDeltas,
                                      began: e.phase == .began, option: option, at: e.timestamp) {
            if step.held { model.performHeld(step.action) } else { model.perform(step.action) }
        }
    }

    /// Two-finger swipe between frames, interactive: the frame follows the
    /// fingers and settles or springs back. **It is cut if it could ever show
    /// an undecoded frame** — a half-released swipe that lands on a blank is
    /// worse than an arrow key, which is what `SwipeGate` asserts.
    private var swiping = false
    /// Whether the swipe is being tracked. When it is not — Swipe between
    /// pages off, a neighbour not decoded yet, a one-frame burst — the scroll
    /// steps a frame instead; it used to be dropped without a word.
    private func beginSwipe(with e: NSEvent) -> Bool {
        if swiping { return true }
        guard e.phase == .began, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              SwipeGate.canSwipe(model: model) else { return false }
        swiping = true
        e.trackSwipeEvent(options: [.lockDirection], dampenAmountThresholdMin: -1, max: 1) {
            [weak self] amount, phase, _, stop in
            guard let self else { stop.pointee = true; return }
            MainActor.assumeIsolated {
                if phase == .ended {
                    if amount <= -0.5 { self.model.perform(.nextFrame) }
                    if amount >= 0.5 { self.model.perform(.previousFrame) }
                }
                if phase == .ended || phase == .cancelled { self.swiping = false }
            }
        }
        return true
    }

    // MARK: - the pointer and the menu

    /// Fitted, the pointer is an ordinary arrow: nothing is being targeted, and
    /// a crosshair over a photograph says a click will place or measure
    /// something, which it will not. Zoomed, the open hand is honest now that
    /// `mouseDragged` pans.
    public override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: model.zoom.isFit ? .arrow : .openHand)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        StageMenu.menu(for: model)
    }

    // MARK: - VoiceOver (§2.15)

    /// The last sentence handed to VoiceOver, and the cheap signature it was
    /// built from.
    private var announced: ViewerModel.AnnouncementKey?

    /// *"Frame 04330, 2 of 7 in burst 3. You kept it. The cull's guess: …"*
    ///
    /// The label says what this element **is** — the photograph — and never
    /// changes; the value says which photograph, and changes with the cursor.
    /// Posting `.valueChanged` is what makes VoiceOver read the new frame where
    /// the user is standing, rather than making him navigate away and back to
    /// discover that arrowing did anything at all.
    private func announceIfChanged() {
        let key = model.announcementKey
        guard key != announced else { return }
        announced = key
        setAccessibilityValue(model.frameAnnouncement)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// Keep, Drop, Clear the Mark and Compare as rotor actions, so a VoiceOver
    /// user can decide a frame without knowing the key.
    private func verdictActions() -> [NSAccessibilityCustomAction] {
        let m = model
        // Accessibility actions arrive on the main thread; they go through the
        // same press queue as the keys, so they meet the same display gate.
        func action(_ name: String, _ a: KeyMap.Action) -> NSAccessibilityCustomAction {
            NSAccessibilityCustomAction(name: name) {
                MainActor.assumeIsolated { m.perform(a) }
                return true
            }
        }
        return [
            action(Strings.Verdict.keep, .keep),
            action(Strings.Verdict.drop, .drop),
            action(Strings.LightTable.clearTheMark, .clearMark),
            action(Strings.LightTable.compare, .compare),
        ]
    }
}

/// Whether a two-finger swipe may start at all: both neighbours have to have
/// pixels already decoded, or the gesture is not offered.
public enum SwipeGate {
    @MainActor
    public static func canSwipe(model: ViewerModel) -> Bool {
        let frames = model.frames
        let i = model.frameIndex
        let pump = model.session.pump
        let shoot = model.session.name
        let neighbours = [i - 1, i + 1].filter { frames.indices.contains($0) }
        guard !neighbours.isEmpty else { return false }
        return neighbours.allSatisfy { pump.best(shoot: shoot, stem: frames[$0]) != nil }
    }
}

/// The right-click menu (§2.5.8). Every one of these has a key, and none of
/// them is destructive.
///
/// Its rows are the Frame menu's rows, under the Frame menu's names and with
/// the Frame menu's keys: the reasons used to show ⌘1–⌘6, which are the Go
/// menu's steps, under a submenu called "Reason" in lower case, beside a
/// Frame menu that says "Why It Is Out ▸ Shadow".
@MainActor
public enum StageMenu {
    public static func menu(for model: ViewerModel) -> NSMenu {
        let m = NSMenu()
        func row(_ title: String, _ id: CommandID?, in menu: NSMenu? = nil, _ act: @escaping () -> Void) {
            let i = NSMenuItem(title: title, action: #selector(Target.fire(_:)), keyEquivalent: "")
            i.target = Target.shared
            i.representedObject = Target.Box(act)
            if let id, let key = CommandTable.shortcut(id) {
                i.keyEquivalent = key.keyEquivalent
                i.keyEquivalentModifierMask = key.modifiers.appKit
            }
            (menu ?? m).addItem(i)
        }
        typealias ID = CommandTable.ID
        row(Words.Frame.keep, ID.keep) { model.perform(.keep) }
        row(Words.Frame.drop, ID.drop) { model.perform(.drop) }
        row(Words.Frame.clearMark, ID.clearMark) { model.perform(.clearMark) }
        m.addItem(.separator())
        let reasons = NSMenu()
        for r in DropReason.allCases {
            row(r.word.capitalizedFirst, ID.reason(r), in: reasons) { model.perform(.reason(r.key)) }
        }
        let why = NSMenuItem(title: Words.Frame.whyItIsOut, action: nil, keyEquivalent: "")
        why.submenu = reasons
        m.addItem(why)
        m.addItem(.separator())
        if model.canCompare {
            row(Words.Frame.compare, ID.compare) { model.perform(.compare) }
        }
        row(Strings.LightTable.fullImage, ID.fullImage) { model.perform(.toggleFullImage) }
        m.addItem(.separator())
        row(Words.Frame.showInFinder, ID.showFrameInFinder) { _ = CommandCenter.shared.run(ID.showFrameInFinder) }
        row(Words.Frame.copyNumber, ID.copyFrameNumber) { _ = CommandCenter.shared.run(ID.copyFrameNumber) }
        return m
    }

    @MainActor final class Target: NSObject {
        static let shared = Target()
        override init() { super.init() }
        final class Box: NSObject { let act: () -> Void; init(_ a: @escaping () -> Void) { act = a } }
        @objc func fire(_ sender: NSMenuItem) { (sender.representedObject as? Box)?.act() }
    }
}

/// The stage, in SwiftUI.
public struct StageView: NSViewRepresentable {
    let model: ViewerModel
    let role: StageLayerView.Role
    /// Read here, in the body that builds this, so Full Image coming and going
    /// always reaches `updateNSView` on both stages. Each decides from the
    /// model itself whether it is the one in charge.
    let fullImage: Bool

    public init(model: ViewerModel, role: StageLayerView.Role = .table) {
        self.model = model
        self.role = role
        self.fullImage = model.fullImage
    }

    public func makeNSView(context: Context) -> StageLayerView {
        let v = StageLayerView(model: model)
        v.role = role
        v.refresh()
        return v
    }

    public func updateNSView(_ v: StageLayerView, context: Context) {
        v.role = role
        v.refresh()
    }

    public static func dismantleNSView(_ v: StageLayerView, coordinator: ()) {
        v.tearDown()
    }
}
