import Foundation
import CoreGraphics

/// Where Keep and Drop live, to the point (DESIGN.md §2.5.2).
///
/// This is the answer to the first thing he said was wrong: *"how far apart
/// the buttons to go to the next one are or how far apart they are to
/// keep/discard an image"*. Today the two are 16 px apart with a 10 px height
/// mismatch (LT-07 / NAT-16), and the row wraps to two lines at the app's own
/// default window size and is then clipped to a 26 px sliver (LT-03).
///
/// So the cluster is computed here, once, from the table in §2.5.2 — and the
/// bar that draws it asks this type for every frame rather than stacking views
/// and hoping. It never wraps, never scrolls and never moves: it is centred on
/// the content column's centre **as the column is with the inspector shut**,
/// so Keep and Drop stay where they are when the inspector opens (see
/// `init(contentWidth:height:inspector:)`).
public struct ControlBarLayout: Equatable, Sendable {

    /// The nine things in the cluster, in the order they are drawn.
    public enum Item: String, CaseIterable, Sendable {
        case undo, previous, drop, label, keep, next, divider, compare, nextBurst

        /// §2.5.2, column "Size".
        public var size: CGSize {
            switch self {
            case .undo: return Tokens.Metric.undoButton                 // 32 × 32
            case .previous, .next: return Tokens.Metric.stepButton      // 36 × 36
            case .drop, .keep: return Tokens.Metric.verdictButton       // 112 × 40
            case .label: return Tokens.Metric.frameLabel                // 112 × 40
            case .divider: return CGSize(width: 1, height: 24)
            case .compare: return Tokens.Metric.compareButton           // 36 × 36
            case .nextBurst: return Tokens.Metric.nextBurstButton       // 128 × 40
            }
        }

        /// §2.5.2, column "Gap to next". Nothing after Next Burst.
        public var gapAfter: CGFloat {
            switch self {
            case .undo: return 24
            case .previous: return 16
            case .drop: return 24
            case .label: return 24
            case .keep: return 16
            case .next: return 24
            case .divider: return 12
            case .compare: return 8
            case .nextBurst: return 0
            }
        }
    }

    /// The sum of the sizes and the gaps above: **753 pt**. Written out as a
    /// constant as well as computed, so the two have to agree.
    public static let width: CGFloat = Item.allCases.reduce(0) { $0 + $1.size.width + $1.gapAfter }

    /// Below this content width the two side captions move to a one-line
    /// lane of the bar's own above the cluster, so the cluster itself never
    /// shifts and nothing is drawn over the photograph.
    public static let captionsNeed: CGFloat = 1100

    /// That lane's height: one line of `.callout`, with room above and below.
    public static let captionLane: CGFloat = 24

    /// What the bar gives up, in this order, when the column it is handed
    /// cannot hold the whole cluster — and, by omission, the four things it
    /// never gives up (DESIGN.md §2.5.2).
    ///
    /// §2.5.2's promise is about **Drop, the frame's label, Keep and Next
    /// Burst**: the two opposite verdicts never adjacent, something between
    /// them naming what is being decided, and one short move to the next
    /// burst. Everything else in the cluster is a second way to reach what a
    /// key already does — ⌘Z, C, ← and → — and the menu, the filmstrip and
    /// the inspector all offer those as well. So those give way, and a
    /// control is never drawn at a negative x where the pointer cannot reach
    /// it. The two step arrows go together, because a bar offering ▸ and not
    /// ◂ is worse than one offering neither.
    ///
    /// **The rule is not one of them.** It went with Compare at first, on the
    /// reading that a rule separating nothing from Next Burst is a mark with
    /// no meaning — but what it separates is Keep from Next Burst, and that is
    /// the whole of why it is in the cluster at all. Shedding it took the last
    /// thing between the commit and the skip: in the 620 pt column a
    /// hand-opened inspector leaves at the minimum window, Keep ended at 430
    /// and Next Burst began at 446, sixteen points of nothing between two
    /// 40 pt targets, which is the very defect this file's header opens by
    /// naming. It costs 13 pt of a column that has room for them.
    public static let shedStages: [[Item]] = [[.undo], [.compare], [.previous, .next]]

