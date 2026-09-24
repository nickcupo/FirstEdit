import Foundation

// MARK: - GET /api/instagram, POST /api/instagram/shape

/// The Instagram step's wall, as the engine sees it (DESIGN.md §2.17).
///
/// The record (`<shoot>/instagram/crops.json`) is the engine's; every cut in
/// here is arithmetic on it, done by the same function that makes the copies,
/// so what a tile draws is what is written (§7.14).
public struct InstagramStatus: FieldDecodable, Equatable {
    public let shoot: String
    public let folder: String
    public let folder_exists: Bool
    /// The shape portraits are worked out and made at: "3:4" or "4:5".
    public let ratio: String
    /// "fit" leaves a landscape whole; "crop" cuts the portrait shape out of it.
    public let landscape: String
    public let ratios: [String]
    public let exported: Int
    public let planned: Int
    /// Unplanned and exported-again together: what a planning pass would look at.
    public let unplanned: Int
    public let stale: Int
    public let made: Int
    public let grid_misses: Int
    /// A pass working out this shoot's cuts, while one runs.
    public let planning: InstagramProgress?
    /// A job making this shoot's copies, while one runs.
    public let making: InstagramProgress?
    /// The job of his holding the slot, when there are cuts to work out and
    /// nothing is working them out.
    public let waiting_for: InstagramWaitingFor?
    /// Every exported frame: the grid misses first, then the rest, each in
    /// stem order.
    public let frames: [InstagramFrame]

    public init(fields f: Fields) throws {
        shoot = try f.requireString("shoot")
        folder = f.string("folder")
        folder_exists = f.bool("folder_exists")
        ratio = f.string("ratio", "3:4")
        landscape = f.string("landscape", "fit")
        let r = f.strings("ratios")
        ratios = r.isEmpty ? ["3:4", "4:5"] : r
        exported = f.int("exported")
        planned = f.int("planned")
        unplanned = f.int("unplanned")
        stale = f.int("stale")
        made = f.int("made")
        grid_misses = f.int("grid_misses")
        planning = try f.object("planning").map(InstagramProgress.init(fields:))
        making = try f.object("making").map(InstagramProgress.init(fields:))
        waiting_for = try f.object("waiting_for").map(InstagramWaitingFor.init(fields:))
        _ = try f.require("frames")
        frames = try f.objects("frames").map(InstagramFrame.init(fields:))
    }

    /// For tests and the snapshot harness.
    public init(shoot: String, folder: String = "", folder_exists: Bool = false, ratio: String = "3:4",
                landscape: String = "fit", planning: InstagramProgress? = nil,
                making: InstagramProgress? = nil, waiting_for: InstagramWaitingFor? = nil,
                frames: [InstagramFrame]) {
        self.shoot = shoot; self.folder = folder; self.folder_exists = folder_exists
        self.ratio = ratio; self.landscape = landscape; self.ratios = ["3:4", "4:5"]
        self.planning = planning; self.making = making; self.waiting_for = waiting_for
        self.frames = frames
        exported = frames.count
        planned = frames.filter { $0.state == .planned }.count
        unplanned = frames.filter { $0.state != .planned }.count
        stale = frames.filter { $0.state == .stale }.count
        made = frames.filter { $0.copy != nil }.count
        grid_misses = frames.filter { $0.state == .planned && $0.cut?.grid_ok == false }.count
    }
}

public struct InstagramProgress: FieldDecodable, Equatable {
    public let id: Int
    public let label: String
    public let fraction: Double
    public init(fields f: Fields) throws {
        id = f.int("id")
        label = f.string("label")
        fraction = f.double("fraction")
    }
    public init(id: Int, label: String, fraction: Double) {
        self.id = id; self.label = label; self.fraction = fraction
    }
}

public struct InstagramWaitingFor: FieldDecodable, Equatable {
    public let title: String
    public let kind: String
    public init(fields f: Fields) throws {
        title = try f.requireString("title")
        kind = f.string("kind")
    }
    public init(title: String, kind: String) { self.title = title; self.kind = kind }
}

