import Foundation
import Observation
import AppKit

/// The engine's one job queue, as the app sees it. One, for the life of the app.
///
/// The poll is one `Task`. It asks `GET /api/job` every 1.2 s while a job runs,
/// goes on for 5 s after it ends so "Done" is seen, then stops entirely. It
/// backs off to 3 s when the app is not frontmost. It starts on any
/// job-starting POST, once at launch, in case a job outlived a window, and
/// whenever the list's own poll sees something running that this one is not
/// watching (DESIGN.md §3.6). There is no unconditional heartbeat.
@MainActor @Observable
public final class JobModel {
    public private(set) var job: Job?
    /// The jobs of the last few days, newest last, for the Activity window:
    /// the earlier runs' read back from the engine's record once at launch
    /// (`readEarlier`), then this session's as they happen.
    public private(set) var history: [Record] = []
    public let refusals = RefusalBoard()
    /// The job in the way, when a start could not have it. Kept as the facts
    /// the engine sent rather than parsed back out of its sentence, so a
    /// screen can draw the bar and offer the two choices (`BusyNotice`).
    public let busy = BusyBoard()
    /// The line after the machine's homework was stood down for his work.
    /// A note, not a refusal, and it is the engine's sentence.
    public private(set) var paused: [RefusalOwner: String] = [:]
    /// The history's rows that had ended while the Activity window was open,
    /// so it opens next time on news rather than on a failure he has read.
    /// Nothing draws this.
    @ObservationIgnored public var readInActivity: Set<UUID> = []

    public struct Record: Identifiable, Sendable, Equatable {
        public let id: UUID
        public var job: Job
        public let started: Date
        /// Frozen the instant the job stops, and never recomputed from the
        /// wall clock (DESIGN.md §7.11).
        public var elapsed: Int
        public var outcome: Job.Outcome
        /// Which run of the engine it came from. The engine numbers its jobs
        /// afresh from what it last wrote down, so a number is only the same
        /// job within one run of it.
        var engine: Int = 0
        /// Read back from before this session: never followed, never news.
        public var earlier = false
    }

    public static let runningInterval: Duration = .milliseconds(1200)
    public static let backgroundInterval: Duration = .seconds(3)
    public static let lingerAfterEnd: Duration = .seconds(5)

    // The poll's own bookkeeping is not something a screen draws, so it is
    // not observed (see `QueueModel`).
    @ObservationIgnored private var client: StudioClient?
    /// Counts the engines this model has been attached to.
    @ObservationIgnored private var engine = 0
    /// Whether the earlier sessions' jobs have been read, which is once: an
    /// engine that restarts mid-session has written down jobs this model
    /// already followed.
    @ObservationIgnored private var readEarlierOnce = false
    @ObservationIgnored private var poll: Task<Void, Never>?
    /// Whether a poll is alive: from `watch()` until it stops by itself or
    /// is cancelled. Counted, so a cancelled poll finishing late cannot mark
    /// the one that replaced it as stopped.
    @ObservationIgnored public private(set) var isWatching = false
    @ObservationIgnored private var pollNumber = 0
    /// The list's poll, woken when this one sees work running. The list
    /// started a job he walked away from, or he started one by hand: either
    /// way both screens have to know, and neither poll can be relied on to
    /// be running already (DESIGN.md §3.6).
    @ObservationIgnored weak var list: QueueModel?
    /// Told once when a job comes to an end, so what the library says about
    /// that shoot can be read again. Including a job that ended before any
    /// poll saw it running — a small presets job, or one that finished while
    /// nothing was watching — which is recorded already finished.
    public var onJobEnded: (@MainActor (Job) -> Void)?
    /// Told every answer about the slot, before anything else is done with
    /// it — including a fresh engine's, which names no job and is otherwise
    /// passed over. A copy of the card that the engine no longer holds is
    /// only found out this way (`ImportModel.jobSeen`).
    public var onJobSeen: (@MainActor (Job) -> Void)?
    /// The engine's number for the last job told as ended, so the five
    /// seconds of polling after an end are not five more endings.
    @ObservationIgnored private var toldEnded: Int?

    /// Injected so the poll can be tested without an app being frontmost.
    var isFrontmost: @MainActor () -> Bool = { NSApp?.isActive ?? true }

    public init(client: StudioClient? = nil) { self.client = client }

    public func attach(_ client: StudioClient?) {
        // Another engine, or none: whatever the last one was running went
        // with it, and the history says so rather than "Running" for ever.
        if client !== self.client {
            closeTheLost()
            engine += 1
        }
        self.client = client
        cancelWatching()
        if client != nil, !readEarlierOnce {
            readEarlierOnce = true
            Task { await readEarlier() }
        }
    }

    /// The jobs of the last few days that ran before this session, from the
    /// engine's own record, put before this session's. Once, at launch: last
    /// night's list is there in the morning, with its outcomes and its logs,
    /// where Activity used to say nothing had run.
    public func readEarlier() async {
        guard let client, let e = try? await client.get(QueueRoutes.earlier()) else { return }
        adoptEarlier(e.beforeThisRun)
    }