    public let contentWidth: CGFloat
    public let height: CGFloat
    /// The width the inspector is taking off the trailing side of the
    /// column, or 0 with it shut.
    public let inspector: CGFloat
    /// The cluster's left edge inside the bar.
    public let origin: CGFloat
    /// What this column is too narrow to draw. With the inspector shut,
    /// empty from 793 pt of column, so at every size he uses. With it open,
    /// also what gives way so Keep and Drop stay where they were: Compare and
    /// the step arrows below 1265 pt of content, his 1100 pt window included,
    /// and Compare alone below 1353.
    public let shed: Set<Item>
    /// The cluster as it is actually drawn: `Self.width` less what was shed.
    public let clusterWidth: CGFloat
    /// How far left of where it stands with the inspector shut Drop is drawn:
    /// 0 wherever the column can hold it there.
    public let dropMoved: CGFloat

    /// The bar for a column `contentWidth` wide, with `inspector` points of
    /// the window beside it taken by the inspector.
    ///
    /// **Keep and Drop do not move when the inspector opens** (§2.5.2). The
    /// cluster used to be centred on whatever column it was handed, and ⌥⌘I
    /// takes 280 pt off that column, so it slid Keep and Drop about 140 pt
    /// left under his pointer — while this header promised it did not. Now
    /// Drop is held where the column without the inspector puts it, and the
    /// label and Keep with it, since the distances between them are fixed:
    ///
    /// 1. What would overrun the trailing edge from there is given up first,
    ///    in `shedStages` order: Compare, then the two step arrows. They are
    ///    second ways to reach keys, and the inspector's own Compare link,
    ///    the menu and the keys still offer them. Undo is not given up for
    ///    this: it is on the other side of Drop and gains nothing.
    /// 2. What still overruns moves the cluster left, only as far as it must.
    /// 3. Should that put Undo past the leading edge, Undo goes, and then the
    ///    arrows; a column too narrow even for that has the cluster centred in
    ///    it, as before — never a control drawn where he cannot press it.
    ///
    /// From 1145 pt of content — 865 left beside the inspector — Drop does
    /// not move at all; from 1353 (1073 beside it) nothing is given up
    /// either, and from 1660 (1380) the side captions stand beside the
    /// cluster too. At his own 1100 pt window the 820 pt left holds Drop 23 pt
    /// left of where it was, not 140, without Compare and the step arrows
    /// while the inspector is open. The inspector's width is its ideal 280 pt;
    /// dragged wider, the bar holds against that and moves by half the
    /// difference.
    public init(contentWidth: CGFloat, height: CGFloat = Tokens.Metric.controlBar,
                inspector: CGFloat = 0) {
        self.contentWidth = contentWidth
        self.height = height
        self.inspector = max(0, inspector)
        let here = Self.centred(in: contentWidth)
        guard self.inspector > 0 else {
            (shed, clusterWidth, origin, dropMoved) = (here.shed, here.width, here.origin, 0)
            return
        }
        let home = Self.centred(in: contentWidth + self.inspector)
        let dropHome = home.origin + Self.lead(home.shed)
        let first = Self.hold(dropAt: dropHome, from: home.shed, in: contentWidth)
        guard let held = first else {
            (shed, clusterWidth, origin, dropMoved) = (here.shed, here.width, here.origin,
                                                       dropHome - (here.origin + Self.lead(here.shed)))
            return
        }
        (shed, clusterWidth, origin) = (held.shed, held.width, held.origin)
        dropMoved = dropHome - (held.origin + Self.lead(held.shed))
    }

