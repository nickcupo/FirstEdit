import Foundation
import Testing
@testable import PipelineKit

/// §2.11 — a new library folder is a new engine, and a new engine stops what
/// the old one was running. One path, for Settings, the first run and the
/// empty sidebar: it asks only when a job of his would be stopped, and saves
/// the folder only when the restart happens.
@Suite("Restarting the engine on a new folder")
@MainActor
struct EngineRestartTests {

    /// A stand-in engine: what is running, what the list holds, and a count
    /// of the restarts and questions.
    @MainActor
    final class Engine {
        var job: Job?
        var listGoesOn = false
        var restarts = 0
        var asked: [String] = []
        var answer: EngineRestart.Answer = .whenItFinishes
        var library = URL(fileURLWithPath: "/scratch/old", isDirectory: true)
        var choosing = false
        var announced: [String] = []

        var world: EngineRestart.World {
            EngineRestart.World(
                hisRunningJob: { self.job },
                listWillGoOn: { self.listGoesOn },
                restart: { self.restarts += 1 },
                engineLibrary: { self.library },
                ask: { job in
                    self.asked.append(EngineRestart.describe(job))
                    return self.answer
                },
                isChoosing: { self.choosing },
                announce: { self.announced.append($0) })
        }
    }

    static func scratch(_ name: String = #function) -> SettingsStore {
        let d = UserDefaults(suiteName: "photopipeline.tests.restart.\(name)")!
        for k in SettingsStore.Key.allCases { d.removeObject(forKey: k.rawValue) }
        return SettingsStore(defaults: d)
    }

    static let new = URL(fileURLWithPath: "/scratch/new", isDirectory: true)

    static func cull() throws -> Job {
        try Fixture.decodeJob(running: true, fraction: 0.4, kind: "cull", shoot: "2026-09-19")
    }

    @Test("with nothing of his running it restarts at once and asks nothing, as the sidebar always did")
    func nothingRunning() async {
        let engine = Engine()
        let settings = Self.scratch()
        let r = EngineRestart()
        r.attach(engine.world, settings: settings)
        #expect(await r.restart(pointingAt: Self.new) == .restarted)
        #expect(engine.restarts == 1)
        #expect(engine.asked.isEmpty)
        #expect(settings.libraryFolder?.path == Self.new.path)
    }

    @Test("the folder the engine is already on is saved and nothing is restarted")
    func theSameFolder() async {
        let engine = Engine()
        let settings = Self.scratch()
        let r = EngineRestart()
        r.attach(engine.world, settings: settings)
        #expect(await r.restart(pointingAt: engine.library) == .restarted)
        #expect(engine.restarts == 0)
    }

    @Test("a running cull is named in the question, and Cancel saves nothing")
    func cancel() async throws {
        let engine = Engine()
        engine.job = try Self.cull()
        engine.answer = .cancel
        let settings = Self.scratch()
        let r = EngineRestart()
        r.attach(engine.world, settings: settings)
        #expect(await r.restart(pointingAt: Self.new) == .cancelled)
        #expect(engine.asked == ["the cull of 2026-09-19"])
        #expect(engine.restarts == 0)
        #expect(settings.libraryFolder == nil, "no split: the app is not pointed where the engine is not")
    }

    @Test("Stop It and Restart does both, as he asked")
    func stopItNow() async throws {
        let engine = Engine()
        engine.job = try Self.cull()
        engine.answer = .stopItNow
        let settings = Self.scratch()
        let r = EngineRestart()
        r.attach(engine.world, settings: settings)
        #expect(await r.restart(pointingAt: Self.new) == .restarted)
        #expect(engine.restarts == 1)
        #expect(settings.libraryFolder?.path == Self.new.path)
    }

