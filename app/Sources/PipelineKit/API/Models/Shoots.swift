import Foundation

// MARK: - GET /api/shoots

public struct ShootsResponse: FieldDecodable {
    public let shoots: [ShootRow]
    public let cards: [String]
    public let ext: ExtConfig?
    public let ready: Bool
    public let app: Bool
    public let update: UpdateInfo

    /// Only the rows that parsed, in the order the engine sent them.
    public var ok: [ShootRowOK] { shoots.compactMap { if case .ok(let r) = $0 { return r } else { return nil } } }
    /// And the ones that did not. One damaged decisions file costs one row.
    public var broken: [ShootRowBroken] { shoots.compactMap { if case .broken(let r) = $0 { return r } else { return nil } } }

    public init(fields f: Fields) throws {
        shoots = try f.objects("shoots").map(ShootRow.init(fields:))
        cards = f.strings("cards")
        ext = try f.object("ext").map(ExtConfig.init(fields:))
        ready = f.bool("ready")
        app = f.bool("app")
        update = try UpdateInfo(fields: f.object("update") ?? Fields([:]))
    }
}

/// Discriminated on `broken`, which the engine puts on a row it could not
/// build. The row still carries its name, because a shoot missing from the
/// list is a shoot he cannot open to repair.
public enum ShootRow: FieldDecodable {
    case ok(ShootRowOK)
    case broken(ShootRowBroken)

    public var name: String {
        switch self {
        case .ok(let r): return r.name
        case .broken(let r): return r.name
        }
    }

    public init(fields f: Fields) throws {
        if f.stringOrNil("broken")?.isEmpty == false {
            self = .broken(try ShootRowBroken(fields: f))
        } else {
            self = .ok(try ShootRowOK(fields: f))
        }
    }
}

public struct ShootRowOK: FieldDecodable, Identifiable {
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
    /// **His**: the frames he said yes to, by pressing K or by walking a
    /// burst and leaving the cull's choice standing. This is the only number
    /// the app ever prints as his, and it is never added to another.
    public let kept: Int
    public let dropped: Int
    /// The frames every keeper check measures against, from the file the
    /// checks read. The same count as `keepers` on today's engine and named
    /// separately so the page cannot drift from the check (§3.9).
    public let recorded_keepers: Int?
    /// What gets a sidecar: his override where he pressed one, else the
    /// cull's. Nobody's opinion on its own, and never shown as his.
    public let will_be_edited: Int?
    /// Frames he walked past inside a burst he has been through and left as
    /// the cull had them. Its own number; never added to `kept`.
    public let agreed: Int?
    public let bursts: Int
    public let seen: Int
    public let card: String
    public let style: String
    public let editor: String
    public let export_where: String
    public let at: String
    public let review_stale: String
    public let verify: String
    public let presets_note: String
    public let focus: Double
    public let frames: Int
    public let raws: Int
    public let sidecars: Int
    public let reels: Int
    public let presets: Int
    public let exported: Int
    public let sidecar_kinds: [String: Int]
    public let reel_dir: String
    public let ingest: IngestNote
    /// Earlier cards copied into this shoot, before the one `ingest` is about.
    public let earlier_copies: [EarlierCopy]
    public let storage: StorageHome?
    /// DESIGN.md §3.9-5. Absent from the engine today, and absent means "yes,
    /// as far as anyone here knows" — the Reels step is hidden only when the
    /// engine says outright that it cannot encode.
    public let can_cut_reels: Bool
    /// The shoot's steps as its own page gets them, done or not (§2.1, "Up
    /// to"): the engine's one table, never worked out here. `nil` from an
    /// engine older than the field.
    public let steps: [StepState]?
    /// Whatever the extension added. Never read by name in this repository.
    public let extra: [String: JSONValue]

    static let known: Set<String> = [
        "name", "path", "raw", "export", "kind", "reviewed", "culled", "raws_cleared", "finished",
        "thumbs", "keepers", "picks", "cull_picks", "kept", "dropped", "bursts", "seen", "card",
        "style", "editor", "export_where", "at", "review_stale", "verify", "presets_note", "focus",
        "recorded_keepers", "will_be_edited", "agreed",
        "frames", "raws", "sidecars", "reels", "presets", "exported", "sidecar_kinds", "reel_dir",
        "ingest", "storage", "can_cut_reels", "broken", "steps",
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
        recorded_keepers = f.intOrNil("recorded_keepers")
        will_be_edited = f.intOrNil("will_be_edited")
        agreed = f.intOrNil("agreed")
        bursts = f.int("bursts")
        seen = f.int("seen")
        card = f.string("card")
        style = f.string("style", "normal")
        editor = f.string("editor")
        export_where = f.string("export_where")
        at = f.string("at")
        review_stale = f.string("review_stale")
        verify = f.string("verify")
        presets_note = f.string("presets_note")
        focus = f.double("focus")
        frames = f.int("frames")
        raws = f.int("raws")
        sidecars = f.int("sidecars")
        reels = f.int("reels")
        presets = f.int("presets")
        exported = f.int("exported")
        sidecar_kinds = f.counts("sidecar_kinds")
        reel_dir = f.string("reel_dir")
        ingest = try IngestNote(fields: f.object("ingest") ?? Fields([:]))
        earlier_copies = EarlierCopy.list(f.object("ingest"))
        storage = try f.object("storage").map(StorageHome.init(fields:))
        can_cut_reels = f.bool("can_cut_reels", true)
        steps = f.has("steps") ? try f.objects("steps").map(StepState.init(fields:)) : nil
        extra = f.extra(without: Self.known)
    }
}

