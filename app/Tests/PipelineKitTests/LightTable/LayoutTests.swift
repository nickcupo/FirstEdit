import Foundation
import Testing
import CoreGraphics
@testable import PipelineKit

/// §2.5.1 and §2.5.2 are a table of numbers, so this is a test of that table.
///
/// It exists because the two things he named as wrong are both distances, and a
/// distance is the easiest thing in a UI to lose by accident: one padding
/// changed by 4 pt and Keep is beside Drop again.
@Suite("The light table's geometry")
struct LayoutTests {

    // MARK: - the four bands

    @Test("fixed chrome is 52 + 18 + 56 + 96 = 222 pt")
    func bands() {
        let b = LightTableGeometry.Bands.standard
        #expect(b.toolbar == 52)
        #expect(b.scrubber == 18)
        #expect(b.controlBar == 56)
        #expect(b.filmstrip == 96)
        #expect(b.total == 222)
        #expect(Tokens.Metric.fixedChrome == 222)
    }

    // MARK: - the §2.5.1 table, row by row

    struct Row {
        let name: String
        let window: CGSize
        let inspector: CGFloat
        let viewerBox: CGSize
        let photograph: CGSize
        let percent: Double
    }

    /// Every measured row of §2.5.1, for a 3:2 landscape frame.
    static let table: [Row] = [
        Row(name: "default, sidebar hidden", window: CGSize(width: 1100, height: 780), inspector: 0,
            viewerBox: CGSize(width: 1084, height: 542), photograph: CGSize(width: 813, height: 542),
            percent: 51.4),
        Row(name: "default, inspector open", window: CGSize(width: 1100, height: 780), inspector: 280,
            viewerBox: CGSize(width: 804, height: 518), photograph: CGSize(width: 777, height: 518),
            percent: 46.9),
        Row(name: "14-inch full screen", window: CGSize(width: 1512, height: 945), inspector: 0,
            viewerBox: CGSize(width: 1496, height: 707), photograph: CGSize(width: 1060, height: 707),
            percent: 52.4),
        Row(name: "16-inch full screen", window: CGSize(width: 1728, height: 1080), inspector: 0,
            viewerBox: CGSize(width: 1712, height: 842), photograph: CGSize(width: 1263, height: 842),
            percent: 57.0),
        Row(name: "27-inch full screen", window: CGSize(width: 2560, height: 1440), inspector: 0,
            viewerBox: CGSize(width: 2544, height: 1202), photograph: CGSize(width: 1803, height: 1202),
            percent: 58.8),
        Row(name: "minimum window", window: CGSize(width: 900, height: 620), inspector: 0,
            viewerBox: CGSize(width: 884, height: 358), photograph: CGSize(width: 537, height: 358),
            percent: 34.5),
    ]

    @Test("the photograph is the size §2.5.1 says at all six window sizes", arguments: table.indices)
    func geometryAtEverySize(_ i: Int) {
        let row = Self.table[i]
        let m = LightTableGeometry.measure(window: row.window, inspector: row.inspector)
        #expect(m.viewerBox.width == row.viewerBox.width, "\(row.name): viewer width")
        #expect(m.viewerBox.height == row.viewerBox.height, "\(row.name): viewer height")
        #expect(abs(m.photograph.width - row.photograph.width) <= 1, "\(row.name): photograph width")
        #expect(abs(m.photograph.height - row.photograph.height) <= 1, "\(row.name): photograph height")
        // §2.5.1 rounds the photograph's width down before working out the
        // share, so a tenth of a point either way is the document's rounding,
        // not a different layout.
        #expect(abs(m.percent - row.percent) <= 0.11, "\(row.name): \(m.percent)% against \(row.percent)%")
    }

    /// Except where the column is under 1100 pt — the minimum window, and an
    /// inspector opened by hand at 1100 — where the control bar's caption
    /// lane takes 24 pt so that nothing is drawn on the picture (§2.5.2).
    @Test("the picture is half the window or more everywhere the caption lane is not")
    func halfTheWindow() {
        for row in Self.table where ControlBarLayout(contentWidth: row.window.width - row.inspector).showsSideCaptions {
            let m = LightTableGeometry.measure(window: row.window, inspector: row.inspector)
            #expect(m.share >= 0.5, "\(row.name) is \(m.percent)% and today's page is 30.1%")
        }
        // Even the smallest window the app will open is four times a filmstrip
        // thumbnail and well past today's 30.1 %.
        let minimum = LightTableGeometry.measure(window: Tokens.Metric.minimumWindow)
        #expect(minimum.share > 0.34)
        #expect(minimum.photograph.width > Tokens.Metric.filmstripThumb.width * 4)
    }

