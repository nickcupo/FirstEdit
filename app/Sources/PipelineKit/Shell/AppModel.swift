import Foundation
import Observation
import AppKit

/// The engine, the library, the job queue and the update line, wired
/// together once for the life of the app.
@MainActor @Observable
public final class AppModel {
    public let engine: EngineHost?
    public private(set) var engineState: EngineHost.State
    public let library: Library
    public let jobs: JobModel
    public let updates: UpdateCoordinator
    public let navigation: Navigation
    /// Copy the Card: the cards going in and out, and the copy he started,
    /// for as long as the app is open (§2.6).
    public let importModel = ImportModel()
    /// "The engine stopped and was restarted. Nothing you decided was lost."
    /// A quiet line, not an alert. It goes by itself after `bannerLingers`,
    /// when he moves to another page, or when he closes it; it was cleared
    /// only by a click on it that nothing invited, and sat over the light
    /// table for the rest of the evening.
    public var banner: String? {
        didSet {
            bannerGoes?.cancel()
            guard let shown = banner else { return }
            bannerGoes = Task { [weak self] in
                try? await Task.sleep(for: Self.bannerLingers)
                guard !Task.isCancelled, let self, self.banner == shown else { return }
                self.banner = nil
            }
        }
    }
    private var bannerGoes: Task<Void, Never>?
    static var bannerLingers: Duration = .seconds(8)
    public private(set) var client: StudioClient?
    public private(set) var pump: ImagePump?
    /// Set by the app: what to do when the updater prints `QUIT`.
    public var onQuitRequested: (@MainActor () -> Void)?
    /// Set by the app: the engine is up and the library has been read. The
    /// endpoint and the per-launch key change on every engine restart, and
    /// what the extension declares changes with the library, so anything that
    /// holds either is re-registered here rather than once at launch.
    public var onConnected: (@MainActor (AppModel) -> Void)?

    private var watchers: [Task<Void, Never>] = []

    /// Where he left off is read from, and written to, here. `nil` — the
    /// harness, the smoke run — neither restores nor remembers anything.
    public var memory: SettingsStore?
    /// The folder the engine is reading, as `LastPlace` spells it.
    public var libraryFolder: @MainActor () -> String = { LastPlace.folder(AppPaths.engineLibrary()) }
    /// The folder the engine is reading, for the empty sidebar to look in.
    /// Asked off the main actor — reading the setting resolves it on disk —
    /// and injected so a snapshot never looks in his real library.
    public var engineLibrary: @Sendable () -> URL = { AppPaths.engineLibrary() }
    /// The engine whose library has been read and whose window has been put
    /// where it belongs. Until then the detail shows "Starting", so the first
    /// page he sees is the right one rather than All Shoots for a moment.
    private var readyFor: EngineHost.Endpoint?
    private var restored = false
    private let preview: Bool

    public init(engine: EngineHost, memory: SettingsStore? = .shared) {
        self.engine = engine
        self.engineState = .stopped
        self.library = Library()
        self.jobs = JobModel()
        self.updates = UpdateCoordinator()
        self.navigation = Navigation(selection: .allShoots)
        self.preview = false
        self.memory = memory
        importModel.attach(self)
        rememberPlaces()
        followTheCounts()
    }

    /// For the snapshot harness: no engine, a library that already has its
    /// answer, and whatever engine state the scene wants to show.
    public init(preview library: Library, state: EngineHost.State, navigation: Navigation) {
        self.engine = nil
        self.engineState = state
        self.library = library
        self.jobs = JobModel()
        self.updates = UpdateCoordinator()
        self.navigation = navigation
        self.preview = true
        self.memory = nil
        // The harness and previews never read a card plugged into the Mac
        // they run on: a scene's card is the one it hands in.
        importModel.readCard = { _ in nil }
        importModel.attach(self)
        rememberPlaces()
        followTheCounts()
    }

    /// The engine is running, and the window is where it should be.
    public var isReady: Bool {
        guard case .running(let e) = engineState else { return false }
        return preview || readyFor == e
    }

    /// Bursts been through, and bursts: the open session's own, which moves
    /// with every N, when there is one; the library's line otherwise. The
    /// library's line is read once and was never read again, so "3 of 19
    /// bursts" in the title and "3/19" in the sidebar sat still for a whole
    /// evening in Choose Keepers.
    public func bursts(for shoot: String) -> (seen: Int, of: Int)? {
        if let s = library.cachedSession(for: shoot), !s.bursts.isEmpty {
            return (s.bursts.lazy.filter(\.seen).count, s.bursts.count)
        }
        guard let row = library.row(named: shoot) else { return nil }
        return (row.seen, row.bursts)
    }

