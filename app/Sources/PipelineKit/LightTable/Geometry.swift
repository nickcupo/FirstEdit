import Foundation
import CoreGraphics

/// The arithmetic of DESIGN.md §2.5.1, with nothing in it that needs a view.
///
/// The light table is four fixed bands and whatever is left. The picture gets
/// what is left, which is half the window or more at every size he uses and
/// 94 % of it on Space. Today it is 30–46 % (LT-04). Every number in the §2.5.1
/// table is checked against this type, so a band that quietly grows by 4 pt
/// fails a test rather than eating the photograph.
public enum LightTableGeometry {

    // MARK: - the four bands

    public struct Bands: Equatable, Sendable {
        public let toolbar: CGFloat
        public let scrubber: CGFloat
        public let controlBar: CGFloat
        public let filmstrip: CGFloat

        public var total: CGFloat { toolbar + scrubber + controlBar + filmstrip }

        public static let standard = Bands(toolbar: Tokens.Metric.toolbar,
                                           scrubber: Tokens.Metric.scrubber,
                                           controlBar: Tokens.Metric.controlBar,
                                           filmstrip: Tokens.Metric.filmstrip)

        /// Full Image hides all four. The picture fills the window.
        public static let fullImage = Bands(toolbar: 0, scrubber: 0, controlBar: 0, filmstrip: 0)
    }

    /// The photograph's own aspect, width over height. A Sony a6500 frame is
    /// 3:2 either way up.
    public static let landscape: CGFloat = 3.0 / 2.0
    public static let portrait: CGFloat = 2.0 / 3.0

    // MARK: - the viewer

    /// The box the photograph is fitted into: the content rect less the four
    /// bands and less the inspector, inset 8 pt on every side.
    ///
    /// `content` is the window's content size — the app draws under the
    /// titlebar, and the toolbar band above is part of these 222 pt.
    public static func viewerBox(content: CGSize, inspector: CGFloat = 0,
                                 bands: Bands = .standard,
                                 inset: CGFloat = Tokens.Metric.viewerInset) -> CGSize {
        // Below 1100 pt of column the control bar has its caption lane too.
        let column = content.width - inspector
        let lane = bands.controlBar > 0
            && !ControlBarLayout(contentWidth: column, inspector: inspector).showsSideCaptions
            ? ControlBarLayout.captionLane : 0
        return CGSize(width: max(0, column - inset * 2),
                      height: max(0, content.height - bands.total - lane - inset * 2))
    }

    /// The photograph, fitted whole inside a box. Never cropped, never scaled
    /// past its box on either axis.
    public static func photograph(in box: CGSize, aspect: CGFloat = landscape) -> CGSize {
        guard box.width > 0, box.height > 0, aspect > 0 else { return .zero }
        let byHeight = CGSize(width: box.height * aspect, height: box.height)
        if byHeight.width <= box.width { return byHeight }
        return CGSize(width: box.width, height: box.width / aspect)
    }

    /// Space: no bands, no inset, the picture fitted to the whole window.
    public static func fullImage(content: CGSize, aspect: CGFloat = landscape) -> CGSize {
        photograph(in: content, aspect: aspect)
    }

    /// What share of the window the photograph actually covers. This is the
    /// number his complaint is about, and the one §2.5.1 tabulates.
    public static func share(of photograph: CGSize, in window: CGSize) -> Double {
        guard window.width > 0, window.height > 0 else { return 0 }
        return Double(photograph.width * photograph.height) / Double(window.width * window.height)
    }

    /// The whole measurement for one window, in one value, so a test reads
    /// like the table it is checking.
    public struct Measured: Equatable, Sendable {
        public let window: CGSize
        public let viewerBox: CGSize
        public let photograph: CGSize
        public let share: Double
        /// Rounded the way §2.5.1 prints it.
        public var percent: Double { (share * 1000).rounded() / 10 }
    }

    public static func measure(window: CGSize, inspector: CGFloat = 0,
                               aspect: CGFloat = landscape, bands: Bands = .standard,
                               inset: CGFloat = Tokens.Metric.viewerInset) -> Measured {
        let box = viewerBox(content: window, inspector: inspector, bands: bands, inset: inset)
        let photo = photograph(in: box, aspect: aspect)
        return Measured(window: window, viewerBox: box, photograph: photo,
                        share: share(of: photo, in: window))
    }

    public static func measureFullImage(window: CGSize, aspect: CGFloat = landscape) -> Measured {
        let photo = fullImage(content: window, aspect: aspect)
        return Measured(window: window, viewerBox: window, photograph: photo,
                        share: share(of: photo, in: window))
    }

    // MARK: - which way the inspector opens

