import Foundation

// MARK: - GET /api/shoot?name=&full=&light=

public struct ShootResponse: FieldDecodable {
    public let info: ShootInfo
    public let rows: [Row]
    public let presets: [PresetRun]
    public let review: Review
    /// DESIGN.md §3.9-6. The server groups frames into time bursts; until it
    /// does, this is empty and a `BurstSource` groups client-side.
    public let bursts: [Burst]
    /// DESIGN.md §3.9-7. Empty until the engine sends one done-ness table.
    public let steps: [StepState]
    /// DESIGN.md §3.9-6. `.fresh` with no note until the engine resolves it.
    public let resume: Resume

    public init(fields f: Fields) throws {
        info = try ShootInfo(fields: f.object("info") ?? Fields([:]))
        rows = try f.objects("rows").map(Row.init(fields:))
        presets = try f.objects("presets").map(PresetRun.init(fields:))
        review = try Review(fields: f.object("review") ?? Fields([:]))
        // The one place a burst's frame names are settled. Everything above
        // this line — the rows table, every image route, the filmstrip, the
        // undo log — is keyed on `stem`, and the engine names a burst's
        // members by `file`. See `Burst.namedByStem`.
        bursts = Burst.namedByStem(try f.objects("bursts").map(Burst.init(fields:)), rows: rows)
        steps = try f.objects("steps").map(StepState.init(fields:))
        resume = try Resume(fields: f.object("resume") ?? Fields([:]))
    }
}

public struct ShootLightResponse: FieldDecodable {
    public let info: ShootInfo
    public init(fields f: Fields) throws {
        info = try ShootInfo(fields: f.object("info") ?? Fields([:]))
    }
}

/// `Shoot.info()`, field for field.
///
/// The two authors never share one. `kept` is what he pressed. `cull_picks` is
/// the machine's shortlist. `will_be_edited` is the count that decides what
/// gets a sidecar and is nobody's opinion. Nothing in this app adds two of
/// them together.
public struct ShootInfo: FieldDecodable, Identifiable {
    public var id: String { name }

    public let name: String
    public let path: String
    public let raw: String
    public let export: String
    public let kind: String?
    public let reviewed: Bool
    public let culled: Bool
    public let raws_cleared: Bool
    public let finished: Bool
    public let thumbs: Bool
    public let keepers: Int
    public let picks: Int
    public let cull_picks: Int
    public let kept: Int
    public let dropped: Int
    public let bursts: Int
    public let seen: Int
    /// DESIGN.md §3.9-4. Not on the engine yet; `nil` means "the engine has
    /// not worked this out", which a view says rather than guesses.
    public let will_be_edited: Int?
    /// DESIGN.md §3.9-4: frames with no verdict of his inside a burst he has
    /// been through.
    public let agreed: Int?
    /// The frames every keeper check measures against, from the file the
    /// checks read. The same count as `keepers` on today's engine and named
    /// separately so a page cannot show one number while the check uses
    /// another. Never `kept`, which is his own presses.
    public let recorded_keepers: Int?
    /// Where the recorded keepers came from, in his words, as the engine
    /// recorded them: "the frames you exported", or with the ones he kept.
    public let recorded_from: String
    /// How many frames the cull learns from on this shoot: the ones he
    /// exported, however many he kept (DESIGN.md §2.6, Finish). Nil from an
    /// engine that does not say.
    public let taught: Int?
    /// "exported": the frames he exported, found now, written down at Finish
    /// or recorded by the learning store - never his keepers. Empty when it
    /// teaches nothing. "recorded" comes only from an older engine, whose
    /// fallback taught a shoot's recorded keepers when its exports could not
    /// be found.
    public let taught_from: String
    /// The day the shoot was marked finished, `yyyy-MM-dd`, or empty.
    public let finished_on: String
    public let card: String
    public let style: String
    public let editor: String
    public let export_where: String
    /// The folders inside the shoot that hold its exports, each drawn as a
    /// row with its own Show. Empty from an engine that does not send it.
    public let export_dirs: [String]
    public let at: String
    public let review_stale: String
    public let verify: String
    public let presets_note: String
    /// What the last presets run did, or nil from a run written before the
    /// engine recorded it (then only what is on the disk can be said).
    public let presets_ran: PresetsRan?
    public let reel_dir: String
    /// What the next cull starts from: what he last asked for, written when
    /// a cull starts. Not what the results on screen were culled with — that
    /// is `cull_ran_with`.
    public let focus: Double
    /// The shoot `style` and `focus` were taken from, on a shoot no cull was
    /// asked of yet: his last shoot's settings, not 1.9 and off. Empty when
    /// they are this shoot's own.
    public let cull_from: String
    public let frames: Int
    public let raws: Int
    public let sidecars: Int
    public let reels: Int
    public let presets: Int
    public let exported: Int
    public let sidecar_kinds: [String: Int]
    public let ingest: IngestNote
    /// Earlier cards copied into this shoot, before the one `ingest` is about.
    public let earlier_copies: [EarlierCopy]
    /// DESIGN.md §3.9-5.
    public let can_cut_reels: Bool
    /// What the cull whose results are on disk ran with, as it recorded
    /// them once they were written. Nil on a shoot culled before this was
    /// kept, and then nothing is said: `focus` and `style` name the last cull
    /// asked for, which may be one he stopped, or one that died.
    public let cull_ran_with: CullRun?
    public let extra: [String: JSONValue]

