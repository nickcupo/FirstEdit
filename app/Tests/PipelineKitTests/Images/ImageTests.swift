import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import PipelineKit

/// A real JPEG of the given size, made in memory.
func makeJPEG(width: Int, height: Int) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = ctx.makeImage()!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

/// Counts how many loads are in flight at once, and holds each for a while.
actor LoadCounter {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var total = 0
    private(set) var cancelled = 0
    func enter() { current += 1; total += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
    func sawCancel() { cancelled += 1 }
}

@Suite("The image pipeline")
struct ImageTests {
    static let jpeg = makeJPEG(width: 600, height: 400)

    @Test("the /full tier is the view's device pixels rounded up to a size the server is asked for")
    func tierLadder() {
        // §2.5.1's measured boxes, at Retina scale.
        #expect(ImagePump.fullPixels(forPoints: CGSize(width: 813, height: 542), scale: 2) == 2048)
        #expect(ImagePump.fullPixels(forPoints: CGSize(width: 1060, height: 707), scale: 2) == 2600)
        #expect(ImagePump.fullPixels(forPoints: CGSize(width: 1263, height: 842), scale: 2) == 2600)
        #expect(ImagePump.fullPixels(forPoints: CGSize(width: 1417, height: 945), scale: 2) == 3200)
        // A 27" fit view is 3606 device px: past today's fixed 2600 (LT-05).
        #expect(ImagePump.fullPixels(forPoints: CGSize(width: 1803, height: 1202), scale: 2) == 4096)
        #expect(ImagePump.fullPixels(forPoints: CGSize(width: 3000, height: 2000), scale: 2) == 4096)
        #expect(ImagePump.fullPixels(forPoints: CGSize(width: 90, height: 60), scale: 2) == 1440)
        #expect(ImagePump.fullPixels(forPoints: CGSize(width: 813, height: 542), scale: 1) == 1440)
        #expect(Downsampler.maxPixel(forPoints: CGSize(width: 90, height: 60), scale: 2) == 180)
    }

    @Test("decoding downsamples to the size it will be drawn at")
    func downsample() throws {
        let big = makeJPEG(width: 3000, height: 2000)
        let small = try Downsampler.decode(big, maxPixel: 300)
        #expect(max(small.width, small.height) == 300)
        let native = try Downsampler.decode(big, maxPixel: nil)
        #expect(native.width == 3000 && native.height == 2000)
        #expect(Downsampler.pixelSize(of: big).map { [$0.0, $0.1] } == [3000, 2000])
        #expect(throws: Downsampler.Failure.self) { try Downsampler.decode(Data("not a jpeg".utf8), maxPixel: 100) }
    }

    @Test("the budget scales with the Mac and shrinks under pressure")
    func budget() {
        let b16 = ImagePump.Budget.scaled(forPhysicalMemory: 16 << 30)
        #expect(b16 == .base)
        #expect(b16.thumbBytes == 96 << 20 && b16.decodedCount == 24 && b16.tileCount == 8)
        let b64 = ImagePump.Budget.scaled(forPhysicalMemory: 64 << 30)
        #expect(b64.thumbBytes == 4 * (96 << 20) && b64.decodedCount == 96)
        let b8 = ImagePump.Budget.scaled(forPhysicalMemory: 8 << 30)
        #expect(b8.thumbBytes == 48 << 20 && b8.decodedCount == 12)
        let p = b16.underPressure
        #expect(p.thumbBytes == 48 << 20 && p.decodedCount == 4)
    }

    @Test("memory pressure shrinks the ring the pump actually keeps")
    func pressure() async throws {
        let pump = ImagePump(budget: .base, loader: { _ in Self.jpeg })
        for i in 0..<10 {
            _ = try await pump.image(.init(shoot: "s", stem: "f\(i)", tier: .large))
        }
        #expect(await pump.report().decodedCount == 10)
        await pump.simulateMemoryPressure(true)
        let r = await pump.report()
        #expect(r.underPressure)
        #expect(r.decodedCount == 4)
        #expect(r.budget.decodedCount == 4)
    }

    @Test("never more than two cold /full requests at once")
    func coldFullCap() async throws {
        let counter = LoadCounter()
        let pump = ImagePump(budget: .base, loader: { route in
            // Only the RAW decodes are counted: each also reads its frame's
            // thumbnail, to draw it at the camera's brightness, and a
            // thumbnail is not a decode and never waits at the gate.
            guard case .full = route else { return Self.jpeg }
            await counter.enter()
            try await Task.sleep(for: .milliseconds(60))
            await counter.leave()
            return Self.jpeg
        })
        try await withThrowingTaskGroup(of: Void.self) { g in
            for i in 0..<8 {
                g.addTask {
                    _ = try await pump.image(.init(shoot: "s", stem: "f\(i)", tier: .full(px: 2048)),
                                             priority: i == 7 ? .userInitiated : .utility)
                }
            }
            try await g.waitForAll()
        }
        #expect(await counter.peak == ImagePump.coldFullLimit)
        #expect(await counter.total == 8)
        #expect(await pump.report().peakColdFull <= 2)
        #expect(await pump.report().inFlightColdFull == 0)
    }

    @Test("two requests for one frame are one fetch")
    func dedupe() async throws {
        let counter = LoadCounter()
        let pump = ImagePump(budget: .base, loader: { _ in
            await counter.enter(); try await Task.sleep(for: .milliseconds(50)); await counter.leave()
            return Self.jpeg
        })
        let k = ImagePump.Key(shoot: "s", stem: "f", tier: .large)
        async let a = pump.image(k)
        async let b = pump.image(k)
        _ = try await (a, b)
        #expect(await counter.total == 1)
        #expect(pump.cached(k) != nil)
    }

    @Test("leaving a burst cancels its prefetches")
    func cancelPrefetch() async throws {
        let counter = LoadCounter()
        let pump = ImagePump(budget: .base, loader: { _ in
            await counter.enter()
            do { try await Task.sleep(for: .seconds(5)) } catch { await counter.sawCancel(); await counter.leave(); throw error }
            await counter.leave()
            return Self.jpeg
        })
        let keys = (0..<4).map { ImagePump.Key(shoot: "s", stem: "f\($0)", tier: .large) }
        await pump.prefetch(keys, priority: .utility)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await pump.report().prefetches == 4)
        await pump.cancelPrefetch(keeping: [keys[0]])
        try await Task.sleep(for: .milliseconds(150))
        #expect(await counter.cancelled == 3)
        #expect(await pump.report().cancelled == 3)
        await pump.cancelPrefetch(keeping: [])
    }

    @Test("the best already-decoded tier is found without waiting")
    func best() async throws {
        let pump = ImagePump(budget: .base, loader: { _ in Self.jpeg })
        #expect(pump.best(shoot: "s", stem: "f") == nil)
        _ = try await pump.image(.init(shoot: "s", stem: "f", tier: .thumb))
        #expect(pump.best(shoot: "s", stem: "f")?.0.tier == .thumb)
        _ = try await pump.image(.init(shoot: "s", stem: "f", tier: .full(px: 2600)))
        #expect(pump.best(shoot: "s", stem: "f")?.0.tier == .full(px: 2600))
    }

    @Test("the ring drops the oldest first, and tiles have their own small store")
    func ring() async throws {
        let budget = ImagePump.Budget(thumbBytes: 1 << 20, decodedCount: 3, decodedBytes: 1 << 30, tileCount: 2)
        let pump = ImagePump(budget: budget, loader: { _ in Self.jpeg })
        for i in 0..<5 { _ = try await pump.image(.init(shoot: "s", stem: "f\(i)", tier: .large)) }
        #expect(pump.cached(.init(shoot: "s", stem: "f0", tier: .large)) == nil)
        #expect(pump.cached(.init(shoot: "s", stem: "f4", tier: .large)) != nil)
        // 1:1 is only ever reached from the fitted picture, which is how a
        // tile knows the frame's brightness (`DisplayTone`).
        let full = ImagePump.Key(shoot: "s", stem: "f4", tier: .full(px: 1440))
        _ = try await pump.image(full)
        let ring = [full, .init(shoot: "s", stem: "f4", tier: .large), .init(shoot: "s", stem: "f4", tier: .thumb)]
        #expect(ring.allSatisfy { pump.cached($0) != nil })
        for i in 0..<3 {
            let box = CropBox(cx: 0.5, cy: 0.5, px: 1000 + i, ar: 0.75)
            _ = try await pump.image(.init(shoot: "s", stem: "f4", tier: .crop(box)))
        }
        let r = await pump.report()
        #expect(r.tileCount == 2)
        #expect(r.decodedCount == 3)             // tiles did not push frames out
        #expect(ring.allSatisfy { pump.cached($0) != nil })
    }

    @Test("a /crop tile uses the engine's meaning: px is width, ar is height over width")
    func tiles() {
        let t = TileFetcher.tile(aim: CGPoint(x: 0.5, y: 0.38), viewportPixels: CGSize(width: 1600, height: 1000))
        #expect(t.px == 2560)
        #expect(t.ar == 0.625)
        let big = TileFetcher.tile(aim: .init(x: 0.5, y: 0.5), viewportPixels: CGSize(width: 3400, height: 2000))
        #expect(big.px == TileFetcher.maximumTilePixels)

        let cover = TileFetcher.coverage(of: t, framePixels: CGSize(width: 6024, height: 4024))
        #expect(abs(cover.width - 2560.0 / 6024) < 1e-6)
        #expect(abs(cover.height - 1600.0 / 4024) < 1e-6)
        // A box off the edge is shifted in, not shrunk.
        let corner = TileFetcher.coverage(of: CropBox(cx: 0.99, cy: 0.99, px: 2000, ar: 0.5),
                                          framePixels: CGSize(width: 6024, height: 4024))
        #expect(abs(corner.maxX - 1) < 1e-9 && abs(corner.maxY - 1) < 1e-9)

        let tile = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        #expect(!TileFetcher.needsNewTile(viewport: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2), tile: tile))
        #expect(TileFetcher.needsNewTile(viewport: CGRect(x: 0.39, y: 0.3, width: 0.2, height: 0.2), tile: tile))
        // Against the frame's own edge there is nowhere further to cut.
        let edge = CGRect(x: 0, y: 0.2, width: 0.4, height: 0.4)
        #expect(!TileFetcher.needsNewTile(viewport: CGRect(x: 0, y: 0.3, width: 0.2, height: 0.2), tile: edge))
    }

    @Test("a crop box is clamped and quantised, so a tiny pan is the same URL")
    func cropBox() {
        let a = CropBox(cx: 0.50001, cy: 0.3, px: 10, ar: 9)
        #expect(a.px == 256 && a.ar == 4 && a.cx == 0.5)
        #expect(CropBox(cx: 0.5001, cy: 0.3, px: 1000, ar: 0.75) == CropBox(cx: 0.50004, cy: 0.3, px: 1000, ar: 0.75))
    }
}

