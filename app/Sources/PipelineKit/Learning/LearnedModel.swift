import Foundation
import Observation

/// What the learning screen knows, and the only thing that writes to it.
///
/// Four rules it keeps.
///
/// 1. **Every sentence on screen is the engine's**, worked out fresh by the
///    engine on each request. `copy` is the one seam where that could change,
///    and it has two implementations (`EngineWrittenCopy`, `ComposedCopy`).
/// 2. **"Use it anyway" is only reachable from the screen that showed him the
///    frames.** This model refuses it otherwise, so a command, a menu item or
///    a future caller cannot route around the review screen.
/// 3. **Going back runs the check first.** The engine does that; the app
///    re-reads the panel afterwards and shows whatever the engine decided,
///    including "it changed nothing".
/// 4. A refusal lands on the row that asked for it, never as an alert.
@MainActor @Observable
public final class LearnedModel {
    public private(set) var learned: Learned?
    public private(set) var loading = false
    /// Cleared only by the thing that wrote it (DESIGN.md §7.7).
    public let refusals = RefusalBoard()
    /// The one-line banner after a run lands, or pauses. Not a sheet, not an
    /// alert (§2.9).
    public private(set) var banner: String?
    /// The first learner the run changed, which the banner's What Changed
    /// brings into view. `nil` when nothing changed.
    public private(set) var bannerLearner: String?
    /// The row What Changed pointed at, lit for a moment so the eye lands.
    public private(set) var highlighted: String?
    /// The job a queued run is waiting behind, in the engine's own title for
    /// it, so "something else is running" can say what.
    public private(set) var inTheWay: String?
    /// The panel as it stood before the run being watched, so what the run
    /// changed can be said when it lands.
    private var beforeRun: Learned?
    /// Which watch is the current one. The newest wins: the page's
    /// `.task(id:)` starts a new watch when Learn Now is pressed, and the one
    /// it replaces is cancelled but may not have unwound yet.
    private var watchTurn = 0
    /// Stop was pressed on this run; its ending is his, and is said as such.
    private var stoppedByHim = false
    /// Which learner's row is waiting on an action of its own.
    public private(set) var busyLearner: String?
    /// Stop was pressed on the running row and the engine has not said so yet.
    public private(set) var stopping = false

    /// How often the panel asks again while the run is going.
    ///
    /// It has to ask: the row carries a bar, a stage in words and a count,
    /// and a page that loads once shows the first second of a six-minute job
    /// for six minutes. The poll exists only while there is something to
    /// watch, and it stops the moment the run ends — there is no heartbeat.
    public static let whileRunning: Duration = .seconds(2)
    /// Injected so a test can watch a run without waiting two seconds a look.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// The one seam. `EngineWrittenCopy` is what ships; the other exists so a
    /// panel from an engine that sends no sentence still reads as English.
    public var copy: any LearnerCopy = EngineWrittenCopy()

    private let client: StudioClient?

    public init(client: StudioClient?) { self.client = client }

    /// For the harness and the tests: a panel that already has its answer and
    /// never asks an engine.
    public init(preview: Learned, banner: String? = nil, bannerLearner: String? = nil) {
        self.client = nil
        self.learned = preview
        self.banner = banner
        self.bannerLearner = bannerLearner
    }

    public var learners: [Learner] { learned?.learners ?? [] }

    /// The row's one line. Always through the seam, never read off the model
    /// directly by a view.
    public func sentence(for learner: Learner) -> String { copy.sentence(learner) }

    public func learner(_ id: String) -> Learner? { learners.first { $0.id == id } }

    public func load() async {
        guard let client else { return }
        loading = learned == nil
        defer { loading = false }
        do {
            learned = try await client.get(Routes.learned())
            refusals.clear(.learning)
        } catch is CancellationError {
        } catch let e as StudioError {
            refusals.set(.learning, e.sentence)
        } catch {
            refusals.set(.learning, Strings.API.offline)
        }
    }