    /// Put these before this session's own rows, oldest first. Public for
    /// the harness and the tests.
    public func adoptEarlier(_ jobs: [EarlierJob]) {
        let rows = jobs.sorted { $0.started < $1.started }.map {
            Record(id: UUID(), job: $0.job, started: $0.started, elapsed: $0.elapsed,
                   outcome: $0.ended, engine: -1, earlier: true)
        }
        history = rows + history.filter { !$0.earlier }
    }

    public var isRunning: Bool { job?.running ?? false }

    /// True while the machine's own homework holds the slot. Nothing he
    /// presses waits on this: the engine stands it down. It exists so a
    /// screen can tell a running background job apart from his own work
    /// rather than treating "something is running" as one thing.
    public var isBackgroundOnly: Bool { job?.running == true && job?.background == true }

    /// Whatever a job-starting answer said, put where the screen that asked
    /// for it will look: the busy job, the engine's sentence, and the line
    /// about the homework standing down. One place, so every caller reports
    /// the same three things the same way.
    ///
    /// Returns whether the job actually started.
    @discardableResult
    public func took<R: StartsAJob>(_ r: R, for owner: RefusalOwner) -> Bool {
        if let b = r.busy {
            busy.set(owner, b)
            refusals.set(owner, r.error ?? Strings.Job.waiting)
            paused[owner] = nil
            return false
        }
        busy.clear(owner)
        if let e = r.error, !e.isEmpty {
            refusals.set(owner, e)
            paused[owner] = nil
            return false
        }
        refusals.clear(owner)
        // The engine's own sentence about what it put down, or ours if it is
        // an engine that stands things down without saying so.
        paused[owner] = r.paused.flatMap { $0.isEmpty ? nil : $0 }
        return true
    }

    public func clearPaused(_ owner: RefusalOwner) { paused[owner] = nil }

    /// He left the page that pressed. What the engine said to that press -
    /// a refusal, the job in the way, the homework it stood down - belongs
    /// under the button he pressed, and the steps all read one slot: left
    /// there, the presets' "no editor found" sat in red under Cull It on
    /// another shoot, and under Cut It on Reels, until some job next started
    /// (DESIGN.md §7.6).
    public func leftThePage() {
        refusals.clear(.job)
        busy.clear(.job)
        paused[.job] = nil
    }

    /// Stop the job that is in the way of `owner`'s request, and forget that
    /// it was. He asked for this with the frames of it in front of him.
    public func stopTheJobInTheWay(of owner: RefusalOwner) async {
        await stop()
        busy.clear(owner)
        refusals.clear(owner)
    }

    /// Runs the POST that starts a job, then watches it. A refusal from the
    /// POST lands on the job's refusal row, never as an alert.
    public func start(_ run: @Sendable () async throws -> Void) async {
        do {
            try await run()
            refusals.clear(.job)
        } catch let e as StudioError {
            refusals.set(.job, e.sentence)
        } catch is CancellationError {
            return
        } catch {
            refusals.set(.job, Strings.API.offline)
        }
        watch()
    }

    public func stop() async {
        guard let client else { return }
        do {
            let ok = try await client.post(Routes.jobStop, EmptyBody())
            if let e = ok.error { refusals.set(.job, e) } else { refusals.clear(.job) }
        } catch let e as StudioError {
            refusals.set(.job, e.sentence)
        } catch {}
        watch()
    }

    /// Stop the job with this number and nothing else. The engine stops it
    /// when it is the one running; any other number is only ever taken off
    /// the list, so a stop that arrives after that job ended cannot stop
    /// whatever started in its place. `nil` is an engine that does not
    /// number its jobs, and stops what is running.
    public func stop(id: Int?) async {
        guard let id else { await stop(); return }
        guard let client else { return }
        do {
            let ok = try await client.post(Routes.jobStop, JobStopBody(id: id))
            if let e = ok.error { refusals.set(.job, e) } else { refusals.clear(.job) }
        } catch let e as StudioError {
            refusals.set(.job, e.sentence)
        } catch {}
        watch()
    }

    /// Ask once now and keep asking while there is something to see.
    public func watch() {
        guard client != nil else { return }
        poll?.cancel()
        pollNumber += 1
        let n = pollNumber
        isWatching = true
        poll = Task { [weak self] in
            await self?.runPoll()
            self?.pollEnded(n)
        }
    }

    /// Start watching unless a poll is already alive. What the list's poll
    /// calls on every reading that has something running, so it must not
    /// restart a poll that is already there: that would ask again at once,
    /// every time, and the two polls would drive each other flat out.
    public func keepWatching() {
        guard !isWatching else { return }
        watch()
    }

    public func cancelWatching() {
        poll?.cancel()
        poll = nil
        pollNumber += 1
        isWatching = false
    }

    private func pollEnded(_ n: Int) {
        guard n == pollNumber else { return }
        poll = nil
        isWatching = false
    }