    static let known: Set<String> = [
        "name", "path", "raw", "export", "kind", "reviewed", "culled", "raws_cleared", "finished",
        "thumbs", "keepers", "picks", "cull_picks", "kept", "dropped", "bursts", "seen",
        "will_be_edited", "agreed", "recorded_keepers", "recorded_from", "finished_on", "card", "style", "editor", "export_where", "export_dirs", "at", "review_stale",
        "verify", "presets_note", "presets_ran", "reel_dir", "focus", "frames", "raws", "sidecars", "reels",
        "presets", "exported", "sidecar_kinds", "ingest", "can_cut_reels", "cull_ran_with",
        "taught", "taught_from", "cull_from",
    ]

    public init(fields f: Fields) throws {
        name = try f.requireString("name")
        path = try f.requireString("path")
        raw = f.string("raw")
        export = f.string("export")
        kind = f.stringOrNil("kind")
        reviewed = f.bool("reviewed")
        culled = f.bool("culled")
        raws_cleared = f.bool("raws_cleared")
        finished = f.bool("finished")
        thumbs = f.bool("thumbs")
        keepers = f.int("keepers")
        picks = f.int("picks")
        cull_picks = f.int("cull_picks")
        kept = f.int("kept")
        dropped = f.int("dropped")
        bursts = f.int("bursts")
        seen = f.int("seen")
        will_be_edited = f.intOrNil("will_be_edited")
        agreed = f.intOrNil("agreed")
        recorded_keepers = f.intOrNil("recorded_keepers")
        recorded_from = f.string("recorded_from")
        taught = f.intOrNil("taught")
        taught_from = f.string("taught_from")
        finished_on = f.string("finished_on")
        card = f.string("card")
        style = f.string("style", "normal")
        editor = f.string("editor")
        export_where = f.string("export_where")
        export_dirs = f.strings("export_dirs")
        at = f.string("at")
        review_stale = f.string("review_stale")
        verify = f.string("verify")
        presets_note = f.string("presets_note")
        presets_ran = try f.object("presets_ran").map(PresetsRan.init(fields:))
        reel_dir = f.string("reel_dir")
        focus = f.double("focus")
        cull_from = f.string("cull_from")
        frames = f.int("frames")
        raws = f.int("raws")
        sidecars = f.int("sidecars")
        reels = f.int("reels")
        presets = f.int("presets")
        exported = f.int("exported")
        sidecar_kinds = f.counts("sidecar_kinds")
        ingest = try IngestNote(fields: f.object("ingest") ?? Fields([:]))
        earlier_copies = EarlierCopy.list(f.object("ingest"))
        can_cut_reels = f.bool("can_cut_reels", true)
        cull_ran_with = f.object("cull_ran_with").flatMap(CullRun.init(fields:))
        extra = f.extra(without: Self.known)
    }
}

