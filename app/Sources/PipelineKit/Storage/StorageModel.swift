import Foundation
import Observation

/// What the storage panel knows, and the plan → token → apply round trip.
///
/// This is the most safety-critical object in the app, and it is written to
/// the rule in DESIGN.md §7.8: **the app never computes a plan, never re-uses
/// a token, and on `stale` it redraws the list rather than acting on a
/// confirmation that no longer describes what would happen.**
///
/// The round trip, exactly:
///
/// 1. `draw(_:options:)` POSTs to `/api/storage/plan`. The engine runs the
///    same command he would have typed, **without** `--apply`, as a job, and
///    writes down the state of the shoot it read.
/// 2. The app waits for that job and then GETs the plan. What comes back is
///    the command's own output and a token fingerprinting the state it was
///    drawn against.
/// 3. The sheet shows those lines verbatim. Nothing in them is parsed.
/// 4. `apply()` POSTs the token back. If the shoot has moved, the engine
///    answers `stale` with the list again and **no token**; the app shows
///    that list and draws a fresh one. It never applies.
/// 5. A token is spent by its apply. `plan` is cleared, so the same
///    confirmation cannot be handed back twice.
@MainActor @Observable
public final class StorageModel {
    public let shoot: String

    public private(set) var storage: Storage?
    public private(set) var frames: [StorageFrameRow]?
    public private(set) var loadingFrames = false

    /// The plan currently on screen, and what it was drawn for. Both are
    /// replaced together: a list and the options it was drawn under never
    /// disagree.
    public private(set) var plan: Plan?
    public private(set) var drawnFor: Request?
    public private(set) var drawing: Request?
    /// Set when the engine refused a confirmation because the shoot moved.
    public private(set) var wasRedrawn = false
    public private(set) var applying = false

    /// The job an apply or Check Every Original started, as the engine last
    /// described it: its own title, stage words, bar and time left. The panel
    /// draws its progress row from this and nothing else.
    public private(set) var following: Job?
    /// That job's number, from the moment the engine took it — so the buttons
    /// are off from the press, not from the first poll a second later. `0`
    /// from an engine that does not number its jobs.
    public private(set) var followingID: Int?
    /// How the last job this panel followed ended, said once on the panel, so
    /// he is told a copy worked without leaving the page to find out.
    public private(set) var ended: Ended?

    /// One job's ending: the engine's title for it, its outcome, and the last
    /// line it printed ("1558 unchanged · 0 drifted · …"), all as they came.
    public struct Ended: Sendable, Equatable {
        public let title: String
        public let outcome: Job.Outcome
        public let line: String
        public init(title: String, outcome: Job.Outcome, line: String) {
            self.title = title; self.outcome = outcome; self.line = line
        }
    }

    public let refusals = RefusalBoard()
    /// The job in the way, when one is. Kept as facts, not as a sentence to
    /// be read back out of, so the sheet can show its bar and offer the two
    /// choices (`BusyNotice`).
    public let busy = BusyBoard()
    /// The engine's line about the learning run it stood down so this could
    /// start. Not a refusal: the work went ahead.
    public private(set) var paused: String?
    /// Set once he has chosen to wait behind the job in the way. The request
    /// is in the engine's queue with this id, and `dontWait` takes it back.
    public private(set) var waitingID: Int?

    /// What a plan is drawn for. The options are part of it, because they are
    /// part of what the engine fingerprints.
    public struct Request: Sendable, Hashable {
        public let what: String
        public let options: PlanOptions
        public init(_ what: String, _ options: PlanOptions = .none) {
            self.what = what; self.options = options
        }
    }

    /// How long to wait for the drawing job before giving up. A dry run of a
    /// 1,558-frame shoot takes seconds; a minute is a wide margin, and giving
    /// up says so rather than spinning.
    public static let drawTimeout: Duration = .seconds(90)
    public static let pollInterval: Duration = .milliseconds(400)
    /// How often a job the panel started is asked about while it runs. There
    /// is no deadline on it: a 36 GB copy to iCloud takes as long as it takes.
    public static let followInterval: Duration = .seconds(1)