/// Where a frame's cut stands (DESIGN.md §2.17).
public enum InstagramFrameState: String, Sendable, Equatable {
    /// No record: the planning pass will look at it.
    case unplanned
    /// A record, worked out from the export that is there now.
    case planned
    /// A record, but he exported the photograph again since. The old cut is
    /// drawn faintly and it is not made until it is worked out again.
    case stale
}

/// A window in a frame's own upright pixels.
public struct PixelRect: Equatable, Sendable, Hashable {
    public var x: Int, y: Int, w: Int, h: Int
    public init(_ x: Int, _ y: Int, _ w: Int, _ h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
    init?(_ a: [Int]) {
        guard a.count == 4 else { return nil }
        self.init(a[0], a[1], a[2], a[3])
    }
    public var centre: (x: Double, y: Double) { (Double(x) + Double(w) / 2, Double(y) + Double(h) / 2) }
}

public struct PixelSize: Equatable, Sendable, Hashable {
    public var w: Int, h: Int
    public init(_ w: Int, _ h: Int) { self.w = w; self.h = h }
    init?(_ a: [Int]) {
        guard a.count == 2 else { return nil }
        self.init(a[0], a[1])
    }
    public var aspect: Double { h > 0 ? Double(w) / Double(h) : 1 }
}

/// His own window: its centre as fractions of the frame, and its size as a
/// share of the largest window of that shape the frame can give.
public struct InstagramManual: Equatable, Sendable, Encodable {
    public var cx: Double, cy: Double, scale: Double
    public init(cx: Double, cy: Double, scale: Double) { self.cx = cx; self.cy = cy; self.scale = scale }
    init?(fields f: Fields?) {
        guard let f, f.has("cx"), f.has("cy"), f.has("scale") else { return nil }
        self.init(cx: f.double("cx"), cy: f.double("cy"), scale: f.double("scale"))
    }
}

/// Where the subject is, as fractions of the frame, and the box around the
/// faces kept together when there are any.
public struct InstagramSubject: Equatable, Sendable {
    public let cx: Double, cy: Double
    public let kind: String
    public let faces: [Double]?
    public init(cx: Double, cy: Double, kind: String = "scene", faces: [Double]? = nil) {
        self.cx = cx; self.cy = cy; self.kind = kind; self.faces = faces
    }
    init?(fields f: Fields?) {
        guard let f else { return nil }
        self.init(cx: f.double("cx", 0.5), cy: f.double("cy", 0.5), kind: f.string("kind", "scene"),
                  faces: f.doublesOrNil("faces"))
    }
}

/// One cut: the window in the frame's pixels, the size it is written at, and
/// whether the profile grid keeps the subject.
public struct InstagramCut: Equatable, Sendable {
    /// "3:4", "4:5", or "whole".
    public var shape: String
    public var rect: PixelRect
    public var out: PixelSize
    public var grid_ok: Bool
    /// Area kept over the frame's area.
    public var kept: Double?
    public init(shape: String, rect: PixelRect, out: PixelSize, grid_ok: Bool = true, kept: Double? = nil) {
        self.shape = shape; self.rect = rect; self.out = out; self.grid_ok = grid_ok; self.kept = kept
    }
    init?(fields f: Fields?, shape fallback: String = "") {
        guard let f, let rect = PixelRect(f.ints("rect")) else { return nil }
        self.init(shape: f.string("shape", fallback), rect: rect,
                  out: PixelSize(f.ints("out")) ?? PixelSize(rect.w, rect.h),
                  grid_ok: f.bool("grid_ok", true), kept: f.doubleOrNil("kept"))
    }
}

/// A copy on disk: the size it was written at and when.
public struct InstagramCopy: Equatable, Sendable {
    public let out: PixelSize
    public let at: Int
    public init(out: PixelSize, at: Int) { self.out = out; self.at = at }
    init?(fields f: Fields?) {
        guard let f else { return nil }
        self.init(out: PixelSize(f.ints("out")) ?? PixelSize(0, 0), at: f.int("at"))
    }
}

/// One exported photograph on the wall.
public struct InstagramFrame: FieldDecodable, Identifiable, Equatable {
    public var id: String { stem }
    public let stem: String
    public let file: String
    /// The export's own mtime: the picture's version, for the app's cache.
    public let export_mtime: Int
    public var state: InstagramFrameState
    /// Upright width and height, from the record; nil when unplanned.
    public var frame: PixelSize?
    /// "portrait", "landscape" or "square".
    public var shape: String?
    /// "crop" or "whole".
    public var mode: String?
    /// "run" or "you".
    public var mode_by: String?
    /// His own window, and the frame is being cut.
    public var adjusted: Bool
    public var manual: InstagramManual?
    public var subject: InstagramSubject?
    /// What Make writes now: drawn clearly.
    public var cut: InstagramCut?
    /// The option not taken: drawn faintly.
    public var other: InstagramCut?
    /// The automatic window at the book's shape, ignoring his.
    public var auto: PixelRect?
    /// The frame left whole, as Whole would write it.
    public var whole: InstagramCut?
    public var copy: InstagramCopy?
    /// The copy on disk is exactly the cut shown.
    public var copy_current: Bool

