import Foundation

// MARK: - what the app sends

public struct IngestBody: Encodable, Sendable {
    public let card: String
    public let name: String
    public let kind: String?
    /// While copying · Again at the end · Don't check. The step's summary
    /// afterwards says which was asked for, so it can never print "checked"
    /// over a copy nothing checked.
    public let verify: String
    /// On his list rather than now. The engine's own copy route takes it, so
    /// the extension's kind travels with the copy; the list's general route
    /// reads "kind" as the kind of work and would drop it.
    public let queue: Bool?
    /// Once the copy has finished, the cull of the shoot starts by itself
    /// with his last shoot's settings (DESIGN.md §2.6). Never after a copy
    /// that stopped, failed or was refused.
    public let then_cull: Bool?
    /// Into the shoot called `name`, which already exists: to finish a copy
    /// that stopped part way, or to add a second card to it before it is
    /// culled. Without it the engine refuses a name already in the library.
    public let into: Bool?
    public init(card: String, name: String, kind: String? = nil, verify: String, queue: Bool? = nil,
                thenCull: Bool? = true, into: Bool? = nil) {
        self.card = card; self.name = name; self.kind = kind; self.verify = verify; self.queue = queue
        self.then_cull = thenCull; self.into = into
    }
}

public struct ReviewBody: Encodable, Sendable {
    public let name: String
    public let at: String?
    public let seen: [String]?
    public let unseen: [String]?
    public init(name: String, at: String? = nil, seen: [String]? = nil, unseen: [String]? = nil) {
        self.name = name; self.at = at; self.seen = seen; self.unseen = unseen
    }
}

public struct KindBody: Encodable, Sendable {
    public let name: String
    public let kind: String?
    public let reviewed: Bool?
    public let finished: Bool?
    public let style: String?
    public init(name: String, kind: String? = nil, reviewed: Bool? = nil,
                finished: Bool? = nil, style: String? = nil) {
        self.name = name; self.kind = kind; self.reviewed = reviewed
        self.finished = finished; self.style = style
    }
}

public struct OpenBody: Encodable, Sendable {
    public let name: String
    public let what: String
    /// With `what: "exported"`: which of the shoot's `export_dirs` to show.
    public let path: String?
    /// With `what: "photolab"`: the editor to open the keepers in, when it is
    /// not the one the shoot's presets were last written for.
    public let editor: String?
    public init(name: String, what: String, path: String? = nil, editor: String? = nil) {
        self.name = name; self.what = what; self.path = path; self.editor = editor
    }
}

public struct CullBody: Encodable, Sendable {
    public let name: String
    public let style: String?
    public let focus: Double?
    public let presets: Bool?
    public let top: Int?
    public init(name: String, style: String? = nil, focus: Double? = nil,
                presets: Bool? = nil, top: Int? = nil) {
        self.name = name; self.style = style; self.focus = focus
        self.presets = presets; self.top = top
    }
}

public struct PresetsBody: Encodable, Sendable {
    public let name: String
    public let force: Bool?
    public let picks_only: Bool?
    public let editor: String?
    public init(name: String, force: Bool? = nil, picks_only: Bool? = nil, editor: String? = nil) {
        self.name = name; self.force = force; self.picks_only = picks_only; self.editor = editor
    }
}

public struct SelectsBody: Encodable, Sendable {
    public let name: String
    public let confirm: Bool?
    public init(name: String, confirm: Bool? = nil) { self.name = name; self.confirm = confirm }
}

public struct LabelBody: Encodable, Sendable {
    public let name: String
    public let file: String
    public let label: String
    public init(name: String, file: String, label: String) {
        self.name = name; self.file = file; self.label = label
    }
}

/// His verdict. `rating: nil` clears the mark and is not the same thing as 0.
public struct RatingBody: Encodable, Sendable, Equatable {
    public let name: String
    public let file: String
    public let rating: Int?
    public init(name: String, file: String, rating: Int?) {
        self.name = name; self.file = file; self.rating = rating
    }
}

public struct RetainBody: Encodable, Sendable {
    public let name: String
    public let days: Int
    public let `default`: Bool?
    public init(name: String, days: Int, default d: Bool? = nil) {
        self.name = name; self.days = days; self.default = d
    }
}

public struct StorageCheckBody: Encodable, Sendable {
    public let name: String
    public let record: Bool?
    public init(name: String, record: Bool? = nil) { self.name = name; self.record = record }
}

