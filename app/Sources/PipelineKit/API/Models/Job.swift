import Foundation

// MARK: - GET /api/job

public struct Job: FieldDecodable, Equatable {
    public let running: Bool
    public let stopped: Bool
    /// DESIGN.md §3.9-10: monotonic, so a second job can be queued honestly
    /// rather than refused. `0` until the engine sends one, which reads as
    /// "this engine does not number its jobs".
    public let id: Int
    public let queued: Bool
    public let kind: String
    public let shoot: String
    public let title: String
    /// The engine's own stage words — "reading the frames", "looking at
    /// faces". The app never writes a stage name of its own.
    public let stage: String
    public let label: String
    public let log: String
    public let fraction: Double
    public let elapsed: Int
    public let code: Int?
    /// Seconds left, as the engine estimates them, or `nil` when it will not
    /// guess yet. The app never computes one of its own and never fills the
    /// gap with a number: too early to say is a thing the screen is allowed
    /// to say.
    public let remaining: Int?
    /// The engine's own words for what is left — "about 4 minutes left" — or
    /// empty when it will not say. Shown as written; nothing in the app turns
    /// seconds into English, so no two screens can disagree about it.
    public let remaining_text: String
    /// The machine's own homework rather than work he asked for. A background
    /// job is never the reason he cannot do something: it stands down, and
    /// the engine says so in the answer to what he pressed.
    public let background: Bool
    /// Stopped by the engine to make room for work of his (`make_room`), not
    /// by his Stop: a pass working out Instagram cuts that a press of his
    /// stood down is not one he stopped (DESIGN.md §2.17).
    public let stoodDown: Bool
    /// What this job was started for, in the engine's words — "you finished
    /// 2026-09-21".
    public let why: String
    /// Whether this job came off the list rather than being started by hand.
    /// The engine is the only thing that knows, and it says so on every read,
    /// which is what lets a finished job be spoken for once by the list
    /// instead of racing two pollers to say it twice.
    public let fromList: Bool
    /// When the engine started it, or `nil` from an engine that does not
    /// say. The history shows this, not the moment the app first noticed.
    public let startedAt: Date?
    /// What the list has finished in this stretch, with each outcome - the
    /// same `queue_done` the list reads. It is how a job the engine replaced
    /// with the list's next one between two polls is still closed with the
    /// word it ended with, rather than left "Running" in the history.
    public let listDone: [QueueDone]

    public init(fields f: Fields) throws {
        running = f.bool("running")
        stopped = f.bool("stopped")
        id = f.int("id")
        queued = f.bool("queued")
        kind = f.string("kind")
        shoot = f.string("shoot")
        title = f.string("title")
        stage = f.string("stage")
        label = f.string("label")
        log = f.string("log")
        fraction = f.double("fraction")
        elapsed = f.int("elapsed")
        code = f.intOrNil("code")
        remaining = f.intOrNil("remaining")
        remaining_text = f.string("remaining_text")
        background = f.bool("background")
        stoodDown = f.bool("stood_down")
        why = f.string("why")
        fromList = f.bool("queue_from_list")
        startedAt = f.doubleOrNil("started").flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        listDone = try f.objects("queue_done").map(QueueDone.init(fields:))
    }

    public init(running: Bool, stopped: Bool, id: Int = 0, queued: Bool = false, kind: String = "",
                shoot: String = "", title: String = "", stage: String = "", label: String = "",
                log: String = "", fraction: Double = 0, elapsed: Int = 0, code: Int? = nil,
                remaining: Int? = nil, remaining_text: String = "", background: Bool = false,
                stoodDown: Bool = false, why: String = "", fromList: Bool = false, startedAt: Date? = nil,
                listDone: [QueueDone] = []) {
        self.running = running; self.stopped = stopped; self.id = id; self.queued = queued
        self.kind = kind; self.shoot = shoot; self.title = title; self.stage = stage
        self.label = label; self.log = log; self.fraction = fraction; self.elapsed = elapsed
        self.code = code; self.remaining = remaining; self.remaining_text = remaining_text
        self.background = background; self.stoodDown = stoodDown; self.why = why; self.fromList = fromList
        self.startedAt = startedAt; self.listDone = listDone
    }

    /// A plan that refused on purpose is not a failure. It is its own state,
    /// in the ordinary text colour, carrying the engine's one sentence
    /// (DESIGN.md §2.7). A job that crashed is not a refusal, whatever its
    /// last line says.
    public var outcome: Outcome {
        if running { return .running }
        if stopped { return .stopped }
        guard let code else { return .idle }
        if code == 0 { return .done }
        return refusalSentence == nil ? .failed : .refused
    }

    public enum Outcome: Sendable, Equatable { case idle, running, done, stopped, refused, failed }

    /// The last line of the log when the engine wrote a sentence on purpose.
    /// Never the end of a crash: that is shown as Failed, not as a calm grey
    /// "Refused: MemoryError" - nor, when a card comes out mid-copy, as
    /// "FileNotFoundError: [Errno 2] No such file or directory: …/DSC0124.ARW"
    /// printed as the body of a notification.
    public var refusalSentence: String? {
        guard !crashed else { return nil }
        guard let last = sinceTheCommand.last(where: { !$0.isEmpty }) else { return nil }
        if last.contains("Traceback") || last.hasPrefix("File \"") { return nil }
        if Self.isExceptionLine(last) { return nil }
        return last
    }

    /// Whether the job died rather than said no.
    ///
    /// The engine refuses by raising `SystemExit` with its sentence, which
    /// prints the sentence and no traceback. So a job ended by a signal - the
    /// Mac out of memory, a kill - or one whose run printed a traceback
    /// crashed, and so did one whose last line is an exception's own:
    /// every real traceback ends on "MemoryError" or "OSError: [Errno 28] No
    /// space left on device", and taking that last line for a sentence is
    /// how a crash came to be drawn as a refusal.
    public var crashed: Bool {
        guard !running, let code, code != 0 else { return false }
        // A negative code is the signal that ended it; 128 and up is how a
        // shell reports one.
        if code < 0 || code >= 128 { return true }
        let lines = sinceTheCommand
        if lines.contains(where: { $0.hasPrefix("Traceback (most recent call last)") }) { return true }
        guard let last = lines.last(where: { !$0.isEmpty }) else { return false }
        return Self.isExceptionLine(last)
    }

    /// The log after the last command line the engine wrote, trimmed. What
    /// ran before the last `$ ` is an earlier part of the job and says
    /// nothing about how this part ended.
    private var sinceTheCommand: [String] {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let i = lines.lastIndex(where: { $0.hasPrefix("$ ") }) else { return lines }
        return Array(lines[(i + 1)...])
    }

    /// "MemoryError", "OSError: [Errno 28] No space left on device",
    /// "json.decoder.JSONDecodeError: Expecting value", "cv2.error: …",
    /// "KeyboardInterrupt": a dotted name ending in Error, Exception,
    /// Interrupt or Exit (or a module's own `.error`), alone or before a
    /// colon. A sentence the engine wrote has spaces before any colon, so it
    /// is never one.
    static func isExceptionLine(_ line: String) -> Bool {
        let name = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? line
        let endings = ["Error", "Exception", "Interrupt", "Exit", ".error"]
        guard endings.contains(where: { name.hasSuffix($0) }) else { return false }
        return !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
    }
}
