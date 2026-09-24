import Foundation
import Testing
@testable import PipelineKit

/// The window arithmetic is the engine's, to the pixel (DESIGN.md §2.17,
/// §7.14): the vectors were computed with `instagram.window_of` and
/// `grid_ok`, and every cut in the fixtures was worked out by the engine's
/// own `rect` and `auto`.
@Suite("The Instagram window arithmetic is the engine's")
@MainActor
struct InstagramWindowTests {

    @Test("windowOf gives the engine's window for every vector", arguments: [
        (4000, 6000, 0.75, 0.5, 0.5, 1.0, PixelRect(0, 334, 4000, 5333)),
        (4000, 6000, 0.8, 0.5, 0.3, 0.8, PixelRect(400, 0, 3200, 4000)),
        (6000, 4000, 0.75, 0.9, 0.5, 1.0, PixelRect(3000, 0, 3000, 4000)),
        (6000, 4000, 0.8, 0.1, 0.1, 0.5, PixelRect(0, 0, 1600, 2000)),
        (4000, 4002, 0.75, 0.5, 0.5, 1.0, PixelRect(499, 0, 3002, 4002)),
        (1200, 800, 0.75, 0.25, 0.75, 0.33333, PixelRect(200, 467, 200, 267)),
        (5000, 5000, 0.8, 0.0, 1.0, 0.05, PixelRect(0, 4750, 200, 250)),
        (3000, 4500, 0.75, 0.61234, 0.38765, 0.72, PixelRect(757, 304, 2160, 2880)),
    ])
    func vectors(_ v: (Int, Int, Double, Double, Double, Double, PixelRect)) {
        let r = InstagramWindow.windowOf(w: v.0, h: v.1, want: v.2, cx: v.3, cy: v.4, scale: v.5)
        #expect(r == v.6)
    }

    @Test("a window through fromRect and back is the same window")
    func roundTrip() {
        for (w, h, want) in [(4000, 6000, 0.75), (6000, 4000, 0.8), (4000, 4002, 0.75), (3000, 4500, 0.8)] {
            for cx in stride(from: 0.0, through: 1.0, by: 0.125) {
                for scale in [0.12, 0.5, 0.85, 1.0] {
                    let r = InstagramWindow.windowOf(w: w, h: h, want: want, cx: cx, cy: 1 - cx, scale: scale)
                    let m = InstagramWindow.kept(InstagramWindow.fromRect(r, w: w, h: h, want: want))
                    let again = InstagramWindow.windowOf(PixelSize(w, h), want: want, m)
                    #expect(abs(again.x - r.x) <= 1 && abs(again.y - r.y) <= 1 && again.w == r.w && again.h == r.h)
                    #expect(again.x >= 0 && again.y >= 0 && again.x + again.w <= w && again.y + again.h <= h)
                }
            }
        }
    }

    @Test("a landscape left whole with its subject at the edge loses it in the grid; at the middle it does not")
    func gridVectors() {
        let size = PixelSize(6000, 4000)
        let whole = PixelRect(0, 0, 6000, 4000)
        let out = PixelSize(1080, 720)
        #expect(!InstagramWindow.gridOK(subject: InstagramSubject(cx: 0.9, cy: 0.5), frame: size, rect: whole, out: out))
        #expect(InstagramWindow.gridOK(subject: InstagramSubject(cx: 0.5, cy: 0.5), frame: size, rect: whole, out: out))
        // What the grid shows of a 3:2 post: its middle half.
        let strip = InstagramWindow.gridStrip(out: out)
        #expect(strip.map { abs($0.lowerBound - 0.25) < 1e-9 && abs($0.upperBound - 0.75) < 1e-9 } == true)
        #expect(InstagramWindow.gridStrip(out: PixelSize(1080, 1440)) == nil)
    }

    @Test("the out sizes are Instagram's")
    func outSizes() {
        #expect(InstagramWindow.outSize(want: 0.75) == PixelSize(1080, 1440))
        #expect(InstagramWindow.outSize(want: 0.8) == PixelSize(1080, 1350))
        #expect(InstagramWindow.want("4:5") == 0.8)
        #expect(InstagramWindow.other("3:4") == "4:5")
    }

    @Test("the automatic window and the whole cut are the engine's, for every frame of the wall")
    func autoAndWhole() throws {
        for name in ["instagram", "instagram-shape"] {
            let s = try Fixture.decode(InstagramStatus.self, name)
            let want = InstagramWindow.want(s.ratio)
            for f in s.frames {
                guard let size = f.frame, let subject = f.subject else { continue }
                #expect(InstagramWindow.auto(size, subject: subject, want: want) == f.auto, "\(f.stem) auto")
                #expect(InstagramWindow.whole(size, subject: subject).rect == f.whole?.rect, "\(f.stem) whole")
                #expect(InstagramWindow.whole(size, subject: subject).out == f.whole?.out, "\(f.stem) whole out")
            }
        }
    }

    @Test("a cut worked out by the app is the cut the engine describes, clear line and faint")
    func projection() throws {
        let m = try InstagramScaffold.model()
        for stem in m.order {
            guard let f = m.frames[stem], f.state == .planned else { continue }
            let g = m.project(f, InstagramModel.record(f))
            #expect(g.cut?.rect == f.cut?.rect, "\(stem) cut")
            #expect(g.cut?.out == f.cut?.out, "\(stem) out")
            #expect(g.cut?.grid_ok == f.cut?.grid_ok, "\(stem) grid")
            #expect(g.other?.rect == f.other?.rect, "\(stem) other")
            #expect(g.adjusted == f.adjusted, "\(stem) adjusted")
        }
    }

    @Test("the contract's worked examples")
    func workedExamples() {
        let portrait = PixelSize(4000, 6000)
        let man = InstagramManual(cx: 0.52, cy: 0.4, scale: 0.85)
        #expect(InstagramWindow.windowOf(portrait, want: 0.75, man) == PixelRect(380, 134, 3400, 4533))
        #expect(InstagramWindow.windowOf(portrait, want: 0.8, man) == PixelRect(380, 275, 3400, 4250))
        #expect(InstagramWindow.kept(PixelRect(380, 134, 3400, 4533), of: portrait) == 0.642)
        let landscape = PixelSize(6000, 4000)
        let s = InstagramSubject(cx: 0.3, cy: 0.5)
        #expect(InstagramWindow.auto(landscape, subject: s, want: 0.75) == PixelRect(300, 0, 3000, 4000))
        #expect(InstagramWindow.auto(landscape, subject: s, want: 0.8) == PixelRect(200, 0, 3200, 4000))
        #expect(InstagramWindow.auto(portrait, subject: InstagramSubject(cx: 0.48, cy: 0.31), want: 0.75)
                == PixelRect(0, 0, 4000, 5333))
    }
}
