import Foundation

/// The work the engine finished in the last few days, every run of it, read
/// back from its own record so the Activity window can show last night's list
/// in the morning (DESIGN.md §2.7). It said "Nothing has run yet in this
/// session" after every quit.
public struct EarlierJobs: FieldDecodable {
    /// The engine running now. Its own jobs are followed as they happen
    /// (`JobModel`); only the other runs' are read from here.
    public let run: String
    public let jobs: [EarlierJob]

    public init(fields f: Fields) throws {
        run = f.string("run")
        jobs = f.objects("jobs").compactMap { try? EarlierJob(fields: $0) }
    }

    /// Every job of an engine that is not this one.
    public var beforeThisRun: [EarlierJob] { jobs.filter { $0.run != run } }
}

/// One finished piece of work, as the engine wrote it down when it ended.
public struct EarlierJob: FieldDecodable, Equatable {
    public let run: String
    public let id: Int
    public let kind, title, shoot, why, log: String
    public let background, fromList: Bool
    public let started: Date
    public let elapsed: Int
    /// `done`, `stopped`, `refused` or `failed`, the engine's word.
    public let outcome: String

    public init(fields f: Fields) throws {
        run = f.string("run"); id = f.int("id")
        kind = f.string("kind"); title = f.string("title"); shoot = f.string("shoot")
        why = f.string("why"); log = f.string("log")
        background = f.bool("background"); fromList = f.bool("from_list")
        started = Date(timeIntervalSince1970: f.double("started"))
        elapsed = f.int("elapsed")
        outcome = f.string("outcome")
    }

    /// The engine's word as the history's outcome, by the list's own rule.
    public var ended: Job.Outcome {
        QueueDone(id: id, kind: kind, outcome: outcome).ended
    }

    /// As the history holds it: finished, with its log, and not this
    /// engine's to follow.
    var job: Job {
        Job(running: false, stopped: ended == .stopped, id: id, kind: kind, shoot: shoot, title: title,
            log: log, fraction: ended == .done ? 1 : 0, elapsed: elapsed, background: background,
            why: why, fromList: fromList, startedAt: started)
    }
}