/// The settings a finished cull ran with, as it recorded them.
public struct CullRun: Equatable, Sendable {
    public let focus: Double
    public let style: String
    public var moving: Bool { style == "action" }

    public init(focus: Double, style: String) {
        self.focus = focus
        self.style = style
    }

    /// Nil when the engine sent no focus: an empty record says nothing.
    init?(fields f: Fields) {
        guard let focus = f.doubleOrNil("focus"), focus > 0 else { return nil }
        self.init(focus: focus, style: f.string("style", "normal"))
    }
}

// MARK: - one frame

/// `ROW_KEEP`, plus the columns that are landing.
///
/// `rating` is the cull's and `override` is his, and this app never merges
/// them, never falls one back to the other and never writes one into the
/// other's field.
public struct Row: FieldDecodable, Identifiable {
    public var id: String { stem }

    public let file: String
    public let stem: String
    /// The cull's own 0/1/2/3/5. The engine reads it out of a CSV, so it
    /// arrives as text and is read back as a number here.
    public let rating: Int
    /// His. Absent when he has not marked this frame. Settable only inside
    /// `PipelineKit`, and only by `ShootSession`, the one writer of verdicts.
    public internal(set) var override: Int?
    public let reason: String?
    public let face_flags: String?
    public let face_score: Double?
    public let quality: Double?
    public let borderline: Double?
    public let focus: Double?
    public let aesthetic: Double?
    public let group: String?
    public let scene: String?
    public let burst: String?
    public let moment: String?
    public let shot_at: String?
    public let face_x: Double?
    public let face_y: Double?
    /// DESIGN.md §3.9-3, not written by the cull yet.
    public let face_w: Double?
    public let face_h: Double?
    /// `[x, y, w, h]`, normalised. §3.9-3.
    public let subject: [Double]?
    /// The in-flight `cull.csv` columns. Absent on today's engine, and absent
    /// means "this frame is in no stack" rather than "stack unknown".
    public let stack: String?
    /// 1 on the cull's guess for a stack.
    public let stack_top: Int?
    /// Why he put it out, in the engine's own label words. Also written
    /// only by `ShootSession`.
    public internal(set) var label: String
    public let edit_note: String
    public let tw: Int?
    public let th: Int?
    public let lw: Int?
    public let lh: Int?
    public let dw: Int?
    public let dh: Int?
    public let extra: [String: JSONValue]

    static let known: Set<String> = [
        "file", "stem", "rating", "override", "reason", "face_flags", "face_score", "quality",
        "borderline", "focus", "aesthetic", "group", "scene", "burst", "moment", "shot_at",
        "face_x", "face_y", "face_w", "face_h", "subject", "stack", "stack_top", "label",
        "edit_note", "tw", "th", "lw", "lh", "dw", "dh",
    ]

    public init(fields f: Fields) throws {
        file = try f.requireString("file")
        // `stem` is added by the engine beside `file`; deriving it here as a
        // fallback keeps a row readable rather than losing the frame.
        stem = f.stringOrNil("stem") ?? String(file.prefix(while: { $0 != "." }))
        rating = f.int("rating")
        override = f.intOrNil("override")
        reason = f.stringOrNil("reason")
        face_flags = f.stringOrNil("face_flags")
        face_score = f.doubleOrNil("face_score")
        quality = f.doubleOrNil("quality")
        borderline = f.doubleOrNil("borderline")
        focus = f.doubleOrNil("focus")
        aesthetic = f.doubleOrNil("aesthetic")
        group = f.stringOrNil("group")
        scene = f.stringOrNil("scene")
        burst = f.stringOrNil("burst")
        moment = f.stringOrNil("moment")
        shot_at = f.stringOrNil("shot_at")
        face_x = f.doubleOrNil("face_x")
        face_y = f.doubleOrNil("face_y")
        face_w = f.doubleOrNil("face_w")
        face_h = f.doubleOrNil("face_h")
        subject = f.doublesOrNil("subject")
        stack = f.stringOrNil("stack")
        stack_top = f.intOrNil("stack_top")
        label = f.string("label")
        edit_note = f.string("edit_note")
        tw = f.intOrNil("tw")
        th = f.intOrNil("th")
        lw = f.intOrNil("lw")
        lh = f.intOrNil("lh")
        dw = f.intOrNil("dw")
        dh = f.intOrNil("dh")
        extra = f.extra(without: Self.known)
    }

