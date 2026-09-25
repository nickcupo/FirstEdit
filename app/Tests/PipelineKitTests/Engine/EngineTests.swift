import Foundation
import Testing
@testable import PipelineKit

/// A throwaway "checkout" whose studio.py is a shell script, run by /bin/sh in
/// place of the interpreter. Enough to drive every lifecycle path of
/// `EngineHost` in a second, without Python.
struct FakeEngine {
    let root: URL
    let support: URL

    init(script: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-engine-\(UUID().uuidString)", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline"),
                                                withIntermediateDirectories: true)
        try script.write(to: root.appendingPathComponent("pipeline/studio.py"), atomically: true, encoding: .utf8)
    }

    var environment: [String: String] {
        ["PIPELINE_CHECKOUT": root.path, "PIPELINE_PYTHON": "/bin/sh", "PIPELINE_EXT": root.path + "/no-ext",
         "HOME": root.path]
    }

    func host(timeout: Duration = .seconds(10)) -> EngineHost {
        EngineHost(bundle: .main, support: support, settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                   environment: environment, startTimeout: timeout)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("The engine host", .serialized)
struct EngineTests {

    @Test("the key is 32 random bytes, base64url, fresh every time")
    func key() {
        let a = StudioKey.make(), b = StudioKey.make()
        #expect(a.count == 43)
        #expect(a != b)
        #expect(!a.contains("+") && !a.contains("/") && !a.contains("="))
    }

    @Test("the key never reaches the log")
    func redact() {
        let k = StudioKey.make()
        #expect(Log.redact("env PIPELINE_STUDIO_KEY=\(k) and again \(k)", key: k)
                == "env PIPELINE_STUDIO_KEY=‹key› and again ‹key›")
    }

    @Test("the child's environment: today's set, plus the key, the library and the extension")
    func environment() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = SettingsStore(defaults: defaults)
        let support = URL(fileURLWithPath: "/scratch/support")
        let bundled = EngineLaunch(origin: .bundled, python: URL(fileURLWithPath: "/R/python/bin/python3.12"),
                                   script: URL(fileURLWithPath: "/R/pipeline/studio.py"),
                                   resources: URL(fileURLWithPath: "/R"))
        var env = EngineHost.environment(for: bundled, base: ["HOME": "/h"], support: support,
                                         bundle: .main, settings: settings, key: "K")
        #expect(env["PIPELINE_STUDIO_KEY"] == "K")
        #expect(env["PIPELINE_SUPPORT"] == "/scratch/support")
        #expect(env["PIPELINE_MODELS"] == "/scratch/support/models")
        #expect(env["PIPELINE_CLIP_CACHE"] == "/scratch/support/models/clip")
        #expect(env["PIPELINE_BUNDLED_MODELS"] == "/R/models")
        #expect(env["PIPELINE_EXIFTOOL"] == "/R/exiftool/exiftool")
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(env["PYTHONDONTWRITEBYTECODE"] == "1" && env["PYTHONUNBUFFERED"] == "1" && env["PYTHONNOUSERSITE"] == "1")
        #expect(env["PIPELINE_APP_PID"] == String(ProcessInfo.processInfo.processIdentifier))
        // The bundle's own modules, for an extension command that imports them.
        #expect(env["PIPELINE_PUBLIC"] == "/R/pipeline")
        // With no extension set, it is looked for in the app's own support
        // folder and nowhere else.
        #expect(env["PIPELINE_EXT"] == "/scratch/support/extension")
        #expect(env["PHOTOS_ROOT"] == nil)

        settings.libraryFolder = URL(fileURLWithPath: "/elsewhere/photos")
        settings.extensionFolder = URL(fileURLWithPath: "/elsewhere/ext")
        env = EngineHost.environment(for: bundled, base: [:], support: support, bundle: .main,
                                     settings: settings, key: "K")
        #expect(env["PHOTOS_ROOT"] == "/elsewhere/photos")
        #expect(env["PIPELINE_EXT"] == "/elsewhere/ext")

        let checkout = EngineLaunch(origin: .checkout, python: URL(fileURLWithPath: "/c/.venv/bin/python"),
                                    script: URL(fileURLWithPath: "/c/pipeline/studio.py"),
                                    resources: URL(fileURLWithPath: "/c"))
        env = EngineHost.environment(for: checkout, base: ["PIPELINE_EXT": "/given"], support: support,
                                     bundle: .main, settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                     key: "K")
        #expect(env["PIPELINE_EXT"] == "/given")
        #expect(env["PIPELINE_EXIFTOOL"] == nil)
        // A checkout's own, never one inherited from whoever started the app.
        env = EngineHost.environment(for: checkout, base: ["PIPELINE_PUBLIC": "/somewhere/else/pipeline"],
                                     support: support, bundle: .main,
                                     settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                     key: "K")
        #expect(env["PIPELINE_PUBLIC"] == "/c/pipeline")
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin") == true)
        #expect(checkout.arguments == ["/c/pipeline/studio.py", "--app", "--no-open", "--port", "0"])
    }

    @Test("with automatic update checks off, the engine does not ask GitHub as it starts")
    func updateCheckSwitch() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let launch = EngineLaunch(origin: .checkout, python: URL(fileURLWithPath: "/usr/bin/python3"),
                                  script: URL(fileURLWithPath: "/tmp/studio.py"),
                                  resources: URL(fileURLWithPath: "/tmp"))
        func env() -> [String: String] {
            EngineHost.environment(for: launch, base: [:], support: URL(fileURLWithPath: "/tmp/support"),
                                   bundle: .main, settings: settings, key: "k")
        }
        #expect(env()["PIPELINE_NO_UPDATE_CHECK"] == nil)
        settings.checkForUpdates = false
        #expect(env()["PIPELINE_NO_UPDATE_CHECK"] == "1")
    }

    @Test("a checkout is found from anywhere inside it")
    func locate() {
        let here = URL(fileURLWithPath: #filePath)
        let found = EngineLaunch.locate(bundle: .main, environment: [:], searchFrom: [here])
        // This file sits inside the repository, which has pipeline/studio.py
        // and, on a machine set up for it, .venv.
        if let found {
            #expect(found.origin == .checkout)
            #expect(found.script.lastPathComponent == "studio.py")
        }
    }

    @Test("start reads PORT off stdout; stop takes the child down")
    func startAndStop() async throws {
        let fake = try FakeEngine(script: "echo 'studio starting'\necho 'PORT 4242'\nexec sleep 30\n")
        defer { fake.remove() }
        let host = fake.host()
        let e = try await host.start()
        #expect(e.base.absoluteString == "http://127.0.0.1:4242/")
        #expect(e.key.count == 43)
        #expect(await host.state == .running(e))
        let pid = try #require(host.childPID)
        #expect(kill(pid, 0) == 0)
        // A second start while running is the same engine.
        #expect(try await host.start() == e)
        await host.stop()
        #expect(await host.state == .stopped)
        #expect(kill(pid, 0) != 0, "the child outlived stop()")
        // The log holds what it printed, and never the key.
        let log = try String(contentsOf: host.logURL, encoding: .utf8)
        #expect(log.contains("studio starting"))
        #expect(!log.contains(e.key))
    }

    @Test("restart gives a new key and a fresh child")
    func restart() async throws {
        let fake = try FakeEngine(script: "echo 'PORT 4243'\nexec sleep 30\n")
        defer { fake.remove() }
        let host = fake.host()
        let a = try await host.start()
        let pidA = try #require(host.childPID)
        let b = try await host.restart()
        #expect(a.key != b.key)
        #expect(kill(pidA, 0) != 0)
        #expect(host.childPID != nil && host.childPID != pidA)
        // The first child's exit can be reported after the second has
        // started. It is the old one's, and is neither a crash of the new
        // engine nor the end of its launch.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await host.state == .running(b))
        host.terminateNow()
        #expect(host.childPID == nil)
    }

    @Test("a child that never says PORT is a failed start with its last line")
    func noPort() async throws {
        let fake = try FakeEngine(script: "echo 'ModuleNotFoundError: No module named cv2' >&2\nexit 3\n")
        defer { fake.remove() }
        let host = fake.host()
        await #expect(throws: EngineHost.StartError.self) { try await host.start() }
        guard case .failed(let why) = await host.state else { Issue.record("not failed"); return }
        #expect(why.contains("No module named cv2"))
    }

    @Test("a crash is restarted once; a second within a minute goes to the engine-down view")
    func crash() async throws {
        let fake = try FakeEngine(script: "echo 'PORT 4244'\nsleep 0.4\necho 'Segmentation fault' >&2\nexit 139\n")
        defer { fake.remove() }
        let host = fake.host()
        // Both subscribed before the engine starts, so neither the first
        // `.running` nor the notice can go by before anyone is listening.
        let notices = await host.noticeStream()
        let states = await host.stateStream()
        let watcher = Task {
            var out: [EngineHost.State] = []
            for await s in states {
                out.append(s)
                if case .failed = s { break }
            }
            return out
        }
        _ = try await host.start()
        var gotRestart = false
        for await n in notices { if n == .restartedAfterCrash { gotRestart = true; break } }
        #expect(gotRestart)
        let seen = await watcher.value
        // The reason is the one the state went down with, read once. The
        // exit is reported only after the child's last line has been read,
        // so there is nothing to wait for: this used to re-read the host for
        // three seconds and still failed six runs in fifteen under load.
        guard case .failed(let why) = seen.last else { Issue.record("never went down: \(seen)"); return }
        #expect(why.contains("Segmentation fault"))
        #expect(seen.filter { if case .running = $0 { return true }; return false }.count == 2)
    }

    @Test("QUIT on stdout asks the app to terminate")
    func quitSentinel() async throws {
        let fake = try FakeEngine(script: "echo 'PORT 4245'\nsleep 0.3\necho 'QUIT'\nexec sleep 30\n")
        defer { fake.remove() }
        let host = fake.host()
        let notices = host.notices
        _ = try await host.start()
        var quit = false
        for await n in notices { if n == .quitRequested { quit = true; break } }
        #expect(quit)
        host.terminateNow()
    }

    @Test("a shoot called QUIT in a sentence does not close the app")
    func quitMustBeAWholeLine() async throws {
        let fake = try FakeEngine(script: "echo 'PORT 4246'\necho 'opened QUIT shoot'\nexec sleep 30\n")
        defer { fake.remove() }
        let host = fake.host()
        let notices = host.notices
        _ = try await host.start()
        let t = Task { for await n in notices where n == .quitRequested { return true }; return false }
        try await Task.sleep(for: .milliseconds(500))
        t.cancel()
        host.terminateNow()
        #expect(await t.value == false)
    }

    @Test("routes build the paths and queries the engine serves")
    func routes() {
        #expect(Routes.shoot("a b").query == ["name": "a b"])
        #expect(Routes.shoot("x", full: true).query["full"] == "1")
        #expect(Routes.shootLight("x").query["light"] == "1")
        #expect(Routes.storagePlan("x", what: "drop", opts: PlanOptions(keepers: true, after: 30)).query
                == ["name": "x", "what": "drop", "keepers": "1", "after": "30"])
        #expect(Routes.rating.method == .post && Routes.rating.path == "/api/rating")
        let c = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:5000/")!, key: "K"))
        let req = c.imageRequest(.full(shoot: "2026 09 dog", stem: "TSC1", px: 2048))
        #expect(req.url?.absoluteString == "http://127.0.0.1:5000/full/2026%2009%20dog/TSC1.jpg?px=2048")
        #expect(req.value(forHTTPHeaderField: "X-Studio-Key") == "K")
        let crop = c.imageRequest(.crop(shoot: "s", stem: "f", cx: 0.5, cy: 0.38, px: 1600, ar: 0.75))
        #expect(crop.url?.query == "ar=0.7500&cx=0.5000&cy=0.3800&px=1600")
    }
}

