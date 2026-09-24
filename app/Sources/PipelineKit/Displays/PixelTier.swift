import Foundation
import CoreGraphics

/// Point size and backing scale in, the number of pixels to ask the engine for
/// out. Pure, so the whole of DESIGN-displays.md §4.1's table is a unit test.
///
/// Two windows at two sizes are two cache entries and two windows at the same
/// size are one, because `ImagePump.Key` already carries the size — the
/// coalescing is free and needs no new API.
public enum PixelTier {

    /// `DESIGN.md` §3.5's ladder, unchanged. Rounding up to one of these keeps
    /// URLs few and cacheable.
    public static let ladder = ImagePump.fullTiers

    /// The `/large` asset's long edge.
    public static let largePixels = 1440
    /// The `/thumb` asset is 480 px on its long edge. A cell is served the
    /// thumbnail up to 440 device pixels and `/large` above that, so a cell is
    /// never drawn from an asset at its own exact size — that is where rounding
    /// costs the one thing a contact sheet is for.
    public static let thumbPixels = 440

    /// The device pixels a picture of `w` points wants, rounded **up** to the
    /// next rung and capped at the top of the ladder.
    ///
    /// On his external filling the screen the picture is 2076 pt at 2×, so
    /// 4152 device pixels are wanted and 4096 are asked for: drawn 1.4 % large,
    /// which is invisible on a fitted view, and 1:1 does not come through here
    /// at all (§4.6).
    public static func px(forPointWidth w: CGFloat, scale: CGFloat) -> Int {
        let need = Int((w * max(scale, 1)).rounded(.up))
        return ladder.first(where: { $0 >= need }) ?? (ladder.last ?? 4096)
    }

    /// The same, from a whole picture box rather than a width.
    public static func px(forPoints points: CGSize, scale: CGFloat) -> Int {
        px(forPointWidth: max(points.width, points.height), scale: scale)
    }

    /// What a contact-sheet cell or a filmstrip cell should be served.
    public static func cellTier(forPointWidth w: CGFloat, scale: CGFloat) -> ImagePump.Tier {
        let need = Int((w * max(scale, 1)).rounded(.up))
        if need <= thumbPixels { return .thumb }
        if need <= largePixels { return .large }
        return .full(px: px(forPointWidth: w, scale: scale))
    }

    // MARK: - 1:1 (§4.6)

    /// How much bigger than the viewport a 1:1 tile is cut, so small pans are
    /// local GPU work rather than a fresh cut.
    public static let overscan = TileFetcher.overscan

    /// Past this share of the frame's width, a tile is no longer a tile: ask
    /// for the frame's whole width once and pan on the GPU.
    public static let wholeFrameThreshold: Double = 0.8

    /// One fetch or a re-cut on every pan, and never a scaled picture at 1:1.
    ///
    /// - `viewportDevice` is the **viewer box** in device pixels, not the
    ///   fitted picture: at 1:1 on his 5K that is 5056 × 2768, 84 % of the
    ///   frame's whole width.
    /// - `frameNative` is the frame's own pixels (6024 × 4024 off the a6500).
    /// - `aim` is normalised, the point he is holding across the burst.
    public static func request(viewportDevice: CGSize,
                               frameNative: CGSize,
                               aim: CGPoint,
                               budget: any TileBudgeting,
                               clamp: any CropClamping = DisplayLimits.crop) -> TileRequest {
        guard viewportDevice.width > 0, frameNative.width > 0 else {
            return .trueSizeCentred(px: max(256, Int(viewportDevice.width)))
        }
        let aspect = viewportDevice.height / max(1, viewportDevice.width)
        let wanted = Int((Double(viewportDevice.width) * overscan).rounded(.up))

        // The whole-frame rule, and the budget that has to afford it: the
        // current frame and the next two.
        if Double(wanted) >= wholeFrameThreshold * Double(frameNative.width) {
            let wholeWidth = min(Int(frameNative.width.rounded()), clamp.maximumCropPixels)
            let cost = wholeWidth * Int((Double(wholeWidth) * Double(aspect)).rounded()) * 4
            if cost > 0, budget.tileBytes >= cost * 3 {
                return .wholeFrame(px: wholeWidth)
            }
            // A Mac that cannot hold three of them keeps ordinary tiles at
            // 4096 and falls to rule 3 below.
            let px = min(wanted, PixelTier.ladder.last ?? 4096)
            return finish(px: px, viewportDevice: viewportDevice, aim: aim, aspect: aspect)
        }

        let px = min(wanted, clamp.maximumCropPixels)
        return finish(px: px, viewportDevice: viewportDevice, aim: aim, aspect: aspect)
    }

    private static func finish(px: Int, viewportDevice: CGSize, aim: CGPoint,
                               aspect: CGFloat) -> TileRequest {
        // Rule 3: if the affordable cut is narrower than the viewport, he sees
        // less of the frame rather than a softer frame. 1:1 exists to answer
        // one question and a 0.81 : 1 picture answers it wrong.
        if Double(px) < Double(viewportDevice.width) {
            return .trueSizeCentred(px: px)
        }
        return .crop(cx: Double(aim.x), cy: Double(aim.y), px: px, ar: Double(aspect))
    }
}

