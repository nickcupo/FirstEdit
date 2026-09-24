import Foundation
import AppKit
import SwiftUI
import Testing
@testable import PipelineKit

/// The whole light table, hosted offscreen, for what only the assembled step
/// can show: how many photographs are on it, and who has the keyboard.
///
/// The window is never ordered in: nothing here appears on a screen.
@Suite("One photograph at a time, and the keyboard on it", .serialized)
@MainActor
struct KeysStageTests {

    /// The step in a window that is never shown, laid out once.
    static func host(_ m: ViewerModel, size: CGSize = CGSize(width: 1100, height: 780))
        -> (NSWindow, NSHostingView<ChooseKeepersStep>) {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let h = NSHostingView(rootView: ChooseKeepersStep(model: m))
        h.frame = NSRect(origin: .zero, size: size)
        w.contentView = h
        spin(h, for: 0.2)
        return (w, h)
    }

    /// The run loop, turned by hand: SwiftUI applies what it observed there.
    static func spin(_ v: NSView, for seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            v.layoutSubtreeIfNeeded()
        }
    }

    static func stages(in v: NSView) -> [StageLayerView] {
        var out: [StageLayerView] = []
        func walk(_ v: NSView) {
            if let s = v as? StageLayerView, s.window != nil { out.append(s) }
            v.subviews.forEach(walk)
        }
        walk(v)
        return out
    }

    /// A loop in the view graph never gives the run loop back, so a test of
    /// one cannot fail — it hangs. This turns the hang into a failure with a
    /// sentence, the way the probe that found it had to.
    final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        init(_ seconds: TimeInterval, _ what: String) {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                if !lock.withLock({ done }) { fatalError("the light table never settled: \(what)") }
            }
        }
        func finish() { lock.withLock { done = true } }
    }

    static func inCharge(_ v: NSView) -> [StageLayerView] { stages(in: v).filter(\.inCharge) }

    @Test("Full Image has one stage in charge while the table's waits under it, it settles, it measures itself, and the keyboard is on the photograph both ways")
    func fullImageHasOneStageInCharge() throws {
        let m = try KeysTests.model()
        let (w, h) = Self.host(m)
        defer { w.close() }
        let table = try #require(Self.stages(in: h).first)
        #expect(Self.stages(in: h).count == 1, "the table has its photograph")
        #expect(table.inCharge)
        #expect(m.viewport == table.bounds.size)

        let into = Watchdog(20, "going into Full Image")
        m.setFullImage(true)
        Self.spin(h, for: 0.6)
        into.finish()
        let full = Self.inCharge(h)
        #expect(full.count == 1, "two stages in charge of one model write their own sizes in turn, for ever")
        #expect(full.first.map { $0 !== table } == true, "Full Image draws its own, over the whole window")
        #expect(Self.stages(in: h).contains { $0 === table },
                "the table's stage was taken down, so Full Image faded in over the bare background")
        #expect(full.first.map { m.viewport == $0.bounds.size } == true,
                "the zoom and the size asked for are Full Image's, not the table's")
        #expect(full.first.map { w.firstResponder === $0 } == true, "Full Image's stage has the keyboard")

        let out = Watchdog(20, "coming out of Full Image")
        m.setFullImage(false)
        Self.spin(h, for: 0.6)
        out.finish()
        let back = Self.inCharge(h)
        #expect(back.count == 1)
        #expect(back.first === table, "the table's own stage, with the picture it kept")
        #expect(m.viewport == table.bounds.size)
        #expect(w.firstResponder === table, "back on the table the arrows and Space work without a click")
        for s in Self.stages(in: h) { s.tearDown() }
    }

    /// A photograph that is one colour, so the middle of the window says
    /// whether a photograph is there at all.
    static func red() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 400, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 600, height: 400).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func middleIsThePhotograph(_ h: NSView) -> Bool {
        let spot = NSRect(x: h.bounds.midX - 2, y: h.bounds.midY - 2, width: 4, height: 4)
        guard let rep = h.bitmapImageRepForCachingDisplay(in: spot) else { return false }
        h.cacheDisplay(in: spot, to: rep)
        guard let c = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
        else { return false }
        return c.redComponent > 0.7 && c.greenComponent < 0.35 && c.blueComponent < 0.35
    }

    @Test("into Full Image and back out, the middle of the window is the photograph the whole way, never the bare background")
    func fullImageNeverDips() async throws {
        let png = Self.red()
        KeysEngine.reset()
        let session = ShootSession(response: try ViewerTests.response(), ext: nil, client: KeysEngine.client(),
                                   pump: ImagePump(budget: .base, loader: { _ in png }),
                                   queue: VerdictQueue(sender: { _ in .success(RatingResult(ok: true, key_note: "")) }))
        let m = ViewerModel(session: session, navigation: Navigation())
        let (w, h) = Self.host(m)
        defer { w.close() }
        for _ in 0..<100 where !Self.middleIsThePhotograph(h) {
            Self.spin(h, for: 0.02)
            await Task.yield()
        }
        try #require(Self.middleIsThePhotograph(h), "the photograph never arrived")

        m.setFullImage(true)
        for i in 0..<15 {
            Self.spin(h, for: 0.02)
            #expect(Self.middleIsThePhotograph(h), "no photograph \(i * 20) ms into Full Image")
        }
        m.setFullImage(false)
        for i in 0..<25 {
            Self.spin(h, for: 0.01)
            #expect(Self.middleIsThePhotograph(h), "no photograph \(i * 10) ms out of Full Image")
        }
        for s in Self.stages(in: h) { s.tearDown() }
    }
}