public struct PlanBody: Encodable, Sendable {
    public let name: String
    public let what: String
    public let force: Bool?
    public let keepers: Bool?
    public let originals: Bool?
    public let after: Int?
    /// Take it into the engine's queue behind whatever is running, instead of
    /// being refused. This is what "Do It After" asks for: the queue is the
    /// engine's and has been all along, and the app asks for it by name
    /// rather than remembering the request and trying again on a timer.
    public let queue: Bool?
    public init(name: String, what: String, opts: PlanOptions = .none, queue: Bool = false) {
        self.name = name; self.what = what
        force = opts.force; keepers = opts.keepers; originals = opts.originals; after = opts.after
        self.queue = queue ? true : nil
    }
}

/// Stop what is running, or — with an id — take that waiting request back out
/// of the line before it starts.
public struct JobStopBody: Encodable, Sendable {
    public let id: Int?
    public init(id: Int? = nil) { self.id = id }
}

/// The token is the list he was shown, and it is used once. `typed` is the
/// number of photographs he wrote out by hand on the one action that cannot be
/// undone.
public struct ApplyBody: Encodable, Sendable {
    public let name: String
    public let what: String
    public let token: String
    public let typed: String?
    public let force: Bool?
    public let keepers: Bool?
    public let originals: Bool?
    public let after: Int?
    public init(name: String, what: String, token: String, typed: String? = nil,
                opts: PlanOptions = .none) {
        self.name = name; self.what = what; self.token = token; self.typed = typed
        force = opts.force; keepers = opts.keepers; originals = opts.originals; after = opts.after
    }
}

/// The reel request is the one body whose option names can come from the
/// extension at runtime, so it is carried as JSON rather than spelled out.
public struct ReelBody: Encodable, Sendable {
    public let values: [String: JSONValue]
    public init(_ values: [String: JSONValue]) { self.values = values }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(values)
    }
}

public struct SpreadBody: Encodable, Sendable {
    public let name: String
    public let burst: String
    public init(name: String, burst: String) { self.name = name; self.burst = burst }
}

public struct LearnedRunBody: Encodable, Sendable {
    /// Why it ran, for the record: "you finished 2026-09-19".
    public let why: String?
    public let learner: String?
    public init(why: String? = nil, learner: String? = nil) { self.why = why; self.learner = learner }
}

public struct LearnedActionBody: Encodable, Sendable {
    public let learner: String
    /// Must be the held candidate's version, so "use it anyway" can only be
    /// pressed from the screen that showed him what it would move.
    public let version: String?
    public init(learner: String, version: String? = nil) {
        self.learner = learner; self.version = version
    }
}

/// A POST with nothing to say. `/api/job/stop` and the update routes take one.
public struct EmptyBody: Encodable, Sendable {
    public init() {}
    public func encode(to encoder: Encoder) throws {
        // `{}`: an empty object, which is what the engine's JSON reader wants.
        _ = encoder.container(keyedBy: StringKey.self)
    }
}

// MARK: - what comes back

/// A response that carries the engine's refusal in the same object as its
/// result. `/api/rating`, `/api/kind` and `/api/storage/apply` do this on
/// purpose, and the client hands the whole thing back rather than throwing.
public protocol CarriesRefusal {
    var error: String? { get }
}

/// A job-starting answer. Three things can come back from one of these and
/// all three are his business.
///
/// - it started (`id`, `queued: false`);
/// - it is in line behind one of his own jobs (`queued: true`, with the `id`
///   to cancel);
/// - it could not start, and `busy` says which job is in the way, where it
///   has got to and roughly how long is left, beside the engine's sentence.
///
/// `paused` is the fourth thing, and it is not a refusal: the machine's
/// homework was standing in the way, so the engine stood it down, started his
/// work at once, and wrote him one line about it. Nothing he pressed ever
/// waits on the learning run.
public protocol StartsAJob: CarriesRefusal {
    var id: Int { get }
    var queued: Bool { get }
    var busy: Busy? { get }
    var paused: String? { get }
}

public struct OK: FieldDecodable, StartsAJob {
    public let ok: Bool
    public let error: String?
    public let id: Int
    public let queued: Bool
    public let busy: Busy?
    public let paused: String?
    public init(fields f: Fields) throws {
        ok = f.bool("ok")
        error = f.stringOrNil("error")
        id = f.int("id")
        queued = f.bool("queued")
        busy = f.object("busy").map(Busy.init(fields:))
        paused = f.stringOrNil("paused")
    }
}

public struct OKName: FieldDecodable, StartsAJob {
    public let ok: Bool
    public let name: String
    public let error: String?
    public let id: Int
    public let queued: Bool
    public let busy: Busy?
    public let paused: String?
    public init(fields f: Fields) throws {
        ok = f.bool("ok")
        name = f.string("name")
        error = f.stringOrNil("error")
        id = f.int("id")
        queued = f.bool("queued")
        busy = f.object("busy").map(Busy.init(fields:))
        paused = f.stringOrNil("paused")
    }
}

