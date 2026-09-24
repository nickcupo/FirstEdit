import AppKit
import Observation

/// §2.11 — the one way a new library folder reaches the engine, from
/// Settings, the first run and the empty sidebar alike.
///
/// The engine reads `PHOTOS_ROOT` when it starts, so a new folder is a new
/// engine, and stopping the engine stops whatever it is running. There were
/// three ways in and none of them asked: Settings put up a sheet saying
/// nothing was lost while a card copy was killed half-way, the sidebar
/// restarted without a word, and the first run saved the folder and never
/// restarted at all, so the sidebar named the new folder while the engine
/// went on serving the old one. Settings' "Not Yet" left the same split.
///
/// Now there is one path. With nothing of his running it restarts at once
/// and asks nothing. With a job of his running it asks, naming the job, and
/// the default is to wait: the engine restarts once that job has ended and
/// nothing is left waiting its turn on the list. The list is waited for, not
/// held and resumed, because what is on it names shoots in the folder being
/// left — started again on the new one, each would fail. The folder is saved
/// only when the restart actually happens, so the app is never pointed one
/// way while the engine reads another.
@MainActor @Observable
public final class EngineRestart {
    public static let shared = EngineRestart()

    public enum Outcome: Equatable, Sendable {
        /// The engine is on the new folder (or already was).
        case restarted
        /// It restarts when the job ends; `waiting` says which.
        case waiting
        /// He kept things as they are. Nothing was saved.
        case cancelled
    }

    /// A restart held for a job to end: what it waits for, and the folder it
    /// will be pointed at, for the line that says so and its Don't Wait.
    public struct Waiting: Equatable, Sendable {
        public let job: String
        public let folder: URL?
        /// The job and the list are done, and the restart is held until he
        /// leaves Choose Keepers, so it never lands between two presses.
        public internal(set) var forChoosing: Bool

        public init(job: String, folder: URL?, forChoosing: Bool = false) {
            self.job = job; self.folder = folder; self.forChoosing = forChoosing
        }

        /// The line under the folder in Settings and at the foot of the
        /// sidebar: one sentence, wherever it is read. `current` names the
        /// folder when the wait has none of its own.
        public func sentence(current: URL?) -> String {
            let path = (folder ?? current)?.abbreviatedPath ?? ""
            return forChoosing ? Strings.Settings.restartWhenYouLeave(path)
                               : Strings.Settings.restartWaiting(job, path)
        }
    }

    public private(set) var waiting: Waiting?

    /// What it needs from the app, injected so a test can stand in for the
    /// engine and nothing here reaches for a real one.
    public struct World {
        /// The job he would lose, or `nil`. The machine's own background work
        /// is not his: the engine stands it down and does it again later.
        public var hisRunningJob: @MainActor () async -> Job?
        /// Work on the list that will start by itself: waiting, and not held.
        public var listWillGoOn: @MainActor () async -> Bool
        public var restart: @MainActor () async -> Void
        /// The folder the engine is reading now.
        public var engineLibrary: @MainActor () -> URL
        /// The question, with its three answers.
        public var ask: @MainActor (Job) async -> Answer
        /// He is in Choose Keepers, where a restart would land between two
        /// presses and take the window to All Shoots under his hand.
        public var isChoosing: @MainActor () -> Bool
        /// The line that says a held restart has happened, since he may be
        /// nowhere near Settings when it does.
        public var announce: @MainActor (String) -> Void

        public init(hisRunningJob: @escaping @MainActor () async -> Job?,
                    listWillGoOn: @escaping @MainActor () async -> Bool,
                    restart: @escaping @MainActor () async -> Void,
                    engineLibrary: @escaping @MainActor () -> URL,
                    ask: @escaping @MainActor (Job) async -> Answer,
                    isChoosing: @escaping @MainActor () -> Bool = { false },
                    announce: @escaping @MainActor (String) -> Void = { _ in }) {
            self.hisRunningJob = hisRunningJob
            self.listWillGoOn = listWillGoOn
            self.restart = restart
            self.engineLibrary = engineLibrary
            self.ask = ask
            self.isChoosing = isChoosing
            self.announce = announce
        }
    }

    public enum Answer: Sendable { case whenItFinishes, stopItNow, cancel }

    private var world: World?
    private var settings: SettingsStore = .shared
    private var wait: Task<Void, Never>?
    /// How often a held restart asks whether the job has ended.
    var interval: Duration = .milliseconds(1500)

    public init() {}

    /// For the snapshot harness: a restart already waiting, with no engine.
    public init(preview waiting: Waiting) { self.waiting = waiting }

    public func attach(_ world: World, settings: SettingsStore = .shared) {
        self.world = world
        self.settings = settings
    }