/// The real engine, from this checkout, against an empty scratch library.
/// Skipped where there is no `.venv` to run it with.
@Suite("The real engine", .serialized)
struct RealEngineTests {
    static let checkout: URL? = {
        let here = URL(fileURLWithPath: #filePath)
        return EngineLaunch.locate(bundle: .main, environment: [:], searchFrom: [here])?.resources
    }()

    @Test("starts with a per-launch key, answers /api/shoots, and leaves nothing running",
          .enabled(if: checkout != nil))
    func realEngine() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("real-engine-\(UUID().uuidString)", isDirectory: true)
        let lib = scratch.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("shoots"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let env = [
            "PHOTOS_ROOT": lib.path,
            "PIPELINE_ICLOUD": scratch.appendingPathComponent("icloud").path,
            "PIPELINE_SITE": scratch.appendingPathComponent("site").path,
            "PIPELINE_EXT": scratch.appendingPathComponent("no-ext").path,
            "HOME": ProcessInfo.processInfo.environment["HOME"] ?? scratch.path,
        ]
        let host = EngineHost(bundle: .main, support: scratch.appendingPathComponent("support"),
                              settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                              environment: env, startTimeout: .seconds(120))
        let e = try await host.start()
        let pid = try #require(host.childPID)
        let r = try await StudioClient(endpoint: e).get(Routes.shoots())
        #expect(r.shoots.isEmpty)
        let job = try await StudioClient(endpoint: e).get(Routes.job())
        #expect(!job.running)
        // The engine sends every refusal as a sentence (studio.sentence_case).
        await #expect(throws: StudioError.refused("No such shoot")) {
            _ = try await StudioClient(endpoint: e).get(Routes.shoot("not-there"))
        }
        await host.stop()
        #expect(kill(pid, 0) != 0, "the engine outlived stop()")
    }
}

