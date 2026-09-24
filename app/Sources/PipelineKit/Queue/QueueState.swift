import Foundation

// The list of work, as the engine sends it.
//
// One reading, from `GET /api/queue`, holding both halves of the one question
// he is asking when he opens this: what is happening, and what is waiting.
// Taking those from two readings a moment apart is how a screen comes to show
// three things waiting behind a job that has already finished.
//
// Nothing here is a second queue. It is the engine's — the same `Jobs` that
// has always held one request behind another — read for the screen that shows
// it whole.

/// One piece of work he put on the list.
public struct QueueItem: FieldDecodable, Identifiable, Equatable {
    /// The engine's job id. It is the id this work will carry when it runs,
    /// so removing it and following it afterwards are the same number.
    public let id: Int
    /// The engine's kind — `cull`, `presets`, `stor-push`. What the app calls
    /// it is `Strings.Queue.what(kind)`; this is never shown as written.
    public let kind: String
    /// The engine's own title, which is the fallback when the app has no word
    /// of its own for a kind — an extension's work, for one.
    public let title: String
    public let shoot: String
    /// What it will do, in one sentence, from the engine: "Look at 1,157
    /// frames and put the ones worth keeping forward."
    public let does: String
    /// Whether it could still be done if its turn came now. The engine asks
    /// the shoot again every time this is read, so a card taken out of the
    /// Mac shows up in his list before he walks away rather than after.
    public let ready: Bool
    /// Why not, in the engine's words. Empty when `ready`.
    public let whyNot: String
    /// Whether it is written down and would survive a restart. False for an
    /// extension's own work, which carries a command this run of the engine
    /// built and nothing to rebuild it from.
    public let kept: Bool
    /// What it was asked for with — the same names the route that does the
    /// work reads — so a page can show what a waiting cull will run with.
    /// Empty from an engine that does not say.
    public let options: [String: JSONValue]
    /// The engine stopped while this ran, and it was put back at the top of
    /// the list for him to start again (DESIGN.md §2.7).
    public let interrupted: Bool

    public init(fields f: Fields) throws {
        id = f.int("id")
        kind = f.string("kind")
        title = f.string("title")
        shoot = f.string("shoot")
        does = f.string("does")
        ready = f.bool("ready", true)
        whyNot = f.string("why_not")
        kept = f.bool("kept")
        options = f.object("opts")?.raw ?? [:]
        interrupted = f.bool("interrupted")
    }

    public init(id: Int, kind: String, title: String = "", shoot: String = "", does: String = "",
                ready: Bool = true, whyNot: String = "", kept: Bool = true,
                options: [String: JSONValue] = [:], interrupted: Bool = false) {
        self.id = id; self.kind = kind; self.title = title; self.shoot = shoot
        self.does = does; self.ready = ready; self.whyNot = whyNot; self.kept = kept
        self.options = options; self.interrupted = interrupted
    }

    /// What the app calls this, in his words, with the engine's title as the
    /// fallback for a kind the app has no word for.
    public var what: String { Strings.Queue.what(kind) ?? (title.isEmpty ? kind : title) }
}

/// Something the list finished.
public struct QueueDone: FieldDecodable, Identifiable, Equatable {
    public let id: Int
    public let kind: String
    public let title: String
    public let shoot: String
    /// `done`, `stopped`, `refused` or `failed`, the engine's word.
    public let outcome: String

    public init(fields f: Fields) throws {
        id = f.int("id"); kind = f.string("kind"); title = f.string("title")
        shoot = f.string("shoot"); outcome = f.string("outcome")
    }

    public init(id: Int, kind: String, title: String = "", shoot: String = "", outcome: String = "done") {
        self.id = id; self.kind = kind; self.title = title; self.shoot = shoot; self.outcome = outcome
    }

    public var what: String { Strings.Queue.what(kind) ?? (title.isEmpty ? kind : title) }

    /// The engine's word as the app's outcome, so a finished list draws each
    /// piece with the same word, symbol and colour the history does. A word
    /// this app does not know is "done", the engine's own default.
    ///
    /// "refused" is a script that said no on purpose (`ended_as`): the
    /// engine wrote every one of those down as "failed", so a guard working
    /// was counted as a crash, in red, beside a history row that called the
    /// same job Refused.
    public var ended: Job.Outcome {
        switch outcome {
        case "failed": return .failed
        case "stopped": return .stopped
        case "refused": return .refused
        default: return .done
        }
    }
}

