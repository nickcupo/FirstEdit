import Foundation
import CoreGraphics

/// What the second screen is showing. One value, computed from the light
/// table, so the picture window holds no decision of his and can vanish
/// mid-burst without costing him a frame.
public enum BigPictureContent: Equatable, Sendable {
    /// Nothing to show: a shoot open on another step, or no shoot at all.
    /// The line fades out after a minute and any change brings it back — a
    /// line sitting on a panel for three hours is not something a photo app
    /// should do to a display (§1.5).
    case nothing(line: String?)
    case frame(stem: String, caption: FrameCaption, zoom: ZoomState)
    /// Compare, and the review Compare the learning screen opens (§5.3).
    case tiles([CompareTile], focus: Int, zoom: ZoomState)
    /// The Whole Burst: every frame in shutter order, nothing hidden.
    case burst(id: String, cells: [BurstCell], cursor: Int)
    /// A job running with no photograph to show. The engine's own stage
    /// words, verbatim.
    case job(title: String, stage: String, fraction: Double)
    case engineDown(sentence: String)

    /// The frame this content is *about*, for prefetch and the display report.
    public var stem: String? {
        switch self {
        case .frame(let stem, _, _): return stem
        case .tiles(let t, let focus, _): return t.indices.contains(focus) ? t[focus].stem : t.first?.stem
        case .burst(_, let cells, let cursor): return cells.indices.contains(cursor) ? cells[cursor].stem : nil
        case .nothing, .job, .engineDown: return nil
        }
    }

    /// Every frame this content draws, in drawing order.
    public var stems: [String] {
        switch self {
        case .frame(let stem, _, _): return [stem]
        case .tiles(let t, _, _): return t.map(\.stem)
        case .burst(_, let cells, _): return cells.map(\.stem)
        case .nothing, .job, .engineDown: return []
        }
    }

    public var caption: FrameCaption? {
        switch self {
        case .frame(_, let c, _): return c
        case .tiles(let t, let focus, _): return t.indices.contains(focus) ? t[focus].caption : nil
        case .nothing, .burst, .job, .engineDown: return nil
        }
    }
}

/// Anything that has frames to show large (§5.3): the light table, the
/// extension's grids, the reels grid, the learning screen's review.
@MainActor
public protocol BigPictureSource: AnyObject {
    var shoot: String { get }
    var content: BigPictureContent { get }
}

/// Where a `present(_:from:)` came from, so the director can tell his own
/// light table from a page asking for a look.
public enum BigPictureOrigin: String, Sendable, Equatable {
    case lightTable, extensionPage, reels, review
}

// MARK: - what the HUD says

/// One frame's caption. His verdict and the cull's line are separate fields
/// and neither ever falls back to the other.
public struct FrameCaption: Equatable, Sendable {
    public let shoot: String
    /// "04330" — the number he reads off the camera.
    public let shortStem: String
    /// 1-based, the way the HUD says it: "2 of 7 in burst 3".
    public let indexInBurst: Int
    public let framesInBurst: Int
    public let burstNumber: Int
    public let burstsInShoot: Int
    /// His press. Never the cull's rating.
    public let his: VerdictValue.His
    /// The cull's own sentence, carried only when Settings ▸ Choosing has it
    /// turned on for this screen. It is off by default: the machine's words
    /// live where his controls are (`DESIGN.md` principle 4).
    public let cullsLine: String?
    /// The frame's own shape, width over height. The badge is placed against
    /// the photograph's edge, so the window has to know where that edge is
    /// before the picture has finished arriving.
    public let aspect: Double

    public init(shoot: String, shortStem: String, indexInBurst: Int, framesInBurst: Int,
                burstNumber: Int, burstsInShoot: Int, his: VerdictValue.His,
                cullsLine: String? = nil, aspect: Double = 3.0 / 2.0) {
        self.shoot = shoot
        self.shortStem = shortStem
        self.indexInBurst = indexInBurst
        self.framesInBurst = framesInBurst
        self.burstNumber = burstNumber
        self.burstsInShoot = burstsInShoot
        self.his = his
        self.cullsLine = cullsLine
        self.aspect = aspect
    }

    /// "04330 · 2 of 7 in burst 3"
    public var line: String {
        "\(shortStem) · \(DisplayStrings.Picture.positionInBurst(indexInBurst, framesInBurst, burstNumber))"
    }

    /// "✓ you kept this", or nothing at all when he has not marked it.
    public var verdictPhrase: String? {
        switch his {
        case .kept: return DisplayStrings.Picture.youKeptThis
        case .out: return DisplayStrings.Picture.youPutThisOut
        case .unmarked: return nil
        }
    }

