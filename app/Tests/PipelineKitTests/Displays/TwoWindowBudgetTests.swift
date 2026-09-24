import Foundation
import CoreGraphics
import Testing
@testable import PipelineKit

/// What two windows cost, and the rule that keeps the far screen from getting
/// in front of the near one.
@Suite("Two windows, one budget")
struct TwoWindowBudgetTests {

    /// §4.5's table, for a 24 MP frame on a 48 GB Mac with the picture window
    /// filling a 5K.
    @Test("the ceiling with both windows open is about a gigabyte of pictures")
    func ceiling() {
        let bytesPerPixel = 4
        let thumbs = 96 << 20
        let stageRing = 2120 * 1414 * bytesPerPixel * 24
        // Three, not twenty-four: he does not arrow backwards through fifteen
        // frames at 4096, he moves forward, and the thumbnail and /large sizes
        // are still underneath for anything further.
        let pictureRing = 4096 * 2731 * bytesPerPixel * ByteTileBudget.automatic.secondaryDecodedCount
        let held = 4096 * 2731 * bytesPerPixel
        let tiles = ByteTileBudget.scaled(forPhysicalMemory: 48 << 30).tileBytes

        let total = thumbs + stageRing + pictureRing + held + tiles
        // ≤ 1.5 GB with the picture window filling a 5K, against ≤ 1.2 GB with
        // one window.
        #expect(total < 1_500 << 20)
        #expect(pictureRing < 140 << 20)
    }

    @Test("a count cannot tell two tile sizes apart, which is why the cap is bytes")
    func countsDoNotWork() {
        // Eight 4096 px tiles at 3:2 are 358 MB; eight whole-width tiles on the
        // external are 631 MB. One count, two very different numbers.
        let small = 8 * 4096 * 2731 * 4
        let big = 8 * 6000 * 3285 * 4
        #expect(small < 400 << 20)
        #expect(big > 600 << 20)
        #expect(Double(big) / Double(small) > 1.7)
    }

    @Test("memory pressure drops the far screen before the near one")
    func pressureOrder() {
        let normal = ByteTileBudget.scaled(forPhysicalMemory: 48 << 30)
        let pressed = normal.underPressure
        // The window he is pressing keys against is the last thing degraded.
        #expect(pressed.secondaryDecodedCount == 1)
        #expect(pressed.tileBytes < normal.tileBytes)
        // The foundation's own ring is what shrinks after that.
        let base = ImagePump.Budget.base
        #expect(base.underPressure.decodedCount <= 4)
        #expect(base.underPressure.decodedCount < base.decodedCount)
    }

    @Test("this side never has two cold requests of its own in the air at once")
    func oneColdRequest() async {
        let jpeg = makeJPEG(width: 400, height: 267)
        let counter = LoadCounter()
        let pump = ImagePump(budget: .base, loader: { route in
            // The cold requests are the RAW decodes. Each also reads its
            // frame's thumbnail, to draw it at the camera's brightness, and
            // that is neither cold nor gated.
            guard case .full = route else { return jpeg }
            await counter.enter()
            try? await Task.sleep(for: .milliseconds(30))
            await counter.leave()
            return jpeg
        })
        let prefetcher = await MainActor.run { PicturePrefetcher(pump: pump) }
        await MainActor.run {
            prefetcher.want(shoot: "s", stems: ["a", "b", "c", "d", "e"], pixels: 4096)
        }
        try? await Task.sleep(for: .milliseconds(200))
        // `DESIGN.md` §3.5's "at most 2 concurrent cold requests" becomes "at
        // most 2 in total, of which at most 1 may be the picture window's" —
        // otherwise a pair of 4096 px decodes on the far screen sits in front
        // of the one frame he is about to press a key on.
        let peak = await MainActor.run { prefetcher.peakInFlight }
        #expect(peak <= 1)
        #expect(await counter.peak <= ImagePump.coldFullLimit)
    }

    @Test("cancelling the far screen's prefetch does not touch the laptop's")
    func cancelIsOwnSideOnly() async {
        let jpeg = makeJPEG(width: 400, height: 267)
        let counter = LoadCounter()
        let pump = ImagePump(budget: .base, loader: { _ in
            await counter.enter()
            try? await Task.sleep(for: .milliseconds(40))
            await counter.leave()
            return jpeg
        })
        // The stage's own prefetch, which must survive the screen going away.
        await pump.prefetch([ImagePump.Key(shoot: "s", stem: "stage", tier: .large)],
                            priority: .utility)
        let prefetcher = await MainActor.run { PicturePrefetcher(pump: pump) }
        await MainActor.run {
            prefetcher.want(shoot: "s", stems: ["a", "b"], pixels: 4096)
            prefetcher.cancelAll()
        }
        try? await Task.sleep(for: .milliseconds(200))
        let report = await pump.report()
        #expect(report.cancelled == 0)
        // `cached` is nonisolated: reading the cache is not a hop.
        #expect(pump.cached(ImagePump.Key(shoot: "s", stem: "stage", tier: .large)) != nil)
    }

    @Test("two windows at two sizes are two entries; two windows at one size are one")
    func coalescing() async {
        let jpeg = makeJPEG(width: 400, height: 267)
        let counter = LoadCounter()
        let pump = ImagePump(budget: .base, loader: { route in
            // The decodes, not the thumbnail each one reads for its brightness.
            guard case .full = route else { return jpeg }
            await counter.enter()
            await counter.leave()
            return jpeg
        })
        let stage = ImagePump.Key(shoot: "s", stem: "a", tier: .full(px: 2600))
        let picture = ImagePump.Key(shoot: "s", stem: "a", tier: .full(px: 4096))
        _ = try? await pump.image(stage)
        _ = try? await pump.image(picture)
        _ = try? await pump.image(stage)
        // Two sizes, two fetches; the third asks for one already decoded.
        #expect(await counter.total == 2)
    }
}