public struct ShootRowBroken: FieldDecodable, Identifiable {
    public var id: String { name }
    public let name: String
    public let path: String
    /// The engine's own sentence about what will not read. Printed as written.
    public let broken: String
    public let broken_where: String
    public let broken_file: String?
    public let frames: Int

    public init(fields f: Fields) throws {
        name = try f.requireString("name")
        path = f.string("path")
        broken = try f.requireString("broken")
        broken_where = f.string("broken_where")
        broken_file = f.stringOrNil("broken_file")
        frames = f.int("frames")
    }
}

/// Where a shoot's photographs are, on the row, before anything is opened.
public struct StorageHome: FieldDecodable {
    public let frames: Int
    public let phrase: String
    public let cells: [StorageCell]
    public let bad: Bool
    public let lost: Int?
    public let error: String?
    /// What the shoot holds on this disk, and the engine's words for it.
    /// Absent from an engine older than the field.
    public let bytes_here: Int?
    public let bytes_here_text: String

    public init(fields f: Fields) throws {
        frames = f.int("frames")
        phrase = f.string("phrase")
        cells = f.strings("cells").map { StorageCell(rawValue: $0) ?? .none }
        bad = f.bool("bad")
        lost = f.intOrNil("lost")
        error = f.stringOrNil("error")
        bytes_here = f.intOrNil("bytes_here")
        bytes_here_text = f.string("bytes_here_text")
    }
}

/// Always two, always this Mac then iCloud.
public enum StorageCell: String, Sendable, Codable, CaseIterable {
    case full, hollow, none, gone, some
}

// MARK: - the extension's own configuration

/// Everything here is text the extension wrote, fetched at runtime. Not one of
/// these strings is compiled into this app, put in the string catalog or
/// written into a fixture: DESIGN.md §2.16.
public struct ExtConfig: FieldDecodable {
    public let kind: String
    public let ask: ExtAsk
    public let steps: [String]
    public let labels: [String: String]
    public let every: [String]
    /// DESIGN.md §3.9-9: step id → URL template. Empty until the extension
    /// serves a whole page per step.
    public let pages: [String: String]

    public init(fields f: Fields) throws {
        kind = f.string("kind")
        ask = try ExtAsk(fields: f.object("ask") ?? Fields([:]))
        steps = f.strings("steps")
        labels = f.words("labels")
        every = f.strings("every")
        pages = f.words("pages")
    }

    /// Two crews wrote this model; the extension-host crew's copy also built
    /// one by hand, which is how its tests name a configuration no engine sent.
    public init(kind: String, ask: ExtAsk = .empty, steps: [String] = [],
                labels: [String: String] = [:], every: [String] = [],
                pages: [String: String] = [:]) {
        self.kind = kind; self.ask = ask; self.steps = steps
        self.labels = labels; self.every = every; self.pages = pages
    }
}

public struct ExtAsk: Sendable {
    public let question, yes, no, blurb, badge, other_badge: String
    public init(fields f: Fields) throws {
        question = f.string("question")
        yes = f.string("yes")
        no = f.string("no")
        blurb = f.string("blurb")
        badge = f.string("badge")
        other_badge = f.string("other_badge")
    }

    public init(question: String = "", yes: String = "", no: String = "", blurb: String = "",
                badge: String = "", other_badge: String = "") {
        self.question = question; self.yes = yes; self.no = no
        self.blurb = blurb; self.badge = badge; self.other_badge = other_badge
    }

    /// An extension that declares no question of its own.
    public static let empty = ExtAsk()
}

// MARK: - GET /api/update

public struct UpdateInfo: FieldDecodable {
    public let newer: Bool?
    public let current: String
    public let latest: String?
    public let url: String?
    public let page: String?
    public let installed: Bool?
    public let staged: Bool
    /// Today this is a raw Python decoder string on a failure (NAT-15). The
    /// app prints whatever is here and never invents a sentence of its own;
    /// making it plain is the engine crew's, DESIGN.md §3.9-13.
    public let error: String?

    public init(fields f: Fields) throws {
        newer = f["newer"]?.boolValue
        current = f.string("current")
        latest = f.stringOrNil("latest")
        url = f.stringOrNil("url")
        page = f.stringOrNil("page")
        installed = f["installed"]?.boolValue
        staged = f.bool("staged")
        error = f.stringOrNil("error")
    }
}

extension UpdateInfo: CarriesRefusal {}

// MARK: - GET /api/cards

public struct CardsResponse: FieldDecodable {
    public let cards: [String]
    /// What is on each card, as the engine read it off the card. Empty from
    /// an engine that only lists the paths.
    public let described: [CardContents]
    public init(fields f: Fields) throws {
        cards = f.strings("cards")
        described = try f.objects("described").map(CardContents.init(fields:))
    }
}

/// One card, counted off the card: its photographs, and the shoot in this
/// library whose raw/ already holds them by name, size and time — never by
/// the name the card mounts as, which is "Untitled" on every card his camera
/// formats.
public struct CardContents: FieldDecodable, Equatable, Sendable {
    public let path: String
    public let photographs: Int
    public let bytes: Int
    public let copiedAs: String
    public let held: Int
    /// The copy into `copiedAs` stopped part way, by its own log.
    public let stopped: Bool
    /// A copy into `copiedAs` is running now or waiting on the list, so what
    /// it holds so far is not where it stopped.
    public let copying: Bool

    public init(fields f: Fields) throws {
        path = f.string("path")
        photographs = f.int("photographs")
        bytes = f.int("bytes")
        copiedAs = f.string("copied_as")
        held = f.int("held")
        stopped = f.bool("stopped")
        copying = f.bool("copying")
    }
}
