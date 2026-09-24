import Foundation
import Testing
@testable import PipelineKit

/// The learning page's watch ends with the task that asked for it.
///
/// Learn Now started its watch in a task of its own, and the watch keeps
/// asking every two seconds while a run is queued — which, stood down for his
/// work "until the Mac is idle", can be hours of culling after he has left
/// the page. The page's own watch was skipped behind a flag saying one was
/// already going. Now Learn Now hands the watch to the page's `.task(id:)`,
/// and a newer watch replaces an older one instead of giving up to it.
///
/// Nested inside `RoundTripTests`: the stub protocol is one answer function
/// for the whole process.
extension RoundTripTests {
@Suite("The learning page's watch")
@MainActor
struct LearnWatch {

    /// A run queued behind his work, for as long as the test likes.
    static func queuedModel(_ asked: Recorder) throws -> LearnedModel {
        var json = try JSONSerialization.jsonObject(with: StorageFixture.data("learned-running")) as! [String: Any]
        json["running"] = false
        json["queued"] = true
        let queued = try JSONSerialization.data(withJSONObject: json)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.answer = { req in
            let path = req.url?.path ?? ""
            asked.add(path)
            if path == "/api/job" {
                return (200, Data(#"{"running": true, "id": 7, "kind": "cull", "title": "culling 2026-09-21"}"#.utf8))
            }
            return (200, queued)
        }
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"),
                                  session: URLSession(configuration: config))
        let model = LearnedModel(client: client)
        model.sleep = { _ in try await Task.sleep(for: .milliseconds(25)) }
        return model
    }

    static func reads(_ asked: Recorder) -> Int { asked.all().filter { $0 == "/api/learned" }.count }

    @Test("a newer watch carries on when the one it replaced is cancelled, and stops when its own task is")
    func theNewestWatchIsTheOne() async throws {
        let asked = Recorder()
        let model = try Self.queuedModel(asked)
        await model.load()
        #expect(model.learned?.queued == true)

        // The page's watch, then Learn Now's press starts the next one and
        // SwiftUI cancels the first — which may not have unwound yet.
        let first = Task { await model.watchWhileItRuns() }
        try await Task.sleep(for: .milliseconds(60))
        let second = Task { await model.watchWhileItRuns() }
        first.cancel()
        await first.value

        let before = Self.reads(asked)
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.reads(asked) > before, "the new watch gave up to the old one, and nothing watches the run")
        #expect(model.inTheWay == "culling 2026-09-21", "and it names what the run waits behind")

        // He leaves the page: the task is cancelled and the asking stops.
        second.cancel()
        await second.value
        // A request already handed to the session when the task was cancelled
        // may still reach the stub; nothing after it may.
        try await Task.sleep(for: .milliseconds(100))
        let after = Self.reads(asked)
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.reads(asked) == after, "it went on asking after the page was gone")
    }
}
}
