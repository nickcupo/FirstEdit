import Foundation

// GET /api/learned, and POST /api/learned/run|back|stop|use-anyway.
//
// Two shapes have to decode into one model, because two engines exist.
// DESIGN.md §3.4 wrote `status` / `detail` / `live_since` / a single flat
// `check`; the engine crew landed `state` / `sentence` / `live.since` and a
// `check` with a per-shoot breakdown under `shoots`. Both are read here, the
// engine's own spelling first, so the app talks to either without a branch
// anywhere above this file.
//
// Nothing below composes a sentence. Where the engine sends one it is shown
// byte for byte; where it does not, `LearnerCopy` says so — and that is the
// one seam, with two implementations and one line to switch them.

/// GET /api/learned
public struct Learned: FieldDecodable, Hashable {
    /// The one paragraph at the top, in the engine's words.
    public let headline: String
    /// Every photograph he kept, on every shoot, that a change is checked
    /// against.
    public let keepers, shoots: Int
    public let last_checked: String?
    /// Shoots finished since the last run.
    public let new_shoots: Int
    public let new_shoot_names: [String]
    public let running: Bool
    /// Something else is running; this starts when it is done.
    public let queued: Bool
    /// There is new data and it has been more than a day.
    public let due: Bool
    public let learners: [Learner]
    /// Things that do not learn, said so they are not mistaken for things
    /// that do.
    public let fixed: [FixedThing]
    /// Where the learned files live, and why they cannot be read when they
    /// cannot.
    public let folder: String
    public let error: String?
    public let job: LearningJob?
    /// The record's own file, when it will not read, and the parser's reason
    /// — kept out of the sentence, which used to begin with his home folder.
    public let record: String?
    public let unreadable_why: String?
    private let unreadableFlag: Bool

    public init(fields f: Fields) throws {
        headline = f.string("headline", Strings.Learning.headline)
        // The engine nests the counts under `keepers`; DESIGN.md had them flat.
        if let k = f.object("keepers") {
            keepers = k.int("photos")
            shoots = k.int("shoots")
            last_checked = f.object("last_run")?.stringOrNil("at") ?? k.stringOrNil("at")
        } else {
            keepers = f.int("keepers")
            shoots = f.int("shoots")
            last_checked = f.stringOrNil("last_checked")
        }
        new_shoot_names = f.strings("new_to_learn_from")
        new_shoots = f.has("new_shoots") ? f.int("new_shoots") : new_shoot_names.count
        running = f.bool("running")
        queued = f.bool("queued")
        due = f.bool("due")
        learners = try f.objects("learners").map(Learner.init(fields:))
        fixed = f.objects("fixed").map(FixedThing.init(fields:))
        folder = f.string("folder")
        error = f.stringOrNil("error")
        job = f.object("job").map(LearningJob.init(fields:))
        record = f.stringOrNil("record")
        unreadable_why = f.stringOrNil("unreadable_why")
        unreadableFlag = f.bool("unreadable")
    }

    /// True when the whole record is unreadable. The panel says so and offers
    /// nothing it cannot honour.
    ///
    /// The engine says so outright. It also still sends a row per learner,
    /// built from a blank record, so "no rows" — all this used to read — was
    /// never true of a real broken record, and the page showed "Nothing
    /// learned yet" with Learn Now under it instead. An engine older than the
    /// flag is still read the old way.
    public var unreadable: Bool { unreadableFlag || (error?.isEmpty == false && learners.isEmpty) }
}

/// The learning run, while it is going, as §2.9 puts it on the row:
/// "Learning from 2026-09-21 — measuring 283 of 283", a bar, how long it has
/// been going, roughly what is left, and a way to stop it.
///
/// Every string in it is the engine's. The app composes none of them: the
/// engine is the thing that knows what the run is doing, and after a year of
/// two vocabularies for the same job there is one.
public struct LearningJob: Sendable, Hashable {
    /// "Learning from 2026-09-21". Empty from an engine that does not send
    /// one, and the row falls back to what it can say honestly.
    public let title: String
    /// "measuring the frames you finished: 283 of 283 frames".
    public let label: String
    public let stage: String
    public let fraction: Double
    public let elapsed: Int
    /// `nil` until the engine will estimate. The row says nothing rather than
    /// a number nobody stands behind.
    public let remaining: Int?
    /// "about 4 minutes left", or empty.
    public let remaining_text: String
    /// Why stopping it costs him nothing — the reason this is allowed to be
    /// stood down at all, said where he can read it before he decides.
    public let safe_to_stop: String

    init(fields f: Fields) {
        title = f.string("title")
        label = f.string("label")
        stage = f.string("stage")
        fraction = f.double("fraction")
        elapsed = f.int("elapsed")
        remaining = f.intOrNil("remaining")
        remaining_text = f.string("remaining_text")
        safe_to_stop = f.string("safe_to_stop")
    }