    /// A portrait frame is height-bound and leaves horizontal slack, so the
    /// inspector opens by default on a portrait burst and is closed by default
    /// on a landscape one — **but only when the 280 pt it takes comes out of
    /// slack rather than out of the control bar**.
    ///
    /// It used to ask only the aspect. The inspector is 280 pt off the content
    /// column, and the control bar measures itself from that column, so at his
    /// own 1100 pt window a portrait burst left 820 pt: below
    /// `ControlBarLayout.captionsNeed`, which put the frame caption and the
    /// tally out of the bar and onto the photograph as a full-width chip, and
    /// moved Keep and Drop 141 pt left of where the same window puts them on a
    /// landscape burst. At the app's own 900 pt minimum it left 620 pt and the
    /// cluster was drawn off both ends. The photograph is not allowed to move
    /// the furniture; a frame's orientation changing what the bar shows is
    /// exactly that.
    ///
    /// So the test is: what is left has to be a column the bar is fully happy
    /// in — the whole cluster **and both side captions**, in the column that
    /// remains. Since Keep and Drop stay where the inspector-shut column puts
    /// them (`ControlBarLayout`), the tally's side of the bar is the
    /// inspector's width shorter, and that is 1660 pt of content width and up
    /// (1380 when the cluster was re-centred on whatever column was left, and
    /// slid 140 pt as the inspector opened).
    ///
    /// It asked for the captions to *match* rather than to be there, which is
    /// not the same thing and stopped discriminating exactly where it was
    /// needed. Below 1100 pt neither column shows them, so the two sides of
    /// that equality were both false, and `left.fits` alone decided — which
    /// needs only 1073 pt. In the 27 pt band from 1073 to 1099 the inspector
    /// opened itself on a portrait shoot, the bar was handed 793–819 pt, and
    /// Keep landed 140 pt left of where the same window puts it on a landscape
    /// shoot. 1080 pt is an ordinary width to drag a window to.
    public static func inspectorOpensByDefault(aspect: CGFloat,
                                               contentWidth: CGFloat,
                                               inspector: CGFloat = Tokens.Metric.inspector) -> Bool {
        guard aspect < 1 else { return false }
        let left = ControlBarLayout(contentWidth: contentWidth - inspector, inspector: inspector)
        return left.fits && left.showsSideCaptions
    }


    /// §2.5.1: the sidebar auto-hides on entering Choose Keepers below 1280 pt.
    public static func sidebarAutoHides(windowWidth: CGFloat) -> Bool {
        windowWidth < Tokens.Metric.sidebarAutoHideBelow
    }

    /// The window's content width, worked out from the detail pane the light
    /// table is handed. The split view has two columns, so the pane is the
    /// window less the sidebar whenever the sidebar is drawn.
    ///
    /// The step used to ask AppKit for `NSApp.keyWindow` instead. In the
    /// harness there is no key window and the first visible one is the window
    /// of whichever scene rendered last, so a 1512 pt capture was measured
    /// against a 1100 pt window and the sidebar stayed hidden. The pane's own
    /// measured width is the truth; nothing else is asked.
    public static func windowWidth(detailPane: CGFloat,
                                   sidebarShown: Bool,
                                   sidebarWidth: CGFloat = Tokens.Metric.sidebarDefault) -> CGFloat {
        detailPane + (sidebarShown ? sidebarWidth : 0)
    }

    /// What entering, or resizing inside, Choose Keepers does to the sidebar.
    public enum SidebarMove: Equatable {
        /// Narrow enough that the photograph wants the room: put it away.
        case hide
        /// Wide again, and we are the ones who put it away: bring it back.
        case show
        /// His own choice, or nothing to do.
        case leaveAlone
    }

    /// Narrower than this and the pane is a layout in progress rather than a
    /// window: the smallest window is 900 pt and the widest sidebar is 320 of
    /// it. SwiftUI hands the split view a 100 pt pane for one pass while it
    /// works out the columns, and acting on that put the sidebar away and
    /// brought it back on every launch.
    public static let smallestBelievablePane =
        Tokens.Metric.minimumWindow.width - Tokens.Metric.sidebarMax

    public static func sidebarMove(detailPane: CGFloat,
                                   sidebarShown: Bool,
                                   weHidIt: Bool,
                                   sidebarWidth: CGFloat = Tokens.Metric.sidebarDefault) -> SidebarMove {
        guard detailPane >= smallestBelievablePane else { return .leaveAlone }
        return sidebarMove(window: windowWidth(detailPane: detailPane,
                                               sidebarShown: sidebarShown,
                                               sidebarWidth: sidebarWidth),
                           sidebarShown: sidebarShown, weHidIt: weHidIt)
    }