    private let client: StudioClient?
    /// Injected so a test can drive the round trip without sleeping.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    public init(shoot: String, client: StudioClient?) {
        self.shoot = shoot
        self.client = client
    }

    /// For the harness and the tests: a panel that already has its answer.
    ///
    /// `busy` and `paused` are here so the two states this change exists for
    /// can be drawn offscreen and looked at — a refusal that explains itself,
    /// and the line after the machine's homework stood down — without an
    /// engine, a job, or six minutes of waiting.
    public init(shoot: String, storage: Storage?, plan: Plan? = nil,
                drawnFor: Request? = nil, frames: [StorageFrameRow]? = nil,
                busy: Busy? = nil, refusal: String? = nil, paused: String? = nil,
                waitingID: Int? = nil, following: Job? = nil, ended: Ended? = nil) {
        self.shoot = shoot
        self.client = nil
        self.storage = storage
        self.plan = plan
        self.drawnFor = drawnFor
        self.frames = frames
        self.paused = paused
        self.waitingID = waitingID
        self.following = following
        self.followingID = following?.id
        self.ended = ended
        if let busy { self.busy.set(.storage, busy) }
        if let refusal { self.refusals.set(.storage, refusal) }
    }

    // MARK: reading

    public func load() async {
        guard let client else { return }
        do {
            storage = try await client.get(Routes.storage(shoot))
            refusals.clear(.storage)
        } catch is CancellationError {
        } catch let e as StudioError {
            refusals.set(.storage, e.sentence)
        } catch {
            refusals.set(.storage, Strings.API.offline)
        }
    }

    /// Only on the first opening of the fold: 1,157 rows are never built for
    /// a panel nobody has unfolded.
    public func loadFrames() async {
        guard let client, frames == nil, !loadingFrames else { return }
        loadingFrames = true
        defer { loadingFrames = false }
        do {
            frames = try await client.get(Routes.storageFrames(shoot)).rows
        } catch let e as StudioError {
            refusals.set(.storage, e.sentence)
        } catch {}
    }

    // MARK: the round trip

    /// Whether the list on screen is the list for this request. A sheet whose
    /// options have changed has no list until the new one lands, and its
    /// button is off until then.
    public func hasPlan(for request: Request) -> Bool {
        plan != nil && drawnFor == request && drawing == nil
    }

    public var isDrawing: Bool { drawing != nil }

    /// Ask the engine to draw the list. Nothing is computed here.
    public func draw(_ request: Request) async {
        guard let client else { return }
        // A list and the options it was drawn under never disagree, so the
        // old one goes the moment a different one is asked for.
        if drawnFor != request { plan = nil }
        drawnFor = request
        drawing = request
        wasRedrawn = false
        refusals.clear(.storage)
        defer { if drawing == request { drawing = nil } }

        do {
            let started = try await client.post(Routes.storagePlanDraw,
                                                PlanBody(name: shoot, what: request.what,
                                                         opts: request.options))
            guard note(started) else { return }
            try await waitForJob(client, id: started.id)
            let p = try await client.get(Routes.storagePlan(shoot, what: request.what,
                                                            opts: request.options))
            // Another request overtook this one while the job ran; that one
            // owns the sheet now.
            guard drawnFor == request else { return }
            if p.stale == true {
                // Drawn and already overtaken. Say nothing and draw again.
                await redraw(request)
                return
            }
            plan = p
            if let e = p.error, !e.isEmpty { refusals.set(.storage, e) }
        } catch let e as StudioError {
            refusals.set(.storage, e.sentence)
        } catch is CancellationError {
        } catch {
            refusals.set(.storage, Strings.API.offline)
        }
    }

    /// Hand the token back. The only thing in the app that starts a
    /// destructive job.
    ///
    /// `typed` is what he typed into the field; the engine checks it against
    /// the count **its own list** was drawn with, which is why the app passes
    /// it through rather than comparing it and deciding for itself.
    @discardableResult
    public func apply(_ request: Request, typed: String? = nil) async -> Bool {
        guard let client, let p = plan, drawnFor == request, let token = p.token, p.ready else {
            return false
        }
        applying = true
        defer { applying = false }
        refusals.clear(.storage)
        do {
            let r = try await client.post(Routes.storageApply,
                                          ApplyBody(name: shoot, what: request.what, token: token,
                                                    typed: typed, opts: request.options))
            if r.stale == true {
                // The engine hands back the list that was drawn, with no
                // token. Show it, then draw a fresh one. Nothing was applied.
                wasRedrawn = true
                if let again = r.plan { plan = again }
                await redraw(request)
                return false
            }
            // A job of his in the way, or the homework stood down for him.
            // Either way it is said here rather than swallowed: this is the
            // exact button that answered "a job is already running" and left
            // him with nowhere to go.
            guard note(r) else { return false }
            // Spent. The same confirmation is never handed back twice.
            plan = nil
            drawnFor = nil
            startFollowing(r.id)
            return true
        } catch let e as StudioError {
            refusals.set(.storage, e.sentence)
            return false
        } catch {
            refusals.set(.storage, Strings.API.offline)
            return false
        }
    }

    /// Reading and comparing only. The one storage job with no plan in front
    /// of it, because it removes nothing.
    public func checkEveryOriginal(record: Bool = false) async -> Bool {
        guard let client else { return false }
        do {
            let ok = try await client.post(Routes.storageCheck,
                                           StorageCheckBody(name: shoot, record: record))
            guard note(ok) else { return false }
            startFollowing(ok.id)
            return true
        } catch let e as StudioError {
            refusals.set(.storage, e.sentence); return false
        } catch { refusals.set(.storage, Strings.API.offline); return false }
    }

    public func setRetention(days: Int, asDefault: Bool) async {
        guard let client else { return }
        do {
            let r = try await client.post(Routes.storageRetain,
                                          RetainBody(name: shoot, days: days, default: asDefault))
            if let e = r.error, !e.isEmpty { refusals.set(.storage, e) } else { refusals.clear(.storage) }
        } catch let e as StudioError {
            refusals.set(.storage, e.sentence)
        } catch {}
        await load()
    }

    /// Drop everything that depends on what just changed, and read it again.
    public func reloadAfterJob() async {
        frames = nil
        plan = nil
        drawnFor = nil
        await load()
    }

    // MARK: the job it started

    /// Whether a job this panel started is still going. Every button on the
    /// panel waits for it: the engine has one slot, and a second press would
    /// only be told about his own job.
    public var isFollowing: Bool { followingID != nil }

    private func startFollowing(_ id: Int) {
        followingID = id
        following = nil
        ended = nil
        // The toolbar's Activity item, the Dock and the keep-awake lock follow
        // the one job model, which only looks when it is told something
        // started. A 36 GB copy is exactly the job the Mac must not sleep in.
        StepJobs.shared?().watch()
    }

    /// Pick up a job of this panel's kind that is already running on this
    /// shoot — one started before he left the page and came back to it — so
    /// the row is there again rather than the panel looking idle over it.
    public func adoptRunningJob() async {
        guard let client, followingID == nil,
              let j = try? await client.get(Routes.job()),
              j.running, j.shoot == shoot, j.kind.hasPrefix("stor-") else { return }
        followingID = j.id
        following = j
    }

    /// Watch the job the panel started until it stops, then read the panel
    /// again and say how it ended. By its number, as `waitForJob` does: a
    /// later number in the slot means this one ended between two looks.
    public func follow() async {
        guard let client else { return }
        while let id = followingID, !Task.isCancelled {
            do { try await sleep(Self.followInterval) } catch { return }
            let j: Job
            do {
                j = try await client.get(Routes.job())
            } catch is CancellationError {
                return
            } catch {
                // The engine is gone or restarting; there is nothing left to
                // watch. What is on disk is read again when it can be.
                await stopFollowing(nil)
                return
            }
            guard followingID == id else { return }
            if j.id == id || (id == 0 && j.shoot == shoot && j.kind.hasPrefix("stor-")) {
                if j.running {
                    following = j
                } else {
                    await stopFollowing(j)
                    return
                }
            } else if j.id > id || (!j.running && !j.queued) {
                // A later number in the slot, or nothing running and nothing
                // waiting: either way the job it follows is not coming, and a
                // panel that went on waiting for it would keep every button
                // off until he left the page.
                await stopFollowing(nil)
                return
            }
        }
    }

    /// `nil` when the job's own ending was not seen — another job took the
    /// slot before the next look. Then the panel says only that it ended,
    /// never a Done it did not read.
    ///
    /// The panel is read again **before** the job's number is let go. That
    /// number is the id of the panel's `.task(id: model.followingID)`, which is
    /// the task running this: clearing it first had SwiftUI cancel the task
    /// mid-reload, the storage read was cancelled with it, and the panel said
    /// "Finished copying… 54 copied and verified" over "nothing in iCloud · one
    /// copy", with Remove the Local RAWs still off on the old counts. Until
    /// the fresh counts land the buttons stay off, so none of them is ever
    /// judged on the figures from before the job.
    private func stopFollowing(_ j: Job?) async {
        let title = j?.title ?? following?.title ?? ""
        ended = Ended(title: title, outcome: j?.outcome ?? .idle, line: j?.refusalSentence ?? "")
        following = nil
        await reloadAfterJob()
        followingID = nil
    }

    public func clearEnded() { ended = nil }

    // MARK: -

    /// What a job-starting answer said, put where the panel will look.
    ///
    /// Three outcomes, and the panel needs all three. It started (and the
    /// machine's homework may have been stood down to let it, which is a line
    /// he is owed). It cannot start because another job of HIS is running,
    /// and then `busy` carries which one and how far along it is. Or the
    /// engine refused it for its own reasons, which is a sentence and nothing
    /// more.
    ///
    /// Returns whether it started.
    @discardableResult
    private func note<R: StartsAJob>(_ r: R) -> Bool {
        if let b = r.busy {
            busy.set(.storage, b)
            refusals.set(.storage, r.error ?? Strings.Job.waiting)
            paused = nil
            return false
        }
        busy.clear(.storage)
        waitingID = nil
        if let e = r.error, !e.isEmpty {
            refusals.set(.storage, e)
            paused = nil
            return false
        }
        refusals.clear(.storage)
        paused = r.paused.flatMap { $0.isEmpty ? nil : $0 }
        return true
    }

    public func clearPaused() { paused = nil }

    /// For the tests: the id of a request already in the engine's line, so
    /// taking it back out can be exercised without racing the queue.
    func setWaitingForTest(_ id: Int) { waitingID = id }

    /// Stop the job in the way, with what it is and where it has got to in
    /// front of him. His decision, on his own work; the panel never makes it.
    public func stopTheJobInTheWay() async {
        guard let client else { return }
        _ = try? await client.post(Routes.jobStop, JobStopBody())
        busy.clear(.storage)
        refusals.clear(.storage)
    }

    /// Take the request into the engine's own queue behind the job in the
    /// way. The queue already exists; this is the app asking for it by name,
    /// and keeping the id so he can take it back out again.
    public func waitForTurn(_ request: Request) async {
        guard let client else { return }
        do {
            let r = try await client.post(Routes.storagePlanDraw,
                                          PlanBody(name: shoot, what: request.what,
                                                   opts: request.options, queue: true))
            if let e = r.error, !e.isEmpty, r.busy == nil {
                refusals.set(.storage, e)
                return
            }
            waitingID = r.id
            busy.clear(.storage)
            refusals.clear(.storage)
            // Same round trip as `draw`, only it starts later.
            drawnFor = request
            drawing = request
            defer { if drawing == request { drawing = nil } }
            try await waitForJob(client, id: r.id)
            waitingID = nil
            guard drawnFor == request else { return }
            plan = try await client.get(Routes.storagePlan(shoot, what: request.what,
                                                           opts: request.options))
        } catch let e as StudioError {
            refusals.set(.storage, e.sentence)
        } catch is CancellationError {
        } catch {
            refusals.set(.storage, Strings.API.offline)
        }
    }

    /// Take a waiting request back out of the engine's line.
    public func dontWait() async {
        guard let client, let id = waitingID else { return }
        waitingID = nil
        drawing = nil
        _ = try? await client.post(Routes.jobCancel, JobStopBody(id: id))
    }

    private func redraw(_ request: Request) async {
        // One redraw, never a loop: if the shoot is moving under him, the
        // second list refuses on its own terms and says so.
        guard let client else { return }
        do {
            let started = try await client.post(Routes.storagePlanDraw,
                                                PlanBody(name: shoot, what: request.what,
                                                         opts: request.options))
            try await waitForJob(client, id: started.id)
            guard drawnFor == request || drawnFor == nil else { return }
            drawnFor = request
            plan = try await client.get(Routes.storagePlan(shoot, what: request.what,
                                                           opts: request.options))
        } catch let e as StudioError {
            refusals.set(.storage, e.sentence)
        } catch {}
    }

    /// The drawing runs as a job, so the list is not there until it ends.
    ///
    /// It waits for **that** job, by the id the engine gave it, and not for
    /// "nothing is running". Those used to be the same thing and are not any
    /// more: the learning run stands down for his work and picks itself up
    /// again afterwards, so a wait for an idle engine would sit here until it
    /// timed out while the list it wanted had been on disk for a minute. An
    /// engine that sends no ids (`id == 0`) gets the old behaviour, which is
    /// the best that can be done with what it says.
    private func waitForJob(_ client: StudioClient, id: Int = 0) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.drawTimeout
        while clock.now < deadline {
            try await sleep(Self.pollInterval)
            let j = try await client.get(Routes.job())
            guard id > 0 else {
                if !j.running { return }
                continue
            }
            // Past it (a later job holds the slot), or it is this one and it
            // has stopped. Either way the drawing is over.
            if j.id > id { return }
            if j.id == id && !j.running { return }
        }
    }
}