    /// The one Learn Now button, and the same job the automatic run uses.
    /// `why` is recorded: "you finished 2026-09-19".
    public func run(why: String? = nil) async {
        beforeRun = learned
        banner = nil
        bannerLearner = nil
        await post(Routes.learnedRun, LearnedRunBody(why: why), owner: .learning)
    }

    /// Measure a shoot's picture vectors, the Measure button beside a check
    /// that could not reach it. The engine starts it as his job, with a bar
    /// and a Stop; the check runs on the next Learn Now.
    public func measure(_ shoot: String) async {
        await post(Self.measureVectors, MeasureVectorsBody(shoot: shoot), owner: .learning)
    }

    static let measureVectors = Route<OK>(.post, "/api/learned/vectors")

    /// `POST /api/learned/vectors`.
    struct MeasureVectorsBody: Encodable, Sendable { let shoot: String }

    public func goBack(_ learner: Learner) async {
        busyLearner = learner.id
        defer { busyLearner = nil }
        await post(Routes.learnedBack, LearnedActionBody(learner: learner.id),
                   owner: .learner(learner.id))
    }

    public func stopUsing(_ learner: Learner) async {
        busyLearner = learner.id
        defer { busyLearner = nil }
        await post(Routes.learnedStop, LearnedActionBody(learner: learner.id),
                   owner: .learner(learner.id))
    }

    /// Only from the review screen, with the frames on screen. The version is
    /// the held candidate's, which is what the engine checks it against — so
    /// a stale call refuses rather than using something he never looked at.
    @discardableResult
    public func useAnyway(_ learner: Learner, sawFrames: Bool) async -> Bool {
        guard sawFrames, learner.can_use_anyway else {
            refusals.set(.learner(learner.id), Strings.Learning.readOnly)
            return false
        }
        busyLearner = learner.id
        defer { busyLearner = nil }
        return await post(Routes.learnedUseAnyway,
                          LearnedActionBody(learner: learner.id, version: learner.candidate_version),
                          owner: .learner(learner.id))
    }

    public func clearBanner() {
        banner = nil
        bannerLearner = nil
    }

    /// What Changed: light the row it points at, briefly.
    public func highlight(_ id: String?) async {
        highlighted = id
        try? await Task.sleep(for: .seconds(2.5))
        if highlighted == id { highlighted = nil }
    }

    /// Ask again, for as long as there is a run to watch or one waiting.
    ///
    /// Started by the screen when it appears and after Learn Now. It keeps
    /// asking while the run is queued behind other work — it used to stop at
    /// once, so a run that started a minute later was never seen to start —
    /// and when a run it saw going stops, it says what the run changed, or
    /// that his work paused it. Then it ends by itself: one pass after the
    /// run stops, so the row is seen to finish rather than freezing at 94%.
    ///
    /// It belongs to the task that asked for it and ends with that task: the
    /// page's own `.task(id:)`, which SwiftUI cancels when he leaves the page.
    /// Learn Now used to start it in a task of its own, which went on asking
    /// every two seconds for as long as a run queued behind his work waited —
    /// hours of culling, long after he had left the page — while a flag saying
    /// "already watching" kept the page's own watch from starting.
    public func watchWhileItRuns() async {
        guard client != nil else { return }
        watchTurn += 1
        let turn = watchTurn
        var sawItRun = learned?.running == true
        if sawItRun, beforeRun == nil { beforeRun = learned }
        while !Task.isCancelled, turn == watchTurn {
            if let l = learned, !l.running, !l.queued { return }
            do { try await sleep(Self.whileRunning) } catch { return }
            guard !Task.isCancelled, turn == watchTurn else { return }
            let was = learned
            await load()
            guard !Task.isCancelled, turn == watchTurn else { return }
            guard let now = learned else { continue }
            if now.running {
                if !sawItRun { beforeRun = beforeRun ?? was }
                sawItRun = true
                inTheWay = nil
                continue
            }
            if now.queued { await nameTheJobInTheWay() }
            if sawItRun {
                let said = Self.landed(before: beforeRun, after: now, stoppedByHim: stoppedByHim)
                banner = said.text
                bannerLearner = said.first
                beforeRun = nil
                stoppedByHim = false
                sawItRun = false
            }
            if !now.queued { inTheWay = nil; return }
        }
    }