public struct ReviewResult: FieldDecodable {
    public let ok: Bool
    public let seen: Int
    public let at: String
    public init(fields f: Fields) throws {
        ok = f.bool("ok")
        seen = f.int("seen")
        at = f.string("at")
    }
}

/// Both at once, deliberately: walking past the keepers step files the record
/// as a side effect, and a refusal there is the guard working.
public struct KindResult: FieldDecodable, CarriesRefusal {
    public let ok: Bool
    public let error: String?
    /// Set when starting his work stood the learning run down. One line, and
    /// not an error.
    public let paused: String?
    /// What the engine did about learning, present only when the shoot was
    /// just marked finished. Marking a shoot finished starts (or queues) the
    /// learning run on the engine, so the app must never post
    /// `/api/learned/run` after this — it would be the second start.
    public let learning: LearningStart?
    public init(fields f: Fields) throws {
        ok = f.bool("ok")
        error = f.stringOrNil("error")
        paused = f.stringOrNil("paused")
        learning = try f.object("learning").map(LearningStart.init(fields:))
    }
}

/// The engine's answer about the learning run it started for itself.
public struct LearningStart: FieldDecodable, CarriesRefusal {
    /// Running now, as opposed to waiting behind whatever else is running.
    public let running: Bool
    public let queued: Bool
    /// Finish asked for no run: automatic learning is off in Settings.
    public let off: Bool
    /// "Learning from 2026-09-21" — the engine's words for the run it just
    /// started, so the app can say which shoot without composing it.
    public let title: String
    /// The engine's own sentence about waiting, printed as it wrote it.
    public let note: String?
    public let error: String?
    public init(fields f: Fields) throws {
        running = f.bool("running")
        queued = f.bool("queued")
        off = f.bool("off")
        title = f.string("title")
        note = f.stringOrNil("note")
        error = f.stringOrNil("error")
    }
}

public struct OpenResult: FieldDecodable, CarriesRefusal {
    public let ok: Bool
    public let folder: String?
    public let app: String?
    public let note: String?
    public let missing: String?
    public let error: String?
    public init(fields f: Fields) throws {
        ok = f.bool("ok")
        folder = f.stringOrNil("folder")
        app = f.stringOrNil("app")
        note = f.stringOrNil("note")
        missing = f.stringOrNil("missing")
        error = f.stringOrNil("error")
    }
}

public struct SelectsResult: FieldDecodable, CarriesRefusal {
    public let n: Int?
    /// Where the keepers just recorded came from, in his words. Empty from an
    /// engine that does not say.
    public let from: String
    public let error: String?
    public let confirm: Bool?
    public init(fields f: Fields) throws {
        n = f.intOrNil("n")
        from = f.string("from")
        error = f.stringOrNil("error")
        confirm = f["confirm"]?.boolValue
    }
}

/// `key_note` is informational and is printed inline on the control bar. It is
/// never an alert: it must not break the rhythm of a cull.
public struct RatingResult: FieldDecodable {
    public let ok: Bool
    public let key_note: String
    public init(fields f: Fields) throws {
        ok = f.bool("ok")
        key_note = f.string("key_note")
    }
    public init(ok: Bool, key_note: String) { self.ok = ok; self.key_note = key_note }
}

public struct RetainResult: FieldDecodable, CarriesRefusal {
    public let ok: Bool
    public let days: Int?
    public let error: String?
    public init(fields f: Fields) throws {
        ok = f.bool("ok")
        days = f.intOrNil("days")
        error = f.stringOrNil("error")
    }
}

public struct ApplyResult: FieldDecodable, StartsAJob {
    public let ok: Bool?
    public let stale: Bool?
    public let plan: Plan?
    public let error: String?
    public let id: Int
    public let queued: Bool
    /// The job in the way. An apply that cannot start says which one, how far
    /// along it is and roughly how long is left — it is the last button
    /// before something is removed, and "a job is already running" was the
    /// worst possible thing to answer it with.
    public let busy: Busy?
    /// The learning run this apply stood down. One line, and not an error.
    public let paused: String?
    public init(fields f: Fields) throws {
        ok = f["ok"]?.boolValue
        stale = f["stale"]?.boolValue
        plan = try f.object("plan").map(Plan.init(fields:))
        error = f.stringOrNil("error")
        id = f.int("id")
        queued = f.bool("queued")
        busy = f.object("busy").map(Busy.init(fields:))
        paused = f.stringOrNil("paused")
    }
}