/// What the app asks for when he is at 1:1.
public enum TileRequest: Equatable, Sendable {
    /// An ordinary `/crop` around the aim.
    case crop(cx: Double, cy: Double, px: Int, ar: Double)
    /// The frame's full width at the viewport's aspect, in one request,
    /// panned locally (§4.6-1).
    case wholeFrame(px: Int)
    /// The budget cannot cover the viewport: the picture is drawn at true
    /// size, centred, with the surround around it (§4.6-3).
    case trueSizeCentred(px: Int)

    /// The pixels this request asks the engine for.
    public var pixels: Int {
        switch self {
        case .crop(_, _, let px, _): return px
        case .wholeFrame(let px): return px
        case .trueSizeCentred(let px): return px
        }
    }

    /// True when the picture will be drawn at one source pixel per device
    /// pixel. Every branch here does; a branch that did not would be a lie
    /// about what 1:1 means.
    public var isTruePixels: Bool { true }
}

// MARK: - the two numbers that are changing underneath us

/// How much decoded picture the app may hold.
///
/// `DESIGN.md` §3.5's caps are counts, and a count stops working the moment two
/// windows ask for sizes that differ by 4× in area: eight 4096 px tiles at 3:2
/// are 358 MB and eight whole-width tiles on a 5K are 631 MB, and a count
/// cannot tell the two apart (§4.5, §8-2). Until `Images/Budget.swift` grows
/// the byte cap, this protocol has the two implementations and the switch is
/// one line in `DisplayLimits`.
public protocol TileBudgeting: Sendable {
    /// Bytes of decoded 1:1 tiles the app may hold at once.
    var tileBytes: Int { get }
    /// The picture window's own decoded ring: the frame he is on and one in
    /// each direction.
    var secondaryDecodedCount: Int { get }
}

/// Today: the foundation's `Budget` counts tiles, so the byte figure is
/// derived from the count at the size a tile is actually cut.
public struct CountedTileBudget: TileBudgeting {
    public let budget: ImagePump.Budget
    /// The size a tile is cut at today, for turning a count into bytes.
    public let assumedTilePixels: Int

    public init(_ budget: ImagePump.Budget = .automatic, assumedTilePixels: Int = 4096) {
        self.budget = budget
        self.assumedTilePixels = assumedTilePixels
    }

    public var tileBytes: Int {
        let h = Int((Double(assumedTilePixels) * 2.0 / 3.0).rounded())
        return budget.tileCount * assumedTilePixels * h * 4
    }
    public var secondaryDecodedCount: Int { 3 }
}

/// §4.5, once the byte cap lands: `clamp(physicalMemory / 64, 96 MB, 512 MB)`.
///
/// On a 48 GB Mac that is 512 MB — six whole-width tiles. On a 16 GB Mac it is
/// 256 MB, three of them: the current frame and the next two, which is exactly
/// `DESIGN.md` §3.5's 1:1 prefetch.
public struct ByteTileBudget: TileBudgeting {
    public let tileBytes: Int
    public let secondaryDecodedCount: Int

    public init(tileBytes: Int, secondaryDecodedCount: Int = 3) {
        self.tileBytes = tileBytes
        self.secondaryDecodedCount = secondaryDecodedCount
    }

    public static func scaled(forPhysicalMemory bytes: UInt64) -> ByteTileBudget {
        let want = Int(bytes / 64)
        return ByteTileBudget(tileBytes: min(512 << 20, max(96 << 20, want)))
    }

    public static let automatic = scaled(forPhysicalMemory: ProcessInfo.processInfo.physicalMemory)

    /// Memory pressure drops the far screen before the near one: the window he
    /// is pressing keys against is the last thing degraded (§4.5).
    public var underPressure: ByteTileBudget {
        ByteTileBudget(tileBytes: min(tileBytes, 96 << 20), secondaryDecodedCount: 1)
    }
}

/// The largest cut `/crop` will hand out.
///
/// A 1:1 viewport on his external is 5056 device pixels wide and the laptop's
/// own 1.6× tile at 14" full screen is 4787 — both over the 4096 the engine is
/// being raised to. §4.6-2 asks for 6144, which also covers the a6500's own
/// 6000 px long edge so the whole-frame case is served by the same route.
public protocol CropClamping: Sendable {
    var maximumCropPixels: Int { get }
}

public struct ServerCropClamp: CropClamping {
    public let maximumCropPixels: Int
    public init(_ px: Int) { maximumCropPixels = px }

    /// What the engine in this checkout clamps to.
    public static let asShipped = ServerCropClamp(TileFetcher.maximumTilePixels)
    /// `DESIGN.md` §3.9-3.
    public static let fourK = ServerCropClamp(TileFetcher.serverClampLanded)
    /// §4.6-2, the one server number this design changes.
    public static let sixK = ServerCropClamp(6144)
}

/// The two lines that change when the server and the foundation land theirs.
public enum DisplayLimits {
    /// Flip to `.sixK` the day `pipeline/studio.py` clamps `/crop` at 6144.
    public static let crop: any CropClamping = ServerCropClamp.asShipped
    /// Flip to `ByteTileBudget.automatic` the day `Images/Budget.swift` counts
    /// bytes instead of tiles.
    public static let tiles: any TileBudgeting = CountedTileBudget()
}