    @Test("the default waits for the job and the list, then restarts on the new folder")
    func whenItFinishes() async throws {
        let engine = Engine()
        engine.job = try Self.cull()
        let settings = Self.scratch()
        let r = EngineRestart()
        r.interval = .milliseconds(10)
        r.attach(engine.world, settings: settings)
        #expect(await r.restart(pointingAt: Self.new) == .waiting)
        #expect(r.waiting == .init(job: "the cull of 2026-09-19", folder: Self.new))
        #expect(settings.libraryFolder == nil, "nothing is saved while it waits")

        // The cull ends, and the list has the next piece of work to start:
        // restarting into that gap would stop it as it began.
        engine.job = nil
        engine.listGoesOn = true
        try await Task.sleep(for: .milliseconds(80))
        #expect(engine.restarts == 0)

        engine.listGoesOn = false
        for _ in 0..<100 where engine.restarts == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.restarts == 1)
        #expect(r.waiting == nil)
        #expect(settings.libraryFolder?.path == Self.new.path)
    }

    @Test("Don't Wait drops the restart and saves nothing")
    func dontWait() async throws {
        let engine = Engine()
        engine.job = try Self.cull()
        let settings = Self.scratch()
        let r = EngineRestart()
        r.interval = .milliseconds(10)
        r.attach(engine.world, settings: settings)
        _ = await r.restart(pointingAt: Self.new)
        r.cancelWaiting()
        engine.job = nil
        try await Task.sleep(for: .milliseconds(60))
        #expect(engine.restarts == 0)
        #expect(r.waiting == nil)
        #expect(settings.libraryFolder == nil)
    }

    /// He chose a new folder, said Restart When It Finishes, and then chose
    /// the old one back. The wait went on, and when the cull ended the engine
    /// restarted on the folder he had backed out of and saved it.
    @Test("choosing the folder the engine is on while a restart waits drops the wait")
    func backToTheFolderItIsOn() async throws {
        let engine = Engine()
        engine.job = try Self.cull()
        let settings = Self.scratch()
        let r = EngineRestart()
        r.interval = .milliseconds(10)
        r.attach(engine.world, settings: settings)
        #expect(await r.restart(pointingAt: Self.new) == .waiting)
        #expect(await r.restart(pointingAt: engine.library) == .restarted)
        #expect(r.waiting == nil, "the line under the folder goes with it")
        engine.job = nil
        try await Task.sleep(for: .milliseconds(80))
        #expect(engine.restarts == 0)
        #expect(settings.libraryFolder?.path != Self.new.path)
        #expect(engine.asked.count == 1, "backing out asks nothing")
    }

    @Test("the folder a restart is already waiting for keeps the wait and is not asked about again")
    func theSameNewFolderAgain() async throws {
        let engine = Engine()
        engine.job = try Self.cull()
        let settings = Self.scratch()
        let r = EngineRestart()
        r.interval = .milliseconds(10)
        r.attach(engine.world, settings: settings)
        #expect(await r.restart(pointingAt: Self.new) == .waiting)
        #expect(await r.restart(pointingAt: Self.new) == .waiting)
        #expect(engine.asked.count == 1)
        #expect(r.waiting?.folder == Self.new)
    }

    @Test("Cancel over a third folder leaves the restart that was waiting as it was")
    func cancelKeepsTheWait() async throws {
        let engine = Engine()
        engine.job = try Self.cull()
        let settings = Self.scratch()
        let r = EngineRestart()
        r.interval = .milliseconds(10)
        r.attach(engine.world, settings: settings)
        #expect(await r.restart(pointingAt: Self.new) == .waiting)
        engine.answer = .cancel
        let third = URL(fileURLWithPath: "/scratch/third", isDirectory: true)
        #expect(await r.restart(pointingAt: third) == .cancelled)
        #expect(r.waiting == .init(job: "the cull of 2026-09-19", folder: Self.new))
        engine.job = nil
        for _ in 0..<100 where engine.restarts == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.restarts == 1)
        #expect(settings.libraryFolder?.path == Self.new.path)
    }

    /// It fired on its own when the list emptied, perhaps between two of his
    /// presses on the light table, and said nothing outside Settings.
    @Test("a restart that waited is held while he is in Choose Keepers, and said when it happens")
    func heldWhileChoosing() async throws {
        let engine = Engine()
        engine.job = try Self.cull()
        engine.choosing = true
        let settings = Self.scratch()
        let r = EngineRestart()
        r.interval = .milliseconds(10)
        r.attach(engine.world, settings: settings)
        #expect(await r.restart(pointingAt: Self.new) == .waiting)
        #expect(r.waiting?.forChoosing == false, "the job is what it waits for first")
        #expect(r.waiting?.sentence(current: nil).contains("once the cull of 2026-09-19") == true)

        engine.job = nil
        for _ in 0..<100 where r.waiting?.forChoosing != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(r.waiting?.forChoosing == true)
        #expect(r.waiting?.sentence(current: nil) == "The engine restarts on /scratch/new when you leave Choose Keepers.")
        #expect(engine.restarts == 0)

        engine.choosing = false
        engine.library = Self.new
        for _ in 0..<100 where engine.restarts == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.restarts == 1)
        #expect(r.waiting == nil)
        #expect(engine.announced == ["Now that the cull of 2026-09-19 is done, the engine reads /scratch/new."])
    }

    @Test("a restart with nothing to wait for is not announced: he is looking at it happen")
    func notAnnouncedAtOnce() async {
        let engine = Engine()
        let r = EngineRestart()
        r.attach(engine.world, settings: Self.scratch())
        #expect(await r.restart(pointingAt: Self.new) == .restarted)
        #expect(engine.announced.isEmpty)
    }

    @Test("the question names the job in his words")
    func theJobsName() {
        #expect(Strings.Settings.runningJob(kind: "cull", shoot: "2026-09-19", title: "")
            == "the cull of 2026-09-19")
        #expect(Strings.Settings.runningJob(kind: "ingest", shoot: "2026-09-19", title: "")
            .contains("copy of the card"))
        #expect(Strings.Settings.runningJob(kind: "nothing-we-know", shoot: "", title: "")
            == "the job that is running")
        #expect(Strings.Settings.runningJob(kind: "setup", shoot: "", title: "getting the picture model, once")
            == "the picture model's download")
        #expect(Strings.Settings.restartStops(Strings.Settings.runningJob(kind: "setup", shoot: "", title: ""))
            == "Restarting the engine stops the picture model's download.")
        #expect(Strings.Settings.runningJob(kind: "gather", shoot: "2026-09-19", title: "")
            == "“Build the PhotoLab folder” for 2026-09-19")
        #expect(Strings.Settings.restartWhenItFinishes == "Restart When It Finishes")
    }
}