    /// The engine's title for the job a queued run waits behind.
    private func nameTheJobInTheWay() async {
        guard let client, let j = try? await client.get(Routes.job()) else { return }
        inTheWay = j.running && !j.title.isEmpty && !j.background ? j.title : nil
    }

    /// What a run that was watched did, in one line, and the first learner it
    /// changed. Read off the panel before and after — which version is in
    /// use, which is waiting — and never off a number the engine did not send.
    ///
    /// DESIGN §2.9 promised this banner and nothing ever set it: the running
    /// row simply disappeared after six minutes and the page re-rendered, and
    /// he was never told whether anything went into use.
    static func landed(before: Learned?, after: Learned, stoppedByHim: Bool) -> (text: String, first: String?) {
        if stoppedByHim { return (Strings.Learning.stoppedBanner, nil) }
        // Stood down for his own work: it is asked for again, not finished.
        if after.queued { return (Strings.Learning.pausedForYou, nil) }
        let old = Dictionary((before?.learners ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var inUse: [Learner] = []
        var held: [Learner] = []
        for l in after.learners {
            let b = old[l.id]
            if let v = l.live_version, v != b?.live_version { inUse.append(l) }
            else if let v = l.candidate_version, v != b?.candidate_version, l.candidate_status == .not_in_use {
                held.append(l)
            }
        }
        let from = before?.new_shoot_names ?? []
        var parts = [from.isEmpty ? Strings.Learning.learnedBare : Strings.Learning.learnedFrom(from)]
        if inUse.count == 1, let l = inUse.first {
            parts.append(l.isStartingEdit ? Strings.Learning.bannerInUseEdit(l.title)
                                          : Strings.Learning.bannerInUse(l.title))
        } else if inUse.count > 1 {
            parts.append(inUse.contains(where: \.isStartingEdit)
                         ? Strings.Learning.bannerInUseManyWithEdit(inUse.count)
                         : Strings.Learning.bannerInUseMany(inUse.count))
        }
        if held.count == 1, let l = held.first { parts.append(Strings.Learning.bannerHeld(l.title)) }
        else if held.count > 1 { parts.append(Strings.Learning.bannerHeldMany(held.count)) }
        if inUse.isEmpty && held.isEmpty { parts.append(Strings.Learning.bannerNothing) }
        return (parts.joined(separator: " "), (inUse + held).first?.id)
    }

    /// Stop the run, from the row that is reporting it.
    ///
    /// Safe by construction, and the row says why above this button: nothing
    /// it has learned goes into use until it has been checked against every
    /// photograph he kept, so what is lost is the time spent and nothing
    /// else. It is asked for again the next time the Mac is idle.
    public func stopLearning() async {
        guard let client else { return }
        stopping = true
        stoppedByHim = true
        defer { stopping = false }
        do {
            let ok = try await client.post(Routes.jobStop, JobStopBody())
            if let e = ok.error, !e.isEmpty { refusals.set(.learning, e) }
        } catch let e as StudioError {
            refusals.set(.learning, e.sentence)
        } catch {}
        await load()
    }

    @discardableResult
    private func post<B: Encodable & Sendable>(_ route: Route<OK>, _ body: B,
                                               owner: RefusalOwner) async -> Bool {
        guard let client else { return false }
        do {
            let ok = try await client.post(route, body)
            if let e = ok.error, !e.isEmpty {
                refusals.set(owner, e)
                await load()
                return false
            }
            refusals.clear(owner)
        } catch let e as StudioError {
            refusals.set(owner, e.sentence)
            return false
        } catch {
            refusals.set(owner, Strings.API.offline)
            return false
        }
        await load()
        return true
    }
}

extension RefusalOwner {
    /// The learning screen as a whole.
    public static let learning = RefusalOwner("learning")
    /// One learner's row: a refusal about it lands on it and nowhere else.
    public static func learner(_ id: String) -> RefusalOwner { RefusalOwner("learner.\(id)") }
}