    public init(fields f: Fields) throws {
        stem = try f.requireString("stem")
        file = f.string("file")
        export_mtime = f.int("export_mtime")
        let s = try f.requireString("state")
        guard let st = InstagramFrameState(rawValue: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [StringKey("state")],
                                                    debugDescription: "\(s) is not a state"))
        }
        state = st
        frame = PixelSize(f.ints("frame"))
        shape = f.stringOrNil("shape")
        mode = f.stringOrNil("mode")
        mode_by = f.stringOrNil("mode_by")
        adjusted = f.bool("adjusted")
        manual = InstagramManual(fields: f.object("manual"))
        subject = InstagramSubject(fields: f.object("subject"))
        cut = InstagramCut(fields: f.object("cut"))
        other = InstagramCut(fields: f.object("other"))
        auto = f.object("auto").flatMap { PixelRect($0.ints("rect")) }
        whole = InstagramCut(fields: f.object("whole"), shape: "whole")
        copy = InstagramCopy(fields: f.object("copy"))
        copy_current = f.bool("copy_current")
    }

    public init(stem: String, file: String = "", export_mtime: Int = 0, state: InstagramFrameState,
                frame: PixelSize? = nil, mode: String? = nil, mode_by: String? = nil, adjusted: Bool = false,
                manual: InstagramManual? = nil, subject: InstagramSubject? = nil, cut: InstagramCut? = nil,
                other: InstagramCut? = nil, auto: PixelRect? = nil, whole: InstagramCut? = nil,
                copy: InstagramCopy? = nil, copy_current: Bool = false) {
        self.stem = stem; self.file = file; self.export_mtime = export_mtime; self.state = state
        self.frame = frame
        self.shape = frame.map { $0.h > $0.w ? "portrait" : ($0.w == $0.h ? "square" : "landscape") }
        self.mode = mode; self.mode_by = mode_by; self.adjusted = adjusted; self.manual = manual
        self.subject = subject; self.cut = cut; self.other = other; self.auto = auto; self.whole = whole
        self.copy = copy; self.copy_current = copy_current
    }

    /// Worked out, and from the export that is there now.
    public var isPlanned: Bool { state == .planned && cut != nil && frame != nil }
    /// The profile grid would lose the subject.
    public var gridMiss: Bool { isPlanned && cut?.grid_ok == false }
    public var made: Bool { copy != nil }
    /// A cut he set by hand: his window, or Cut or Whole chosen by him.
    public var his: Bool { adjusted || mode_by == "you" }
    public var isWhole: Bool { mode == "whole" }
}

// MARK: - POST /api/instagram/plan

