import Foundation

/// The engine: the bundled Python running `pipeline/studio.py` as a child of
/// this app, on a port it picks itself.
///
/// It does what `app/main.swift` has always done — start the interpreter, read
/// `PORT n` off its stdout, SIGTERM on quit and give it three seconds before
/// SIGKILL, watch for the `QUIT` the updater prints — plus the per-launch key,
/// and one automatic restart after a crash.
public actor EngineHost {

    public struct Endpoint: Sendable, Equatable {
        public let base: URL
        public let key: String
        public init(base: URL, key: String) { self.base = base; self.key = key }
    }

    public enum State: Sendable, Equatable {
        case starting
        case running(Endpoint)
        case failed(String)
        case stopped

        public var endpoint: Endpoint? {
            if case .running(let e) = self { return e }
            return nil
        }
    }

    /// Things the window says once and that are not a state of the engine.
    public enum Notice: Sendable, Equatable {
        /// It stopped on its own and was started again. A quiet banner:
        /// "The engine stopped and was restarted. Nothing you decided was lost."
        case restartedAfterCrash
        /// The updater printed `QUIT`: the app should terminate cleanly now.
        case quitRequested
    }

    public enum StartError: Error, Sendable, Equatable {
        case noInterpreter
        case failed(String)
    }

    // MARK: -

    private let bundle: Bundle
    private let support: URL
    private let settings: SettingsStore
    private let baseEnvironment: [String: String]
    private let server: ServerProcess
    private let startTimeout: Duration

    public private(set) var state: State = .stopped
    private var launchTask: Task<Endpoint, Error>?
    private var lastCrash: Date?
    private var stopping = false
    private var stateSubscribers: [UUID: AsyncStream<State>.Continuation] = [:]
    private var noticeSubscribers: [UUID: AsyncStream<Notice>.Continuation] = [:]

    public nonisolated let logURL: URL

    public init(bundle: Bundle, support: URL, settings: SettingsStore) {
        self.init(bundle: bundle, support: support, settings: settings,
                  environment: ProcessInfo.processInfo.environment, startTimeout: .seconds(120))
    }

    /// The environment is injectable so a test can start the real engine
    /// against a scratch library without touching the process's own.
    public init(bundle: Bundle, support: URL, settings: SettingsStore,
                environment: [String: String], startTimeout: Duration) {
        self.bundle = bundle
        self.support = support
        self.settings = settings
        self.baseEnvironment = environment
        self.startTimeout = startTimeout
        self.logURL = support.appendingPathComponent("studio.log")
        self.server = ServerProcess(logURL: support.appendingPathComponent("studio.log"))
    }

    // MARK: - streams

    /// Every state change, starting with the current one. Each read makes a
    /// new stream, so any number of windows can watch.
    public nonisolated var states: AsyncStream<State> {
        AsyncStream { cont in
            let id = UUID()
            Task { await self.subscribe(id, cont) }
            cont.onTermination = { _ in Task { await self.unsubscribeState(id) } }
        }
    }

    public nonisolated var notices: AsyncStream<Notice> {
        AsyncStream { cont in
            let id = UUID()
            Task { await self.subscribeNotices(id, cont) }
            cont.onTermination = { _ in Task { await self.unsubscribeNotice(id) } }
        }
    }

    /// The same stream as `states`, subscribed before this returns. `states`
    /// subscribes from a task of its own, so a watcher that reads it and
    /// then starts the engine can miss the first `.running`; one that awaits
    /// this cannot.
    public func stateStream() -> AsyncStream<State> {
        let (stream, cont) = AsyncStream.makeStream(of: State.self)
        let id = UUID()
        subscribe(id, cont)
        cont.onTermination = { _ in Task { await self.unsubscribeState(id) } }
        return stream
    }

    /// `notices`, subscribed before this returns, for the same reason.
    public func noticeStream() -> AsyncStream<Notice> {
        let (stream, cont) = AsyncStream.makeStream(of: Notice.self)
        let id = UUID()
        subscribeNotices(id, cont)
        cont.onTermination = { _ in Task { await self.unsubscribeNotice(id) } }
        return stream
    }

    private func subscribe(_ id: UUID, _ c: AsyncStream<State>.Continuation) {
        stateSubscribers[id] = c
        c.yield(state)
    }
    private func unsubscribeState(_ id: UUID) { stateSubscribers[id] = nil }
    private func subscribeNotices(_ id: UUID, _ c: AsyncStream<Notice>.Continuation) { noticeSubscribers[id] = c }
    private func unsubscribeNotice(_ id: UUID) { noticeSubscribers[id] = nil }

    private func set(_ s: State) {
        guard s != state else { return }
        state = s
        for c in stateSubscribers.values { c.yield(s) }
    }

    private func post(_ n: Notice) {
        for c in noticeSubscribers.values { c.yield(n) }
    }

    // MARK: - start, restart, stop

    /// Starts the engine if it is not running and returns where it is. A
    /// second call while one start is in flight waits for that start rather
    /// than launching a second interpreter.
    @discardableResult
    public func start() async throws -> Endpoint {
        if case .running(let e) = state, server.isRunning { return e }
        if let t = launchTask { return try await t.value }

        stopping = false
        set(.starting)
        let t = Task { try await self.launch() }
        launchTask = t
        do {
            let e = try await t.value
            launchTask = nil
            set(.running(e))
            return e
        } catch {
            launchTask = nil
            let why = Self.sentence(for: error, lastLine: server.lastLogLine)
            set(.failed(why))
            throw StartError.failed(why)
        }
    }

    /// Stops the child and starts a fresh one with a fresh key. Which shoot he
    /// was on is the window's state, not the engine's, so nothing of that is
    /// lost.
    @discardableResult
    public func restart() async throws -> Endpoint {
        await stop()
        lastCrash = nil
        return try await start()
    }

    public func stop() async {
        stopping = true
        launchTask?.cancel()
        launchTask = nil
        let s = server
        await Task.detached { s.terminate() }.value
        set(.stopped)
    }

    /// For `applicationWillTerminate`, which cannot await anything: SIGTERM,
    /// three seconds, SIGKILL, on the calling thread.
    public nonisolated func terminateNow() {
        server.terminate()
    }

    /// The child's pid while it is running, for the smoke test's "is it gone".
    public nonisolated var childPID: Int32? { server.pid }

    // MARK: - the launch itself

    private func launch() async throws -> Endpoint {
        let env = baseEnvironment
        guard let where_ = EngineLaunch.locate(
            bundle: bundle, environment: env,
            searchFrom: [bundle.bundleURL, URL(fileURLWithPath: CommandLine.arguments.first ?? "."),
                         URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        ) else {
            throw StartError.noInterpreter
        }

        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let key = StudioKey.make()
        let childEnv = Self.environment(for: where_, base: env, support: support, bundle: bundle,
                                        settings: settings, key: key)

        server.onExit = { [weak self] status, intentional, last in
            guard let self else { return }
            Task { await self.childExited(status: status, intentional: intentional, lastLine: last) }
        }
        server.onQuit = { [weak self] in
            guard let self else { return }
            Task { await self.quitRequested() }
        }

        let port = try await server.launch(where_, environment: childEnv, key: key, timeout: startTimeout)
        guard let base = URL(string: "http://127.0.0.1:\(port)/") else { throw StartError.failed(Strings.Engine.noPort) }
        return Endpoint(base: base, key: key)
    }

    /// The child's environment: today's set from `app/main.swift`, plus the key,
    /// the library folder, the extension and the engine's own modules.
    static func environment(for launch: EngineLaunch, base: [String: String], support: URL,
                            bundle: Bundle, settings: SettingsStore, key: String) -> [String: String] {
        var env = base
        let fm = FileManager.default
        let res = launch.resources
        env["PIPELINE_MODELS"] = support.appendingPathComponent("models").path
        env["PIPELINE_BUNDLED_MODELS"] = res.appendingPathComponent("models").path
        env["PIPELINE_CLIP_CACHE"] = support.appendingPathComponent("models/clip").path
        env["PIPELINE_SUPPORT"] = support.path
        env["PIPELINE_APP_PATH"] = bundle.bundleURL.path
        env["PIPELINE_APP_VERSION"] = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        env["PIPELINE_APP_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        // The engine's own modules, the `pipeline/` folder beside the script
        // it runs, for an extension command that imports them. Nothing set
        // it, so such a command found them only when a checkout happened to
        // sit beside the extension, and the app ran that checkout's code
        // rather than its own. Always this engine's, whatever was inherited.
        env["PIPELINE_PUBLIC"] = launch.script.deletingLastPathComponent().path
        env["PYTHONUNBUFFERED"] = "1"
        // The bundle is signed; nothing may be written into it.
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONNOUSERSITE"] = "1"

        switch launch.origin {
        case .bundled:
            env["PIPELINE_EXIFTOOL"] = res.appendingPathComponent("exiftool/exiftool").path
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        case .checkout:
            // From a checkout there is no bundled exiftool; the one he
            // installed is found where a terminal would find it. The bundled
            // app keeps today's fixed PATH exactly.
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }

        // Nothing here ships ffmpeg — it is GPL and this app is not — so name
        // the one he installed, if there is one, exactly as main.swift does.
        // The real fix is DESIGN.md §3.10 / §5.8: encode through AVFoundation.
        if env["PIPELINE_FFMPEG"] == nil {
            for c in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            where fm.isExecutableFile(atPath: c) {
                env["PIPELINE_FFMPEG"] = c
                break
            }
        }

        env["PIPELINE_STUDIO_KEY"] = key
        // A PHOTOS_ROOT already in this process's environment was put there by
        // hand — the smoke script, a test, a run pointed at a scratch clone —
        // and it wins over the saved setting. It did not, and so the build's
        // own smoke test ran the app against HIS library while claiming to use
        // a clone: it listed 8 shoots where the clone holds 7, and that count
        // is the only reason anyone noticed.
        if env["PHOTOS_ROOT"] == nil, let root = settings.libraryFolder {
            env["PHOTOS_ROOT"] = root.path
        }
        if let ext = settings.extensionFolder {
            env["PIPELINE_EXT"] = ext.path
        } else if env["PIPELINE_EXT"] == nil {
            // The extension lives in the app's own support folder. Naming it
            // outright means a run with a scratch support folder never falls
            // through to the real one in ~/Library.
            env["PIPELINE_EXT"] = support.appendingPathComponent("extension").path
        }
        // Settings ▸ General ▸ "Check for updates automatically", off: the
        // engine asked GitHub at every launch whatever the switch said. A
        // check he asks for (First Edit ▸ Check for Updates…) still runs.
        if !settings.checkForUpdates {
            env["PIPELINE_NO_UPDATE_CHECK"] = "1"
        }
        // Settings ▸ Learning, both switches: read by nothing, so learning ran
        // after every finished shoot and two minutes after any job, in the
        // middle of Choose Keepers. A change while the engine runs goes by
        // POST (`EngineSettings.sendLearning`); this is the value it starts on.
        env["PIPELINE_LEARN_AUTO"] = settings.learnAutomatically ? "1" : "0"
        env["PIPELINE_LEARN_IDLE_ONLY"] = settings.learnOnlyWhenIdle ? "1" : "0"
        return env
    }

    // MARK: - the child ended

    private func childExited(status: Int32, intentional: Bool, lastLine: String) async {
        guard !intentional, !stopping else { return }
        // Still starting: `start()` reports it.
        guard case .running = state else { return }

        let now = Date()
        if let last = lastCrash, now.timeIntervalSince(last) < 60 {
            // A second crash within a minute goes to the engine-down view
            // instead of looping.
            set(.failed(lastLine.isEmpty ? Strings.Engine.exited(status) : lastLine))
            return
        }
        lastCrash = now
        set(.starting)
        do {
            let t = Task { try await self.launch() }
            launchTask = t
            let e = try await t.value
            launchTask = nil
            set(.running(e))
            post(.restartedAfterCrash)
        } catch {
            launchTask = nil
            set(.failed(Self.sentence(for: error, lastLine: server.lastLogLine)))
        }
    }

    private func quitRequested() {
        stopping = true
        post(.quitRequested)
    }

    static func sentence(for error: Error, lastLine: String) -> String {
        switch error {
        case StartError.noInterpreter:
            return Strings.Engine.couldNotStart
        case StartError.failed(let s):
            return s
        case let e as ServerProcess.LaunchError:
            switch e {
            case .couldNotRun(let why): return Strings.Engine.couldNotStart + " " + why
            case .exitedBeforePort(let code, let last):
                return last.isEmpty ? Strings.Engine.exited(code) : last
            case .noPort:
                return lastLine.isEmpty ? Strings.Engine.noPort : lastLine
            }
        case is CancellationError:
            return Strings.Engine.stopped
        default:
            return lastLine.isEmpty ? "\(error)" : lastLine
        }
    }
}
