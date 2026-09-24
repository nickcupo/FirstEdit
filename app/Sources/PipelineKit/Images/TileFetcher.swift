import Foundation
import CoreGraphics

/// A window of a frame at its own resolution: what `/crop` cuts.
///
/// The engine's own semantics, read out of `Handler._crop` and confirmed on the
/// wire (`px=1024&ar=1.5` comes back 1024 × 1536): `cx`, `cy` are the box's
/// centre in normalised frame units, `px` is its **width** in source pixels
/// and `ar` is its **height over width**. The engine clamps every one of them
/// (px 256–3000, ar 0.25–4); the app clamps them first so a URL it builds is
/// always the URL of the pixels it gets.
public struct CropBox: Hashable, Sendable {
    public let cx: Double
    public let cy: Double
    public let px: Int
    public let ar: Double

    public init(cx: Double, cy: Double, px: Int, ar: Double) {
        // Quantised, so a pan of a thousandth of a frame is the same URL and
        // the same cache entry rather than a fresh 70 ms cut.
        self.cx = Self.q(min(1, max(0, cx)))
        self.cy = Self.q(min(1, max(0, cy)))
        self.px = min(TileFetcher.maximumTilePixels, max(256, px))
        self.ar = Self.q(min(4, max(0.25, ar)))
    }

    private static func q(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}

/// Where the 1:1 tile goes, and when a new one is needed (DESIGN.md §2.5.7).
///
/// At 1:1 the app fetches a tile 1.6 × the viewport around the aim, so small
/// pans are local GPU work. A new cut is asked for only as the pan approaches
/// the tile's edge; while it is in flight the fitted image is shown scaled at
/// the new offset — never a blank frame.
public enum TileFetcher {
    /// The server's `/crop` `px` clamp before DESIGN.md §3.9-3, and after it.
    /// It has landed — the engine cuts up to 6144 (`CROP_MAX_PX`) — so the app
    /// asks for up to 4096: at 3000 a 1:1 tile was smaller than the viewport
    /// on a large display and "Sharpening…" came up on every short pan.
    public static let serverClampToday = 3000
    public static let serverClampLanded = 4096
    public static let maximumTilePixels = serverClampLanded

    /// How much bigger than the viewport a tile is cut.
    public static let overscan: Double = 1.6
    /// A new tile is asked for once the viewport's edge is within this share
    /// of the tile's margin from the tile's edge.
    public static let refetchMargin: Double = 0.25

    /// The tile around `aim` (normalised) for a viewport of `viewportPixels`
    /// device pixels, at 1:1.
    public static func tile(aim: CGPoint, viewportPixels: CGSize) -> CropBox {
        let w = Double(viewportPixels.width) * overscan
        let h = Double(viewportPixels.height) * overscan
        return CropBox(cx: aim.x, cy: aim.y, px: Int(w.rounded(.up)), ar: w > 0 ? h / w : 0.75)
    }

    /// The normalised rectangle of the frame a tile covers. The engine shifts
    /// a box that would cross the frame's edge back inside rather than
    /// shrinking it, and so does this.
    public static func coverage(of box: CropBox, framePixels: CGSize) -> CGRect {
        guard framePixels.width > 0, framePixels.height > 0 else { return .zero }
        let wpx = min(Double(box.px), Double(framePixels.width))
        let hpx = min(max(1, (Double(box.px) * box.ar).rounded()), Double(framePixels.height))
        let nw = min(1, wpx / Double(framePixels.width))
        let nh = min(1, hpx / Double(framePixels.height))
        let x = min(max(0, box.cx - nw / 2), 1 - nw)
        let y = min(max(0, box.cy - nh / 2), 1 - nh)
        return CGRect(x: x, y: y, width: nw, height: nh)
    }

    /// Whether the viewport (normalised, same frame) has come close enough to
    /// the tile's edge that the next tile should be cut now.
    public static func needsNewTile(viewport: CGRect, tile: CGRect) -> Bool {
        guard !tile.isEmpty else { return true }
        let mx = max(0, (tile.width - viewport.width) / 2) * refetchMargin
        let my = max(0, (tile.height - viewport.height) / 2) * refetchMargin
        let safe = tile.insetBy(dx: mx, dy: my)
        // At the frame's own edge the tile cannot move any further, so being
        // near that edge is not a reason to cut again.
        let clampedSafe = CGRect(
            x: tile.minX <= 0 ? tile.minX : safe.minX,
            y: tile.minY <= 0 ? tile.minY : safe.minY,
            width: (tile.maxX >= 1 ? tile.maxX : safe.maxX) - (tile.minX <= 0 ? tile.minX : safe.minX),
            height: (tile.maxY >= 1 ? tile.maxY : safe.maxY) - (tile.minY <= 0 ? tile.minY : safe.minY))
        return !clampedSafe.contains(viewport)
    }
}
