import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import PipelineKit

/// A frame as the camera's JPEG sees it, and the same frame as the engine's
/// RAW decode sees it: the same picture, every level pushed down the way a
/// decode with no brightening sits under the camera's own tone curve.
enum TwoRenderings {
    /// A ramp from black to white across the frame, with a little colour so
    /// the three channels are not one channel.
    static func camera(width: Int = 600, height: Int = 400) -> Data {
        render(width: width, height: height) { $0 }
    }

    /// The decode: every level taken down by a 1.8 power, which puts its
    /// average at about 0.6 of the camera's — what his 2026-09-19 night
    /// measured, 0.56–0.66.
    static func decode(width: Int = 1200, height: Int = 800) -> Data {
        render(width: width, height: height) { 255 * pow($0 / 255, 1.8) }
    }

    private static func render(width: Int, height: Int, _ tone: (Double) -> Double) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let base = Double(x) / Double(width - 1) * 255
                let o = y * ctx.bytesPerRow + x * 4
                p[o] = UInt8(min(255, max(0, tone(min(255, base * 1.0)).rounded())))
                p[o + 1] = UInt8(min(255, max(0, tone(base * 0.92).rounded())))
                p[o + 2] = UInt8(min(255, max(0, tone(base * 0.8).rounded())))
                p[o + 3] = 255
            }
        }
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// A pump that serves the camera's JPEG for the thumbnail and `/large`
    /// and the decode for `/full` and `/crop`, as the engine does. With a
    /// gate, the camera's JPEG waits for the test to open it.
    static func pump(thumbGate: Gate? = nil) -> ImagePump {
        let cam = camera(), dec = decode()
        return ImagePump(budget: .base, loader: { route in
            switch route {
            case .thumb, .large, .preview:
                await thumbGate?.pass()
                return cam
            default:
                return dec
            }
        })
    }

    /// Holds whoever passes until it is opened, and counts them.
    actor Gate {
        private var isOpen = false
        private var held: [CheckedContinuation<Void, Never>] = []
        private(set) var asked = 0

        func pass() async {
            asked += 1
            if isOpen { return }
            await withCheckedContinuation { held.append($0) }
        }

        func open() {
            isOpen = true
            for c in held { c.resume() }
            held = []
        }
    }

    /// Until `done` says so, without a fixed sleep that a loaded machine
    /// outruns. Ten seconds at most.
    static func until(_ done: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !(await done()) {
            try #require(ContinuousClock.now < end, "waited ten seconds")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func mean(_ data: Data) throws -> Double {
        try #require(DisplayTone.meanLevel(try Downsampler.decode(data, maxPixel: nil)))
    }
}

@Suite("the sharp picture at the camera's brightness")
struct DisplayToneTests {

    /// Decision 3: the full-size version stays at the camera's brightness, as
    /// the filmstrip is, instead of going about 40 % darker when it lands.
    @Test("a /full lands at the brightness of the thumbnail he was already looking at")
    func fullMatchesTheCamera() async throws {
        let pump = TwoRenderings.pump()
        let camera = try TwoRenderings.mean(TwoRenderings.camera())
        let decode = try TwoRenderings.mean(TwoRenderings.decode())
        // The premise: as the engine serves it, the decode is much darker.
        #expect(decode < camera * 0.75)

        let full = try await pump.image(.init(shoot: "s", stem: "f", tier: .full(px: 2048)))
        let shown = try #require(DisplayTone.meanLevel(full))
        #expect(abs(shown - camera) < 3, "shown \(shown) against the camera's \(camera)")
        // Still the decode's pixels, at the size asked for: only the levels moved.
        #expect(full.width == 1200 && full.height == 800)
        #expect(full.colorSpace?.name == CGColorSpace.sRGB)
        #expect(await pump.displayCurve(shoot: "s", stem: "f") != nil)
    }