    @Test("Full Image reaches 93 % or more of the window")
    func fullImage() {
        let expected: [(CGSize, Double)] = [
            (CGSize(width: 1100, height: 780), 94.0),
            (CGSize(width: 1512, height: 945), 93.7),
            (CGSize(width: 1728, height: 1080), 93.8),
            (CGSize(width: 2560, height: 1440), 84.4),
        ]
        for (window, percent) in expected {
            let m = LightTableGeometry.measureFullImage(window: window)
            #expect(abs(m.percent - percent) <= 0.1, "\(window): \(m.percent)% against \(percent)%")
        }
        // §5.1's acceptance line, on the two sizes it names.
        #expect(LightTableGeometry.measureFullImage(window: CGSize(width: 1100, height: 780)).share >= 0.93)
        #expect(LightTableGeometry.measureFullImage(window: CGSize(width: 1512, height: 945)).share >= 0.93)
    }

    @Test("Full Image is always bigger than the stage, at every size")
    func fullImageIsAlwaysBigger() {
        for row in Self.table {
            let stage = LightTableGeometry.measure(window: row.window, inspector: row.inspector)
            let full = LightTableGeometry.measureFullImage(window: row.window)
            #expect(full.share > stage.share, "\(row.name)")
        }
    }

    @Test("the inspector opens by default on a portrait burst and not on a landscape one")
    func inspectorDefault() {
        // 1728 pt of content: what is left is 1448, which still holds the
        // whole cluster where the shut column puts it, and both side captions.
        #expect(LightTableGeometry.inspectorOpensByDefault(aspect: LightTableGeometry.portrait,
                                                          contentWidth: 1728))
        #expect(!LightTableGeometry.inspectorOpensByDefault(aspect: LightTableGeometry.landscape,
                                                           contentWidth: 1728))
        // Opened by hand at 1100 it leaves the bar 820 pt, under the 1100 its
        // captions need, so the bar's caption lane takes 24 pt of height from
        // either shape of frame (§2.5.2) — one more reason it only opens
        // itself at 1660 and up.
        let landscapeOpen = LightTableGeometry.measure(window: Tokens.Metric.defaultWindow, inspector: 280)
        let landscapeShut = LightTableGeometry.measure(window: Tokens.Metric.defaultWindow)
        #expect(landscapeShut.photograph.height - landscapeOpen.photograph.height == ControlBarLayout.captionLane)
        let portraitOpen = LightTableGeometry.measure(window: Tokens.Metric.defaultWindow, inspector: 280,
                                                      aspect: LightTableGeometry.portrait)
        let portraitShut = LightTableGeometry.measure(window: Tokens.Metric.defaultWindow,
                                                      aspect: LightTableGeometry.portrait)
        #expect(portraitShut.photograph.height - portraitOpen.photograph.height == ControlBarLayout.captionLane)
        // Where the column keeps its captions, a portrait frame loses nothing
        // to the inspector: 1728 pt of content leaves 1448.
        let wide = CGSize(width: 1728, height: 1080)
        #expect(LightTableGeometry.measure(window: wide, inspector: 280, aspect: LightTableGeometry.portrait).photograph
                == LightTableGeometry.measure(window: wide, aspect: LightTableGeometry.portrait).photograph)
    }

    /// The bug he reported as "the bottom bar looks weird if a photo was taken
    /// portrait": at his own window the inspector opened itself for a portrait
    /// frame, and the 280 pt it took came out of the control bar.
    @Test("a portrait frame never costs the bar its captions or its cluster")
    func portraitDoesNotMoveTheFurniture() {
        // Not three sizes: a sweep of every one. Checking 900, 1100 and 1512
        // stepped straight over a 27 pt band — 1073 to 1099 — where the rule
        // asked only whether the remaining column showed *the same* captions
        // as the whole one. Below 1100 neither does, so the test stopped
        // discriminating and the inspector opened itself at 1080.
        for window in stride(from: CGFloat(568), through: 2560, by: 1) {
            let portrait = column(window, aspect: LightTableGeometry.portrait)
            let landscape = column(window, aspect: LightTableGeometry.landscape)
            let opens = portrait != landscape
            let p = ControlBarLayout(contentWidth: portrait, inspector: opens ? Tokens.Metric.inspector : 0)
            let l = ControlBarLayout(contentWidth: landscape)
            // Whatever the window, the bar says the same things either way up:
            // the same controls and the same two side captions.
            #expect(p.shed == l.shed, "the bar gave a control up at \(window) pt")
            #expect(p.fits == l.fits, "the cluster stopped fitting at \(window) pt")
            #expect(p.showsSideCaptions == l.showsSideCaptions,
                    "the captions left the bar at \(window) pt")
            if LightTableGeometry.inspectorOpensByDefault(aspect: LightTableGeometry.portrait,
                                                          contentWidth: window) {
                // Where it opens itself, the 280 pt comes out of **slack**.
                // "It fits" is not slack: at 1080 the old rule opened it and
                // left the bar 800 pt, where the 753 pt cluster has 4 pt each
                // side and the captions are on the photograph.
                #expect(p.fits, "the cluster was broken up at \(window) pt")
                #expect(p.showsSideCaptions, "the captions were pushed out at \(window) pt")
                #expect(p.sideSlack >= 154, "the bar was left \(p.sideSlack) pt at \(window) pt")
                // And Keep and Drop are where a landscape burst has them.
                #expect(p.frame(.keep) == l.frame(.keep), "Keep moved at \(window) pt")
                #expect(p.frame(.drop) == l.frame(.drop), "Drop moved at \(window) pt")
            } else {
                // Below the threshold the column itself is the same, so Keep
                // is in exactly the same place — the 141 pt he reported.
                #expect(portrait == landscape, "the column moved at \(window) pt")
                #expect(p.frame(.keep) == l.frame(.keep), "Keep moved at \(window) pt")
            }
        }

        // The threshold itself, to the point: 1660 pt of content width, where
        // what is left is exactly the column the two side captions need with
        // the cluster held where the shut column puts it — 1100 and the
        // inspector's 280 again, because the tally's side is that much shorter.
        #expect(!LightTableGeometry.inspectorOpensByDefault(aspect: LightTableGeometry.portrait,
                                                           contentWidth: 1659))
        #expect(LightTableGeometry.inspectorOpensByDefault(aspect: LightTableGeometry.portrait,
                                                          contentWidth: 1660))
        #expect(1660 - Tokens.Metric.inspector
                == ControlBarLayout.captionsNeed(inspector: Tokens.Metric.inspector))

        // Above it the inspector does open itself — and then it takes its
        // 280 pt out of slack: the whole cluster and both side captions
        // survive, so the bar says the same things it said before.
        let wide = column(1728, aspect: LightTableGeometry.portrait)
        #expect(wide == 1728 - Tokens.Metric.inspector)
        #expect(ControlBarLayout(contentWidth: wide, inspector: Tokens.Metric.inspector).fits)
        #expect(ControlBarLayout(contentWidth: wide, inspector: Tokens.Metric.inspector).showsSideCaptions)
    }

    private func column(_ window: CGFloat, aspect: CGFloat) -> CGFloat {
        LightTableGeometry.inspectorOpensByDefault(aspect: aspect, contentWidth: window)
            ? window - Tokens.Metric.inspector : window
    }

    /// He can still open the inspector himself at the minimum window, and then
    /// the column really is 620 pt. Nothing may be drawn where he cannot press
    /// it: the bar gives up its duplicates instead.
    @Test("every control the bar draws is inside the column, down to 568 pt")
    func nothingIsDrawnOffTheEdge() {
        for width in stride(from: CGFloat(568), through: 2560, by: 4) {
            let l = ControlBarLayout(contentWidth: width)
            #expect(l.everythingIsReachable, "at \(width) pt of content width")
            // The four §2.5.2 is about are never given up.
            for item in [ControlBarLayout.Item.drop, .label, .keep, .nextBurst] {
                #expect(l.shows(item), "\(item) at \(width) pt")
            }
        }
    }

    /// Keep is the commit; Next Burst skips the rest of the burst. Shedding
    /// the rule along with Compare put them 16 pt apart at the 620 pt column —
    /// a mis-click, and the exact defect `ControlBarLayout`'s own header opens
    /// by naming.
    @Test("Keep and Next Burst never come within a mis-click of each other, at any width")
    func keepIsNeverBesideNextBurst() {
        for width in stride(from: CGFloat(568), through: 2560, by: 1) {
            let l = ControlBarLayout(contentWidth: width)
            #expect(l.keepToNextBurstCentres >= ControlBarLayout.narrowestKeepToNextBurstCentres,
                    "\(l.keepToNextBurstCentres) pt centre to centre at \(width) pt")
            // And a rule stands in the gap at every one of those widths, so
            // the two never read as a pair.
            #expect(l.shows(.divider), "no rule at \(width) pt")
            #expect(l.frame(.divider).minX > l.frame(.keep).maxX, "at \(width) pt")
            #expect(l.frame(.divider).maxX < l.frame(.nextBurst).minX, "at \(width) pt")
        }
        // The narrowest column the bar is ever handed: the 620 pt a
        // hand-opened inspector leaves at the 900 pt minimum window.
        let narrow = ControlBarLayout(contentWidth: Tokens.Metric.minimumWindow.width
                                        - Tokens.Metric.inspector)
        #expect(narrow.keepToNextBurstCentres == ControlBarLayout.narrowestKeepToNextBurstCentres)
        #expect(narrow.frame(.nextBurst).minX - narrow.frame(.keep).maxX == 29)
    }

    @Test("the 620 pt column a hand-opened inspector leaves at the minimum window")
    func minimumWindowWithInspector() {
        let l = ControlBarLayout(contentWidth: Tokens.Metric.minimumWindow.width - Tokens.Metric.inspector)
        #expect(!l.fits)
        #expect(l.everythingIsReachable)
        // ⌘Z, C, ← and → all still work, and the menu still offers them.
        #expect(!l.shows(.undo))
        #expect(!l.shows(.compare))
        #expect(l.shows(.drop) && l.shows(.keep) && l.shows(.label) && l.shows(.nextBurst))
        // Drop and Keep keep the one distance §2.5.2 fixes.
        #expect(l.dropToKeepClearSpace == 160)
    }

    // MARK: - the sidebar on entering Choose Keepers (§2.1, §2.5.1)

    @Test("the sidebar goes away at 1100 and is there at 1512, from the pane's own width")
    func sidebarAtBothSizes() {
        let sidebar = Tokens.Metric.sidebarDefault
        // Entering at 1100: the pane is the window less the sidebar.
        #expect(LightTableGeometry.sidebarMove(detailPane: 1100 - sidebar,
                                               sidebarShown: true, weHidIt: false) == .hide)
        // And once it is away the pane is the whole window, which must not
        // read as a window that has suddenly grown.
        #expect(LightTableGeometry.sidebarMove(detailPane: 1100,
                                               sidebarShown: false, weHidIt: true) == .leaveAlone)
        // Entering at 1512: nothing moves, the sidebar stays.
        #expect(LightTableGeometry.sidebarMove(detailPane: 1512 - sidebar,
                                               sidebarShown: true, weHidIt: false) == .leaveAlone)
        // Widening from 1100 to 1512 with it away: it comes back.
        #expect(LightTableGeometry.sidebarMove(detailPane: 1512,
                                               sidebarShown: false, weHidIt: true) == .show)
        // 1280 exactly is wide enough.
        #expect(LightTableGeometry.sidebarMove(detailPane: 1280 - sidebar,
                                               sidebarShown: true, weHidIt: false) == .leaveAlone)
        #expect(LightTableGeometry.sidebarMove(detailPane: 1279 - sidebar,
                                               sidebarShown: true, weHidIt: false) == .hide)
    }

    @Test("his own ⌃⌘S is never undone, and a pane of no width moves nothing")
    func sidebarLeavesHisChoiceAlone() {
        // He put it away himself at 1512: we did not, so we do not bring it back.
        #expect(LightTableGeometry.sidebarMove(detailPane: 1512,
                                               sidebarShown: false, weHidIt: false) == .leaveAlone)
        // He brought it back at 1100: it is his window, so it stays.
        #expect(LightTableGeometry.sidebarMove(detailPane: 1100 - Tokens.Metric.sidebarDefault,
                                               sidebarShown: true, weHidIt: true) == .hide)
        // Before the first layout there is no width to judge by, and the
        // 100 pt pane SwiftUI hands the split view mid-pass is not a window.
        #expect(LightTableGeometry.sidebarMove(detailPane: 0,
                                               sidebarShown: true, weHidIt: false) == .leaveAlone)
        #expect(LightTableGeometry.sidebarMove(detailPane: 100,
                                               sidebarShown: true, weHidIt: false) == .leaveAlone)
        // The whole arrival at 1512, pass by pass, ends with it showing.
        var hider = LightTableGeometry.SidebarAutoHider()
        _ = hider.onLayout(detailPane: 1512 - Tokens.Metric.sidebarDefault, sidebarShown: true)
        _ = hider.onLayout(detailPane: 100, sidebarShown: true)
        #expect(hider.onLayout(detailPane: 1512 - Tokens.Metric.sidebarDefault,
                               sidebarShown: true) == .leaveAlone)
        #expect(!hider.weHidIt)
    }

    // MARK: - the control bar (§2.5.2)

    @Test("the cluster is 753 pt, and every gap in the table is the gap that is drawn")
    func clusterWidth() {
        #expect(ControlBarLayout.width == 753)
        #expect(Tokens.Metric.controlCluster == 753)

        let l = ControlBarLayout(contentWidth: 1100)
        // Walking the table of §2.5.2 from the left.
        #expect(l.frame(.undo).width == 32 && l.frame(.undo).height == 32)
        #expect(l.frame(.previous).minX - l.frame(.undo).maxX == 24)
        #expect(l.frame(.drop).minX - l.frame(.previous).maxX == 16)
        #expect(l.frame(.label).minX - l.frame(.drop).maxX == 24)
        #expect(l.frame(.keep).minX - l.frame(.label).maxX == 24)
        #expect(l.frame(.next).minX - l.frame(.keep).maxX == 16)
        #expect(l.frame(.divider).minX - l.frame(.next).maxX == 24)
        #expect(l.frame(.compare).minX - l.frame(.divider).maxX == 12)
        #expect(l.frame(.nextBurst).minX - l.frame(.compare).maxX == 8)
        #expect(l.frame(.nextBurst).maxX - l.frame(.undo).minX == 753)
    }

    @Test("Keep and Drop are the same size and weight, and Keep is on the right")
    func sameSize() {
        let l = ControlBarLayout(contentWidth: 1100)
        #expect(l.frame(.keep).size == l.frame(.drop).size)
        #expect(l.frame(.keep).size == CGSize(width: 112, height: 40))
        #expect(l.frame(.keep).minX > l.frame(.drop).minX)
        // The 10 px height mismatch of NAT-16 cannot come back.
        #expect(l.frame(.keep).height == l.frame(.drop).height)
    }

    /// The six sizes §5.1 asks for the cluster to be proved at.
    static let widths: [CGFloat] = [900, 1100, 1100 - 280, 1512, 1728, 2560]

    @Test("Drop to Keep is 160 pt of clear space at every window size", arguments: widths)
    func clearSpace(_ width: CGFloat) {
        let l = ControlBarLayout(contentWidth: width)
        #expect(l.dropToKeepClearSpace == 160, "at \(width) pt of content width")
        #expect(l.dropToKeepCentres == 272, "at \(width) pt of content width")
        #expect(l.keepToNextBurstCentres == 253, "at \(width) pt of content width")
        #expect(l.fits, "the cluster must fit whole at \(width) pt")
    }

    @Test("the frame label sits in the gap, so the two are never adjacent")
    func labelBetween() {
        let l = ControlBarLayout(contentWidth: 1100)
        #expect(l.frame(.label).minX >= l.frame(.drop).maxX)
        #expect(l.frame(.label).maxX <= l.frame(.keep).minX)
        // And it is a real target, not a caption squeezed in.
        #expect(l.frame(.label).width == 112)
    }

    @Test("a rule stands between Keep and Next Burst so they never read as a pair")
    func ruleBetween() {
        let l = ControlBarLayout(contentWidth: 1100)
        #expect(l.frame(.divider).minX > l.frame(.keep).maxX)
        #expect(l.frame(.divider).maxX < l.frame(.nextBurst).minX)
    }

    @Test("the cluster is centred, and the side room is 154 pt at 1100 and 54 pt at 900")
    func sideSlack() {
        #expect(abs(ControlBarLayout(contentWidth: 1100).sideSlack - 154) <= 0.5)
        #expect(abs(ControlBarLayout(contentWidth: 900).sideSlack - 54) <= 0.5)
        // Centred means centred: the same room each side.
        for width in Self.widths {
            let l = ControlBarLayout(contentWidth: width)
            let right = width - l.frame(.nextBurst).maxX - Tokens.Metric.barMargin
            #expect(abs(right - l.sideSlack) <= 1, "at \(width)")
        }
    }

    @Test("below 1100 pt the captions move and the cluster does not")
    func captionsMoveNotTheCluster() {
        let wide = ControlBarLayout(contentWidth: 1100)
        let narrow = ControlBarLayout(contentWidth: 900)
        #expect(wide.showsSideCaptions)
        #expect(!narrow.showsSideCaptions)
        // The cluster's own arithmetic is identical; only its origin moves with
        // the window's centre, which is what "centred" means.
        #expect(wide.dropToKeepClearSpace == narrow.dropToKeepClearSpace)
        #expect(wide.keepToNextBurstCentres == narrow.keepToNextBurstCentres)
    }

    /// Decision 4: Keep and Drop don't move when the inspector opens. The
    /// cluster was centred on whatever column it was handed, and ⌥⌘I slid
    /// them about 140 pt left under his pointer.
    @Test("opening the inspector leaves Keep and Drop where they are wherever the column can hold them")
    func inspectorDoesNotMoveIt() {
        let i = Tokens.Metric.inspector
        // From the narrowest column the bar is promised to work in, 568 pt,
        // with the inspector beside it.
        for width in stride(from: CGFloat(568) + i, through: 2560, by: 1) {
            let shut = ControlBarLayout(contentWidth: width)
            let open = ControlBarLayout(contentWidth: width - i, inspector: i)
            let recentred = ControlBarLayout(contentWidth: width - i)
            // Never a control where he cannot press it, and never the four
            // §2.5.2 is about.
            #expect(open.everythingIsReachable, "at \(width) pt")
            for item in [ControlBarLayout.Item.drop, .label, .keep, .nextBurst, .divider] {
                #expect(open.shows(item), "\(item) at \(width) pt")
            }
            #expect(open.keepToNextBurstCentres >= ControlBarLayout.narrowestKeepToNextBurstCentres)
            #expect(open.dropToKeepClearSpace == 160)
            let moved = shut.frame(.drop).minX - open.frame(.drop).minX
            #expect(moved == open.dropMoved, "at \(width) pt")
            #expect(shut.frame(.keep).minX - open.frame(.keep).minX == moved)
            // It never moves further than re-centring would have moved it.
            #expect(moved <= shut.frame(.drop).minX - recentred.frame(.drop).minX, "at \(width) pt")
            if width >= 1145 {
                #expect(moved == 0, "Drop moved \(moved) pt as the inspector opened at \(width) pt")
            }
            // What is given up to hold it there, as §2.5.2 and `shed` say.
            if width >= 1353 { #expect(open.shed.isEmpty, "at \(width) pt") }
            else if width >= 1265 { #expect(open.shed == [.compare], "at \(width) pt") }
            else if width >= 1145 { #expect(open.shed == [.compare, .previous, .next], "at \(width) pt") }
        }
        // His own 1100 pt window: 23 pt, not the 140 he saw, while Compare and
        // the step arrows wait for the inspector to close.
        let shut = ControlBarLayout(contentWidth: 1100)
        let open = ControlBarLayout(contentWidth: 820, inspector: i)
        #expect(open.dropMoved == 23)
        #expect(shut.frame(.drop).minX - ControlBarLayout(contentWidth: 820).frame(.drop).minX == 140)
        #expect(!open.shows(.compare) && !open.shows(.previous) && !open.shows(.next))
        #expect(open.shows(.undo), "Undo is on the other side of Drop and gains it nothing")
        // A laptop with the sidebar and a desktop: nothing moves, and on the
        // desktop nothing is given up either.
        let laptop = ControlBarLayout(contentWidth: 1220 - i, inspector: i)
        #expect(laptop.dropMoved == 0 && laptop.frame(.keep) == ControlBarLayout(contentWidth: 1220).frame(.keep))
        let desktop = ControlBarLayout(contentWidth: 1700 - i, inspector: i)
        #expect(desktop.dropMoved == 0 && desktop.fits && desktop.showsSideCaptions)
        // The cluster's own spacing is the same in every column it is drawn in.
        let whole = ControlBarLayout(contentWidth: 1700)
        for item in ControlBarLayout.Item.allCases {
            #expect(desktop.frame(item).minX - desktop.origin == whole.frame(item).minX - whole.origin)
        }
    }

    @Test("minimum hit targets are met by every control in the bar")
    func hitTargets() {
        let l = ControlBarLayout(contentWidth: 1100)
        for item in ControlBarLayout.Item.allCases where item != .divider {
            let f = l.frame(item)
            #expect(f.width >= Tokens.Metric.minimumHitTarget, "\(item.rawValue) is \(f.width) pt wide")
            #expect(f.height >= Tokens.Metric.minimumHitTarget, "\(item.rawValue) is \(f.height) pt tall")
        }
    }

    // MARK: - the other two grids

    @Test("All Bursts is 4 columns at 1100 and 9 on a 27-inch")
    func allBursts() {
        #expect(LightTableGeometry.allBurstsColumns(width: 1100) == 4)
        #expect(LightTableGeometry.allBurstsColumns(width: 2560) == 9)
        #expect(LightTableGeometry.allBurstsColumns(width: 900) >= 3)
    }

    @Test("Compare tiles are equal, the photograph's shape, and 538 × 359 for two at 1100 × 780")
    func compare() {
        let box = LightTableGeometry.viewerBox(content: CGSize(width: 1100, height: 780))
        let two = LightTableGeometry.compareTile(in: box, count: 2)
        #expect(abs(two.width - 538) <= 1)
        #expect(abs(two.height - 359) <= 1)
        // 2 across for 2–3, 2 × 2 for 4, 3 × 2 for 5–6, and a page of six beyond.
        #expect(LightTableGeometry.compareGrid(count: 2).columns == 2)
        #expect(LightTableGeometry.compareGrid(count: 4) == (2, 2, 4))
        #expect(LightTableGeometry.compareGrid(count: 6) == (3, 2, 6))
        #expect(LightTableGeometry.compareGrid(count: 9).perPage == 6)
        // Every tile in a grid is the same size as every other: that is what
        // makes it a comparison and not a collage.
        for count in 2...8 {
            let t = LightTableGeometry.compareTile(in: box, count: count)
            #expect(t.width > 0 && t.height > 0, "\(count) tiles")
            #expect(abs(t.width / t.height - LightTableGeometry.landscape) < 0.01, "\(count) tiles")
        }
    }

    @MainActor
    @Test("the filmstrip's 96 pt is the sum of its parts")
    func filmstrip() {
        #expect(Tokens.Metric.filmstrip == 96)
        #expect(Tokens.Metric.filmstripThumb == CGSize(width: 90, height: 60))
        // 12 bracket + 60 thumb + 4 + 14 caption, and 6 pt of padding below.
        #expect(FilmstripItemView.itemHeight == 90, "itemHeight is \(FilmstripItemView.itemHeight), bracket \(FilmstripItemView.bracket), thumb \(FilmstripItemView.thumb), caption \(FilmstripItemView.caption)")
        #expect(FilmstripItemView.itemHeight + 6 == Tokens.Metric.filmstrip)
    }

    @Test("no burst segment in the scrubber is smaller than 8 pt")
    func scrubber() {
        #expect(Tokens.Metric.scrubberMinSegment == 8)
        // His own 155-burst shoot, at the narrowest window: today each burst is
        // a 5.94 pt target (LT-10), which is narrower than a pointer.
        let ideal = (Tokens.Metric.minimumWindow.width - 154) / 155
        #expect(ideal < Tokens.Metric.scrubberMinSegment)
        #expect(max(Tokens.Metric.scrubberMinSegment, ideal) == Tokens.Metric.scrubberMinSegment)
    }
}

/// §2.5.9. The strip's cell is 3:2; the photographs in it are not always.
@MainActor
@Suite("the filmstrip's cell")
struct FilmstripCellTests {
    private func cgImage(width: Int, height: Int) -> CGImage {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
    }

    private var cell: CGRect {
        FilmstripItemView.thumbRect(in: CGSize(width: FilmstripItemView.thumb.width,
                                               height: FilmstripItemView.itemHeight))
    }

    /// `Filmstrip.fitItemToTheBand` hands the flow layout a shorter item when
    /// the band is under 91 pt — the item's own 90 pt is a ceiling, not a
    /// promise. What gives up the difference is **the picture**: a frame's run
    /// and a frame's number are writing, and §2.5.9 is that nothing in the
    /// strip is hidden.
    ///
    /// The picture used to be drawn at a fixed 60 pt from a fixed 12 pt down,
    /// so a shorter item cut the caption off the bottom first and then the
    /// bottom of the picture — the opposite of what the comment claimed.
    @Test("a short band takes its points off the picture, never off the caption or the bracket")
    func aShortBandShrinksThePicture() {
        // The full band: nothing has changed at the size he actually uses.
        #expect(cell == CGRect(x: 0, y: 12, width: 90, height: 60))

        for height in stride(from: CGFloat(90), through: 40, by: -1) {
            let r = FilmstripItemView.thumbRect(in: CGSize(width: 90, height: height))
            // The bracket lane keeps its 12 pt, above the picture.
            #expect(r.minY == FilmstripItemView.bracket, "at \(height) pt")
            // The caption keeps its 4 pt gap and its 14 pt, below it.
            #expect(r.maxY + 4 + FilmstripItemView.caption <= height, "at \(height) pt")
            // And the picture is never taller than its own 60.
            #expect(r.height <= FilmstripItemView.thumb.height, "at \(height) pt")
            #expect(r.height >= 0, "at \(height) pt")
        }
        // Point for point: a band 4 pt short costs the picture 4 pt.
        #expect(FilmstripItemView.thumbRect(in: CGSize(width: 90, height: 86)).height == 56)
        // And a frame drawn into it is still whole, still centred, still inside.
        let short = FilmstripItemView.thumbRect(in: CGSize(width: 90, height: 86))
        let r = FilmstripItemView.fitted(image: cgImage(width: 4024, height: 6024), in: short)
        #expect(r.minY >= short.minY && r.maxY <= short.maxY)
        // Within the half point an odd width rounds to.
        #expect(abs(r.midX - short.midX) <= 0.5)
    }

    @Test("a 3:2 frame either way up fills the cell exactly")
    func landscapeFillsIt() {
        let r = FilmstripItemView.fitted(image: cgImage(width: 1440, height: 962), in: cell)
        #expect(r.width == 90)
        #expect(abs(r.height - 60) <= 1)
        #expect(cell.contains(r.insetBy(dx: 0, dy: -0.5)) || cell.insetBy(dx: 0, dy: -1).contains(r))
    }

    /// The bug: a 4024 × 6024 frame was drawn 90 × 135 in a 90 × 60 cell, with
    /// no clip — 37 pt into the stack-bracket lane above and 37 pt over its own
    /// frame number below.
    @Test("a portrait frame is drawn whole and stays inside the cell")
    func portraitStaysInside() {
        let r = FilmstripItemView.fitted(image: cgImage(width: 4024, height: 6024), in: cell)
        #expect(r.height <= cell.height)
        #expect(r.width <= cell.width)
        #expect(r.minY >= cell.minY)
        #expect(r.maxY <= cell.maxY)
        // 4024/6024 of 60 pt is 40 pt wide, centred.
        #expect(r.width == 40)
        #expect(r.midX == cell.midX)
    }

    @Test("nothing reaches the bracket lane or the caption lane")
    func lanesAreClear() {
        for (w, h) in [(4024, 6024), (1440, 962), (962, 1440), (2000, 2000), (6024, 4024)] {
            let r = FilmstripItemView.fitted(image: cgImage(width: w, height: h), in: cell)
            #expect(r.minY >= FilmstripItemView.bracket, "\(w)×\(h) reached the bracket lane")
            #expect(r.maxY <= FilmstripItemView.bracket + FilmstripItemView.thumb.height,
                    "\(w)×\(h) reached the caption lane")
        }
    }
}

/// ⌥⌘I pins either choice and it sticks (DESIGN.md §2.5.1).
@MainActor
@Suite("the inspector remembers who moved it")
struct InspectorMemoryTests {
    @Test("the portrait default applies until he touches it, and never after")
    func hisChoiceSticks() {
        let nav = Navigation()
        nav.setInspectorByDefault(true)
        #expect(nav.inspectorShown)
        #expect(!nav.inspectorIsHisChoice)

        // ⌥⌘I. From here the default is not allowed to speak again — which is
        // what returning to Choose Keepers used to do, on every appear.
        nav.toggleInspector()
        #expect(!nav.inspectorShown)
        #expect(nav.inspectorIsHisChoice)

        nav.setInspectorByDefault(true)
        #expect(!nav.inspectorShown)
        nav.setInspectorByDefault(false)
        #expect(!nav.inspectorShown)
    }
}