    public init(title: String = "", label: String = "", stage: String = "", fraction: Double = 0,
                elapsed: Int = 0, remaining: Int? = nil, remaining_text: String = "",
                safe_to_stop: String = "") {
        self.title = title; self.label = label; self.stage = stage; self.fraction = fraction
        self.elapsed = elapsed; self.remaining = remaining
        self.remaining_text = remaining_text; self.safe_to_stop = safe_to_stop
    }

    /// The second line: where it has got to, and what is left. Both the
    /// engine's, joined and nothing more.
    public var whereItHasGot: String {
        [label, remaining_text].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Something built in, shown so he knows it exists and knows it is not
/// learning from his photographs.
public struct FixedThing: Sendable, Hashable, Identifiable {
    public let id, title, sentence: String
    init(fields f: Fields) {
        id = f.string("id"); title = f.string("title"); sentence = f.string("sentence")
    }
}

/// One learner: what it read, what it would cost him, and whether it is in
/// use or held.
public struct Learner: FieldDecodable, Hashable, Identifiable {
    public let id, title: String
    public let status: LearnerStatus
    /// The row's one line, worked out fresh by the engine each request: what
    /// is IN USE, and what it was learned from.
    public let detail: String
    /// The version waiting beside it, and why it waits, in the engine's words:
    /// "Held back: …" (checked, and it would cost him something) or
    /// "Waiting: …" (nothing has been able to measure it yet). Empty when
    /// nothing is waiting. A held candidate used to be the row's state and
    /// its only sentence, so a starting edit that WAS in use read "Not in use".
    public let candidate_sentence: String
    /// `held` or `couldnt_check` for the version waiting, or nil.
    public let candidate_status: LearnerStatus?
    /// What it is short of, as things he could do: "Not enough yet to learn
    /// your own: 6 more frames dropped for blur…". The opposite situation from
    /// a version held back, with the opposite remedy, so it is its own line.
    public let needs_sentence: String
    /// The same, a fact to a line, as the page draws it. Empty from an engine
    /// that sends only the sentence, and then the sentence is drawn.
    public let needs_lines: [String]
    /// The shoots those lines ask him to act on, and what to do there, so the
    /// row carries a button rather than a command to type.
    public let needs_do: [LearnerNeed]
    /// The shoots its check could not reach for want of picture vectors, a
    /// Measure button each beside the check's line. Empty from an engine that
    /// does not say.
    public let check_do: [LearnerNeed]
    /// What it read, and the plain-words measurement. Absent on the engine's
    /// own shape, which folds both into `sentence`.
    public let learned_from, plain_metric: String
    /// What this learner changes, in the engine's words.
    public let changes: String
    public let check: LearnerCheck?
    public let live_since, previous: String?
    public let live_version, candidate_version: String?
    /// The engine says what it will honour; the app never offers more.
    public let can_go_back, can_stop, can_use_anyway: Bool

    /// The starting edit: it sets the first preset of a new shoot and never
    /// changes which frames the cull puts forward, so nothing said about
    /// keepers being shown less, or hidden, is true of it.
    public var isStartingEdit: Bool { id == "edit" }
    /// The learner that orders the frames inside a burst: it moves keepers
    /// earlier or later and hides none.
    public var isBurstOrder: Bool { id == "tier-order" }

    /// What it is short of, as VoiceOver reads it: the lines the row draws,
    /// or the one sentence from an engine that sends no lines. The sentence
    /// from an engine that sends both still carries the command to type that
    /// the lines replaced.
    public var needsText: String {
        needs_lines.isEmpty ? needs_sentence : needs_lines.joined(separator: " ")
    }

    public init(fields f: Fields) throws {
        id = try f.requireString("id")
        title = f.string("title", id)
        status = LearnerStatus(engine: f.string("state", f.string("status")))
        detail = f.string("sentence", f.string("detail"))
        candidate_sentence = f.string("candidate_sentence")
        let waiting = f.string("candidate_state")
        candidate_status = waiting.isEmpty ? nil : LearnerStatus(engine: waiting)
        needs_sentence = f.string("needs_sentence")
        needs_lines = f.strings("needs_lines")
        needs_do = f.objects("needs_do").compactMap(LearnerNeed.init(fields:))
        check_do = f.objects("check_do").compactMap(LearnerNeed.init(fields:))
        changes = f.string("changes")
        plain_metric = f.string("plain_metric")
        check = f.object("check").map(LearnerCheck.init(fields:))
        let live = f.object("live")
        live_since = live?.stringOrNil("since") ?? f.stringOrNil("live_since")
        live_version = live?.stringOrNil("version")
        let candidate = f.object("candidate")
        candidate_version = candidate?.stringOrNil("version")
        // What the version IN USE read. The engine always sends it (empty
        // when the row's sentence says it instead). An engine that does not
        // gets the version in use's own source and never the candidate's: the
        // held candidate's "learned: you finished …" sat over a row whose
        // version in use it did not describe.
        learned_from = f.string("learned_from", live?.string("source") ?? "")
        previous = f.stringOrNil("previous") ?? live?.stringOrNil("previous")
        // Where the engine does not say, the state decides — and it decides
        // conservatively: nothing is offered that a refusal would take back.
        can_go_back = f.has("can_go_back") ? f.bool("can_go_back") : (previous != nil)
        can_stop = f.has("can_stop") ? f.bool("can_stop") : (status == .in_use)
        can_use_anyway = f.has("can_use_anyway")
            ? f.bool("can_use_anyway")
            : (status == .not_in_use && (check?.costsHim ?? false))
    }

    /// The two lines under the title, when the engine sends them apart.
    public var readWhat: String { learned_from }

    /// Whether this row has frames behind it that can be looked at. "Use it
    /// anyway" exists only where they are on screen, so this gates it.
    public var hasFramesToShow: Bool { !(check?.frames.isEmpty ?? true) }
}

/// Always a symbol and a word, never colour alone (§2.9).
///
/// Six states reach the app and one more is a convenience: `fixed` marks a
/// row that is built in rather than trained, which the engine sends in its own
/// `fixed` array but DESIGN.md's fixture sends as a learner.
public enum LearnerStatus: String, Sendable, Hashable, CaseIterable {
    case in_use
    /// The engine calls this `held`: trained, checked, and not used because
    /// the check said it would cost him.
    case not_in_use
    case not_enough
    case could_not_check
    /// He turned it off. What it learned is kept.
    case stopped
    /// Nothing has ever been learned here.
    case none
    /// Built in, not trained on his photographs.
    case fixed

    init(engine word: String) {
        switch word {
        case "in_use": self = .in_use
        case "held", "not_in_use": self = .not_in_use
        case "not_enough": self = .not_enough
        case "couldnt_check", "could_not_check": self = .could_not_check
        case "stopped": self = .stopped
        case "fixed": self = .fixed
        default: self = .none
        }
    }

    public var symbol: String {
        switch self {
        case .in_use: return Symbols.inUse
        case .not_in_use: return Symbols.notInUse
        case .not_enough: return Symbols.notEnough
        case .could_not_check: return Symbols.couldNotCheck
        case .stopped: return Symbols.notInUse
        case .none: return Symbols.notEnough
        case .fixed: return Symbols.cullForward
        }
    }

    public var word: String {
        switch self {
        case .in_use: return Strings.Learning.inUse
        case .not_in_use: return Strings.Learning.notInUse
        case .not_enough: return Strings.Learning.notEnough
        case .could_not_check: return Strings.Learning.couldNotCheck
        case .stopped: return Strings.Learning.stoppedUsing
        case .none: return Strings.Learning.nothingLearnedYet
        case .fixed: return Strings.Learning.builtIn
        }
    }
}

/// What the candidate would do to the photographs he kept.
public struct LearnerCheck: Sendable, Hashable {
    public let kind: String
    public let at: String
    public let passed: Bool
    public let keepers, checked, hidden, moved_down, moved_up: Int
    /// One shoot's worth, when the check names one.
    public let shoot: String?
    public let sentence: String
    public let shoots: [LearnerShootCheck]
    /// Every affected frame, flattened across the shoots, so a review screen
    /// has one list to show.
    public let frames: [LearnerFrame]
    /// Shoots whose keepers could not all be read. Named, never skipped.
    public let couldnt_check: [UncheckedShoot]

    init(fields f: Fields) {
        kind = f.string("kind")
        at = f.string("at")
        passed = f.bool("passed")
        shoot = f.stringOrNil("shoot")
        sentence = f.string("sentence")
        shoots = f.objects("shoots").map(LearnerShootCheck.init(fields:))
        couldnt_check = f.objects("couldnt_check").map(UncheckedShoot.init(fields:))
        // Flat on DESIGN.md's shape, per-shoot on the engine's. Where both
        // are there the flat totals win, because the engine wrote them.
        keepers = f.has("keepers") ? f.int("keepers") : shoots.reduce(0) { $0 + $1.keepers }
        checked = f.has("checked") ? f.int("checked") : shoots.reduce(0) { $0 + $1.checked }
        hidden = f.has("hidden") ? f.int("hidden") : shoots.reduce(0) { $0 + $1.hidden }
        moved_down = f.has("moved_down") ? f.int("moved_down") : shoots.reduce(0) { $0 + $1.moved_down }
        // The engine calls a keeper that moved up "lifted".
        if f.has("moved_up") { moved_up = f.int("moved_up") }
        else if f.has("lifted") { moved_up = f.int("lifted") }
        else { moved_up = shoots.reduce(0) { $0 + $1.lifted } }
        let own = f.objects("frames").map(LearnerFrame.init(fields:))
        frames = own.isEmpty ? shoots.flatMap(\.frames) : own
    }

    /// Whether this change would take something from him. Hidden keepers are
    /// the line that is never crossed without the frames in front of him.
    public var costsHim: Bool { hidden > 0 || moved_down > moved_up }
}

public struct LearnerShootCheck: Sendable, Hashable, Identifiable {
    public let shoot: String
    public let keepers, checked, moved_down, hidden, lifted: Int
    public let passed: Bool
    public let why: String
    public let frames: [LearnerFrame]

    init(fields f: Fields) {
        shoot = f.string("shoot")
        keepers = f.int("keepers"); checked = f.int("checked")
        moved_down = f.int("moved_down"); hidden = f.int("hidden"); lifted = f.int("lifted")
        passed = f.bool("passed")
        why = f.string("why")
        frames = f.objects("frames").map(LearnerFrame.init(fields:))
    }

    public var id: String { shoot }
}

/// One thing a learner's needs line asks him to do, on one shoot.
public struct LearnerNeed: Sendable, Hashable, Identifiable {
    public enum Act: String, Sendable, Hashable {
        /// Bring its RAWs back from iCloud.
        case pull
        /// Finish some of its keepers in PhotoLab.
        case finish
        /// Measure its frames' picture vectors off its previews, so the
        /// keeper check can reach it. It was a command to type.
        case vectors
    }
    public let shoot: String
    public let act: Act

    init?(fields f: Fields) {
        guard let act = Act(rawValue: f.string("do")), !f.string("shoot").isEmpty else { return nil }
        shoot = f.string("shoot")
        self.act = act
    }

    public init(shoot: String, act: Act) { self.shoot = shoot; self.act = act }

    public var id: String { "\(act.rawValue):\(shoot)" }
}

public struct UncheckedShoot: Sendable, Hashable, Identifiable {
    public let shoot: String
    public let keepers: Int
    public let why: String
    init(fields f: Fields) {
        shoot = f.string("shoot"); keepers = f.int("keepers"); why = f.string("why")
    }
    public var id: String { shoot }
}

/// One photograph he kept, and what the new version would do to it.
public struct LearnerFrame: Sendable, Hashable, Identifiable {
    public let shoot, stem: String
    /// Where it stands now, and where the candidate would put it — the
    /// engine's own words for both.
    public let now, candidate: String
    public let why: String
    public let burst: String?
    public let down: Bool

    init(fields f: Fields) {
        shoot = f.string("shoot")
        stem = f.string("stem")
        now = f.string("now")
        // DESIGN.md said `candidate`; the engine says `new`.
        candidate = f.has("new") ? f.string("new") : f.string("candidate")
        why = f.string("why")
        burst = f.stringOrNil("burst")
        down = f.bool("down", true)
    }

    public var id: String { "\(shoot)/\(stem)" }
}

// MARK: - the one seam

/// Where a learner's row sentence comes from.
///
/// The engine writes it (`sentence`), and that is what is shown. An engine
/// that does not — an older one, or a record it could not read — leaves the
/// row with nothing to say, and rather than an empty line the app composes
/// one from the structured fields it does have. Two implementations, and the
/// switch is the one assignment in `LearnedModel.copy`.
public protocol LearnerCopy: Sendable {
    func sentence(_ learner: Learner) -> String
}

/// The engine's own sentence, byte for byte. The default, always.
public struct EngineWrittenCopy: LearnerCopy {
    public init() {}
    public func sentence(_ l: Learner) -> String { l.detail }
}

/// Composed here, from structured fields, only when the engine sent no
/// sentence at all. It never claims a number the engine did not send.
public struct ComposedCopy: LearnerCopy {
    public init() {}
    public func sentence(_ l: Learner) -> String {
        if !l.detail.isEmpty { return l.detail }
        switch l.status {
        case .in_use:
            return l.live_since.map(Strings.Learning.inUseSince) ?? Strings.Learning.inUse
        case .not_in_use:
            guard let c = l.check, c.hidden > 0 else { return Strings.Learning.notInUse }
            return Strings.Learning.wouldHide(c.hidden, c.shoot ?? c.shoots.first?.shoot ?? "")
        case .not_enough: return Strings.Learning.notEnough
        case .could_not_check: return Strings.Learning.couldNotCheck
        case .stopped: return Strings.Learning.stoppedUsing
        case .none: return Strings.Learning.nothingLearnedYet
        case .fixed: return l.plain_metric
        }
    }
}
