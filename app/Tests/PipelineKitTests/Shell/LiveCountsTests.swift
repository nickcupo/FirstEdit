import Foundation
import Testing
@testable import PipelineKit

/// The counts in the title and the sidebar move with what he does, rather than
/// staying at what the library said at launch.
@Suite("Counts that keep up", .serialized)
@MainActor
struct LiveCountsTests {

    @Test("a job that ends is told once, so the library can be read again")
    func jobEnded() {
        let jobs = JobModel()
        var ended: [String] = []
        jobs.onJobEnded = { ended.append($0.kind) }
        jobs.take(Job(running: true, stopped: false, id: 1, kind: "cull", shoot: "s"))
        jobs.take(Job(running: true, stopped: false, id: 1, kind: "cull", shoot: "s"))
        #expect(ended.isEmpty)
        jobs.take(Job(running: false, stopped: false, id: 1, kind: "cull", shoot: "s"))
        // The poll goes on for five seconds after the end; that is not a
        // second ending.
        jobs.take(Job(running: false, stopped: false, id: 1, kind: "cull", shoot: "s"))
        #expect(ended == ["cull"])
    }

    @Test("a job that ended before any poll saw it running is told too, once")
    func quickJobEnded() {
        let jobs = JobModel()
        var ended: [Int] = []
        jobs.onJobEnded = { ended.append($0.id) }
        // A presets job over before the first look: recorded finished.
        jobs.take(Job(running: false, stopped: false, id: 4, kind: "presets", shoot: "s"))
        jobs.take(Job(running: false, stopped: false, id: 4, kind: "presets", shoot: "s"))
        #expect(ended == [4])
        // Another of the same kind for the same shoot, just as quick: a new
        // number, so a new ending, though the list already has a record.
        jobs.take(Job(running: false, stopped: false, id: 5, kind: "presets", shoot: "s"))
        jobs.take(Job(running: false, stopped: false, id: 5, kind: "presets", shoot: "s"))
        #expect(ended == [4, 5])
    }

    /// An engine that says yes to everything and counts what it was asked.
    final class Yes: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var paths: [String] = []
        nonisolated(unsafe) static var shoots: Data = Data("{}".utf8)
        static let lock = NSLock()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let path = request.url?.path ?? ""
            Self.lock.withLock { Self.paths.append(path) }
            let body = path == "/api/shoots" ? Self.shoots : Data("{}".utf8)
            let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["content-type": "application/json"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    static func client() -> StudioClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Yes.self]
        return StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"),
                            session: URLSession(configuration: config))
    }

    @Test("bursts been through come from the open shoot, and move with an N the engine accepted")
    func burstsFromTheSession() async throws {
        let client = Self.client()
        let session = ShootSession(response: try ViewerTests.response(), ext: nil, client: client,
                                   pump: ImagePump(budget: .base, loader: { _ in Data() }),
                                   queue: VerdictQueue(sender: { _ in .failure(.offline) }))
        let r = try Fixture.decode(ShootsResponse.self, "shoots")
        let app = AppModel(preview: Library(preview: r), state: .stopped, navigation: Navigation())
        let name = session.name
        if let row = app.library.row(named: name) {
            #expect(app.bursts(for: name)! == (row.seen, row.bursts), "before it is open, the library's line")
        }
        app.library.adopt(session)
        let i = try #require(session.bursts.firstIndex { !$0.seen })
        session.go(burst: i)
        let before = try #require(app.bursts(for: name))
        #expect(before.of == session.bursts.count)
        #expect(await session.finishBurst() == .applied)
        #expect(app.bursts(for: name)!.seen == before.seen + 1)
    }

    @Test("an N the engine accepts reads the library again, so kept moves with the bursts beside it")
    func keptMovesWithN() async throws {
        Yes.lock.withLock { Yes.paths = []; Yes.shoots = (try? Fixture.data("shoots")) ?? Data() }
        let client = Self.client()
        let lib = Library(client: client, pump: ImagePump(budget: .base, loader: { _ in Data() }))
        let session = ShootSession(response: try ViewerTests.response(), ext: nil, client: client,
                                   pump: ImagePump(budget: .base, loader: { _ in Data() }),
                                   queue: VerdictQueue(sender: { _ in .failure(.offline) }))
        lib.adopt(session)
        let i = try #require(session.bursts.firstIndex { !$0.seen })
        session.go(burst: i)
        #expect(await session.finishBurst() == .applied)
        var reads = 0
        for _ in 0..<50 where reads == 0 {
            try await Task.sleep(for: .milliseconds(10))
            reads = Yes.lock.withLock { Yes.paths.filter { $0 == "/api/shoots" }.count }
        }
        #expect(reads == 1, "one read of the list for one N, not \(reads)")
    }

    /// An engine whose list answers or does not, as the test says.
    final class Flaky: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var up = true
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard Self.up else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["content-type": "application/json"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? Fixture.data("shoots")) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @Test("a read nobody asked for neither says offline on one failure nor clears a refused command")
    func quietReads() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Flaky.self]
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"),
                                  session: URLSession(configuration: config))
        let lib = Library(client: client, pump: ImagePump(budget: .base, loader: { _ in Data() }))

        // Never read: the failure is what All Shoots has to say.
        Flaky.up = false
        await lib.refreshSoon()
        #expect(lib.refusals[.library] != nil)
        Flaky.up = true
        await lib.refreshSoon()
        #expect(lib.loaded)
        #expect(lib.refusals[.library] == nil, "the list's own failure goes once it reads")

        // Read, and an Eject was refused at the foot of the sidebar.
        lib.refusals.set(.library, "The card is in use.")
        Flaky.up = false
        await lib.refreshSoon()
        #expect(lib.refusals[.library] == "The card is in use.", "one failed background read is not news")
        Flaky.up = true
        await lib.refreshSoon()
        #expect(lib.refusals[.library] == "The card is in use.", "an unrelated read does not unsay it")
        // Asked for by name, the read still speaks.
        Flaky.up = false
        await lib.refresh()
        #expect(lib.refusals[.library] != "The card is in use.")
        Flaky.up = true
    }

    @Test("asking for the list again while a read is out makes one more read, not a pile")
    func refreshCoalesces() async throws {
        Yes.lock.withLock { Yes.paths = []; Yes.shoots = (try? Fixture.data("shoots")) ?? Data() }
        let lib = Library(client: Self.client(), pump: ImagePump(budget: .base, loader: { _ in Data() }))
        async let a: Void = lib.refreshSoon()
        async let b: Void = lib.refreshSoon()
        async let c: Void = lib.refreshSoon()
        _ = await (a, b, c)
        let reads = Yes.lock.withLock { Yes.paths.filter { $0 == "/api/shoots" }.count }
        #expect(reads >= 1 && reads <= 2, "\(reads) reads for three asks")
        #expect(lib.loaded)
    }
}