@Suite("The line he is shown when the engine stops")
struct FailureLineTests {
    @Test("the handshake is never the reason")
    func handshakeIsNotAReason() {
        #expect(ServerProcess.isHandshake("PORT 58518"))
        #expect(ServerProcess.isHandshake("QUIT"))
        #expect(!ServerProcess.isHandshake("Segmentation fault"))
        #expect(!ServerProcess.isHandshake("PORT of the shoot is full"))
        #expect(!ServerProcess.isHandshake("QUITTING early"))
        #expect(!ServerProcess.isHandshake("ModuleNotFoundError: No module named cv2"))
    }
}

@Suite("Which library a run is pointed at")
struct LibraryRootTests {
    private func env(_ base: [String: String], setting: String?) -> [String: String] {
        let defaults = UserDefaults(suiteName: "root-test-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.libraryFolder = setting.map { URL(fileURLWithPath: $0) }
        let launch = EngineLaunch(origin: .checkout, python: URL(fileURLWithPath: "/usr/bin/python3"),
                                  script: URL(fileURLWithPath: "/tmp/studio.py"),
                                  resources: URL(fileURLWithPath: "/tmp"))
        return EngineHost.environment(for: launch, base: base, support: URL(fileURLWithPath: "/tmp/support"),
                                      bundle: .main, settings: settings, key: "k")
    }

    @Test("a PHOTOS_ROOT put there by hand wins over the saved setting")
    func handBeatsSetting() {
        // The build's own smoke test passed --library <clone> and the app used
        // his real library anyway: it listed 8 shoots where the clone holds 7.
        let byHand = env(["PHOTOS_ROOT": "/tmp/a-clone"], setting: "/Users/someone/photos")
        #expect(byHand["PHOTOS_ROOT"] == "/tmp/a-clone")
    }

    @Test("with nothing said by hand, the saved setting is used")
    func settingOtherwise() {
        #expect(env([:], setting: "/Users/someone/photos")["PHOTOS_ROOT"] == "/Users/someone/photos")
        #expect(env([:], setting: nil)["PHOTOS_ROOT"] == nil)
    }
}