    /// The cluster centred on a column: what it gives up, how wide it then
    /// is, and where it starts.
    private static func centred(in column: CGFloat) -> (shed: Set<Item>, width: CGFloat, origin: CGFloat) {
        var gone: Set<Item> = []
        var w = Self.width
        let room = column - Tokens.Metric.barMargin * 2
        for stage in Self.shedStages where w > room {
            for i in stage {
                gone.insert(i)
                w -= i.size.width + i.gapAfter
            }
        }
        // Clamped at the leading edge. Centred it went negative below 753 pt
        // of content — at the app's own 900 pt minimum with the inspector
        // open the origin was -67, which put Undo entirely off the left of
        // the window where no pointer could reach it. Off the trailing edge
        // is recoverable by widening the window; off the leading edge is not.
        return (gone, w, max(Tokens.Metric.barMargin, ((column - w) / 2).rounded()))
    }

    /// Drop held at `dropAt`, giving up as little as it must (see `init`), or
    /// nothing when the column cannot hold it even so.
    private static func hold(dropAt: CGFloat, from shed: Set<Item>,
                             in column: CGFloat) -> (shed: Set<Item>, width: CGFloat, origin: CGFloat)? {
        let before: Set<Item> = [.undo, .previous]
        let after: Set<Item> = [.next, .divider, .compare, .nextBurst]
        let start = Tokens.Metric.barMargin, end = column - Tokens.Metric.barMargin
        var gone = shed
        for stage in shedStages where dropAt + span(gone) > end && !after.isDisjoint(with: stage) {
            gone.formUnion(stage)
        }
        var drop = min(dropAt, end - span(gone))
        for stage in shedStages where drop - lead(gone) < start && !before.isDisjoint(with: stage) {
            gone.formUnion(stage)
            drop = min(dropAt, end - span(gone))
        }
        guard drop - lead(gone) >= start else { return nil }
        let w = Item.allCases.filter { !gone.contains($0) }.reduce(0) { $0 + $1.size.width + $1.gapAfter }
        return (gone, w, (drop - lead(gone)).rounded())
    }

    /// From the cluster's leading edge to Drop, with `shed` given up.
    private static func lead(_ shed: Set<Item>) -> CGFloat {
        [Item.undo, .previous].filter { !shed.contains($0) }.reduce(0) { $0 + $1.size.width + $1.gapAfter }
    }

    /// From Drop's leading edge to the end of Next Burst, with `shed` given up.
    private static func span(_ shed: Set<Item>) -> CGFloat {
        Item.allCases.drop(while: { $0 != .drop }).filter { !shed.contains($0) }
            .reduce(0) { $0 + $1.size.width + $1.gapAfter }
    }

    /// Whether this column is wide enough to draw that control at all.
    public func shows(_ item: Item) -> Bool { !shed.contains(item) }

    /// One item's frame inside the bar, vertically centred. A control this
    /// column is too narrow for has no frame: `CGRect.null`.
    public func frame(_ item: Item) -> CGRect {
        guard shows(item) else { return .null }
        var x = origin
        for i in Item.allCases {
            if i == item { break }
            guard shows(i) else { continue }
            x += i.size.width + i.gapAfter
        }
        let s = item.size
        return CGRect(x: x, y: ((height - s.height) / 2).rounded(), width: s.width, height: s.height)
    }

    public func centre(_ item: Item) -> CGPoint {
        let f = frame(item)
        return CGPoint(x: f.midX, y: f.midY)
    }

    // MARK: - the numbers that answer his complaint

    /// Drop's inner edge to Keep's inner edge: **160 pt of clear space**, with
    /// the frame's own label sitting in it. The two opposite controls are never
    /// adjacent and are separated by something that names what is being decided.
    public var dropToKeepClearSpace: CGFloat {
        frame(.keep).minX - frame(.drop).maxX
    }

    /// **272 pt** centre to centre.
    public var dropToKeepCentres: CGFloat {
        centre(.keep).x - centre(.drop).x
    }

    /// **253 pt**: one short move from Keep to Next Burst, with a rule between
    /// them so they never read as a pair.
    ///
    /// In the narrowest column the bar is ever handed it falls to
    /// `narrowestKeepToNextBurstCentres` and no further, because the rule is
    /// never given up. Keep is the commit and Next Burst skips the rest of the
    /// burst; nothing between them is a mis-click.
    public var keepToNextBurstCentres: CGFloat {
        centre(.nextBurst).x - centre(.keep).x
    }