public struct InstagramPlanAnswer: FieldDecodable, CarriesRefusal {
    public let ok: Bool
    public let planning: Bool
    public let id: Int
    public let already: Bool
    public let nothing: Bool
    public let count: Int
    public let waiting_for: InstagramWaitingFor?
    public let paused: String?
    public let error: String?
    public init(fields f: Fields) throws {
        ok = f.bool("ok")
        planning = f.bool("planning")
        id = f.int("id")
        already = f.bool("already")
        nothing = f.bool("nothing")
        count = f.int("count")
        waiting_for = try f.object("waiting_for").map(InstagramWaitingFor.init(fields:))
        paused = f.stringOrNil("paused")
        error = f.stringOrNil("error")
    }
    public init(planning: Bool, id: Int = 0, already: Bool = false, nothing: Bool = false, count: Int = 0,
                waiting_for: InstagramWaitingFor? = nil, error: String? = nil) {
        ok = error == nil; self.planning = planning; self.id = id; self.already = already
        self.nothing = nothing; self.count = count; self.waiting_for = waiting_for; paused = nil
        self.error = error
    }
}

// MARK: - POST /api/instagram/crop

public struct InstagramCropAnswer: FieldDecodable, CarriesRefusal {
    public let ok: Bool
    public let frame: InstagramFrame?
    public let remade: Bool
    /// "Saved, but the copy could not be made again: …" — the record is saved
    /// and `frame` says so.
    public let error: String?
    public init(fields f: Fields) throws {
        ok = f.bool("ok")
        frame = try f.object("frame").map(InstagramFrame.init(fields:))
        remade = f.bool("remade")
        error = f.stringOrNil("error")
    }
    public init(ok: Bool = true, frame: InstagramFrame?, remade: Bool = false, error: String? = nil) {
        self.ok = ok; self.frame = frame; self.remade = remade; self.error = error
    }
}

// MARK: - what the app sends

/// `/api/instagram/plan`: the shoot, and nothing else.
public struct InstagramPlanBody: Encodable, Sendable, Equatable {
    public let name: String
    public init(name: String) { self.name = name }
}

/// `/api/instagram/make`: exactly the cuts shown.
public struct InstagramMakeBody: Encodable, Sendable, Equatable {
    public let name: String
    public let stems: [String]
    public init(name: String, stems: [String]) { self.name = name; self.stems = stems }
}

/// What a frame's cut was decided from, as undo puts it back: the mode, who
/// chose it, and his window or none.
public struct InstagramCutRecord: Equatable, Sendable, Encodable {
    public let mode: String
    public let mode_by: String
    public let manual: InstagramManual?
    public init(mode: String, mode_by: String, manual: InstagramManual?) {
        self.mode = mode; self.mode_by = mode_by; self.manual = manual
    }

    enum Keys: String, CodingKey { case mode, mode_by, manual }
    /// `manual` is sent as null when there is none: the engine removes his
    /// window when told nothing is there, and an absent key would leave it.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(mode_by, forKey: .mode_by)
        if let manual { try c.encode(manual, forKey: .manual) } else { try c.encodeNil(forKey: .manual) }
    }
}

/// `/api/instagram/crop`.
public struct InstagramCropBody: Encodable, Sendable, Equatable {
    public let name: String
    public let stem: String
    public let mode: String?
    public let manual: InstagramManual?
    public let auto: Bool?
    public let restore: InstagramCutRecord?
    public init(name: String, stem: String, mode: String? = nil, manual: InstagramManual? = nil,
                auto: Bool? = nil, restore: InstagramCutRecord? = nil) {
        self.name = name; self.stem = stem; self.mode = mode; self.manual = manual
        self.auto = auto; self.restore = restore
    }
}

/// `/api/instagram/shape`.
public struct InstagramShapeBody: Encodable, Sendable, Equatable {
    public let name: String
    public let ratio: String?
    public let landscape: String?
    public init(name: String, ratio: String? = nil, landscape: String? = nil) {
        self.name = name; self.ratio = ratio; self.landscape = landscape
    }
}

// MARK: - the window arithmetic

/// The engine's window arithmetic (`instagram.window_of`, `grid_ok`), ported
/// exactly, so the editor draws the window the engine will keep to the pixel
/// (DESIGN.md §2.17, §7.14). Halves round up, as the engine's do.
public enum InstagramWindow {
    public static let wide = 1080
    /// What the profile grid shows of every post: its middle 3:4.
    public static let grid = 3.0 / 4.0
    /// The least his window may be, as the editor lets him drag it.
    public static let leastScale = 0.12