    /// The key the engine's review file is written under today, `scene/burst`.
    /// It splits one time burst across several screens (DUP-6) and is replaced
    /// by `Burst.id` the moment §3.9-6 lands; both readers go through here.
    public var legacyBurstKey: String { "\(scene ?? "")/\(burst ?? "")" }

    /// Whether the app has any pixels of this frame at all. A frame with none
    /// can never take a verdict (DESIGN.md §2.5.4).
    public var hasAnyRendering: Bool { (tw ?? 0) > 0 || (lw ?? 0) > 0 || (dw ?? 0) > 0 }
}

// MARK: - the server's own grouping (§3.9-6)

public struct Burst: FieldDecodable, Identifiable {
    /// `TSC07363.ARW` -> `TSC07363`, and anything already a stem is left alone.
    /// Only a known camera or picture suffix is cut, so a shoot whose frames
    /// carry a dot in the name keeps it.
    static let suffixes: Set<String> = ["arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "dng",
                                        "jpg", "jpeg", "heic", "tif", "tiff", "png"]
    public static func stem(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, suffixes.contains(ext) else { return name }
        return (name as NSString).deletingPathExtension
    }

    public let id: String
    public let index: Int
    public let scene: String?
    public let started_at: String?
    public let frames: [String]
    public let cover: String?
    /// Looked through. Only leaving the burst forward records it, never
    /// scrolling past (§7.4).
    public let seen: Bool
    public let kept: Int
    public let out: Int
    public let cull_picks: Int
    public let undecided: Int

    public init(fields f: Fields) throws {
        id = try f.requireString("id")
        index = f.int("index")
        scene = f.stringOrNil("scene")
        started_at = f.stringOrNil("started_at")
        // Stems, whatever the engine called them. Every picture route is
        // /thumb/<shoot>/<stem>.jpg and the session keys its rows by stem, so
        // one engine that sent file names (TSC07363.ARW) made the app ask for
        // TSC07363.ARW.jpg on every frame: 404 each time, and a light table
        // with no photographs in it, on his own library, in the first hour he
        // used it. The engine sends stems now; this makes sure an older or a
        // newer one cannot blank the screen again.
        frames = f.strings("frames").map(Burst.stem)
        cover = f.stringOrNil("cover").map(Burst.stem)
        seen = f.bool("seen")
        kept = f.int("kept")
        out = f.int("out")
        cull_picks = f.int("cull_picks")
        undecided = f.int("undecided")
    }

    public init(id: String, index: Int, scene: String?, started_at: String?, frames: [String],
                cover: String?, seen: Bool, kept: Int, out: Int, cull_picks: Int, undecided: Int) {
        self.id = id; self.index = index; self.scene = scene; self.started_at = started_at
        self.frames = frames; self.cover = cover; self.seen = seen; self.kept = kept
        self.out = out; self.cull_picks = cull_picks; self.undecided = undecided
    }