    /// The least the above may ever be: **149 pt**, in a column too narrow for
    /// Compare and the two step arrows, with 29 pt of clear space and the rule
    /// standing in the middle of it. Dropping the rule as well made it 136,
    /// with 16 pt of nothing — the defect this file's header opens by naming.
    public static let narrowestKeepToNextBurstCentres: CGFloat = 149

    /// How much room is left each side of the cluster for the caption and the
    /// tally, inside the bar's own 20 pt margins: **154 pt** at 1100 pt of
    /// content width and **54 pt** at the 900 pt minimum, which are the two
    /// numbers §2.5.1 uses to say the cluster still fits whole.
    public var sideSlack: CGFloat { origin - Tokens.Metric.barMargin }

    /// The cluster fits whole, with its margins. Below this the bar sheds in
    /// `shedStages` order rather than drawing a control where it cannot be
    /// pressed — which is what "it is never allowed not to" has to mean for a
    /// window the user is free to make 900 pt wide and then open a 280 pt
    /// inspector in.
    public var fits: Bool { shed.isEmpty }

    /// Every control this column draws lies inside it. This is the invariant
    /// the shedding exists for, and it holds at every width down to 568 pt.
    public var everythingIsReachable: Bool {
        Item.allCases.filter(shows).allSatisfy { i in
            let f = frame(i)
            return f.minX >= 0 && f.maxX <= contentWidth
        }
    }

    /// At or above 1100 pt the caption and the tally sit beside the cluster;
    /// below it they take the lane above it, and the cluster stays exactly
    /// where it was. With the inspector open the cluster stands where the
    /// wider column put it, so the tally's side has the inspector's width
    /// less: the captions need that much more column to stay beside it.
    public var showsSideCaptions: Bool { contentWidth >= Self.captionsNeed(inspector: inspector) }

    /// The column the two side captions need, with this much inspector open:
    /// the same 137 pt for the tally as a 1100 pt column gives it.
    public static func captionsNeed(inspector: CGFloat) -> CGFloat { captionsNeed + max(0, inspector) }

    /// How wide a side caption's box may be. Past this the caption and the
    /// tally stay beside the cluster rather than going out to the window's
    /// edges: at 1920 pt they sat some 550 pt from the controls they describe.
    public static let sideCaptionWidth: CGFloat = 260

    /// The leading caption's box — `04330 · burst 3` over `the cull: maybe —
    /// the face is softer than most here` — ending 16 pt before the cluster.
    /// Its text is set against that end, 16 pt from Undo, as the tally's is
    /// 16 pt from Next Burst, so the two stand the same way either side of
    /// the controls they describe.
    public var leadingCaption: CGRect {
        let end = origin - Tokens.Metric.groupGap
        let width = max(0, min(Self.sideCaptionWidth, end - Tokens.Metric.barMargin))
        return CGRect(x: end - width, y: 0, width: width, height: height)
    }

    /// The trailing tally — `Kept 5 · Out 1 · 1 left`, his numbers only —
    /// a group's gap clear of Next Burst, so the two never read as one.
    public var trailingTally: CGRect {
        let x = frame(.nextBurst).maxX + Tokens.Metric.groupGap
        let width = max(0, min(Self.sideCaptionWidth, contentWidth - Tokens.Metric.barMargin - x))
        return CGRect(x: x, y: 0, width: width, height: height)
    }

    /// Every number §2.5.2 fixes, for the layout test and for the bench.
    public var described: [String: CGFloat] {
        [
            "clusterWidth": clusterWidth,
            "dropToKeepClearSpace": dropToKeepClearSpace,
            "dropToKeepCentres": dropToKeepCentres,
            "keepToNextBurstCentres": keepToNextBurstCentres,
            "sideSlack": sideSlack,
        ]
    }
}
