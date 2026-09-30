import Foundation
import Testing
@testable import PipelineKit

/// Pack in iCloud, started from the panel, is followed by the panel: its row
/// names the job and how far along it is. He saw "Starting…" over a pack that
/// was running and reporting its progress. These answers are the engine's
/// own, captured from a real run (Fixtures/StorageLearning/*-repack.json).
extension RoundTripTests {
@Suite("The panel follows the job it started")
@MainActor
struct Following {

    @Test("Pack in iCloud: the row names the job while it runs, and it ends as done")
    func packInICloud() async throws {
        let plan = try StorageFixture.data("plan-repack")
        let running = try StorageFixture.data("job-repack")
        let polls = Recorder()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.answer = { req in
            let path = req.url?.path ?? ""
            switch (req.httpMethod ?? "GET", path) {
            case ("POST", "/api/storage/plan"): return (200, Data(#"{"ok": true, "id": 1, "queued": false}"#.utf8))
            case ("GET", "/api/storage/plan"): return (200, plan)
            case ("POST", "/api/storage/apply"): return (200, Data(#"{"ok": true, "id": 2, "queued": false}"#.utf8))
            case ("GET", "/api/job"):
                polls.add("job")
                let n = polls.all().count
                if n <= 1 { return (200, Data(#"{"running": false, "id": 1, "outcome": "done"}"#.utf8)) }
                if n <= 6 { return (200, running) }
                var done = try! JSONSerialization.jsonObject(with: running) as! [String: Any]
                done["running"] = false
                done["code"] = 0
                return (200, try! JSONSerialization.data(withJSONObject: done))
            default: return (404, Data(#"{"error": "no"}"#.utf8))
            }
        }
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"),
                                  session: URLSession(configuration: config))
        let m = StorageModel(shoot: "2026-01-01-stop", client: client)
        m.sleep = { _ in }
        let request = StorageModel.Request("repack")
        await m.draw(request)
        #expect(m.hasPlan(for: request))
        #expect(await m.apply(request))
        #expect(m.isFollowing)

        var titles: [String] = []
        let follow = Task { await m.follow() }
        for _ in 0..<200 where m.isFollowing {
            if let t = m.following?.title { titles.append(t) }
            await Task.yield()
        }
        await follow.value
        #expect(titles.contains("packing the RAWs of 2026-01-01-stop in iCloud"),
                "the row named the job, not Starting…")
        #expect(m.ended?.title == "packing the RAWs of 2026-01-01-stop in iCloud")
        #expect(m.ended?.outcome == .done)
    }

    @Test("a storage job on this shoot is followed even when its number is not the one the start gave")
    func theNumberDisagrees() async throws {
        let running = try StorageFixture.data("job-repack")
        let polls = Recorder()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.answer = { req in
            guard req.url?.path == "/api/job" else { return (404, Data(#"{"error": "no"}"#.utf8)) }
            polls.add("job")
            if polls.all().count <= 4 { return (200, running) }            // id 2
            var done = try! JSONSerialization.jsonObject(with: running) as! [String: Any]
            done["running"] = false
            done["code"] = 0
            return (200, try! JSONSerialization.data(withJSONObject: done))
        }
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"),
                                  session: URLSession(configuration: config))
        let m = StorageModel(shoot: "2026-01-01-stop", client: client)
        m.sleep = { _ in }
        m.setFollowingForTest(3)                                             // told 3; 2 is running
        var titles: [String] = []
        for _ in 0..<5 where m.isFollowing {
            await m.follow()
            if let t = m.following?.title { titles.append(t) }
        }
        #expect(titles.contains("packing the RAWs of 2026-01-01-stop in iCloud"))
        #expect(m.ended?.outcome == .done, "and its ending is seen, not taken for nothing")
    }
}
}