    /// The same bursts, with every frame named the way the rest of the app
    /// names a frame: by `stem`.
    ///
    /// The engine names a burst's members and its cover by `file` —
    /// `TSC05805.ARW` — because that is the key its own decision files are
    /// written under. Everything above the decoder is keyed on `stem`:
    /// `Row.id`, the rows table `ShootSession` builds, `ImageRoute`, the undo
    /// log, the filmstrip. Carried through as sent, every row lookup missed
    /// and every image request asked the engine for `TSC05805.ARW.jpg`, which
    /// is a 404 — a burst of frames with no rows and no pixels, which is a
    /// light table with no photograph on it. The app's own client-side
    /// grouping (`Fallbacks.legacyBursts`) had always used stems, so this
    /// could only appear once the engine began sending `bursts` of its own,
    /// which no captured fixture had.
    ///
    /// Nothing is invented and nothing is dropped: a name this cannot place
    /// is carried through untouched, so an unfamiliar name costs its frame a
    /// picture and never its place in the burst.
    public static func namedByStem(_ bursts: [Burst], rows: [Row]) -> [Burst] {
        guard !bursts.isEmpty, !rows.isEmpty else { return bursts }
        var stemOfFile: [String: String] = [:]
        var stems = Set<String>()
        for r in rows {
            stemOfFile[r.file] = r.stem
            stems.insert(r.stem)
        }
        func name(_ n: String) -> String {
            if stems.contains(n) { return n }           // already a stem
            if let s = stemOfFile[n] { return s }       // the engine sent `file`
            let dropped = (n as NSString).deletingPathExtension
            return stems.contains(dropped) ? dropped : n
        }
        // Nothing to do when the engine already speaks in stems, which is the
        // day this whole function stops being called on anything.
        guard bursts.contains(where: { b in
            b.frames.contains { !stems.contains($0) } || (b.cover.map { !stems.contains($0) } ?? false)
        }) else { return bursts }
        return bursts.map { b in
            Burst(id: b.id, index: b.index, scene: b.scene, started_at: b.started_at,
                  frames: b.frames.map(name), cover: b.cover.map(name), seen: b.seen,
                  kept: b.kept, out: b.out, cull_picks: b.cull_picks, undecided: b.undecided)
        }
    }
}

// MARK: - one done-ness table (§3.9-7)

public struct StepState: FieldDecodable, Identifiable {
    public let id: String
    public let label: String
    public let done: Bool
    public let enabled: Bool
    /// Shown in the help tag, the VoiceOver hint and the detail pane. A
    /// disabled step that will not say why is a dead end.
    public let why_disabled: String?
    public let source: StepSource

    public init(fields f: Fields) throws {
        id = try f.requireString("id")
        label = f.string("label")
        done = f.bool("done")
        enabled = f.bool("enabled", true)
        why_disabled = f.stringOrNil("why_disabled")
        source = StepSource(rawValue: f.string("source", "base")) ?? .base
    }

    public init(id: String, label: String, done: Bool, enabled: Bool,
                why_disabled: String? = nil, source: StepSource = .base) {
        self.id = id; self.label = label; self.done = done; self.enabled = enabled
        self.why_disabled = why_disabled; self.source = source
    }
}

public enum StepSource: String, Sendable, Codable {
    case base
    case extensionProvided = "extension"
}

// MARK: - where he left off (§3.9-6)

public struct Resume: FieldDecodable {
    public let burst_id: String?
    public let kind: ResumeKind
    /// The engine's own sentence. Printed as written.
    public let note: String

    public init(fields f: Fields) throws {
        burst_id = f.stringOrNil("burst_id")
        kind = ResumeKind(rawValue: f.string("kind", "fresh")) ?? .fresh
        note = f.string("note")
    }

    public init(burst_id: String?, kind: ResumeKind, note: String) {
        self.burst_id = burst_id; self.kind = kind; self.note = note
    }
}

public enum ResumeKind: String, Sendable, Codable {
    case left_off, moved, all_seen, fresh
}

// MARK: - been through

public struct Review: FieldDecodable {
    public let at: String
    public let bursts: [String: ReviewBurst]
    /// Non-empty when the record was written against a cull that has since
    /// been run again. Printed beside every count drawn from it.
    public let stale: String

    public init(fields f: Fields) throws {
        at = f.string("at")
        bursts = try f.objectMap("bursts").mapValues(ReviewBurst.init(fields:))
        stale = f.string("stale")
    }

    public init(at: String, bursts: [String: ReviewBurst], stale: String) {
        self.at = at; self.bursts = bursts; self.stale = stale
    }
}