    /// Kept, frames and finished are the engine's to count (his K, and the
    /// cull's call in a burst he has been through), so they are read again
    /// rather than worked out here: when a job ends, and when he leaves a
    /// shoot's step.
    func followTheCounts() {
        jobs.onJobEnded = { [weak self] job in
            guard let self else { return }
            // A card's copy ends wherever he is: its eject and its sentence
            // are the app's to see to, not the card page's (§2.6).
            self.importModel.jobEnded(job)
            self.jobEnded(job)
            Task { await self.library.refreshSoon() }
        }
        jobs.onJobSeen = { [weak self] job in self?.importModel.jobSeen(job) }
    }

    /// The job that has just ended, for the toolbar's status item to say so.
    /// When a job ended while he was looking at the app, the item simply
    /// disappeared: done, stopped and failed all looked the same — gone —
    /// and notifications only speak when the app is not in front.
    public private(set) var justEnded: Job?
    private var endedFades: Task<Void, Never>?
    /// How long "done" and "stopped" stay in the toolbar. A refusal or a
    /// failure stays until he has looked.
    static let doneLingers: Duration = .seconds(6)

    /// A job that finished, or that he stopped, is said for a moment and
    /// then goes; one that was refused or failed stays until he clicks it,
    /// and another job's success does not bury it. The same work — its kind
    /// and its shoot — run again and finished does: "Cull · Failed" sat in
    /// the toolbar after a good re-cull until he clicked it. The machine's
    /// own homework finishing is not news.
    func jobEnded(_ j: Job) {
        let outcome = j.outcome
        guard outcome != .idle, outcome != .running else { return }
        let stays = Self.stays(j)
        if !stays {
            if j.background { return }
            if let held = justEnded, Self.stays(held) {
                guard outcome == .done, held.kind == j.kind, held.shoot == j.shoot else { return }
            }
        }
        justEnded = j
        endedFades?.cancel()
        guard !stays else { return }
        endedFades = Task { [weak self] in
            try? await Task.sleep(for: Self.doneLingers)
            guard !Task.isCancelled, let self, self.justEnded?.id == j.id else { return }
            self.justEnded = nil
        }
    }

    /// An ending he has to read — the engine said no, or the job broke —
    /// rather than one he expected.
    static func stays(_ o: Job.Outcome) -> Bool { o == .refused || o == .failed }

    /// The same, for one job: a storage plan the engine turned down on
    /// purpose ("has no archive manifest") is said where he asked for it, in
    /// the Storage panel, so the toolbar says it for a moment like a finished
    /// job rather than holding it until he clicks. A plan that failed stays.
    static func stays(_ j: Job) -> Bool {
        guard stays(j.outcome) else { return false }
        return !(j.outcome == .refused && j.kind.hasPrefix("plan-"))
    }

    /// He has looked.
    public func dismissEnded() {
        endedFades?.cancel()
        justEnded = nil
    }

    private func rememberPlaces() {
        navigation.onPlace = { [weak self] shoot, step in
            guard let self, let memory = self.memory else { return }
            let here = self.libraryFolder()
            memory.lastPlace = LastPlace(library: here, shoot: shoot, step: step)
            guard step != nil else { return }
            // Only the shoots the library holds, so a map of every shoot he
            // ever renamed or let go of does not grow for ever.
            let names = Set(self.library.rows.map(\.name))
            let steps = self.library.loaded ? self.navigation.lastStepIn.filter { names.contains($0.key) }
                                            : self.navigation.lastStepIn
            let now = ShootSteps(library: here, steps: steps)
            if memory.shootSteps != now { memory.shootSteps = now }
        }
        navigation.onInspectorPinned = { [weak self] shown in self?.memory?.inspectorPinned = shown }
        if let pinned = memory?.inspectorPinned { navigation.restoreInspectorPin(pinned) }
        navigation.onFinishedChoice = { [weak self] open in self?.memory?.finishedExpanded = open }
        if let open = memory?.finishedExpanded { navigation.restoreFinishedChoice(open) }
    }

