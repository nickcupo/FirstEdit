import Foundation
import CoreGraphics

/// Every picture the app draws comes through here.
///
/// Cold RAW decode costs 650–720 ms on the server (PERF-01), so the app never
/// asks for a picture at the moment he needs it — it asked already. The pump
/// fetches over `URLSession` with the studio key, decodes with ImageIO off the
/// main actor at the size the view will draw, keeps what it decoded within a
/// budget scaled to the Mac, and runs the prefetch ladder of DESIGN.md §3.5.
public actor ImagePump {

    public struct Key: Hashable, Sendable {
        public let shoot: String
        public let stem: String
        public let tier: Tier
        /// The long edge to decode to, in device pixels. `nil` is the tier's
        /// own size: the asset for thumb and large, `px` for full, native for
        /// a crop.
        public let maxPixel: Int?

        public init(shoot: String, stem: String, tier: Tier, maxPixel: Int? = nil) {
            self.shoot = shoot
            self.stem = stem
            self.tier = tier
            self.maxPixel = maxPixel
        }

        public func with(_ tier: Tier, maxPixel: Int? = nil) -> Key {
            Key(shoot: shoot, stem: stem, tier: tier, maxPixel: maxPixel)
        }
    }

    public enum Tier: Hashable, Sendable {
        case thumb
        case large
        case full(px: Int)
        case crop(CropBox)

        /// Coarse to sharp, for "show the best one already here".
        public var rank: Int {
            switch self {
            case .thumb: return 0
            case .large: return 1
            case .full: return 2
            case .crop: return 3
            }
        }
    }

    /// The `/full?px=` sizes. Rounding up to one of these keeps URLs few and
    /// cacheable; 4096 covers a 27" fit view (3606 device px), past today's
    /// fixed 2600 (LT-05).
    public static let fullTiers = [1440, 2048, 2600, 3200, 4096]

    /// The tier for a view of `points` at `scale`: the needed long edge in
    /// device pixels, rounded up to the next size the server is asked for.
    public static func fullTier(forPoints points: CGSize, scale: CGFloat) -> Tier {
        .full(px: fullPixels(forPoints: points, scale: scale))
    }

    public static func fullPixels(forPoints points: CGSize, scale: CGFloat) -> Int {
        let need = Downsampler.maxPixel(forPoints: points, scale: scale)
        return fullTiers.first(where: { $0 >= need }) ?? fullTiers[fullTiers.count - 1]
    }

    /// The engine's `/large` rendering, in pixels on its long edge
    /// (`common.py: LARGE_PX`). The same 1440 as the smallest `/full` tier —
    /// and **not the same picture**: `/large` is the camera's own embedded
    /// JPEG resized, which `common.py` says in as many words is "too soft to
    /// call a missed focus on", while `/full` is the RAW decode, capped.
    public static let largePixels = 1440

    /// The tiers a view of this size should actually climb, coarse to sharp.
    ///
    /// `stopsAtLarge` is a view saying **nobody judges a photograph in me**. A
    /// cover, a cell, a strip: it wants a picture of the frame, not the frame.
    /// Such a box that needs no more than `/large` stops there, because asking
    /// `/full` for it buys no pixels it can draw — the two are the same 1440
    /// px on the long edge — and costs a cold RAW decode, 650–720 ms behind a
    /// two-wide gate (PERF-01), inserted *ahead* of every prefetch because
    /// anything at `.userInitiated` is urgent. Every small view in the app was
    /// doing it: a 90 pt filmstrip cell needs 180 px and asked for 1440, a
    /// 180 pt burst cover needs 360 and asked for 1440. Scrolling All Bursts
    /// queued one of those per cover crossed, in front of the photograph he
    /// was looking at.
    ///
    /// A view he judges focus in passes `false` and climbs to `/full` at
    /// whatever size it draws, 1440 included. The cap is about **what the box
    /// is for**, never about its size alone: at the documented 900 × 620
    /// minimum the fitted picture is 1146 device px, which rounds to 1440, and
    /// a size-only cap left the stage — the state he culls in — looking at the
    /// camera's JPEG on every window up to roughly 1010 × 730, and on every
    /// window at all on a 1× display.
    public static func ladder(toFullPixels px: Int, stopsAtLarge: Bool) -> [Tier] {
        stopsAtLarge && px <= largePixels ? [.thumb, .large] : [.thumb, .large, .full(px: px)]
    }

    /// At most two cold `/full` requests at once, mirroring the server's own
    /// decode gate, so prefetch can never queue behind itself and stall the
    /// frame he is on.
    public static let coldFullLimit = 2

    /// Where the bytes come from. The engine, normally; a folder of files for
    /// the snapshot harness; a counting stub in a test.
    public typealias Loader = @Sendable (ImageRoute) async throws -> Data

    // MARK: -

    private let fetch: Loader
    private let cache: ImageCache
    private var baseBudget: Budget
    private var pressured = false

    private var inFlight: [Key: Task<CGImage, Error>] = [:]
    private var prefetching: [Key: Task<Void, Never>] = [:]
    private var coldFull = 0
    private var peakColdFull = 0
    /// Waiting for a cold-`/full` slot. The frame under the cursor is always
    /// served before a prefetch.
    private var waiters: [(urgent: Bool, id: UUID, c: CheckedContinuation<Void, Error>)] = []
    private var fetched = 0
    private var cancelled = 0

    /// Each frame's display curve (`DisplayTone`), worked out from the first
    /// `/full` of it that arrives and kept for as long as the shoot is open:
    /// 256 bytes a frame, so every size of `/full` and every `/crop` of one
    /// frame is drawn at the one brightness.
    private var curves: [Frame: DisplayTone.Curve] = [:]
    private struct Frame: Hashable { let shoot: String; let stem: String }
    /// Frames whose thumbnail could not be had — the fetch failed, not was
    /// cancelled — so no curve could be measured. A `/crop` of one is drawn
    /// as it comes rather than asking for a `/full` to measure with, which
    /// would only fail the same way: every 1:1 tile of such a frame used to
    /// cost a 1440 px RAW decode. The next `/full` of it tries again.
    private var unmeasured: Set<Frame> = []

    private nonisolated(unsafe) var pressureSource: DispatchSourceMemoryPressure?

    public init(client: StudioClient, budget: Budget = .automatic) {
        self.init(budget: budget, loader: { route in
            let (data, response) = try await URLSession.studio.data(for: client.imageRequest(route))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw StudioError.http(status: status, body: "")
            }
            return data
        })
    }

    public init(budget: Budget = .automatic, loader: @escaping Loader) {
        self.fetch = loader
        self.baseBudget = budget
        self.cache = ImageCache(budget: budget)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal],
                                                             queue: .global(qos: .utility))
        let cache = self.cache
        source.setEventHandler { [weak self] in
            let event = source.data
            let pressured = event.contains(.warning) || event.contains(.critical)
            Task { await self?.setPressure(pressured) }
            cache.setBudget(pressured ? budget.underPressure : budget)
        }
        source.resume()
        self.pressureSource = source
    }

    deinit { pressureSource?.cancel() }

    // MARK: - public

    /// The picture for `key`, fetched and decoded if it is not already here.
    /// A request for a key that is already being fetched joins that fetch —
    /// and, awaited from a higher priority, lifts it.
    ///
    /// Never a fetch that has been cancelled. A prefetch let go as he left a
    /// burst stays in flight until it notices, which for a `/full` includes
    /// the wait for its thumbnail and the curve's measuring, and a request
    /// that joined it — the stage, as he came back to that frame — was handed
    /// its cancellation and drew the soft camera JPEG until the stage next
    /// asked. It starts its own fetch instead, and the one being cancelled
    /// takes only itself out of the book when it ends.
    public func image(_ key: Key, priority: TaskPriority = .userInitiated) async throws -> CGImage {
        if let hit = cache.image(key) { return hit }
        if let t = inFlight[key], !t.isCancelled { return try await t.value }
        let urgent = priority >= .userInitiated
        let t = Task(priority: priority) { try await self.load(key, urgent: urgent) }
        inFlight[key] = t
        defer { if inFlight[key] == t { inFlight[key] = nil } }
        return try await t.value
    }

    /// Whatever is already decoded, without waiting. The viewer draws this on
    /// every move so it is never empty.
    public nonisolated func cached(_ key: Key) -> CGImage? {
        cache.image(key)
    }

    /// The sharpest picture of this frame already decoded, at any tier.
    public nonisolated func best(shoot: String, stem: String, full: Int? = nil) -> (Key, CGImage)? {
        var keys: [Key] = []
        if let full { keys.append(Key(shoot: shoot, stem: stem, tier: .full(px: full))) }
        for px in Self.fullTiers.reversed() where px != full {
            keys.append(Key(shoot: shoot, stem: stem, tier: .full(px: px)))
        }
        keys.append(Key(shoot: shoot, stem: stem, tier: .large))
        keys.append(Key(shoot: shoot, stem: stem, tier: .thumb))
        for k in keys { if let i = cache.image(k) { return (k, i) } }
        return nil
    }

    /// Ask for these now so they are here when he gets to them. Lower
    /// priority than anything he is looking at, and cancellable.
    public func prefetch(_ keys: [Key], priority: TaskPriority = .utility) {
        for key in keys where cache.image(key) == nil && prefetching[key] == nil {
            let t = Task(priority: priority) { [weak self] in
                guard let self else { return }
                _ = try? await self.image(key, priority: priority)
                await self.prefetchEnded(key)
            }
            prefetching[key] = t
        }
    }

    /// Leaving a burst cancels its outstanding prefetches. Cancelling the
    /// task cancels the underlying `URLSessionTask`.
    public func cancelPrefetch(keeping: Set<Key>) {
        for (k, t) in prefetching where !keeping.contains(k) {
            t.cancel()
            inFlight[k]?.cancel()
            prefetching[k] = nil
            cancelled += 1
        }
    }

    /// Everything decoded for one shoot, dropped — after a re-cull, say.
    public func evict(shoot: String) {
        cancelPrefetch(keeping: Set(prefetching.keys.filter { $0.shoot != shoot }))
        cache.evict(shoot: shoot)
        curves = curves.filter { $0.key.shoot != shoot }
        unmeasured = unmeasured.filter { $0.shoot != shoot }
    }

    /// The curve a frame's sharp pictures are drawn through, once one of them
    /// has arrived. For the tests and the bench.
    public func displayCurve(shoot: String, stem: String) -> DisplayTone.Curve? {
        curves[Frame(shoot: shoot, stem: stem)]
    }

    public func report() -> Report {
        let c = cache.counts
        return Report(budget: cache.currentBudget, thumbBytes: c.thumbBytes, decodedCount: c.decodedCount,
                      decodedBytes: c.decodedBytes, tileCount: c.tileCount, inFlight: inFlight.count,
                      inFlightColdFull: coldFull, peakColdFull: peakColdFull,
                      prefetches: prefetching.count, fetched: fetched, cancelled: cancelled,
                      underPressure: pressured)
    }

    /// For the test that simulates memory pressure.
    public func simulateMemoryPressure(_ on: Bool) {
        setPressure(on)
        cache.setBudget(on ? baseBudget.underPressure : baseBudget)
    }

    // MARK: - the prefetch ladder (§3.5)

    /// A shoot opens: every thumbnail, lowest priority.
    public func shootOpened(_ shoot: String, stems: [String]) {
        prefetch(stems.map { Key(shoot: shoot, stem: $0, tier: .thumb) }, priority: .background)
    }

    /// A burst opens: `/large` for every frame, `/full` for the cursor ± 2.
    public func burstOpened(_ shoot: String, frames: [String], cursor: Int, fullPx: Int) {
        var keep = Set<Key>()
        let large = frames.map { Key(shoot: shoot, stem: $0, tier: .large) }
        let near = frames.indices.filter { abs($0 - cursor) <= 2 }
            .map { Key(shoot: shoot, stem: frames[$0], tier: .full(px: fullPx)) }
        keep.formUnion(large)
        keep.formUnion(near)
        // Thumbnails for the whole shoot stay wanted; only other bursts'
        // larger tiers are let go.
        keep.formUnion(prefetching.keys.filter { $0.tier == .thumb })
        cancelPrefetch(keeping: keep)
        prefetch(near, priority: .userInitiated)
        prefetch(large, priority: .utility)
    }

    /// The cursor moved: `/full` for the next three frames in the direction
    /// of travel.
    public func cursorMoved(_ shoot: String, frames: [String], cursor: Int, forward: Bool, fullPx: Int) {
        let step = forward ? 1 : -1
        let ahead = (1...3).map { cursor + $0 * step }.filter { frames.indices.contains($0) }
        prefetch(ahead.map { Key(shoot: shoot, stem: frames[$0], tier: .full(px: fullPx)) }, priority: .utility)
    }

    /// The burst is three frames from its end, or N was pressed: the first
    /// frame of the next burst, sharp. This is the single biggest wait today —
    /// about 1.8 minutes of pure waiting per 155-burst session (PERF-01).
    public func nextBurstComing(_ shoot: String, firstFrame: String, fullPx: Int) {
        prefetch([Key(shoot: shoot, stem: firstFrame, tier: .full(px: fullPx))], priority: .userInitiated)
    }

    // MARK: - the fetch

    private func load(_ key: Key, urgent: Bool) async throws -> CGImage {
        let route = Self.route(for: key)
        let isColdFull: Bool = { if case .full = key.tier { return true }; return false }()

        let data: Data
        if case .thumb = key.tier, let d = cache.data(key.with(.thumb)) {
            data = d
        } else {
            if isColdFull { try await acquireColdFull(urgent: urgent) }
            defer { if isColdFull { releaseColdFull() } }
            try Task.checkCancellation()
            data = try await fetch(route)
            fetched += 1
            if case .thumb = key.tier { cache.store(data, for: key.with(.thumb)) }
        }
        try Task.checkCancellation()

        let maxPixel = key.maxPixel ?? Self.naturalMaxPixel(key.tier)
        var image = try await Self.decodeDetached(data, maxPixel: maxPixel)
        switch key.tier {
        case .full, .crop: image = try await atCameraBrightness(image, key)
        case .thumb, .large: break
        }
        cache.store(image, for: key)
        return image
    }

    // MARK: - the camera's brightness (§3.5)

    /// A RAW decode, redrawn at the brightness of the same frame's camera
    /// JPEG (`DisplayTone`). On screen only: nothing the engine keeps or the
    /// cull reads is touched.
    ///
    /// The curve is measured once per frame, from its first `/full` against
    /// its thumbnail — often here already, since the filmstrip and every view
    /// climb through it on the way up, and otherwise fetched here; nothing
    /// asks for a whole shoot's thumbnails as it opens (`shootOpened` has no
    /// caller) — and a `/crop` of the frame uses that frame's curve. A picture
    /// is never kept in the ring without its curve because the wait for the
    /// thumbnail was cancelled: that is the one way it could come back dark
    /// later, from the cache, with nothing to say it was. One whose thumbnail
    /// could not be fetched at all is kept as it came, as every `/full` was
    /// before the curve, and its frame is remembered (`unmeasured`).
    private func atCameraBrightness(_ image: CGImage, _ key: Key) async throws -> CGImage {
        let frame = Frame(shoot: key.shoot, stem: key.stem)
        var curve = curves[frame]
        if curve == nil {
            let priority = Task.currentPriority
            switch key.tier {
            case .full:
                do {
                    let camera = try await self.image(Key(shoot: key.shoot, stem: key.stem, tier: .thumb),
                                                      priority: priority)
                    curve = await Self.measureDetached(camera: camera, decode: image)
                    unmeasured.remove(frame)
                } catch is CancellationError {
                    // Whether that was this picture's own wait is asked below.
                } catch let e as URLError where e.code == .cancelled {
                    // The same, from under URLSession.
                } catch {
                    unmeasured.insert(frame)
                }
            case .crop:
                // The whole frame's curve, never one measured on a window of
                // it: a crop of a dark corner would be lifted to the whole
                // frame's brightness. Whichever `/full` of it is coming is
                // waited for, or the smallest is asked for, and that measures.
                // Not for a frame with no thumbnail to measure against.
                guard !unmeasured.contains(frame) else { return image }
                let coming = inFlight.keys.first { k in
                    guard k.shoot == key.shoot, k.stem == key.stem, case .full = k.tier else { return false }
                    return true
                }
                let whole = coming ?? Key(shoot: key.shoot, stem: key.stem, tier: .full(px: Self.fullTiers[0]))
                _ = try? await self.image(whole, priority: priority)
                curve = curves[frame]
            case .thumb, .large:
                return image
            }
            try Task.checkCancellation()
            if let curve { curves[frame] = curve }
        }
        guard let curve, !curve.leavesItAlone else { return image }
        return await Self.applyDetached(curve, to: image) ?? image
    }

    private static func measureDetached(camera: CGImage, decode: CGImage) async -> DisplayTone.Curve? {
        await Task.detached(priority: Task.currentPriority) {
            DisplayTone.curve(matching: camera, from: decode)
        }.value
    }

    private static func applyDetached(_ curve: DisplayTone.Curve, to image: CGImage) async -> CGImage? {
        await Task.detached(priority: Task.currentPriority) {
            DisplayTone.apply(curve, to: image)
        }.value
    }

    private static func naturalMaxPixel(_ t: Tier) -> Int? {
        switch t {
        case .full(let px): return px
        case .thumb, .large, .crop: return nil
        }
    }

    /// Off the actor as well as off the main actor: a 4096 px decode must not
    /// hold up the next request's bookkeeping.
    private static func decodeDetached(_ data: Data, maxPixel: Int?) async throws -> CGImage {
        try await Task.detached(priority: Task.currentPriority) {
            try Downsampler.decode(data, maxPixel: maxPixel)
        }.value
    }

    static func route(for key: Key) -> ImageRoute {
        switch key.tier {
        case .thumb: return .thumb(shoot: key.shoot, stem: key.stem)
        case .large: return .large(shoot: key.shoot, stem: key.stem)
        case .full(let px): return .full(shoot: key.shoot, stem: key.stem, px: px)
        case .crop(let b): return .crop(shoot: key.shoot, stem: key.stem, cx: b.cx, cy: b.cy, px: b.px, ar: b.ar)
        }
    }

    // MARK: - the cold-/full gate

    private func acquireColdFull(urgent: Bool) async throws {
        if coldFull < Self.coldFullLimit {
            coldFull += 1
            peakColdFull = max(peakColdFull, coldFull)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if urgent {
                    // In front of every prefetch, behind any earlier urgent one.
                    let at = waiters.firstIndex(where: { !$0.urgent }) ?? waiters.count
                    waiters.insert((urgent, id, c), at: at)
                } else {
                    waiters.append((urgent, id, c))
                }
            }
        } onCancel: {
            Task { await self.dropWaiter(id) }
        }
    }

    private func releaseColdFull() {
        if !waiters.isEmpty {
            // The slot passes straight to the next waiter; the count is unchanged.
            let next = waiters.removeFirst()
            next.c.resume()
        } else {
            coldFull = max(0, coldFull - 1)
        }
    }

    private func dropWaiter(_ id: UUID) {
        if let i = waiters.firstIndex(where: { $0.id == id }) {
            let w = waiters.remove(at: i)
            w.c.resume(throwing: CancellationError())
        }
    }

    private func prefetchEnded(_ key: Key) { prefetching[key] = nil }
    private func setPressure(_ on: Bool) { pressured = on }
}