    /// The same rule, for a window whose width is known rather than worked
    /// out from the pane.
    public static func sidebarMove(window: CGFloat, sidebarShown: Bool, weHidIt: Bool) -> SidebarMove {
        if sidebarAutoHides(windowWidth: window) {
            return sidebarShown ? .hide : .leaveAlone
        }
        return weHidIt ? .show : .leaveAlone
    }

    /// The whole rule, with the one piece of memory it needs: ⌃⌘S sticks for
    /// the width it was pressed at. Without that, showing the sidebar by hand
    /// at 1100 shrinks the pane, which is a layout, which would put it
    /// straight back — the app arguing with him about his own window.
    public struct SidebarAutoHider {
        public var lastWindowWidth: CGFloat = 0
        public var weHidIt = false

        public init() {}

        /// `window`, when the page could measure it, is where the page ends
        /// in its window (`putsTheSidebarAway`). Without it the window is the
        /// pane plus a sidebar of `sidebarWidth`, which is right only while
        /// the sidebar is that wide.
        public mutating func onLayout(detailPane: CGFloat,
                                      sidebarShown: Bool,
                                      sidebarWidth: CGFloat = Tokens.Metric.sidebarDefault,
                                      window measured: CGFloat? = nil) -> SidebarMove {
            guard detailPane >= smallestBelievablePane else { return .leaveAlone }
            let window = measured ?? windowWidth(detailPane: detailPane,
                                                 sidebarShown: sidebarShown,
                                                 sidebarWidth: sidebarWidth)
            // The same window as last time, drawn differently: his doing.
            guard abs(window - lastWindowWidth) > 0.5 else { return .leaveAlone }
            lastWindowWidth = window
            let move = sidebarMove(window: window, sidebarShown: sidebarShown, weHidIt: weHidIt)
            switch move {
            case .hide: weHidIt = true
            case .show: weHidIt = false
            case .leaveAlone: break
            }
            return move
        }

        /// Leaving the last page that puts it away: the sidebar comes back if
        /// we took it away. The window's one copy is `Navigation`'s, which
        /// Choose Keepers and Reels share (`Navigation.sidebarPageLeft`).
        public mutating func onLeave() -> SidebarMove {
            defer { weHidIt = false; lastWindowWidth = 0 }
            return weHidIt ? .show : .leaveAlone
        }
    }

    // MARK: - All Bursts (§2.5.11)

    /// 4 columns at 1100, 9 on a 27". The cover's 180 × 120 is its minimum,
    /// not its size: covers grow to fill the column they are given, so a wider
    /// display shows bigger covers as well as more of them.
    public static let allBurstsColumnTarget: CGFloat = 265

    public static func allBurstsColumns(width: CGFloat,
                                        margin: CGFloat = Tokens.Metric.windowMargin) -> Int {
        let usable = width - margin * 2
        guard usable > Tokens.Metric.burstCover.width else { return 1 }
        return max(1, Int(usable / allBurstsColumnTarget))
    }

    // MARK: - Compare (§2.5.12)

    /// Tiles at equal size, laid out to maximise tile area: 2 across for 2–3,
    /// 2 × 2 for 4, 3 × 2 for 5–6, and a scrolling 3 × 2 beyond.
    public static func compareGrid(count: Int) -> (columns: Int, rows: Int, perPage: Int) {
        switch max(1, count) {
        case 1: return (1, 1, 1)
        case 2: return (2, 1, 2)
        case 3: return (2, 2, 3)
        case 4: return (2, 2, 4)
        case 5, 6: return (3, 2, 6)
        default: return (3, 2, 6)
        }
    }

    /// One tile's size in a Compare grid of `count` over a box.
    ///
    /// Tiles are the **photograph's** shape, not the cell's: a tile stretched
    /// to fill a wide cell is a frame in a letterbox, and the thing he is doing
    /// here is comparing sharpness at the largest size the window allows. At
    /// 1100 × 780 two tiles come out 538 × 359, which is what §2.5.12 measured.
    public static func compareTile(in box: CGSize, count: Int, rows: Int? = nil,
                                   aspect: CGFloat = landscape,
                                   gutter: CGFloat = Tokens.Metric.relatedGap,
                                   caption: CGFloat = 20) -> CGSize {
        let g = compareGrid(count: count)
        let r = max(1, rows ?? g.rows)
        let w = (box.width - gutter * CGFloat(g.columns - 1)) / CGFloat(g.columns)
        let h = (box.height - gutter * CGFloat(r - 1)) / CGFloat(r) - caption
        return photograph(in: CGSize(width: max(0, w), height: max(0, h)), aspect: aspect)
    }
}