    /// Once, at launch, after the library has been read: the shoot and the
    /// step he was on. A read and a selection — never a job, never a sheet.
    /// Anything that no longer holds lands on All Shoots and says nothing.
    ///
    /// Only while the window is still on its launch default: a click he made
    /// while the engine was starting is his, and it wins.
    func restorePlace() {
        guard !restored, library.loaded else { return }
        restored = true
        recallSteps()
        guard let memory, navigation.selection == .allShoots,
              let last = memory.lastPlace,
              let place = last.selection(library: libraryFolder(), shoots: library.shoots, ext: library.ext)
        else { return }
        navigation.restore(place, finished: library.row(named: last.shoot)?.finished ?? false)
    }

    /// Where he left off, when it is in the folder the engine is reading and
    /// the window is still on its launch default.
    private func rememberedHere() -> LastPlace? {
        guard let last = memory?.lastPlace, last.library == libraryFolder(),
              navigation.selection == .allShoots else { return nil }
        return last
    }

    /// Opens the remembered shoot as soon as its own answer is here. The
    /// engine answering for it says it is there and readable; the step is
    /// kept when the shoot still has it. When the list lands,
    /// `keepSelectionInLibrary` holds it to the list like any other.
    private func openEarly(_ last: LastPlace, on e: EngineHost.Endpoint) async {
        guard let s = try? await library.session(for: last.shoot),
              !restored, navigation.selection == .allShoots, client?.endpoint == e else { return }
        restored = true
        recallSteps()
        navigation.restore(Self.place(last, in: s), finished: false)
        readyFor = e
    }

    /// The step he was last on in each shoot of this library, from the last
    /// launch, and the shoot he was last in, so a click on a shoot and ⌘J
    /// from a library page go where he was (§2.1). Read with the place he
    /// reopens on, once.
    private func recallSteps() {
        guard let memory else { return }
        let here = libraryFolder()
        var steps = memory.shootSteps.flatMap { $0.library == here ? $0.steps : nil } ?? [:]
        let last = memory.lastPlace.flatMap { $0.library == here ? $0 : nil }
        if let last, let step = last.step { steps[last.shoot] = step }
        navigation.recall(steps, lastShoot: last?.shoot)
    }

    // MARK: - arriving at a shoot

    /// The shoot's steps as the app knows them now: the open session's, the
    /// engine's on the library's row, or the fixed list before either.
    public func steps(of shoot: String) -> [StepState] {
        if let s = library.cachedSession(for: shoot) { return s.steps }
        let row = library.row(named: shoot)
        if let steps = row?.steps { return steps.map { $0.namedByTheApp(library.ext) } }
        return Fallbacks.listSteps(canCutReels: row?.can_cut_reels ?? true, ext: library.ext)
            .map { $0.namedByTheApp(library.ext) }
    }

    /// Where arriving at a shoot goes (§2.1, "Clicking a shoot"): the step
    /// he was last on in it, else the step it is up to, else its own page.
    /// A broken shoot is its own page, which is its one row's way in.
    public func place(in shoot: String) -> SidebarSelection {
        guard !library.broken.contains(where: { $0.name == shoot }) else { return .shoot(shoot) }
        return navigation.place(in: shoot, has: steps(of: shoot), next: library.row(named: shoot)?.upTo?.id)
    }

    /// His click on a shoot's row, in the sidebar or All Shoots. A shoot he
    /// is not in opens where he was in it; the row of the shoot he is already
    /// in is its own page, which is how the summary is reached.
    public func open(shoot: String) {
        navigation.selection = navigation.shoot == shoot ? .shoot(shoot) : place(in: shoot)
    }

    /// The remembered place in an open shoot: the step when the shoot has it,
    /// the shoot's own page when it does not.
    static func place(_ last: LastPlace, in s: ShootSession) -> SidebarSelection {
        guard let step = last.step else { return .shoot(last.shoot) }
        return s.steps.contains { $0.id == step } ? .step(shoot: last.shoot, step: step) : .shoot(last.shoot)
    }

    /// The shoot he left off in, for the title while the engine starts, so
    /// the window does not say All Shoots and then jump.
    public var shootBeingReopened: String? {
        guard !isReady, !restored else { return nil }
        return memory?.lastPlace.flatMap { $0.library == libraryFolder() ? $0.shoot : nil }
    }

    /// After a restart — a crash, or a new library folder from Settings — the
    /// shoot on screen may not be in the library any more. All Shoots, not a
    /// page for a shoot that is not there.
    func keepSelectionInLibrary() {
        guard library.loaded, let shoot = navigation.shoot,
              !library.rows.contains(where: { $0.name == shoot }) else { return }
        navigation.selection = .allShoots
    }

