import Foundation
import CoreGraphics

/// The numbers the second screen fixes (§1.4, §1.6, §4.4), in one place, so a
/// layout test can assert them and no view types one in by hand.
public enum DisplayMetric {
    /// Every side. The photograph never touches the bezel: a frame with no
    /// surround at all cannot be judged for tone.
    public static let pictureInset: CGFloat = 16
    /// The HUD capsule.
    public static let hudHeight: CGFloat = 44
    public static let hudBottomInset: CGFloat = 28
    public static let hudPadding: CGFloat = 18
    /// The two edge hairlines. Increase Contrast thickens them to 3.
    public static let hairline: CGFloat = 2
    public static let hairlineContrast: CGFloat = 3
    /// The verdict badge, echoed in the surround.
    public static let badge: CGFloat = 40
    public static let badgeInset: CGFloat = 28
    /// The top strip that reveals the real title bar.
    public static let titleBarZone: CGFloat = 52
    /// Compare tiles, gutter between them.
    public static let tileGutter: CGFloat = 8
    /// The Whole Burst's cells. They grow to fill the glass — a 34-frame burst
    /// on a 27" panel showing ten small tiles and two thirds of nothing would
    /// waste the one thing the second screen is for — and shrink to the
    /// minimum for a long burst, which then scrolls. Nothing is ever hidden.
    public static let cellWidth: CGFloat = 240
    public static let cellMinWidth: CGFloat = 160
    public static let cellMaxWidth: CGFloat = 520
    public static let cellStep: CGFloat = 8
    public static let cellCaption: CGFloat = 18
    public static let cellGap: CGFloat = 8

    /// The largest cell width at which every frame of the burst is on the
    /// glass at once, or the minimum when it cannot be.
    public static func cellWidth(forFrames count: Int, in bounds: CGRect) -> CGFloat {
        let available = bounds.insetBy(dx: pictureInset, dy: pictureInset)
        guard count > 0, available.width > cellMinWidth, available.height > 0 else { return cellWidth }
        var width = min(cellMaxWidth, available.width)
        while width > cellMinWidth {
            let columns = max(1, Int((available.width + cellGap) / (width + cellGap)))
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let height = cellHeight(forWidth: width)
            if CGFloat(rows) * (height + cellGap) - cellGap <= available.height { return width }
            width -= cellStep
        }
        return cellMinWidth
    }

    public static func cellHeight(forWidth width: CGFloat) -> CGFloat {
        (width * 2 / 3).rounded() + cellCaption
    }
    public static let cursorRing: CGFloat = 3

    /// The photograph's box inside a window of this size.
    public static func pictureBox(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: pictureInset, dy: pictureInset)
    }

    /// Where his verdict badge goes: in the surround, against the
    /// photograph's edge, **never over the photograph**.
    ///
    /// The left band first, because on a 3:2 frame filling a 16:9 panel that
    /// band is 226 pt wide and the one under the picture is 16. If neither band
    /// can hold it — a frame whose shape happens to match the glass exactly —
    /// it falls to the window's own corner, which is the only place left.
    public static func badgeOrigin(picture: CGRect, in bounds: CGRect) -> CGPoint {
        let needed = badge + badgeInset
        if picture.minX - bounds.minX >= needed {
            return CGPoint(x: picture.minX - badgeInset - badge, y: picture.maxY - badge)
        }
        if bounds.maxY - picture.maxY >= needed {
            return CGPoint(x: picture.minX, y: picture.maxY + badgeInset)
        }
        return CGPoint(x: bounds.minX + badgeInset, y: bounds.maxY - badgeInset - badge)
    }

    /// The hold badge: the pin over "holding" over the frame number, in the
    /// surround, the verdict badge's corner mirrored to the top.
    public static let holdBadge = CGSize(width: 64, height: 60)

    /// Where the hold badge goes: in the surround, against the photograph's
    /// top edge, **never over the photograph**, by the same rule as his
    /// verdict badge — the left band first, then the band above, then the
    /// window's own corner.
    public static func holdOrigin(picture: CGRect, in bounds: CGRect) -> CGPoint {
        if picture.minX - bounds.minX >= holdBadge.width + badgeInset {
            return CGPoint(x: picture.minX - badgeInset - holdBadge.width, y: picture.minY)
        }
        if picture.minY - bounds.minY >= holdBadge.height + badgeInset {
            return CGPoint(x: picture.minX, y: picture.minY - badgeInset - holdBadge.height)
        }
        return CGPoint(x: bounds.minX + badgeInset, y: bounds.minY + badgeInset)
    }

    /// How far above the window's bottom edge the HUD sits: in the middle of
    /// the band under the photograph when that band can hold it, so it is
    /// drawn on the surround as his verdict badge is; 28 pt up, over the
    /// picture's bottom edge, only when the frame fills the height of the
    /// glass and there is no band to put it in.
    public static func hudInset(picture: CGRect, in bounds: CGRect) -> CGFloat {
        let band = bounds.maxY - picture.maxY
        guard band >= hudHeight + tileGutter * 2 else { return hudBottomInset }
        return ((band - hudHeight) / 2).rounded()
    }

    /// A 3:2 frame fitted in that box — §1.6's table, computed rather than
    /// copied.
    public static func fitted(_ aspect: CGFloat, in box: CGRect) -> CGRect {
        guard box.width > 0, box.height > 0, aspect > 0 else { return .zero }
        let byHeight = CGSize(width: box.height * aspect, height: box.height)
        let size = byHeight.width <= box.width
            ? byHeight
            : CGSize(width: box.width, height: box.width / aspect)
        return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