    private func runPoll() async {
        var endedAt: ContinuousClock.Instant?
        let clock = ContinuousClock()
        while !Task.isCancelled {
            guard let client else { return }
            do {
                let j = try await client.get(Routes.job())
                // A poll replaced while its answer was on the way: the answer
                // is from before whatever replaced it — a copy just started
                // would read it as the slot holding something else.
                guard !Task.isCancelled else { return }
                take(j)
                if j.running {
                    endedAt = nil
                } else if endedAt == nil {
                    endedAt = clock.now
                }
            } catch is CancellationError {
                return
            } catch {
                // The engine is down or restarting; EngineHost says so. This
                // poll stops rather than hammering a dead port.
                return
            }
            if let e = endedAt, clock.now - e >= Self.lingerAfterEnd { return }
            let wait = isFrontmost() ? Self.runningInterval : Self.backgroundInterval
            try? await Task.sleep(for: wait)
        }
    }

    /// Take one answer from `GET /api/job`. Public so the snapshot harness
    /// can put a running job in front of the window and photograph it, which
    /// is the only way to look at a six-minute job without waiting six
    /// minutes for it.
    public func take(_ j: Job) {
        job = j
        onJobSeen?(j)
        // Running work changes what every step's button does - it adds to
        // the list instead of starting - and only the list's poll can say so.
        if j.running { list?.keepWatching() }
        // A fresh engine that has run nothing: a record still running
        // belongs to one that is gone.
        guard !j.kind.isEmpty else { closeTheLost(); return }
        // A record still running that is not this job ended between two
        // looks: the list starts its next piece the instant one ends, so the
        // poll very rarely sees the end of any but the last.
        closeTheOvertaken(by: j)
        if j.id > 0 {
            // Keyed by the engine's own number, which it never reuses, so a
            // second run of the same thing on the same shoot - the presets
            // written again, and failing - is a row of its own, not the first
            // run's "Done" left standing.
            if let i = history.lastIndex(where: { $0.job.id == j.id && $0.engine == engine }) {
                update(i, with: j)
            } else {
                append(j)
            }
            return
        }
        // An engine that does not number its jobs: kind and shoot are all
        // there is to go on.
        if let i = history.lastIndex(where: { Self.sameWork($0.job, j) && $0.outcome == .running }) {
            update(i, with: j)
        } else if j.running || !history.contains(where: { Self.sameWork($0.job, j) }) {
            append(j)
        }
    }

    private func update(_ i: Int, with j: Job) {
        let wasRunning = history[i].outcome == .running
        history[i].job = j
        // The elapsed time moves while it runs and freezes at the reading
        // that says it stopped; it is never recomputed (§7.11).
        if j.running || wasRunning { history[i].elapsed = j.elapsed }
        history[i].outcome = j.outcome
        if !j.running && wasRunning { tellEnded(j) }
    }

    private func append(_ j: Job) {
        history.append(Record(id: UUID(), job: j, started: j.startedAt ?? Date(),
                              elapsed: j.elapsed, outcome: j.outcome, engine: engine))
        if !j.running { tellEnded(j) }
    }

    private static func sameWork(_ a: Job, _ b: Job) -> Bool {
        if a.id > 0 && b.id > 0 { return a.id == b.id }
        return a.kind == b.kind && a.shoot == b.shoot
    }

    /// Every record still running that is not `j`: closed with the word the
    /// list wrote down for it when it came off the list, and otherwise as
    /// "ended" - the app did not see how, and a guess of "Done" would be a
    /// failure dressed as one.
    private func closeTheOvertaken(by j: Job) {
        for i in history.indices where history[i].outcome == .running && !Self.sameWork(history[i].job, j) {
            let lost = history[i].job
            history[i].outcome = j.listDone.first { $0.id == lost.id && lost.id > 0 }?.ended ?? .idle
            tellEnded(lost)
        }
    }

    /// Every record still running, when the engine that ran it is gone:
    /// Failed, with a line under its log that says why. It used to stay
    /// "Running" for the rest of the evening, with no Stop and no failure.
    /// Badged on the Dock like any failure of his work (§2.7): the engine
    /// going down under it overnight is the failure the badge is for.
    private func closeTheLost() {
        for i in history.indices where history[i].outcome == .running {
            let lost = history[i].job
            if !lost.background {
                DockProgress.noteFailure(id: lost.id, kind: lost.kind, shoot: lost.shoot)
            }
            history[i].outcome = .failed
            history[i].job = Job(running: false, stopped: false, id: lost.id, queued: lost.queued,
                                 kind: lost.kind, shoot: lost.shoot, title: lost.title,
                                 stage: lost.stage, label: lost.label,
                                 log: [lost.log, Strings.Activity.engineStoppedWhileRunning]
                                    .filter { !$0.isEmpty }.joined(separator: "\n"),
                                 fraction: lost.fraction, elapsed: history[i].elapsed,
                                 background: lost.background, why: lost.why,
                                 fromList: lost.fromList, startedAt: lost.startedAt)
        }
    }

    private func tellEnded(_ j: Job) {
        if j.id > 0 {
            guard j.id != toldEnded else { return }
            toldEnded = j.id
        }
        onJobEnded?(j)
    }
}
