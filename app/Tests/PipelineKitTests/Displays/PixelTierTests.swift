import Foundation
import CoreGraphics
import Testing
@testable import PipelineKit

/// DESIGN-displays.md §4.1's table, row by row, and §4.6's three branches.
@Suite("The size each window asks for")
struct PixelTierTests {

    @Test("the picture window filling his 5K at 2× asks for 4096 and is drawn 1.4 % large")
    func fillingTheExternal() {
        // 2528 × 1384 pt of window, a 3:2 frame fitted: 2076 pt wide.
        let box = DisplayMetric.pictureBox(in: CGRect(x: 0, y: 0, width: 2560, height: 1416))
        let picture = DisplayMetric.fitted(3.0 / 2.0, in: box)
        #expect(Int(picture.width.rounded()) == 2076)
        #expect(Int(picture.height.rounded()) == 1384)
        #expect(PixelTier.px(forPointWidth: picture.width, scale: 2) == 4096)
        // 4152 wanted, 4096 asked for: 1.4 % over, invisible on a fitted view,
        // and 1:1 does not come through here at all.
        let over = 2076.0 * 2 / 4096.0
        #expect(over > 1.01 && over < 1.015)
    }

    @Test("true full screen on the same panel is 2112 × 1408 pt")
    func trueFullScreen() {
        let box = DisplayMetric.pictureBox(in: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let picture = DisplayMetric.fitted(3.0 / 2.0, in: box)
        #expect(Int(picture.width.rounded()) == 2112)
        #expect(Int(picture.height.rounded()) == 1408)
    }

    @Test("a portrait burst gets a third of the panel, and there is no trick that fixes it")
    func portrait() {
        let box = DisplayMetric.pictureBox(in: CGRect(x: 0, y: 0, width: 2560, height: 1416))
        let picture = DisplayMetric.fitted(2.0 / 3.0, in: box)
        #expect(Int(picture.width.rounded()) == 923)
        #expect(Int(picture.height.rounded()) == 1384)
        let share = (picture.width * picture.height) / (2560 * 1440)
        #expect(share > 0.34 && share < 0.35)
    }

    @Test("§4.1's table, row by row")
    func theTable() {
        // Picture window on the same panel driven at 1×.
        #expect(PixelTier.px(forPointWidth: 2076, scale: 1) == 2600)
        // The laptop's stage at 14" full screen.
        #expect(PixelTier.px(forPointWidth: 1060, scale: 2) == 2600)
        // The laptop's stage in the default 1100 × 780 window.
        #expect(PixelTier.px(forPointWidth: 813, scale: 2) == 2048)
        // A Compare tile, four up on the 5K.
        #expect(PixelTier.px(forPointWidth: 1032, scale: 2) == 2600)
        // The Whole Burst's cells.
        #expect(PixelTier.cellTier(forPointWidth: 240, scale: 2) == .large)
        #expect(PixelTier.cellTier(forPointWidth: 220, scale: 2) == .thumb)
    }

    @Test("a window straddling two screens uses the window's scale, not the screen's")
    func straddling() {
        // The window is composited at the higher scale for its whole surface.
        // Reading the 1× screen would ask for less than half the pixels for
        // exactly the case — a window being dragged between his two displays —
        // where the wrong answer is visible.
        let windowScale: CGFloat = 2
        let theOtherScreensScale: CGFloat = 1
        #expect(PixelTier.px(forPointWidth: 1600, scale: windowScale) == 3200)
        #expect(PixelTier.px(forPointWidth: 1600, scale: theOtherScreensScale) == 2048)
    }

    @Test("it always rounds up, and never past the top of the ladder")
    func ladder() {
        #expect(PixelTier.px(forPointWidth: 1, scale: 1) == 1440)
        #expect(PixelTier.px(forPointWidth: 1440, scale: 1) == 1440)
        #expect(PixelTier.px(forPointWidth: 1441, scale: 1) == 2048)
        #expect(PixelTier.px(forPointWidth: 9000, scale: 2) == 4096)
        #expect(PixelTier.ladder == [1440, 2048, 2600, 3200, 4096])
    }

    // MARK: - 1:1 (§4.6)

    /// The a6500's frames.
    static let native = CGSize(width: 6000, height: 4000)
    /// The viewer box at 1:1 on the 5K, in device pixels.
    static let bigViewport = CGSize(width: 5056, height: 2768)
    /// The laptop's own box at 14" full screen.
    static let laptopViewport = CGSize(width: 2992, height: 1418)

    static func budget(gigabytes: UInt64) -> ByteTileBudget {
        .scaled(forPhysicalMemory: gigabytes << 30)
    }

    @Test("on a 48 GB Mac, 1:1 on the external becomes one whole-frame request")
    func wholeFrameAt48() {
        let r = PixelTier.request(viewportDevice: Self.bigViewport, frameNative: Self.native,
                                  aim: CGPoint(x: 0.5, y: 0.4),
                                  budget: Self.budget(gigabytes: 48), clamp: ServerCropClamp.sixK)
        #expect(r == .wholeFrame(px: 6000))
    }

    @Test("on a 16 GB Mac it is still one whole-frame request — three of them fit")
    func wholeFrameAt16() {
        let r = PixelTier.request(viewportDevice: Self.bigViewport, frameNative: Self.native,
                                  aim: CGPoint(x: 0.5, y: 0.5),
                                  budget: Self.budget(gigabytes: 16), clamp: ServerCropClamp.sixK)
        #expect(r == .wholeFrame(px: 6000))
        #expect(Self.budget(gigabytes: 16).tileBytes == 256 << 20)
    }

    @Test("on an 8 GB Mac the tile stays at 4096 and the picture is drawn true size, centred")
    func trueSizeAt8() {
        let r = PixelTier.request(viewportDevice: Self.bigViewport, frameNative: Self.native,
                                  aim: CGPoint(x: 0.5, y: 0.5),
                                  budget: Self.budget(gigabytes: 8), clamp: ServerCropClamp.sixK)
        // He sees less of the frame, not a softer frame: 1:1 exists to answer
        // one question and a 0.81 : 1 picture answers it wrong.
        #expect(r == .trueSizeCentred(px: 4096))
        #expect(r.isTruePixels)
    }

    @Test("the laptop's own tile at 14-inch full screen is over 4096 and needs the 6144 clamp")
    func laptopTileNeedsSixK() {
        let aspect = Double(Self.laptopViewport.height / Self.laptopViewport.width)
        let r = PixelTier.request(viewportDevice: Self.laptopViewport, frameNative: Self.native,
                                  aim: CGPoint(x: 0.5, y: 0.5),
                                  budget: Self.budget(gigabytes: 48), clamp: ServerCropClamp.sixK)
        // 2992 device pixels of viewport at 1.6× is 4788 — over 4096 on the
        // laptop alone, before the external is plugged in at all.
        #expect(r == .crop(cx: 0.5, cy: 0.5, px: 4788, ar: aspect))
        #expect(r.pixels > ServerCropClamp.fourK.maximumCropPixels)

        // At the clamp this checkout's engine has, the same request is cut back
        // to one that only just covers the viewport: still one source pixel per
        // device pixel, with none of the margin that makes a pan free.
        let clamped = PixelTier.request(viewportDevice: Self.laptopViewport, frameNative: Self.native,
                                        aim: CGPoint(x: 0.5, y: 0.5),
                                        budget: Self.budget(gigabytes: 48),
                                        clamp: ServerCropClamp.asShipped)
        #expect(clamped == .crop(cx: 0.5, cy: 0.5,
                                 px: TileFetcher.maximumTilePixels, ar: aspect))
        #expect(Double(clamped.pixels) >= Double(Self.laptopViewport.width))
    }

    @Test("1:1 never asks for something that would be drawn scaled")
    func neverScaled() {
        for width in stride(from: 800.0, through: 6000.0, by: 137.0) {
            for gb: UInt64 in [8, 16, 48] {
                let viewport = CGSize(width: width, height: width * 0.55)
                let r = PixelTier.request(viewportDevice: viewport, frameNative: Self.native,
                                          aim: CGPoint(x: 0.5, y: 0.5),
                                          budget: Self.budget(gigabytes: gb),
                                          clamp: ServerCropClamp.sixK)
                switch r {
                case .crop(_, _, let px, _):
                    // A crop wide enough to cover the viewport, so every source
                    // pixel lands on one device pixel.
                    #expect(Double(px) >= Double(viewport.width))
                case .wholeFrame(let px):
                    #expect(px == 6000)
                case .trueSizeCentred(let px):
                    // Narrower than the viewport, and drawn at true size.
                    #expect(Double(px) < Double(viewport.width))
                }
            }
        }
    }

    @Test("the byte budget is clamped at both ends")
    func budgetClamps() {
        #expect(Self.budget(gigabytes: 4).tileBytes == 96 << 20)
        #expect(Self.budget(gigabytes: 192).tileBytes == 512 << 20)
        #expect(ByteTileBudget.automatic.secondaryDecodedCount == 3)
        #expect(ByteTileBudget.automatic.underPressure.secondaryDecodedCount == 1)
    }
}