    /// Restart the engine, pointed at `folder` when one is given.
    ///
    /// A folder that is the one the engine is already reading is saved and
    /// nothing is restarted — and a restart waiting to take it somewhere else
    /// is dropped, because choosing the folder he is on is him changing his
    /// mind. It used to be checked before the wait was, so the waiting
    /// restart went ahead once the job ended and put the engine, and the
    /// saved folder, on the one he had backed out of. The folder a restart is
    /// already waiting for keeps that wait and asks nothing again. With no
    /// world attached — the harness — the folder is saved, which is all a
    /// scene can see.
    @discardableResult
    public func restart(pointingAt folder: URL?) async -> Outcome {
        guard let world else {
            if let folder { settings.libraryFolder = folder }
            return .restarted
        }
        if let folder, Self.same(folder, world.engineLibrary()) {
            cancelWaiting()
            settings.libraryFolder = folder
            return .restarted
        }
        if let folder, let w = waiting, let already = w.folder, Self.same(folder, already) {
            return .waiting
        }
        // The wait already set is put down while he is asked, so it cannot
        // restart under the question, and taken up again if he cancels:
        // Cancel keeps things as they were, and a wait was part of that.
        let before = waiting
        cancelWaiting()
        guard let job = await world.hisRunningJob() else {
            await now(folder)
            return .restarted
        }
        switch await world.ask(job) {
        case .cancel:
            if let before { hold(before) }
            return .cancelled
        case .stopItNow:
            await now(folder)
            return .restarted
        case .whenItFinishes:
            hold(Waiting(job: Self.describe(job), folder: folder))
            return .waiting
        }
    }

    /// Don't Wait: the restart is dropped and nothing is saved.
    public func cancelWaiting() {
        wait?.cancel()
        wait = nil
        waiting = nil
    }

    private func now(_ folder: URL?) async {
        if let folder { settings.libraryFolder = folder }
        await world?.restart()
    }

    /// Waits for the job and the list, then for him to leave Choose Keepers,
    /// then restarts and says so. A restart that fired on its own while he
    /// was pressing K and D sent his next verdict to an engine being stopped
    /// and took the window to All Shoots of the other library, and the only
    /// sign it was coming was a line in a Settings window he had closed.
    private func hold(_ w: Waiting) {
        guard let world else { return }
        waiting = w
        wait = Task { [weak self] in
            guard let self else { return }
            // Between one job and the next the engine is briefly idle, so
            // "nothing running" alone would restart into the gap and stop the
            // next piece of work as it began.
            while !Task.isCancelled {
                try? await Task.sleep(for: self.interval)
                if Task.isCancelled { return }
                let done = await world.hisRunningJob() == nil
                let clear = done ? await !world.listWillGoOn() : false
                if Task.isCancelled { return }
                let choosing = clear && world.isChoosing()
                if self.waiting?.forChoosing != choosing { self.waiting?.forChoosing = choosing }
                if clear && !choosing { break }
            }
            if Task.isCancelled { return }
            self.waiting = nil
            self.wait = nil
            await self.now(w.folder)
            world.announce(Strings.Settings.restartedAfter(w.job, world.engineLibrary().abbreviatedPath))
        }
    }

    /// Two spellings of one folder compare equal.
    static func same(_ a: URL, _ b: URL) -> Bool {
        LibraryFolder.normalised(a).standardizedFileURL.path
            == LibraryFolder.normalised(b).standardizedFileURL.path
    }

    /// The job, as the question names it: "the cull of 2026-09-19".
    public static func describe(_ job: Job) -> String {
        Strings.Settings.runningJob(kind: job.kind, shoot: job.shoot, title: job.title)
    }
}

// MARK: - the real one

extension EngineRestart.World {
    /// The app's engine, its list, and the question as an alert on the
    /// window that asked — the same alert, with the default on the right,
    /// that ⌘Q puts up over a running job.
    public static func real(_ app: AppModel) -> Self {
        EngineRestart.World(
            hisRunningJob: { [weak app] in
                guard let client = app?.client,
                      let j = try? await client.get(Routes.job()),
                      j.running, !j.background else { return nil }
                return j
            },
            listWillGoOn: { [weak app] in
                guard let client = app?.client,
                      let q = try? await client.get(QueueRoutes.state()) else { return false }
                return !q.held && !q.waiting.isEmpty
            },
            restart: { [weak app] in await app?.restartEngine() },
            engineLibrary: { AppPaths.engineLibrary() },
            ask: { job in await EngineRestart.alert(for: job) },
            isChoosing: { [weak app] in
                if case .step(_, "keepers") = app?.navigation.selection { return true }
                return false
            },
            // The window's quiet line, the one a crash-restart uses.
            announce: { [weak app] line in app?.banner = line })
    }
}

extension EngineRestart {
    /// "Restarting the engine stops the cull of 2026-09-19." [Restart When It
    /// Finishes] (default) [Stop It and Restart] [Cancel]. A sheet on the
    /// window he is in, so it is plainly about what he just did there.
    static func alert(for job: Job) async -> Answer {
        let a = NSAlert()
        a.messageText = Strings.Settings.restartStops(describe(job))
        a.informativeText = Strings.Settings.restartStopsBody
        a.addButton(withTitle: Strings.Settings.restartWhenItFinishes)
        a.addButton(withTitle: Strings.Settings.stopItAndRestart)
        a.addButton(withTitle: Strings.Settings.restartCancel)
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await withCheckedContinuation { go in
                a.beginSheetModal(for: window) { go.resume(returning: $0) }
            }
        } else {
            response = a.runModal()
        }
        switch response {
        case .alertFirstButtonReturn: return .whenItFinishes
        case .alertSecondButtonReturn: return .stopItNow
        default: return .cancel
        }
    }
}
