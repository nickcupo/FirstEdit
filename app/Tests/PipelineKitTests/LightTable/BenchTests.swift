import Foundation
import AppKit
import Testing
import CoreGraphics
@testable import PipelineKit

/// The three budgets §5.1 puts on this crew, measured rather than asserted by
/// eye. They are here and not in `tools/bench.swift` because they need the
/// library and a window, and because a budget that only a person can run is a
/// budget that stops being true.
///
/// Frame to frame is the one that decides whether the app feels like anything
/// at all: at 300 presses an hour a 60 ms swap is a different instrument from a
/// 6 ms one.
@Suite("The light table's budgets", .serialized)
@MainActor
struct BenchTests {

    /// A decoded picture of the size the pump would hand the stage.
    static func picture(_ w: Int = 1200, _ h: Int = 800) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// The same picture as JPEG bytes, which is what the engine serves and
    /// what the pump decodes.
    static func jpeg(_ w: Int = 1200, _ h: Int = 800) -> Data {
        let rep = NSBitmapImageRep(cgImage: picture(w, h))
        return rep.representation(using: .jpeg, properties: [:]) ?? Data()
    }

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))]
    }

    @Test("frame to frame from cache is under 16 ms at p95")
    func frameToFrame() async throws {
        let bytes = Self.jpeg()
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"))
        let pump = ImagePump(budget: .base, loader: { _ in bytes })
        let session = ShootSession(response: try ViewerTests.response(), ext: nil,
                                   client: client, pump: pump,
                                   queue: VerdictQueue(sender: { _ in .success(RatingResult(ok: true, key_note: "")) }))
        let m = ViewerModel(session: session, navigation: Navigation())
        m.goToBurst(0)

        // Everything the burst needs is already decoded: this budget is about
        // the swap, not the fetch. The pump asked for all of it before he got
        // here, which is the whole point of §3.5.
        for stem in m.frames {
            for tier in [ImagePump.Tier.thumb, .large] {
                _ = try? await pump.image(.init(shoot: session.name, stem: stem, tier: tier))
            }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1084, height: 542),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = StageLayerView(model: m)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        view.frame = NSRect(x: 0, y: 0, width: 1084, height: 542)
        view.refresh()
        window.layoutIfNeeded()

        var samples: [Double] = []
        let clock = ContinuousClock()
        // Back and forth across the burst, the way an arrow key run goes.
        for i in 0..<200 {
            let next = i % 2 == 0 ? min(m.frameIndex + 1, m.frames.count - 1) : max(0, m.frameIndex - 1)
            // The whole move: the cursor, the best cached tier onto the layer,
            // the layout, and the window actually drawing it.
            let took = clock.measure {
                m.goToFrame(next)
                view.refresh()
                view.layoutSubtreeIfNeeded()
                view.needsDisplay = true
                window.displayIfNeeded()
            }
            samples.append(Double(took.components.attoseconds) / 1e15)   // ms
        }
        let p95 = Self.percentile(samples, 0.95)
        let p50 = Self.percentile(samples, 0.5)
        window.orderOut(nil)
        view.tearDown()
        print(String(format: "frame to frame from cache: p50 %.2f ms, p95 %.2f ms (budget 16 ms)", p50, p95))
        #expect(p95 <= 16, "frame to frame p50 \(p50) ms, p95 \(p95) ms — the budget is 16 ms")
    }

    @Test("a held K writes exactly one verdict, however long it is held")
    func heldKey() async throws {
        let log = WriteLog()
        let m = try ViewerTests.model(log: log)
        ViewerTests.show(m)
        // Two seconds of macOS key repeat is roughly 30 events after the first.
        _ = m.key(KeyMap.Press("k"))
        for _ in 0..<60 { _ = m.key(KeyMap.Press("k", isARepeat: true)) }
        for _ in 0..<60 { try? await Task.sleep(for: .milliseconds(2)); await Task.yield() }
        #expect(await log.writes.count == 1)
        #expect(m.verdictsWritten == 1)
    }

    @Test("200 arrow repeats write nothing at all")
    func arrowRepeats() async throws {
        let log = WriteLog()
        let m = try ViewerTests.model(log: log)
        ViewerTests.show(m)
        for _ in 0..<200 { _ = m.key(KeyMap.Press(key: .right, isARepeat: true)) }
        for _ in 0..<200 { _ = m.key(KeyMap.Press(key: .left, isARepeat: true)) }
        for _ in 0..<60 { try? await Task.sleep(for: .milliseconds(2)); await Task.yield() }
        #expect(await log.writes.isEmpty)
        #expect(m.verdictsWritten == 0)
    }

    @Test("the prefetch ladder asks for the next burst before he gets to it")
    func nextBurstIsAsked() async throws {
        let asked = AskLog()
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"))
        let pump = ImagePump(budget: .base, loader: { route in
            await asked.add(route.path)
            return Data()
        })
        let session = ShootSession(response: try ViewerTests.response(), ext: nil,
                                   client: client, pump: pump,
                                   queue: VerdictQueue(sender: { _ in .success(RatingResult(ok: true, key_note: "")) }))
        let m = ViewerModel(session: session, navigation: Navigation())
        m.viewport = CGSize(width: 1084, height: 542)
        m.goToBurst(0)
        // Three frames from the end of the burst, the first frame of the next
        // one is already being fetched — the single biggest wait today
        // (PERF-01: about 1.8 minutes per 155-burst session).
        let next = try #require(session.bursts.count > 1 ? session.bursts[1].frames.first : nil)
        m.goToFrame(max(0, m.frames.count - 1))
        for _ in 0..<50 { try? await Task.sleep(for: .milliseconds(4)); await Task.yield() }
        #expect(await asked.paths.contains { $0.contains(next) },
                "the first frame of burst 2 was never asked for")
    }
}

/// Records the image routes the pump actually goes and gets.
actor AskLog {
    private(set) var paths: [String] = []
    func add(_ p: String) { paths.append(p) }
}