    @Test("the camera's own JPEG tiers are drawn exactly as they come")
    func cameraTiersUntouched() async throws {
        let pump = TwoRenderings.pump()
        let camera = try TwoRenderings.mean(TwoRenderings.camera())
        for tier in [ImagePump.Tier.thumb, .large] {
            let img = try await pump.image(.init(shoot: "s", stem: "f", tier: tier))
            let m = try #require(DisplayTone.meanLevel(img))
            #expect(abs(m - camera) < 0.5)
        }
        // And asking for them measured nothing: only a sharp picture has a curve.
        #expect(await pump.displayCurve(shoot: "s", stem: "f") == nil)
    }

    /// Z at 1:1 is where he checks the eyes; the tile over the fitted picture
    /// has to be the same brightness as the picture under it.
    @Test("a 1:1 cut of the frame is drawn through that frame's curve")
    func cropFollowsTheFrame() async throws {
        let pump = TwoRenderings.pump()
        let camera = try TwoRenderings.mean(TwoRenderings.camera())
        // No /full asked for first: the cut asks for the smallest itself, so
        // the curve is the whole frame's, never one measured on a corner.
        let box = CropBox(cx: 0.5, cy: 0.5, px: 1200, ar: 0.66)
        let tile = try await pump.image(.init(shoot: "s", stem: "f", tier: .crop(box)))
        let m = try #require(DisplayTone.meanLevel(tile))
        #expect(abs(m - camera) < 3, "tile \(m) against the camera's \(camera)")
        let curve = try #require(await pump.displayCurve(shoot: "s", stem: "f"))

        // A second size of /full of the same frame is drawn through the same
        // curve, so no two tiers of one frame disagree about its brightness.
        _ = try await pump.image(.init(shoot: "s", stem: "f", tier: .full(px: 4096)))
        #expect(await pump.displayCurve(shoot: "s", stem: "f") == curve)
    }

    @Test("a /full already at the camera's brightness is left as it is")
    func alreadyRightIsLeftAlone() async throws {
        let jpeg = TwoRenderings.camera()
        let pump = ImagePump(budget: .base, loader: { _ in jpeg })
        let full = try await pump.image(.init(shoot: "s", stem: "f", tier: .full(px: 2048)))
        let curve = try #require(await pump.displayCurve(shoot: "s", stem: "f"))
        #expect(curve.leavesItAlone)
        let m = try #require(DisplayTone.meanLevel(full))
        #expect(abs(m - (try TwoRenderings.mean(jpeg))) < 0.5)
    }

    /// The picture is kept in the ring. Kept without its curve because the
    /// wait for the thumbnail was cancelled, it would come back dark from the
    /// cache the next time he arrived on the frame.
    @Test("a /full whose wait was cancelled is never kept dark")
    func cancelledIsNotKept() async throws {
        let gate = TwoRenderings.Gate()
        let pump = TwoRenderings.pump(thumbGate: gate)
        let key = ImagePump.Key(shoot: "s", stem: "f", tier: .full(px: 2048))
        await pump.prefetch([key], priority: .utility)
        // Cancelled while it waits for the thumbnail to measure against.
        try await TwoRenderings.until { await gate.asked > 0 }
        await pump.cancelPrefetch(keeping: [])
        await gate.open()
        try await TwoRenderings.until { await pump.report().inFlight == 0 }
        #expect(pump.cached(key) == nil)

        // Asked for again, it arrives at the camera's brightness.
        let full = try await pump.image(key)
        let m = try #require(DisplayTone.meanLevel(full))
        #expect(abs(m - (try TwoRenderings.mean(TwoRenderings.camera()))) < 3)
    }

    /// He leaves a burst, which lets its prefetches go, and comes straight
    /// back: the stage asks for the frame while the prefetch of it is still
    /// finding out it was cancelled.
    @Test("a request while a cancelled fetch of the same picture is still ending gets the picture, not the cancellation")
    func freshRequestDuringCancel() async throws {
        let gate = TwoRenderings.Gate()
        let pump = TwoRenderings.pump(thumbGate: gate)
        let key = ImagePump.Key(shoot: "s", stem: "f", tier: .full(px: 2048))
        await pump.prefetch([key], priority: .utility)
        try await TwoRenderings.until { await gate.asked > 0 }
        await pump.cancelPrefetch(keeping: [])
        #expect(await pump.report().fetched == 1)

        // Joined to the cancelled fetch, it would never fetch a /full of its
        // own, and would be handed the cancellation once the thumbnail came.
        async let asked = pump.image(key)
        // Opened on the way out whatever happens, so a failure here ends
        // rather than waiting on the thumbnail for ever.
        defer { Task { await gate.open() } }
        try await TwoRenderings.until { await pump.report().fetched == 2 }
        await gate.open()
        let full = try await asked
        let m = try #require(DisplayTone.meanLevel(full))
        #expect(abs(m - (try TwoRenderings.mean(TwoRenderings.camera()))) < 3)
        try await TwoRenderings.until { await pump.report().inFlight == 0 }
        #expect(pump.cached(key) != nil, "the fresh fetch's picture was not kept")
    }