public struct ReviewBurst: FieldDecodable {
    public let seen: String
    public let from: String?
    public init(fields f: Fields) throws {
        seen = f.string("seen")
        from = f.stringOrNil("from")
    }
    public init(seen: String, from: String?) { self.seen = seen; self.from = from }
}

// MARK: - what the presets step decided

/// The last presets run, in three counts that add up to the frames it was
/// given: written, left alone because he had changed them in his editor, and
/// already carrying its preset. `under` is of the written ones: his own
/// edited frames given the new starting preset under his changes, which only
/// Write Them Again does. The engine reads all four off the run's own log.
public struct PresetsRan: FieldDecodable, Equatable, Sendable {
    public let wrote: Int
    public let changed: Int
    public let already: Int
    public let under: Int
    public init(fields f: Fields) throws {
        wrote = f.int("wrote")
        changed = f.int("changed")
        already = f.int("already")
        under = f.int("under")
    }
}

public struct PresetRun: FieldDecodable {
    public let notes: [String]?
    public let decided: [String: String]?
    /// DESIGN.md §3.9-8: the sidecars a re-write left alone, so "Nothing you
    /// had already changed in PhotoLab was touched" is a fact.
    public let left_alone: [String]?
    /// The rest of what the engine writes per run, kept because the Presets
    /// step names the look it started from and how many frames it covered.
    public let scene: Int?
    public let name: String?
    public let frames: [String]
    public let all: Int?

    public init(fields f: Fields) throws {
        notes = f.has("notes") ? f.strings("notes") : nil
        decided = f.has("decided") ? f.words("decided") : nil
        left_alone = f.has("left_alone") ? f.strings("left_alone") : nil
        scene = f.intOrNil("scene")
        name = f.stringOrNil("name")
        frames = f.strings("frames")
        all = f.intOrNil("all")
    }
}

// MARK: - what the copy itself recorded

/// A card copied into a shoot before its last one, by that copy's own log,
/// which the engine keeps beside the last's (`ingest-1.log`, …): a second
/// camera's card added to the night's shoot.
public struct EarlierCopy: Equatable, Sendable {
    public let files: Int
    public let proof: String
    /// How that copy ended, by its log: "done", "stopped", "failed" or
    /// "unclear". A copy that did not finish keeps saying so under a later
    /// card's, so the shoot never reads as copied while one card of it is
    /// half there.
    public let state: String
    /// For a copy that stopped: how many photographs its card held.
    public let of: Int
    public init(files: Int, proof: String, state: String = "done", of: Int = 0) {
        self.files = files; self.proof = proof; self.state = state; self.of = of
    }

    public var finished: Bool { state == "done" }

    /// The copies of earlier cards, off the note's `earlier`. One without a
    /// state is from an engine that listed only the finished ones.
    static func list(_ note: Fields?) -> [EarlierCopy] {
        (note?.objects("earlier") ?? []).map {
            let state = $0.string("state")
            return EarlierCopy(files: $0.int("files"), proof: $0.string("proof"),
                               state: state.isEmpty ? "done" : state, of: $0.int("of"))
        }
    }
}

/// Decoded on `state`. The ingest summary is built from the copy's own log and
/// never from a listing of the folder (DESIGN.md §2.6), which is why this is
/// the engine's note and not a count the app takes.
public enum IngestNote: FieldDecodable {
    case none
    case failed(detail: String)
    /// Still going: a copy is running into this shoot or waiting on the list.
    /// Its log reads like a stopped one until it ends, so the engine asks the
    /// list rather than the log.
    case copying(files: Int, of: Int)
    case stopped(files: Int, of: Int)
    case done(files: Int, proof: String)
    case unclear(log: String)

    public init(fields f: Fields) throws {
        switch f.string("state") {
        case "failed": self = .failed(detail: f.string("detail"))
        case "copying": self = .copying(files: f.int("files"), of: f.int("of"))
        case "stopped": self = .stopped(files: f.int("files"), of: f.int("of"))
        case "done": self = .done(files: f.int("files"), proof: f.string("proof"))
        case "unclear": self = .unclear(log: f.string("log"))
        default: self = .none
        }
    }
}