/// Something the list could not do when its turn came, and why.
///
/// It is kept, not dropped. The whole point of looking at a shoot again
/// before starting is undone if the answer then goes quiet: he walked away
/// from four things and has to be able to find out afterwards that three of
/// them happened and one did not, and which.
public struct QueueSkipped: FieldDecodable, Identifiable, Equatable {
    public let id: Int
    public let kind: String
    public let title: String
    public let shoot: String
    /// The engine's sentence, printed as it wrote it.
    public let whyNot: String

    public init(fields f: Fields) throws {
        id = f.int("id"); kind = f.string("kind"); title = f.string("title")
        shoot = f.string("shoot"); whyNot = f.string("why_not")
    }

    public init(id: Int, kind: String, title: String = "", shoot: String = "", whyNot: String) {
        self.id = id; self.kind = kind; self.title = title; self.shoot = shoot; self.whyNot = whyNot
    }

    public var what: String { Strings.Queue.what(kind) ?? (title.isEmpty ? kind : title) }
}

/// Why the list is held when it was not his Hold that held it, and the job
/// it was about (DESIGN.md §2.7).
public struct HeldAfter: FieldDecodable, Equatable {
    public enum Why: String, Sendable { case stopped, crashed }
    /// `stopped`: he pressed Stop with work waiting. `crashed`: the engine
    /// stopped under this job, and it is back at the top of the list.
    public let why: Why
    public let kind: String
    public let title: String
    public let shoot: String
    /// Whether the crash's work is back on the list. It always is now: a
    /// card copy goes back as the copy that finishes into the same shoot,
    /// with where it stopped (`files` of `of` frames). An engine from before
    /// a copy could be finished into its shoot did not put one back, and
    /// said so (`put_back: false`); a list it held still reads that way.
    public let putBack: Bool
    public let files: Int
    public let of: Int

    public init(fields f: Fields) throws {
        why = Why(rawValue: f.string("why")) ?? .stopped
        kind = f.string("kind"); title = f.string("title"); shoot = f.string("shoot")
        putBack = f.bool("put_back", true)
        files = f.int("files"); of = f.int("of")
    }

    public init(why: Why, kind: String, title: String = "", shoot: String = "",
                putBack: Bool = true, files: Int = 0, of: Int = 0) {
        self.why = why; self.kind = kind; self.title = title; self.shoot = shoot
        self.putBack = putBack; self.files = files; self.of = of
    }

    /// The job, as Up Next names it: "Cull · 2026-09-19".
    public var named: String {
        let what = Strings.Queue.what(kind) ?? (title.isEmpty ? kind : title.capitalizedFirst)
        return shoot.isEmpty ? what : "\(what) · \(shoot)"
    }
}

/// What is happening and what is waiting, in one reading.
public struct QueueState: FieldDecodable, Equatable {
    public let waiting: [QueueItem]
    /// He has held the list. What is running is untouched; the next one does
    /// not start.
    public let held: Bool
    /// Why, when it was not his Hold: a Stop he pressed with work waiting, or
    /// the engine stopping under a job. `nil` when he held it himself.
    public let heldAfter: HeldAfter?
    /// The job this run of the engine found cut off by the last one's crash
    /// and put back at the top, for the line that says the engine restarted.
    public let cutOff: HeldAfter?
    /// How many pieces of work this stretch has: finished, skipped, running
    /// and waiting, together.
    public let listed: Int
    /// The bar for the WHOLE list, which is what the Dock shows. A list of
    /// four is one piece of work with four parts, not four bars.
    public let fraction: Double
    /// Changes when a new stretch of work starts, so the app can tell him
    /// once at the end rather than once a job (DESIGN.md §2.7).
    public let pass: Int
    public let done: [QueueDone]
    public let skipped: [QueueSkipped]

    // What is running, if anything.
    public let running: Bool
    /// Whether what is running came off the list. A cull he started by hand
    /// is not part of it and is not counted into its bar.
    public let fromList: Bool
    public let id: Int
    public let kind: String
    public let title: String
    public let shoot: String
    /// The engine's own stage words and count. Never written here.
    public let label: String
    public let remainingText: String
    /// This job's own bar, as opposed to the list's.
    public let jobFraction: Double
    /// The machine's own homework, which is never on the list and never
    /// waits for it.
    public let background: Bool

    public init(fields f: Fields) throws {
        waiting = try f.objects("queue").map(QueueItem.init(fields:))
        held = f.bool("held")
        heldAfter = held ? try f.object("held_after").map(HeldAfter.init(fields:)) : nil
        cutOff = try f.object("cut_off").map(HeldAfter.init(fields:))
        listed = f.int("listed")
        fraction = f.double("fraction")
        pass = f.int("pass")
        done = try f.objects("done").map(QueueDone.init(fields:))
        skipped = try f.objects("skipped").map(QueueSkipped.init(fields:))
        running = f.bool("running")
        fromList = f.bool("from_list")
        id = f.int("id")
        kind = f.string("kind")
        title = f.string("title")
        shoot = f.string("shoot")
        label = f.string("label")
        remainingText = f.string("remaining_text")
        jobFraction = f.double("job_fraction")
        background = f.bool("background")
    }

