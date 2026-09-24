import Foundation

// Storage: GET /api/storage, /api/storage/frames, /api/storage/plan,
// /api/storage/library.
//
// **The app renders these; it does not recompute them.** Every sentence,
// glyph pair, order and count below is the engine's own, and DESIGN.md §3.9
// says deliberately that they stay server-side because they encode invariants
// the app must not re-derive.

/// GET /api/storage?name=
public struct Storage: FieldDecodable, Hashable {
    public let name: String
    public let archive: StorageArchive
    /// How many frames are in each state, keyed by the engine's state ids.
    public let states: [String: Int]
    /// The order those states are shown in. The app never sorts them itself.
    public let order: [String]
    /// The engine's sentence for each state.
    public let words: [String: String]
    /// The two-cell glyph pair for each state: this Mac, then iCloud.
    public let glyphs: [String: [StorageCell]]
    /// The one line at the top of the panel.
    public let line: String
    public let cache: StorageCache
    public let retain: Retain
    public let icloud: String?
    public let free: Int
    public let free_text: String

    public init(fields f: Fields) throws {
        name = try f.requireString("name")
        archive = StorageArchive(fields: f.object("archive") ?? Fields([:]))
        states = f.counts("states")
        order = f.strings("order")
        words = f.words("words")
        glyphs = (f["glyphs"]?.objectValue ?? [:]).compactMapValues { v in
            (v.arrayValue ?? []).compactMap { $0.stringValue.flatMap(StorageCell.init(rawValue:)) }
        }
        line = f.string("line")
        cache = StorageCache(fields: f.object("cache") ?? Fields([:]))
        retain = Retain(fields: f.object("retain") ?? Fields([:]))
        icloud = f.stringOrNil("icloud")
        free = f.int("free")
        free_text = f.string("free_text")
    }

    /// The states that have at least one frame in them, in the engine's order.
    public var presentStates: [String] { order.filter { (states[$0] ?? 0) > 0 } }
}

public struct StorageArchive: Sendable, Hashable {
    public let frames, here, here_evicted, up, up_evicted, dropped: Int
    public let todo, pullable, droppable, drop_evicted, missing, lost: Int
    public let bytes_here, bytes_up: Int
    public let here_text, up_text, todo_text, pullable_text, droppable_text: String

    init(fields f: Fields) {
        frames = f.int("frames"); here = f.int("here"); here_evicted = f.int("here_evicted")
        up = f.int("up"); up_evicted = f.int("up_evicted"); dropped = f.int("dropped")
        todo = f.int("todo"); pullable = f.int("pullable"); droppable = f.int("droppable")
        drop_evicted = f.int("drop_evicted"); missing = f.int("missing"); lost = f.int("lost")
        bytes_here = f.int("bytes_here"); bytes_up = f.int("bytes_up")
        here_text = f.string("here_text"); up_text = f.string("up_text")
        todo_text = f.string("todo_text"); pullable_text = f.string("pullable_text")
        droppable_text = f.string("droppable_text")
    }
}

public struct StorageCache: Sendable, Hashable {
    public let bytes: Int
    public let bytes_text: String
    public let files: Int
    public let derived_text, rebuildable_text: String
    public let refusals: [String]
    public let last_copy: LastCopy

    init(fields f: Fields) {
        bytes = f.int("bytes"); bytes_text = f.string("bytes_text"); files = f.int("files")
        derived_text = f.string("derived_text"); rebuildable_text = f.string("rebuildable_text")
        refusals = f.strings("refusals")
        last_copy = LastCopy(fields: f.object("last_copy") ?? Fields([:]))
    }
}

/// Renderings that are the last copy of a frame this shoot has no original
/// for. They are counted as originals and are never in a removal list.
public struct LastCopy: Sendable, Hashable {
    public let count: Int
    public let bytes_text: String
    /// DESIGN.md calls it `with`; the engine sends `where`. The engine wins.
    public let with: [String]

    init(fields f: Fields) {
        count = f.int("count")
        bytes_text = f.string("bytes_text")
        with = f.has("where") ? f.strings("where") : f.strings("with")
    }
}

/// The retention lock. It is a lock, not a trigger: nothing on this machine is
/// scheduled by writing it, and all it decides is when the expire button
/// stops refusing.
public struct Retain: Sendable, Hashable {
    public let days: Int
    public let source: String
    /// The library's own number, which new shoots get; `nil` when it has
    /// none and they get the engine's default.
    public let library_days: Int?
    /// An empty string is not a yes.
    public let finished: Bool
    public let age_days, due_in_days, keepers: Int?
    public let due: Bool
    public let archived: Int

