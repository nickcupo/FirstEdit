import Foundation
import Testing
@testable import PipelineKit

/// What the app does when what he pressed cannot start at once.
///
/// The bug these exist for: he marked a shoot finished, which starts the
/// learning run, then asked to copy that shoot's RAWs to iCloud. The whole of
/// the answer was `{"error": "a job is already running"}`, and the whole of
/// what reached his screen was that sentence in red. It did not say what was
/// running, how far along it was, when it would end, or what he could do. It
/// was also, on those facts, the wrong answer entirely: what was in the way
/// was the machine's own homework, which holds nothing he is waiting for.
///
/// Nested inside `RoundTripTests` on purpose: the stub protocol is one answer
/// function for the whole process, and a suite of its own would answer the
/// round trip's requests and be answered by them. A nested suite inherits its
/// parent's `.serialized`, which is the only thing that keeps them apart.
extension RoundTripTests {
@Suite("When something is in the way")
@MainActor
struct InTheWay {

    static func model(shoot: String = "2026-09-21",
                      answers: @escaping @Sendable (URLRequest) -> (Int, Data)) -> StorageModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.answer = answers
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"),
                                  session: URLSession(configuration: config))
        let m = StorageModel(shoot: shoot, client: client)
        m.sleep = { _ in }
        return m
    }

    /// Exactly what the engine sends when a cull of his is in the way.
    nonisolated static let busyBody = """
    {"error": "Working out what would go in 2026-09-21 has to wait: culling 2026-09-13-dog \
    — looking at faces: 240 of 1,157 frames, about 4 minutes left.",
     "busy": {"id": 7, "kind": "cull", "title": "culling 2026-09-13-dog",
              "shoot": "2026-09-13-dog", "stage": "faces",
              "label": "looking at faces: 240 of 1,157 frames",
              "fraction": 0.38, "elapsed": 154, "remaining": 251,
              "remaining_text": "about 4 minutes left", "background": false,
              "can_queue": true, "wanted": "working out what would go in 2026-09-21"}}
    """

    @Test("a refusal that cannot start names the job, its progress and what is left")
    func itExplainsItself() async throws {
        let m = Self.model(answers: { req in
            switch req.url?.path {
            case "/api/storage/plan":
                return (200, Data(Self.busyBody.utf8))
            default: return (200, Data(#"{"running": false}"#.utf8))
            }
        })

        await m.draw(StorageModel.Request("push"))

        // The engine's sentence, byte for byte, under the control he pressed.
        let sentence = try #require(m.refusals[.storage])
        #expect(sentence.contains("culling 2026-09-13-dog"))
        #expect(sentence.contains("looking at faces"))
        #expect(sentence != "a job is already running")

        // And the facts behind it, kept as facts rather than parsed back out
        // of that sentence.
        let busy = try #require(m.busy[.storage])
        #expect(busy.id == 7)
        #expect(busy.title == "culling 2026-09-13-dog")
        #expect(busy.label == "looking at faces: 240 of 1,157 frames")
        #expect(busy.fraction == 0.38)
        #expect(busy.remaining == 251)
        #expect(busy.remaining_text == "about 4 minutes left")
        #expect(busy.can_queue, "the queue will take it, and the engine says so")
        #expect(!busy.background, "his own work: the choice is his")
        #expect(busy.whereItHasGot == "looking at faces: 240 of 1,157 frames · about 4 minutes left")
        #expect(m.plan == nil, "nothing was drawn")
    }

    @Test("nothing invents a number the engine would not give")
    func noFalsePrecision() throws {
        let bare = Busy(fields: Fields(["title": .string("culling"), "label": .string("")]))
        #expect(bare.remaining == nil)
        #expect(bare.remaining_text.isEmpty)
        #expect(bare.whereItHasGot.isEmpty, "an empty line, not a made-up one")
    }

    @Test("Do It After puts it in the engine's own queue, with an id to take it back")
    func heCanWait() async throws {
        let asked = Recorder()
        let plan = try StorageFixture.data("plan-drop")
        let m = Self.model(answers: { req in
            let path = req.url?.path ?? ""
            if path == "/api/storage/plan", req.httpMethod == "POST" {
                let body = (try? JSONSerialization.jsonObject(with: req.bodyData ?? Data()))
                    as? [String: Any] ?? [:]
                asked.add(body["queue"] as? Bool == true ? "queued" : "now")
                return (200, Data(#"{"ok": true, "id": 9, "queued": true}"#.utf8))
            }
            if path == "/api/storage/plan" { return (200, plan) }
            if path == "/api/job" { return (200, Data(#"{"running": false, "id": 9}"#.utf8)) }
            if path == "/api/job/stop" {
                let body = (try? JSONSerialization.jsonObject(with: req.bodyData ?? Data()))
                    as? [String: Any] ?? [:]
                asked.add("cancel \(body["id"] as? Int ?? 0)")
                return (200, Data(#"{"ok": true}"#.utf8))
            }
            return (404, Data(#"{"error": "no"}"#.utf8))
        })

        await m.waitForTurn(StorageModel.Request("drop"))
        #expect(asked.all().contains("queued"), "it asks the engine to queue it, by name")
        #expect(m.busy[.storage] == nil)

        // And it comes back out of the line by its id.
        m.setWaitingForTest(9)
        await m.dontWait()
        #expect(asked.all().contains("cancel 9"))
    }

    @Test("Stop What Is Running stops the job in the way and clears the notice")
    func heCanStopTheOther() async throws {
        let asked = Recorder()
        let m = Self.model(answers: { req in
            if req.url?.path == "/api/job/stop" {
                asked.add("stop")
                return (200, Data(#"{"ok": true}"#.utf8))
            }
            return (200, Data(Self.busyBody.utf8))
        })
        await m.draw(StorageModel.Request("push"))
        #expect(m.busy[.storage] != nil)

        await m.stopTheJobInTheWay()

        #expect(asked.all() == ["stop"])
        #expect(m.busy[.storage] == nil)
        #expect(m.refusals[.storage] == nil, "the notice goes with the job it was about")
    }

    // MARK: the machine's homework

    @Test("his work never waits on the learning run, and he is told it was put down")
    func theHomeworkStandsDown() async throws {
        let m = Self.model(answers: { req in
            let path = req.url?.path ?? ""
            if path == "/api/storage/plan", req.httpMethod == "POST" {
                return (200, Data("""
                {"ok": true, "id": 2, "queued": false,
                 "paused": "Learning paused; it will pick up when you are finished."}
                """.utf8))
            }
            if path == "/api/storage/plan" { return (200, try! StorageFixture.data("plan-drop")) }
            return (200, Data(#"{"running": false, "id": 2}"#.utf8))
        })

        await m.draw(StorageModel.Request("push"))

        #expect(m.busy[.storage] == nil, "nothing was in the way: it stood down")
        #expect(m.refusals[.storage] == nil, "and nothing was refused")
        #expect(m.paused == "Learning paused; it will pick up when you are finished.")
        #expect(m.plan != nil, "his work went ahead")
    }

    @Test("a step waits behind another of his jobs and never behind the homework")
    func stepsDoNotWaitOnHomework() {
        let jobs = JobModel()
        let step = StepJobRunner(kinds: ["stor-push"], shoot: "2026-09-21", jobs: jobs)
        step.preview = nil

        // His own cull: a reason to wait, and the step says so.
        jobs.take(Job(running: true, stopped: false, id: 1, kind: "cull",
                      shoot: "2026-09-13-dog", title: "culling 2026-09-13-dog"))
        #expect(step.other != nil)
        #expect(step.phase == StepJobPhase.idle, "idle until he presses; the waiting starts then")

        // The learning run: never a reason to wait. The engine stands it down
        // the moment he asks, so a step showing "Waiting…" here would be
        // waiting for something that has already got out of the way — the same
        // wrong answer as before, in a nicer box.
        jobs.take(Job(running: true, stopped: false, id: 2, kind: "learn-learn",
                      title: "learning from your finished shoots", background: true))
        #expect(step.other == nil)
        #expect(jobs.isBackgroundOnly)
    }

    @Test("Stop on the row stops the run, and the panel asks again afterwards")
    @MainActor
    func stoppingTheRun() async throws {
        let asked = Recorder()
        let running = try StorageFixture.data("learned-running")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.answer = { req in
            let path = req.url?.path ?? ""
            asked.add("\(req.httpMethod ?? "") \(path)")
            if path == "/api/job/stop" { return (200, Data(#"{"ok": true}"#.utf8)) }
            return (200, running)
        }
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"),
                                  session: URLSession(configuration: config))
        let model = LearnedModel(client: client)

        await model.stopLearning()

        #expect(asked.all().first == "POST /api/job/stop")
        #expect(asked.all().contains("GET /api/learned"), "and the panel reads what happened")
        #expect(!model.stopping)
    }

    @Test("the job model sorts a start's three answers out once, for every caller")
    func oneWayToReadAStart() throws {
        let jobs = JobModel()
        let owner = RefusalOwner.job

        let busy = try Fixture.decodeJSON(OK.self, Self.busyBody)
        #expect(!jobs.took(busy, for: owner))
        #expect(jobs.busy[owner]?.title == "culling 2026-09-13-dog")
        #expect(jobs.refusals[owner]?.contains("culling") == true)

        let paused = try Fixture.decodeJSON(OK.self, #"{"ok": true, "id": 3, "paused": "Learning paused."}"#)
        #expect(jobs.took(paused, for: owner))
        #expect(jobs.busy[owner] == nil, "the notice goes when the job goes")
        #expect(jobs.refusals[owner] == nil)
        #expect(jobs.paused[owner] == "Learning paused.")

        let plain = try Fixture.decodeJSON(OK.self, #"{"ok": true, "id": 4}"#)
        #expect(jobs.took(plain, for: owner))
        #expect(jobs.paused[owner] == nil, "nothing was put down, so nothing is claimed")
    }
}

}

/// Records what the stub was asked, without a detached task the assertion
/// could outrun.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    func add(_ s: String) { lock.lock(); seen.append(s); lock.unlock() }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return seen }
}
