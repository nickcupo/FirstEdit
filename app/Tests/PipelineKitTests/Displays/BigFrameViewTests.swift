import Foundation
import AppKit
import CoreGraphics
import Testing
@testable import PipelineKit

/// The layer that actually draws the photograph on the far screen.
@Suite("The big frame's own layer", .serialized)
@MainActor
struct BigFrameViewTests {

    static func host(_ view: NSView, size: NSSize = NSSize(width: 1200, height: 800)) -> NSWindow {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        w.contentView = view
        w.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        w.orderBack(nil)
        return w
    }

    /// Suspends this task rather than blocking the main queue, so the view's
    /// own fetch gets the main actor back.
    static func settle(_ seconds: Double = 0.5) async {
        for _ in 0..<max(1, Int(seconds / 0.05)) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("a frame arrives and lands on the layer")
    func draws() async {
        let jpeg = makeJPEG(width: 1200, height: 800)
        let pump = ImagePump(budget: .base, loader: { _ in jpeg })
        let view = BigFrameView(frame: .zero)
        view.pump = pump
        let window = Self.host(view)
        defer { view.tearDown(); window.close() }

        view.show(shoot: "s", stem: "TSC04330")
        await Self.settle()

        #expect(view.stem == "TSC04330")
        let visible = (view.layer?.sublayers ?? []).first { $0.opacity > 0.5 }
        #expect(visible?.contents != nil)
    }

    @Test("what lands on the layer is tagged sRGB")
    func tagged() async {
        let jpeg = makeJPEG(width: 800, height: 533)
        let pump = ImagePump(budget: .base, loader: { _ in jpeg })
        let view = BigFrameView(frame: .zero)
        view.pump = pump
        let window = Self.host(view)
        defer { view.tearDown(); window.close() }

        view.show(shoot: "s", stem: "a")
        await Self.settle(0.4)

        let drawn = (view.layer?.sublayers ?? []).compactMap { $0.contents as! CGImage? }
        #expect(!drawn.isEmpty)
        for image in drawn {
            #expect(image.colorSpace?.name == CGColorSpace.sRGB)
        }
    }

    @Test("changing the frame never leaves the window blank")
    func neverBlank() async {
        let jpeg = makeJPEG(width: 600, height: 400)
        let pump = ImagePump(budget: .base, loader: { _ in
            try? await Task.sleep(for: .milliseconds(80))
            return jpeg
        })
        let view = BigFrameView(frame: .zero)
        view.pump = pump
        let window = Self.host(view)
        defer { view.tearDown(); window.close() }

        view.show(shoot: "s", stem: "a")
        await Self.settle(0.4)
        func visibleContents() -> CGImage? {
            (view.layer?.sublayers ?? []).first { $0.opacity > 0.5 }?.contents as! CGImage?
        }
        #expect(visibleContents() != nil)

        // The next frame, while its own picture is still being fetched: what is
        // already there keeps drawing.
        view.show(shoot: "s", stem: "b")
        #expect(visibleContents() != nil)
        await Self.settle(0.4)
        #expect(visibleContents() != nil)
    }

    @Test("the size it asks for comes from its own box and its own window")
    func asksForItsOwnSize() {
        let view = BigFrameView(frame: .zero)
        let window = Self.host(view, size: NSSize(width: 2560, height: 1416))
        defer { view.tearDown(); window.close() }
        view.layoutSubtreeIfNeeded()

        // AppKit constrains a window to a screen that actually exists, so the
        // assertion is against the box the view really has — and the point is
        // that the number comes from the **window's** scale, not the screen's.
        let scale = window.backingScaleFactor
        #expect(view.pictureBox.width == view.bounds.width - 2 * DisplayMetric.pictureInset)
        #expect(view.neededPixels() == PixelTier.px(forPointWidth: view.pictureBox.width, scale: scale))
        #expect(scale == view.window?.backingScaleFactor)
    }

    @Test("a covered or sleeping window stops drawing and picks straight back up")
    func drawingStops() async {
        let jpeg = makeJPEG(width: 600, height: 400)
        let pump = ImagePump(budget: .base, loader: { _ in jpeg })
        let view = BigFrameView(frame: .zero)
        view.pump = pump
        let window = Self.host(view)
        defer { view.tearDown(); window.close() }

        view.show(shoot: "s", stem: "a")
        await Self.settle(0.3)
        view.setDrawing(false)
        await Self.settle(0.1)
        // What was on screen stays on screen; it simply stops asking for more.
        let still = (view.layer?.sublayers ?? []).first { $0.opacity > 0.5 }?.contents
        #expect(still != nil)
        view.setDrawing(true)
        await Self.settle(0.2)
        #expect((view.layer?.sublayers ?? []).first { $0.opacity > 0.5 }?.contents != nil)
    }
}

@Suite("The second screen's own arithmetic")
struct DisplayMetricTests {

    @Test("his badge lands in the surround beside the photograph, never on it")
    func badge() {
        let bounds = CGRect(x: 0, y: 0, width: 2560, height: 1416)
        let box = DisplayMetric.pictureBox(in: bounds)
        let picture = DisplayMetric.fitted(3.0 / 2.0, in: box)
        let origin = DisplayMetric.badgeOrigin(picture: picture, in: bounds)
        let badge = CGRect(origin: origin, size: CGSize(width: DisplayMetric.badge,
                                                        height: DisplayMetric.badge))
        #expect(!badge.intersects(picture))
        // 28 pt in from the photograph's edge.
        #expect(picture.minX - badge.maxX == DisplayMetric.badgeInset)
        #expect(badge.maxY == picture.maxY)

        // A portrait frame leaves an even wider band, and the rule is the same.
        let portrait = DisplayMetric.fitted(2.0 / 3.0, in: box)
        let there = CGRect(origin: DisplayMetric.badgeOrigin(picture: portrait, in: bounds),
                           size: CGSize(width: DisplayMetric.badge, height: DisplayMetric.badge))
        #expect(!there.intersects(portrait))
        #expect(there.minX >= bounds.minX)
    }

