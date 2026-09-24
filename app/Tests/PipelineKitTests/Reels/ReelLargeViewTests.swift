import AppKit
import Foundation
import Testing
@testable import PipelineKit

/// Space on a reel tile (DESIGN.md §2.6). The tile shows the JPEG he exported
/// and the reel is cut from exports; the large view showed the camera's JPEG
/// and then the unedited RAW, so he was judging a different picture from the
/// one that goes in the video. It now asks `/reelthumb` for the same picture
/// at its own size.
@Suite("The reel's large view")
struct ReelLargeViewTests {

    @Test("a tile asks for 400 px as it always did; a large view names its size")
    func theRoute() {
        #expect(ImageRoute.reelThumb(shoot: "s", stem: "TSC1", src: nil).query.isEmpty)
        #expect(ImageRoute.reelThumb(shoot: "s", stem: "TSC1", src: "/x", px: 1600).query
                == ["src": "/x", "px": "1600"])
        #expect(ImageRoute.reelThumb(shoot: "s", stem: "TSC1", src: nil, px: 1600).path
                == "/reelthumb/s/TSC1.jpg")
    }

    @Test("the size asked for fills the view, in steps of 400, and stops where the engine does")
    @MainActor func theSize() {
        #expect(ReelThumbs.pixels(for: CGSize(width: 100, height: 80), scale: 2) == 400)
        #expect(ReelThumbs.pixels(for: CGSize(width: 900, height: 600), scale: 2) == 2000)
        #expect(ReelThumbs.pixels(for: CGSize(width: 901, height: 600), scale: 1) == 1200)
        #expect(ReelThumbs.pixels(for: CGSize(width: 1800, height: 1200), scale: 2) == 2400)
    }

    @Test("the large picture is asked for at its size and kept apart from the tile's")
    @MainActor func keptApart() async {
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .representation(using: .png, properties: [:])!
        let asked = ReelRoutesAsked()
        let t = ReelThumbs(load: { route in await asked.add(route); return png })
        _ = await t.image(shoot: "s", stem: "TSC1", src: nil)
        #expect(t.cached(shoot: "s", stem: "TSC1", src: nil, px: 1600) == nil)
        _ = await t.image(shoot: "s", stem: "TSC1", src: nil, px: 1600)
        #expect(t.cached(shoot: "s", stem: "TSC1", src: nil, px: 1600) != nil)
        #expect(t.cached(shoot: "s", stem: "TSC1", src: nil) != nil)
        let routes = await asked.routes
        #expect(routes == [.reelThumb(shoot: "s", stem: "TSC1", src: nil),
                           .reelThumb(shoot: "s", stem: "TSC1", src: nil, px: 1600)])
    }
}

extension ReelLargeViewTests {
    /// Arrowing through a burst in the large view flashed empty on every frame
    /// while the large picture was made from the full-size export.
    @Test("until the large picture is made, the large view shows the tile's")
    @MainActor func tileFirst() async {
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .representation(using: .png, properties: [:])!
        let t = ReelThumbs(load: { _ in png })
        #expect(t.showing(shoot: "s", stem: "TSC1", src: nil, px: 1600) == nil)
        let tile = await t.image(shoot: "s", stem: "TSC1", src: nil)
        #expect(tile != nil)
        #expect(t.showing(shoot: "s", stem: "TSC1", src: nil, px: 1600) === tile)
        let large = await t.image(shoot: "s", stem: "TSC1", src: nil, px: 1600)
        #expect(t.showing(shoot: "s", stem: "TSC1", src: nil, px: 1600) === large)
        // Another version (exported since) is another picture: the old tile is not it.
        #expect(t.showing(shoot: "s", stem: "TSC1", src: nil, version: "exported", px: 1600) == nil)
    }
}

actor ReelRoutesAsked {
    var routes: [ImageRoute] = []
    func add(_ r: ImageRoute) { routes.append(r) }
}
