import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// §2.5.9: the marks on a thumbnail say what is true of the frame.
@Suite("The marks on a filmstrip thumbnail", .serialized)
@MainActor
struct FilmstripMarksTests {

    /// Every thumbnail the strip has drawn, with its frame's row.
    static func thumbs(_ m: ViewerModel) throws -> (NSWindow, [(FilmstripItemView, Row)]) {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1100, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 200))
        w.contentView = root
        let strip = FilmstripView(model: m)
        strip.frame = NSRect(x: 0, y: 0, width: 1100, height: Tokens.Metric.filmstrip)
        root.addSubview(strip)
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            root.layoutSubtreeIfNeeded()
            strip.refresh()
        }
        let scroll = try #require(strip.subviews.compactMap { $0 as? NSScrollView }.first)
        let collection = try #require(scroll.documentView as? NSCollectionView)
        var out: [(FilmstripItemView, Row)] = []
        for (i, stem) in m.frames.enumerated() {
            guard let item = collection.item(at: IndexPath(item: i, section: 0)) as? FilmstripItem,
                  let row = m.session.rows[stem] else { continue }
            out.append((item.thumb, row))
        }
        return (w, out)
    }

    /// After N every frame he left alone carried the same green check, the
    /// ones the cull set aside included, so a finished burst looked as if he
    /// had kept all of it.
    @Test("in a burst he has been through, a frame he left alone shows the cull's call standing, kept or out")
    func agreedFollowsTheCull() throws {
        let m = try ViewerTests.modelAllSeen()
        // A burst with both calls in it.
        let i = try #require(m.bursts.firstIndex { b in
            let ratings = b.frames.compactMap { m.session.rows[$0]?.rating }
            return ratings.contains { $0 >= VerdictValue.inThreshold }
                && ratings.contains { $0 < VerdictValue.inThreshold }
        })
        m.goToBurst(i)
        let (w, thumbs) = try Self.thumbs(m)
        defer { w.close() }
        #expect(!thumbs.isEmpty)
        var sawKeep = false, sawOut = false
        for (thumb, row) in thumbs where VerdictValue.his(row) == .unmarked {
            #expect(thumb.marks.agreed)
            let keep = FilmstripItemView.agreedIsKeep(thumb.marks)
            #expect(keep == (row.rating >= VerdictValue.inThreshold))
            if keep { sawKeep = true } else { sawOut = true }
        }
        #expect(sawKeep && sawOut)
    }

    @Test("in a burst he has not been through, nothing is marked as agreed")
    func notSeenIsNotAgreed() throws {
        let m = try ViewerTests.model()
        #expect(!(m.currentBurst?.seen ?? true))
        let (w, thumbs) = try Self.thumbs(m)
        defer { w.close() }
        #expect(thumbs.allSatisfy { !$0.0.marks.agreed })
    }

    /// The numbers he copies into PhotoLab were 10 pt tertiary grey: 1.8:1 on
    /// the light bar, 1.6:1 on the dark one.
    @Test("the frame numbers are 11 pt and at least 4.5:1 on the bar, light and dark")
    func captionsAreReadable() throws {
        #expect(FilmstripItemView.captionFont(current: false).pointSize >= 11)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var ratio = 0.0
            appearance.performAsCurrentDrawingAppearance {
                let bar = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
                let ink = FilmstripItemView.captionColour(increaseContrast: false).usingColorSpace(.sRGB)!
                ratio = Self.contrast(Self.over(ink, bar), bar)
            }
            #expect(ratio >= 4.5, "\(name.rawValue): \(ratio):1")
        }
    }

    /// `top` at its alpha over an opaque `bottom`.
    static func over(_ top: NSColor, _ bottom: NSColor) -> NSColor {
        let a = top.alphaComponent
        func mix(_ t: CGFloat, _ b: CGFloat) -> CGFloat { t * a + b * (1 - a) }
        return NSColor(srgbRed: mix(top.redComponent, bottom.redComponent),
                       green: mix(top.greenComponent, bottom.greenComponent),
                       blue: mix(top.blueComponent, bottom.blueComponent), alpha: 1)
    }

    /// WCAG contrast between two opaque sRGB colours.
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func lum(_ c: NSColor) -> Double {
            func lin(_ v: CGFloat) -> Double {
                let v = Double(v)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        }
        let (l1, l2) = (lum(a), lum(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// A portrait burst was a row of 40 pt pictures in grey 90 pt boxes: the
    /// placeholder grey filled the whole cell under every frame, loaded or not.
    @Test("a portrait frame shows the strip's own surface either side, and the grey only while it loads")
    func portraitHasNoGreyBox() throws {
        let view = FilmstripItemView(frame: NSRect(x: 0, y: 0, width: 90, height: FilmstripItemView.itemHeight))
        view.appearance = NSAppearance(named: .aqua)
        func alpha(atX x: Int) throws -> CGFloat {
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            // The middle of the picture's height, in the cell.
            let y = Int((FilmstripItemView.bracket + FilmstripItemView.thumb.height / 2) * scale)
            return rep.colorAt(x: Int(CGFloat(x) * scale), y: y)?.alphaComponent ?? -1
        }
        #expect(try alpha(atX: 5) > 0, "a frame still on its way is a grey box")

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(data: nil, width: 20, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        view.image = ctx.makeImage()
        #expect(try alpha(atX: 5) == 0, "beside a portrait picture is the strip's surface, not grey")
        #expect(try alpha(atX: 45) == 1, "the picture itself")
    }

    /// Every visible thumbnail was drawn again on every press — picture,
    /// symbols and number — when a press changes two of them: the one he
    /// left and the one he arrived on. The strip hands every thumbnail its
    /// marks and picture on every press; the thumbnail asks to be drawn only
    /// when they are different.
    @Test("a press draws again only the thumbnails it changed")
    func onlyWhatChangedIsDrawn() throws {
        let m = try ViewerTests.model()
        #expect(m.frames.count >= 4)
        let (w, thumbs) = try Self.thumbs(m)
        defer { w.close() }
        let strip = try #require(w.contentView?.subviews.compactMap { $0 as? FilmstripView }.first)
        #expect(m.frameIndex == 0)
        func asked() -> [Int] { thumbs.map(\.0.redrawsAsked) }

        var before = asked()
        strip.refresh()
        #expect(asked() == before, "nothing changed, nothing is drawn")

        before = asked()
        m.goToFrame(1)
        strip.refresh()
        let drawn = thumbs.indices.filter { asked()[$0] != before[$0] }
        #expect(drawn == [0, 1], "the frame he left and the one he is on")
    }
}
