import SwiftUI
import AppKit

/// The numbers DESIGN.md §2 fixes, in one place, so a layout test can assert
/// them and no view types one in by hand.
///
/// System font, system materials, system accent, light and dark. No brand
/// palette and no serif anywhere (NAT-08).
public enum Tokens {

    public enum Metric {
        // §2.5.1 — fixed chrome is 52 + 18 + 56 + 96 = 222 pt.
        public static let toolbar: CGFloat = 52
        public static let scrubber: CGFloat = 18
        public static let controlBar: CGFloat = 56
        public static let filmstrip: CGFloat = 96
        public static var fixedChrome: CGFloat { toolbar + scrubber + controlBar + filmstrip }
        /// Picture inset inside the viewer box, each side.
        public static let viewerInset: CGFloat = 8

        // §2.5.2 — the two verdict buttons are the same size, shape and weight.
        public static let verdictButton = CGSize(width: 112, height: 40)
        /// Drop's inner edge to Keep's inner edge. The frame label sits in it.
        public static let verdictClearGap: CGFloat = 160
        public static let frameLabel = CGSize(width: 112, height: 40)
        public static let undoButton = CGSize(width: 32, height: 32)
        public static let stepButton = CGSize(width: 36, height: 36)
        public static let compareButton = CGSize(width: 36, height: 36)
        public static let nextBurstButton = CGSize(width: 128, height: 40)
        /// Sum of the cluster's sizes and gaps in the §2.5.2 table.
        public static let controlCluster: CGFloat = 753
        public static let barMargin: CGFloat = 20

        // §2.2 spacing.
        public static let windowMargin: CGFloat = 20
        public static let groupGap: CGFloat = 16
        public static let relatedGap: CGFloat = 8
        public static let labelValueGap: CGFloat = 4
        /// Step pages are a centred column, left-aligned inside.
        public static let column: CGFloat = 680
        public static let minimumHitTarget: CGFloat = 28

        // §2.1 window and sidebar.
        public static let defaultWindow = CGSize(width: 1100, height: 780)
        public static let minimumWindow = CGSize(width: 900, height: 620)
        /// 240, not 220. At 220 the row for What the Cull Has Learned is cut
        /// off mid-word — "What the Cull Has Lea…" — because a sidebar row
        /// spends 86 pt on its icon, its insets and its selection shape, and
        /// that label is 161 pt of text. Every extension-supplied step label
        /// is at the same risk, and 20 pt of a 1,100 pt window is 1.8 % of
        /// the detail pane. The words are the product; the width is not.
        ///
        /// 256, not 240: with a mouse attached the Mac draws classic
        /// scrollers, and once the library is long enough to scroll the
        /// sidebar's takes 15 pt of every row — "What the Cull Has Learn…"
        /// again, and the Keepers row's count gone.
        public static let sidebarDefault: CGFloat = 256
        public static let sidebarMin: CGFloat = 180
        public static let sidebarMax: CGFloat = 320
        public static let sidebarRow: CGFloat = 28
        public static let inspector: CGFloat = 280
        /// The sidebar auto-hides on entering Choose Keepers below this width.
        public static let sidebarAutoHideBelow: CGFloat = 1280
        /// On Choose Keepers the toolbar's status item says the shoot and the
        /// time left only in a window at least this wide. The whole line
        /// beside the mode picker needs about 1,200 pt of detail with the
        /// sidebar hidden and 1,030 with it shown; at 1440 the sidebar is
        /// back and 160 pt are to spare (measured), and at 1280 the whole
        /// line and the sidebar coming back fought over the width and never
        /// settled.
        public static let statusItemWholeFrom: CGFloat = 1440

        // §2.5.9 filmstrip.
        public static let filmstripThumb = CGSize(width: 90, height: 60)
        public static let filmstripGap: CGFloat = 6
        public static let currentRing: CGFloat = 3
        // §2.5.10 scrubber.
        public static let scrubberMinSegment: CGFloat = 8
        // §2.5.11 All Bursts.
        public static let burstCover = CGSize(width: 180, height: 120)
        public static let burstCaption: CGFloat = 32
        // §2.8 destructive group.
        public static let destructiveClearance: CGFloat = 32
        // §2.10 first run.
        public static let firstRunSheet = CGSize(width: 560, height: 440)
    }

    public enum Palette {
        /// A photographer judges tone against a known surround, so the viewer's
        /// background is its own setting. Neutral Grey is the same neutral in
        /// both appearances; a surround that changed with the OS theme would
        /// change how he reads exposure.
        ///
        /// Read through `LiveSettings`, so every view that draws it is redrawn
        /// the moment the choice changes, from the menu or from Settings.
        @MainActor public static var viewerBackground: Color {
            Color(nsColor: viewerBackgroundNSColor(LiveSettings.shared.viewerBackground, fullImage: false))
        }

        /// Full Image always uses the darkest variant of the chosen option.
        @MainActor public static var fullImageBackground: Color {
            Color(nsColor: viewerBackgroundNSColor(LiveSettings.shared.viewerBackground, fullImage: true))
        }

        /// One grey, named in sRGB, for both windows.
        ///
        /// This was `NSColor(white:)`, which is a *calibrated* white and
        /// renders as a different grey on every panel — DESIGN-displays.md
        /// §4.4 calls that the most visible two-screen fault there is, and the
        /// values were ≈#5C5C5C / #212121 rather than the measured #3A3A3A /
        /// #1A1A1A. `DisplaySurround` holds the arithmetic and the picture
        /// window already uses it, so both windows now read it from one place.
        public static func viewerBackgroundNSColor(_ choice: ViewerBackground, fullImage: Bool) -> NSColor {
            DisplaySurround.color(choice, wide: fullImage)
        }

        // Verdict colour is always accompanied by a symbol and a word, so
        // Differentiate Without Color loses nothing.
        public static let kept = Color.green
        public static let out = Color.red
        public static let fault = Color.orange
        public static let alarm = Color.red
        public static let machine = Color.secondary
        /// White text on this fixed purple stays legible in either appearance.
        /// Suggestions have a star and a word; personal keeps use a green check.
        public static let suggestionNS = NSColor(srgbRed: 0.38, green: 0.20, blue: 0.68, alpha: 1)
        public static let suggestion = Color(nsColor: suggestionNS)
    }

    public enum Motion {
        /// A step change: a 120 ms crossfade, or 100 ms under Reduce Motion.
        /// Frame to frame by key is never animated at all.
        public static func step(_ a: Animation = .easeInOut(duration: 0.12)) -> Animation {
            PipelineKit.Motion.reduced ? .easeInOut(duration: 0.1) : a
        }
    }

    public enum Sym {
        public static let keep = Symbols.keep
        public static let drop = Symbols.drop
        public static let undo = Symbols.undo
        public static let compare = Symbols.compare
        public static let nextBurst = Symbols.nextBurst
        public static let fullImage = Symbols.fullImage
    }
}

/// View ▸ Viewer Background and Settings ▸ Choosing.
public enum ViewerBackground: String, CaseIterable, Sendable, Codable {
    case neutralGrey, matchSystem, black
}

// MARK: - type (§2.2)

extension Font {
    /// Frame numbers line up: 04330 over 04331.
    public static var frameNumber: Font { .system(.caption, design: .monospaced) }
}

extension View {
    /// Counts use monospaced digits so a tally does not jitter as it changes.
    public func countStyle() -> some View { monospacedDigit() }
}