    static func up(_ v: Double) -> Int { Int((v + 0.5).rounded(.down)) }
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    /// "3:4" → 0.75.
    public static func want(_ ratio: String) -> Double {
        let parts = ratio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return 0.75 }
        return parts[0] / parts[1]
    }

    /// The other portrait shape.
    public static func other(_ ratio: String) -> String { ratio == "4:5" ? "3:4" : "4:5" }

    public static func windowOf(w: Int, h: Int, want: Double, cx: Double, cy: Double, scale: Double) -> PixelRect {
        let W = Double(w), H = Double(h)
        let big = min(W, H * want)
        let cw = min(w, max(16, up(big * clamp(scale, 0.05, 1))))
        let ch = min(h, up(Double(cw) / want))
        let x = up(clamp(cx * W - Double(cw) / 2, 0, Double(w - cw)))
        let y = up(clamp(cy * H - Double(ch) / 2, 0, Double(h - ch)))
        return PixelRect(x, y, cw, ch)
    }

    public static func windowOf(_ size: PixelSize, want: Double, _ m: InstagramManual) -> PixelRect {
        windowOf(w: size.w, h: size.h, want: want, cx: m.cx, cy: m.cy, scale: m.scale)
    }

    /// The window a rectangle is, as his fractions.
    public static func fromRect(_ r: PixelRect, w: Int, h: Int, want: Double) -> InstagramManual {
        let big = min(Double(w), Double(h) * want)
        return InstagramManual(cx: (Double(r.x) + Double(r.w) / 2) / Double(w),
                               cy: (Double(r.y) + Double(r.h) / 2) / Double(h),
                               scale: big > 0 ? Double(r.w) / big : 1)
    }

    /// As the engine keeps it: centre 0–1, size 0.05–1, five places.
    public static func kept(_ m: InstagramManual) -> InstagramManual {
        func r5(_ v: Double) -> Double { (v * 100_000).rounded() / 100_000 }
        return InstagramManual(cx: r5(clamp(m.cx, 0, 1)), cy: r5(clamp(m.cy, 0, 1)),
                               scale: r5(clamp(m.scale, 0.05, 1)))
    }

    public static func outSize(want: Double) -> PixelSize { PixelSize(wide, Int((Double(wide) / want).rounded())) }

    /// Whether the subject is inside what the profile grid shows of a post
    /// cut to `r` and written at `out`.
    public static func gridOK(subject s: InstagramSubject, frame: PixelSize, rect r: PixelRect, out: PixelSize) -> Bool {
        guard r.w > 0, r.h > 0, out.h > 0 else { return true }
        let sx = (s.cx * Double(frame.w) - Double(r.x)) / Double(r.w)
        let sy = (s.cy * Double(frame.h) - Double(r.y)) / Double(r.h)
        let ratio = Double(out.w) / Double(out.h)
        if ratio > grid {
            let half = grid / ratio / 2
            return 0.5 - half <= sx && sx <= 0.5 + half
        }
        let half = ratio / grid / 2
        return 0.5 - half <= sy && sy <= 0.5 + half
    }

    /// The middle strip the profile grid shows, as fractions of the cut's
    /// width, when the post is wider than the grid: nil when it shows it all.
    public static func gridStrip(out: PixelSize) -> ClosedRange<Double>? {
        let ratio = out.aspect
        guard ratio > grid + 0.0001 else { return nil }
        let f = grid / ratio
        return (1 - f) / 2 ... (1 + f) / 2
    }

    /// Area kept over the frame's, to three places, as the engine says it.
    public static func kept(_ r: PixelRect, of frame: PixelSize) -> Double {
        guard frame.w > 0, frame.h > 0 else { return 0 }
        return (Double(r.w * r.h) / Double(frame.w * frame.h) * 1000).rounded() / 1000
    }
}