    /// Counts the `/full` fetches of a pump whose thumbnails are all missing.
    actor FullCount {
        private(set) var n = 0
        func add() { n += 1 }
    }

    @Test("a frame whose thumbnail cannot be had is drawn as it comes, and its 1:1 tiles ask for nothing more")
    func noThumbnail() async throws {
        let dec = TwoRenderings.decode()
        let fulls = FullCount()
        let pump = ImagePump(budget: .base, loader: { route in
            switch route {
            case .thumb, .large, .preview: throw StudioError.http(status: 404, body: "")
            case .full: await fulls.add(); return dec
            default: return dec
            }
        })
        let full = try await pump.image(.init(shoot: "s", stem: "f", tier: .full(px: 2048)))
        let m = try #require(DisplayTone.meanLevel(full))
        #expect(abs(m - (try TwoRenderings.mean(dec))) < 1, "with nothing to measure against it is the decode as served")
        #expect(await pump.displayCurve(shoot: "s", stem: "f") == nil)
        for cx in [0.3, 0.5, 0.7] {
            let box = CropBox(cx: cx, cy: 0.5, px: 400, ar: 0.66)
            _ = try await pump.image(.init(shoot: "s", stem: "f", tier: .crop(box)))
        }
        #expect(await fulls.n == 1, "a 1:1 tile asked for a /full to measure with, which could only fail the same way")
    }

    @Test("the curve starts at black, ends at white and never turns one tone past another")
    func curveShape() throws {
        var dark = [Int](repeating: 0, count: 256), bright = [Int](repeating: 0, count: 256)
        for i in 0..<256 {
            dark[Int(255 * pow(Double(i) / 255, 1.8))] += 10
            bright[i] += 10
        }
        let c = try #require(DisplayTone.curve(matching: bright, from: dark))
        #expect(c(0) == 0 && c(255) == 255)
        for i in 1..<256 { #expect(c(i) >= c(i - 1)) }
        // It lifts: the decode's middle grey goes up towards the camera's.
        #expect(c(55) > 90)
        // The same distribution on both sides is the identity, to a level.
        let same = try #require(DisplayTone.curve(matching: bright, from: bright))
        #expect(same.leavesItAlone)
        // Nothing to measure is no curve at all, not a guess.
        #expect(DisplayTone.curve(matching: [Int](repeating: 0, count: 256), from: bright) == nil)
    }

    @Test("the curve keeps the picture in the colour space it came in")
    func keepsItsSpace() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let ctx = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: p3, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(colorSpace: p3, components: [0.2, 0.3, 0.4, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let image = try #require(ctx.makeImage())
        var lift = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { lift[i] = UInt8(min(255, i + 40)) }
        let out = try #require(DisplayTone.apply(DisplayTone.Curve(table: lift), to: image))
        #expect(out.colorSpace?.name == CGColorSpace.displayP3)
        #expect(out.width == 64 && out.height == 32)
        #expect(try #require(DisplayTone.meanLevel(out)) > (try #require(DisplayTone.meanLevel(image))) + 20)
    }

    @Test("a shoot let go takes its curves with it")
    func evictForgets() async throws {
        let pump = TwoRenderings.pump()
        _ = try await pump.image(.init(shoot: "s", stem: "f", tier: .full(px: 2048)))
        #expect(await pump.displayCurve(shoot: "s", stem: "f") != nil)
        await pump.evict(shoot: "s")
        #expect(await pump.displayCurve(shoot: "s", stem: "f") == nil)
    }
}