    /// How far through the burst he is: the bottom hairline's filled share.
    public var burstFraction: Double {
        guard framesInBurst > 0 else { return 0 }
        return Double(indexInBurst) / Double(framesInBurst)
    }

    /// The window's native two-line title.
    public var windowSubtitle: String { "Burst \(burstNumber) of \(burstsInShoot)" }
}

/// Zoom and aim, shared between the two windows. One `ZoomState` drives both
/// and each renders it at its own pixel size — two independent zoom levels
/// would mean two answers to "am I at 1:1", and §2.5.7's whole design only
/// works if there is one aim.
public struct ZoomState: Equatable, Sendable {
    /// 1 is Fit. 1:1 is not a number here; it is `isOneToOne`, because the
    /// scale that means 1:1 depends on the window.
    public var scale: Double
    /// Normalised, in the frame's own coordinates: the point held across a
    /// burst, usually the face.
    public var aim: CGPoint
    public var isOneToOne: Bool

    public init(scale: Double = 1, aim: CGPoint = CGPoint(x: 0.5, y: 0.5), isOneToOne: Bool = false) {
        self.scale = scale
        self.aim = aim
        self.isOneToOne = isOneToOne
    }

    public static let fit = ZoomState()
    public var isFit: Bool { !isOneToOne && abs(scale - 1) < 0.001 }
}

public struct CompareTile: Equatable, Sendable, Identifiable {
    public var id: String { stem }
    public let stem: String
    public let caption: FrameCaption
    /// Width over height. The tile is drawn at the frame's own shape, so the
    /// focus ring hugs the photograph and the caption sits under it rather than
    /// at the bottom of a column of surround.
    public let aspect: Double

    public init(stem: String, caption: FrameCaption, aspect: Double = 3.0 / 2.0) {
        self.stem = stem
        self.caption = caption
        self.aspect = aspect
    }
}

/// The cull's mark on a frame. Hollow, grey, and never in the same field as
/// his (`DESIGN.md` principle 4).
public enum CullMark: String, Sendable, Equatable {
    case none, forward, aside, fault
}

public struct BurstCell: Equatable, Sendable, Identifiable {
    public var id: String { stem }
    public let stem: String
    public let shortStem: String
    /// His press, filled.
    public let his: VerdictValue.His
    /// The machine's, hollow.
    public let cull: CullMark
    /// The stack this frame is in, and whether the cull guessed it the best
    /// of that stack — drawn as the bracket §2.5.9 draws.
    public let stack: String?
    public let isStackTop: Bool

    public init(stem: String, shortStem: String, his: VerdictValue.His, cull: CullMark,
                stack: String? = nil, isStackTop: Bool = false) {
        self.stem = stem
        self.shortStem = shortStem
        self.his = his
        self.cull = cull
        self.stack = stack
        self.isStackTop = isStackTop
    }
}

// MARK: - the light table, as the second screen needs to see it

/// What the director reads off the light table. The light table's own
/// `ViewerModel` conforms to this in one extension and changes no behaviour;
/// until it exists, everything here is driven by the fixtures and the tests.
///
/// It is read-only on purpose. The second screen holds no decision of his, so
/// there is nothing here that writes.
@MainActor
public protocol LightTable: AnyObject {
    var shoot: String { get }
    var lightTableMode: LightTableMode { get }
    var currentStem: String? { get }
    var currentCaption: FrameCaption? { get }
    var zoomState: ZoomState { get }
    var compareTiles: [CompareTile] { get }
    var compareFocus: Int { get }
    /// The burst he is in — every frame, in shutter order, nothing hidden.
    var burstIdentifier: String { get }
    var burstCells: [BurstCell] { get }
    var cursorInBurst: Int { get }
}

public enum LightTableMode: String, Sendable, Equatable, CaseIterable {
    case single, compare, allBursts
}

/// The actions Presentation has an opinion about. The light table asks
/// `DisplayDirector.allows(_:)` before it acts, so the refusal lives in one
/// place rather than in nine.
public enum DisplayAction: String, Sendable, Equatable, CaseIterable {
    case keep, drop, clearMark, reason, keepOnly, undo
    case nextBurst, previousBurst
    case nextFrame, previousFrame
    case compare, singleFrame, allBursts, fullImage, zoom, hold

    /// True for anything that writes, and for N and P — **N records "looked
    /// through"**, as leaving any burst forward does, and a shoot must never come back from
    /// being shown to someone with bursts newly marked as looked through.
    public var decidesSomething: Bool {
        switch self {
        case .keep, .drop, .clearMark, .reason, .keepOnly, .undo, .nextBurst, .previousBurst:
            return true
        case .nextFrame, .previousFrame, .compare, .singleFrame, .allBursts, .fullImage, .zoom, .hold:
            return false
        }
    }
}