    public init(waiting: [QueueItem] = [], held: Bool = false, heldAfter: HeldAfter? = nil,
                listed: Int = 0,
                fraction: Double = 0, pass: Int = 0, done: [QueueDone] = [],
                skipped: [QueueSkipped] = [], running: Bool = false, fromList: Bool = false,
                id: Int = 0, kind: String = "", title: String = "", shoot: String = "",
                label: String = "", remainingText: String = "", jobFraction: Double = 0,
                background: Bool = false) {
        self.waiting = waiting; self.held = held; self.heldAfter = held ? heldAfter : nil
        self.cutOff = nil
        self.listed = listed; self.fraction = fraction
        self.pass = pass; self.done = done; self.skipped = skipped; self.running = running
        self.fromList = fromList; self.id = id; self.kind = kind; self.title = title
        self.shoot = shoot; self.label = label; self.remainingText = remainingText
        self.jobFraction = jobFraction; self.background = background
    }

    public static let empty = QueueState()

    /// Nothing running that belongs to the list, and nothing waiting. Not the
    /// same as "nothing is running": the machine's homework, and a job he
    /// started by hand, are both outside the list.
    public var isFinished: Bool { waiting.isEmpty && !(running && fromList) }

    /// Anything at all to show: work waiting, or work of his running.
    public var hasAnything: Bool { !waiting.isEmpty || (running && !background) }

    /// How many are waiting — the number on the toolbar's Activity item.
    public var count: Int { waiting.count }

    /// What the pass came to, by outcome. "4 finished" over a list whose
    /// cull failed told him nothing was wrong until he opened a log.
    public var tally: Tally {
        Tally(done: done.filter { $0.ended == .done }.count,
              failed: done.filter { $0.ended == .failed }.count,
              stopped: done.filter { $0.ended == .stopped }.count,
              skipped: skipped.count,
              refused: done.filter { $0.ended == .refused }.count)
    }

    public struct Tally: Equatable, Sendable {
        public let done: Int, failed: Int, stopped: Int, skipped: Int, refused: Int
        public init(done: Int = 0, failed: Int = 0, stopped: Int = 0, skipped: Int = 0, refused: Int = 0) {
            self.done = done; self.failed = failed; self.stopped = stopped; self.skipped = skipped
            self.refused = refused
        }
        /// Anything he has to go and look at: a crash, and a no whose reason
        /// is only in the window.
        public var wentWrong: Bool { failed > 0 || refused > 0 || skipped > 0 }
    }

    /// What finished, what went wrong first: the failed, then the refused,
    /// then the stopped, then the rest, each group in the order it ran.
    public var doneWorstFirst: [QueueDone] {
        let rank: (Job.Outcome) -> Int = {
            switch $0 {
            case .failed: return 0
            case .refused: return 1
            case .stopped: return 2
            default: return 3
            }
        }
        return done.enumerated()
            .sorted { (rank($0.element.ended), $0.offset) < (rank($1.element.ended), $1.offset) }
            .map(\.element)
    }

    /// The row for what is running, when it is worth drawing one.
    public var runningItem: QueueItem? {
        guard running, !background else { return nil }
        return QueueItem(id: id, kind: kind, title: title, shoot: shoot)
    }

    /// Where it has got to and how long is left — both the engine's, joined,
    /// and nothing joined when there is nothing to join.
    public var whereItHasGot: String {
        [label, remainingText].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// What comes back from a POST that changed the list: the engine's refusal if
/// it refused, and the list as it is now either way.
public struct QueueChanged: FieldDecodable, CarriesRefusal {
    public let ok: Bool
    public let error: String?
    /// Present on a refusal: whether this kind may EVER go on the list. False
    /// says the answer is no and always will be, which is a different thing
    /// from "not now" and reads differently beside the control.
    public let queueable: Bool?
    /// The item that was added, when one was.
    public let added: QueueItem?
    public let list: QueueState?

    public init(fields f: Fields) throws {
        ok = f.bool("ok")
        error = f.stringOrNil("error")
        queueable = f["queueable"]?.boolValue
        added = try f.object("added").map(QueueItem.init(fields:))
        list = try f.object("list").map(QueueState.init(fields:))
    }
}