/// PERF-01. A cold `/full` is a 650–720 ms RAW decode behind a two-wide gate,
/// and anything asked at `.userInitiated` is inserted ahead of every prefetch.
/// So which views are allowed to ask for one is a question about how the app
/// feels while he is scrolling, not a question about pixels.
@Suite("the tier ladder a view climbs")
struct TierLadderTests {

    /// `/large` is `common.py: LARGE_PX = 1440`, the same long edge as the
    /// smallest `/full` tier — and a resize of the camera's embedded JPEG,
    /// which `common.py` calls too soft to call a missed focus on.
    @Test("a thumbnail no bigger than /large never asks for /full")
    func smallBoxesStopAtLarge() {
        #expect(ImagePump.largePixels == ImagePump.fullTiers[0])
        let ladder = ImagePump.ladder(toFullPixels: ImagePump.largePixels, stopsAtLarge: true)
        #expect(ladder == [.thumb, .large])
        #expect(!ladder.contains { if case .full = $0 { return true } else { return false } })
    }

    @Test("a thumbnail that needs more than /large still climbs to it")
    func bigBoxesStillAsk() {
        #expect(ImagePump.ladder(toFullPixels: 2600, stopsAtLarge: true)
                == [.thumb, .large, .full(px: 2600)])
    }

    /// The boxes the app actually draws. The small ones used to ask the engine
    /// for `/full?px=1440` apiece; the stage was then stopped at `/large` by a
    /// cap that asked only about size, and `/large` is the camera's JPEG.
    @Test("a cover and a cell ask for no RAW decode; every view he judges a frame in does")
    func theFourBoxes() {
        func asksForFull(_ size: CGSize, scale: CGFloat = 2, _ showing: Showing) -> Bool {
            let px = ImagePump.fullPixels(forPoints: size, scale: scale)
            return ImagePump.ladder(toFullPixels: px, stopsAtLarge: showing.stopsAtLarge)
                .contains { if case .full = $0 { return true } else { return false } }
        }
        #expect(!asksForFull(Tokens.Metric.filmstripThumb, .aThumbnail))   // 90 × 60 → 180 px
        #expect(!asksForFull(Tokens.Metric.burstCover, .aThumbnail))       // 180 × 120 → 360 px
        #expect(!asksForFull(CGSize(width: 130, height: 87), .aThumbnail)) // a Review cell

        // The photograph he is looking at, at the sizes it is really drawn at.
        // 1068 × 526 is the stage in his own 1100 pt window.
        #expect(asksForFull(CGSize(width: 1068, height: 526), .aPhotograph))
        // The documented minimum window, 900 × 620: the fitted picture is
        // 537 × 358 pt under the control bar's caption lane = 1074 device px,
        // which rounds to the 1440 tier. A cap
        // that asked only about size stopped the stage here — and on every
        // window up to roughly 1010 × 730.
        let minimum = LightTableGeometry.measure(window: Tokens.Metric.minimumWindow)
        #expect(ImagePump.fullPixels(forPoints: minimum.photograph, scale: 2) == 1440)
        #expect(asksForFull(minimum.photograph, .aPhotograph))
        // And on a 1× display that cap took the decode away at every window
        // size there is: 1512 pt of picture still needs only 1512 px.
        #expect(asksForFull(CGSize(width: 1068, height: 526), scale: 1, .aPhotograph))
        #expect(asksForFull(CGSize(width: 1417, height: 945), scale: 1, .aPhotograph))
    }

    /// The four `FrameImageView`s in the app, by what each one is for. A new
    /// one that is neither a cover nor a viewer has to say which it is.
    @Test("what a box is for, not how big it is, decides whether it asks for a decode")
    func purposeNotSize() {
        // The same 1440 px box: a cover stops, a photograph climbs.
        #expect(ImagePump.ladder(toFullPixels: 1440, stopsAtLarge: true) == [.thumb, .large])
        #expect(ImagePump.ladder(toFullPixels: 1440, stopsAtLarge: false)
                == [.thumb, .large, .full(px: 1440)])
        #expect(Showing.aThumbnail.stopsAtLarge)
        #expect(!Showing.aPhotograph.stopsAtLarge)
    }
}