    public var logURL: URL? { engine?.logURL }

    /// Start the engine and keep the rest of the app in step with it.
    public func launch() async {
        guard let engine else { return }
        importModel.watch()
        if watchers.isEmpty {
            watchers.append(Task { [weak self] in
                for await s in engine.states { self?.engineChanged(s) }
            })
            watchers.append(Task { [weak self] in
                for await n in engine.notices { self?.notice(n) }
            })
        }
        do {
            let e = try await engine.start()
            await connected(e)
        } catch {
            // The state stream has already carried `.failed(why)`, which is
            // what the window shows.
        }
    }

    public func restartEngine() async {
        guard let engine else { return }
        banner = nil
        do {
            let e = try await engine.restart()
            await connected(e)
        } catch {}
    }

    private func engineChanged(_ s: EngineHost.State) {
        engineState = s
        switch s {
        case .running(let e):
            if client?.endpoint != e { Task { await self.connected(e) } }
        case .failed, .stopped:
            jobs.cancelWatching()
        case .starting:
            break
        }
    }

    /// The line after a crash that cut off a piece of work, once the new
    /// engine has said which (`sayWhatTheCrashCutOff`).
    private var cutOffLine: String?

    private func notice(_ n: EngineHost.Notice) {
        switch n {
        case .restartedAfterCrash: banner = cutOffLine ?? Strings.Engine.restarted
        case .quitRequested: onQuitRequested?()
        }
    }

    private func connected(_ e: EngineHost.Endpoint) async {
        if client?.endpoint == e { return }
        // A second endpoint is a new engine: a crash, or a new library
        // folder. It knows nothing of the job the last one was running.
        let restarted = client != nil
        let c = StudioClient(endpoint: e)
        let p = ImagePump(client: c)
        client = c
        pump = p
        library.attach(client: c, pump: p)
        jobs.attach(c)
        updates.attach(c)
        // Settings' rows whose value is the engine's (§2.11).
        EngineSettings.shared.attach(c)
        // The shoot he left off in is asked for beside the list, not after
        // it: the list reads every shoot's info, which on a cold engine took
        // over a second on a one-shoot library and grows with every shoot,
        // and the step waited behind "Starting" for all of it.
        let early = restored ? nil : rememberedHere()
        async let listRead: Void = library.refresh()
        if let early { await openEarly(early, on: e) }
        await listRead
        // A copy of the card the last engine was running would otherwise
        // say "Copying…" for the rest of the evening (§2.6).
        if restarted { importModel.engineRestarted() }
        if restarted { await sayWhatTheCrashCutOff(c) }
        if restored { keepSelectionInLibrary() } else { restorePlace() }
        readyFor = e
        // Once at launch, in case a job outlived a window.
        jobs.watch()
        onConnected?(self)
        if SettingsStore.shared.checkForUpdates { await updates.check() }
    }

    /// After a restart: the piece of work the crash cut off, which the new
    /// engine put back at the top of Up Next and held, named in the line that
    /// says the engine restarted (DESIGN.md §2.7). The line said only that
    /// nothing was lost, and the cull he had walked away from was not
    /// mentioned anywhere.
    private func sayWhatTheCrashCutOff(_ c: StudioClient) async {
        cutOffLine = nil
        guard let q = try? await c.get(QueueRoutes.state()), let cut = q.cutOff else { return }
        cutOffLine = Self.cutOffLine(cut)
        banner = cutOffLine
        // A piece of his work that did not get to its end: the Dock's badge
        // is for exactly that, while he is in PhotoLab or away.
        DockProgress.noteFailure(id: 0, kind: cut.kind, shoot: cut.shoot)
    }

    nonisolated static func cutOffLine(_ cut: HeldAfter) -> String {
        if !cut.putBack { return Strings.Queue.restartedDuringCopy(cut.named, files: cut.files, of: cut.of) }
        // A card copy is back to finish into its shoot, and says how far it got.
        if cut.kind == "ingest" { return Strings.Queue.restartedDuringCopyBack(cut.named, files: cut.files, of: cut.of) }
        return Strings.Queue.restartedWhile(cut.named)
    }

    /// The running job's question, asked by `applicationShouldTerminate`.
    public func jobIsRunning() async -> Bool {
        guard let client else { return false }
        return (try? await client.get(Routes.job()))?.running ?? false
    }
}