    init(fields f: Fields) {
        days = f.int("days")
        source = f.string("source")
        library_days = f.intOrNil("library_days")
        finished = f.bool("finished")
        age_days = f.intOrNil("age_days")
        due_in_days = f.intOrNil("due_in_days")
        keepers = f.intOrNil("keepers")
        due = f.bool("due")
        archived = f.int("archived")
    }

    /// Whether this shoot's number is also what new shoots get. From an
    /// engine that does not send the library's number, only a shoot that
    /// takes the library's is known to.
    public var isLibraryDefault: Bool {
        library_days.map { $0 == days } ?? (source == "library")
    }
}

/// GET /api/storage/frames — fetched only on the first expand of the fold.
public struct StorageFrames: FieldDecodable {
    public let rows: [StorageFrameRow]
    public init(fields f: Fields) throws {
        rows = f.objects("rows").map(StorageFrameRow.init(fields:))
    }
}

public struct StorageFrameRow: Sendable, Hashable, Identifiable {
    public let name: String
    public let bytes: Int
    public let bytes_text, state: String
    public let cells: [StorageCell]
    public let words: String

    init(fields f: Fields) {
        name = f.string("name")
        bytes = f.int("bytes")
        bytes_text = f.string("bytes_text")
        state = f.string("state")
        cells = f.strings("cells").compactMap(StorageCell.init(rawValue:))
        words = f.string("words")
    }

    public var id: String { name }
}

/// GET|POST /api/storage/plan, and what POST /api/storage/apply hands back.
///
/// `lines` is the command's own output, shown verbatim in a monospaced list.
/// Nothing in it is parsed, summarised or re-ordered by the app.
public struct Plan: FieldDecodable, Hashable, CarriesRefusal {
    public let what: String
    public let counts: [String: Int]
    public let bytes_text, label, why: String
    public let refusals, names, lines: [String]
    public let ready: Bool
    /// Spent once used. A plan with no token cannot be applied.
    public let token: String?
    public let error: String?
    /// The shoot moved since the list was drawn: redraw, silently, rather than
    /// act on a confirmation that no longer describes what would happen
    /// (DESIGN.md §7.8).
    public let stale: Bool?

    public init(fields f: Fields) throws {
        what = f.string("what")
        counts = f.counts("counts")
        bytes_text = f.string("bytes_text")
        label = f.string("label")
        why = f.string("why")
        refusals = f.strings("refusals")
        names = f.strings("names")
        lines = f.strings("lines")
        ready = f.bool("ready")
        token = f.stringOrNil("token").flatMap { $0.isEmpty ? nil : $0 }
        error = f.stringOrNil("error")
        stale = f["stale"]?.boolValue
    }

    /// How many photographs would cease to exist. The number he has to type,
    /// and it is frozen at the value the list was drawn against.
    public var doomed: Int { counts["doomed"] ?? 0 }
    /// Frames he kept, protected by the answer key this list was drawn
    /// against — never recomputed live (DESIGN.md §7.8).
    public var protectedKeepers: Int { counts["protected"] ?? 0 }

    public var isApplicable: Bool { ready && token != nil && error == nil }
}

/// The options a plan can be drawn with. They are part of what the token
/// fingerprints, so a plan drawn with one set is never applied with another.
public struct PlanOptions: Sendable, Hashable {
    public var force: Bool?
    /// Let go of the frames he kept as well.
    public var keepers: Bool?
    /// Include the frames with no other copy — the ones that cease to exist.
    public var originals: Bool?
    public var after: Int?

    public static let none = PlanOptions()

    public init(force: Bool? = nil, keepers: Bool? = nil, originals: Bool? = nil, after: Int? = nil) {
        self.force = force; self.keepers = keepers; self.originals = originals; self.after = after
    }

    public var query: [String: String] {
        var q: [String: String] = [:]
        if force == true { q["force"] = "1" }
        if keepers == true { q["keepers"] = "1" }
        if originals == true { q["originals"] = "1" }
        if let after { q["after"] = String(after) }
        return q
    }
}

/// GET /api/storage/library — the whole library's one line.
public struct LibraryLine: FieldDecodable, Hashable {
    public let free_text, reclaimable_text, strays_text, root: String
    public let files: Int
    public let strays: [Stray]

    public init(fields f: Fields) throws {
        free_text = f.string("free_text")
        reclaimable_text = f.string("reclaimable_text")
        strays_text = f.string("strays_text")
        root = f.string("root")
        files = f.int("files")
        strays = f.objects("strays").map(Stray.init(fields:))
    }
}

public struct Stray: Sendable, Hashable, Identifiable {
    public let name, bytes_text: String
    init(fields f: Fields) { name = f.string("name"); bytes_text = f.string("bytes_text") }
    public var id: String { name }
}