    /// The held frame was only a word in the HUD, which shows when the pointer
    /// moves on that screen; a held screen looked stuck.
    @Test("the hold badge stays in the surround beside the photograph's top edge, never on it")
    func holdBadge() {
        for size in [CGSize(width: 2560, height: 1416), CGSize(width: 1920, height: 1056)] {
            let bounds = CGRect(origin: .zero, size: size)
            let box = DisplayMetric.pictureBox(in: bounds)
            for aspect in [3.0 / 2.0, 2.0 / 3.0] {
                let picture = DisplayMetric.fitted(aspect, in: box)
                let hold = CGRect(origin: DisplayMetric.holdOrigin(picture: picture, in: bounds),
                                  size: DisplayMetric.holdBadge)
                #expect(!hold.intersects(picture), "\(size) \(aspect)")
                #expect(bounds.contains(hold))
                #expect(hold.minY == picture.minY, "level with the top of the picture")
                // And clear of his verdict badge, which is the same band's
                // bottom corner.
                let badge = CGRect(origin: DisplayMetric.badgeOrigin(picture: picture, in: bounds),
                                   size: CGSize(width: DisplayMetric.badge, height: DisplayMetric.badge))
                #expect(!hold.intersects(badge))
            }
        }
    }

    /// The HUD sat 28 pt up from the window's foot, over the photograph's
    /// bottom edge, even where a band of surround under the picture could
    /// hold it.
    @Test("the HUD goes under the photograph when there is a band to hold it, and over its edge only when there is not")
    func hudUnderThePicture() {
        // A 3:2 frame on a 4:3 panel leaves a band above and below.
        let square = CGRect(x: 0, y: 0, width: 1600, height: 1200)
        let wide = DisplayMetric.fitted(3.0 / 2.0, in: DisplayMetric.pictureBox(in: square))
        let inset = DisplayMetric.hudInset(picture: wide, in: square)
        let hud = CGRect(x: square.midX - 200, y: square.maxY - inset - DisplayMetric.hudHeight,
                         width: 400, height: DisplayMetric.hudHeight)
        #expect(!hud.intersects(wide))
        #expect(hud.maxY < square.maxY)

        // A 3:2 frame filling the height of a 16:9 panel: there is no band,
        // and it keeps its 28 pt.
        let panel = CGRect(x: 0, y: 0, width: 2560, height: 1416)
        let tall = DisplayMetric.fitted(3.0 / 2.0, in: DisplayMetric.pictureBox(in: panel))
        #expect(DisplayMetric.hudInset(picture: tall, in: panel) == DisplayMetric.hudBottomInset)
    }

    @Test("Compare's captions on the other screen grow with the tiles")
    @MainActor
    func compareCaptions() {
        // Two tiles across a 27" panel, and across a 1920 pt one.
        let big = CompareTilesPane.tileWidth(columns: 2, in: 2560)
        let mid = CompareTilesPane.tileWidth(columns: 2, in: 1920)
        #expect(CompareTilesPane.captionFont(tileWidth: big) == .title2)
        #expect(CompareTilesPane.captionFont(tileWidth: mid) == .title3)
        #expect(CompareTilesPane.captionFont(tileWidth: 500) == .callout)
    }

    @Test("the whole burst fills the glass, and a long one scrolls rather than hiding a frame")
    func cells() {
        let big = CGRect(x: 0, y: 0, width: 2560, height: 1416)
        // A 34-frame burst on a 27" panel: the cells grow. Ten small tiles and
        // two thirds of nothing would waste the one thing this screen is for.
        let wide = DisplayMetric.cellWidth(forFrames: 34, in: big)
        #expect(wide > DisplayMetric.cellWidth)
        #expect(wide <= DisplayMetric.cellMaxWidth)

        // Every frame of that burst is on the glass at once.
        let available = big.insetBy(dx: DisplayMetric.pictureInset, dy: DisplayMetric.pictureInset)
        let columns = Int((available.width + DisplayMetric.cellGap) / (wide + DisplayMetric.cellGap))
        let rows = Int((34.0 / Double(columns)).rounded(.up))
        let used = CGFloat(rows) * (DisplayMetric.cellHeight(forWidth: wide) + DisplayMetric.cellGap)
            - DisplayMetric.cellGap
        #expect(used <= available.height)

        // A 300-frame burst cannot fit, so it takes the minimum and scrolls.
        // Nothing is hidden either way.
        #expect(DisplayMetric.cellWidth(forFrames: 300, in: big) == DisplayMetric.cellMinWidth)
        // And a laptop-sized window never goes below the minimum either.
        let small = CGRect(x: 0, y: 0, width: 1100, height: 780)
        #expect(DisplayMetric.cellWidth(forFrames: 34, in: small) >= DisplayMetric.cellMinWidth)
    }

    @Test("§1.6's geometry, from the window rather than from a table")
    func geometry() {
        let filling = DisplayMetric.fitted(3.0 / 2.0,
                                           in: DisplayMetric.pictureBox(in: CGRect(x: 0, y: 0,
                                                                                    width: 2560,
                                                                                    height: 1416)))
        #expect(Int(filling.width.rounded()) == 2076)
        #expect(Int(filling.height.rounded()) == 1384)
        // 77.9 % of the panel.
        let share = (filling.width * filling.height) / (2560 * 1440)
        #expect(share > 0.778 && share < 0.78)
    }
}
