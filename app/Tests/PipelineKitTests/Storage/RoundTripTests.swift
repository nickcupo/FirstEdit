import Foundation
import Testing
@testable import PipelineKit

/// The plan → token → apply round trip, driven against a fake engine.
///
/// This is the single most safety-critical path in the app (DESIGN.md §7.8),
/// so each of its rules is a test of its own and each one names the bug it
/// exists to prevent.
/// Serialized on purpose: the stub protocol is one answer function for the
/// whole process, and two of these running at once would answer each other's
/// requests.
@Suite("Plan, token, apply", .serialized)
@MainActor
struct RoundTripTests {

    /// An engine that answers from a script, records what it was asked, and
    /// never touches a disk. Synchronous, because a recorder that records on
    /// a detached task is a recorder the assertion can outrun.
    final class FakeEngine: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        private var applies: [[String: String]] = []
        func record(_ what: String) { lock.lock(); calls.append(what); lock.unlock() }
        func recordApply(_ body: [String: String]) { lock.lock(); applies.append(body); lock.unlock() }
        func all() -> [String] { lock.lock(); defer { lock.unlock() }; return calls }
        func appliesSoFar() -> [[String: String]] { lock.lock(); defer { lock.unlock() }; return applies }
    }

    /// The model, wired to a `StudioClient` whose session is a stub.
    static func model(shoot: String = "2026-09-13-dog",
                      answers: @escaping @Sendable (URLRequest) -> (Int, Data),
                      engine: FakeEngine) -> StorageModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.answer = answers
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"),
                                  session: URLSession(configuration: config))
        let m = StorageModel(shoot: shoot, client: client)
        // No sleeping in a test: the poll loop turns as fast as it can.
        m.sleep = { _ in }
        return m
    }

    @Test("a list is drawn by the engine and never by the app")
    func theAppNeverDrawsAPlan() async throws {
        let engine = FakeEngine()
        let plan = try StorageFixture.data("plan-drop")
        let m = Self.model(answers: { req in
            let path = req.url?.path ?? ""
            (engine.record("\(req.httpMethod ?? "") \(path)"))
            switch path {
            case "/api/storage/plan":
                return req.httpMethod == "POST" ? (200, Data(#"{"ok": true}"#.utf8)) : (200, plan)
            case "/api/job":
                return (200, Data(#"{"running": false, "kind": "plan-drop"}"#.utf8))
            default:
                return (404, Data(#"{"error": "no"}"#.utf8))
            }
        }, engine: engine)

        let request = StorageModel.Request("drop")
        await m.draw(request)

        let calls = engine.all()
        #expect(calls.first == "POST /api/storage/plan", "the engine is asked to draw it")
        #expect(calls.contains("GET /api/storage/plan"), "and then it is read back")
        #expect(m.hasPlan(for: request))
        #expect(m.plan?.label == "Remove 54 originals and free 1.3 GB")
        #expect(m.plan?.token?.count == 64)
    }

    @Test("the token that comes back is the token that goes out, once")
    func aTokenIsUsedOnce() async throws {
        let engine = FakeEngine()
        let plan = try StorageFixture.data("plan-drop")
        let token = try #require(try StorageFixture.decode(Plan.self, "plan-drop").token)
        let m = Self.model(answers: { req in
            switch req.url?.path {
            case "/api/storage/plan":
                return req.httpMethod == "POST" ? (200, Data(#"{"ok": true}"#.utf8)) : (200, plan)
            case "/api/job": return (200, Data(#"{"running": false}"#.utf8))
            case "/api/storage/apply":
                let body = (try? JSONSerialization.jsonObject(with: req.bodyData ?? Data()))
                    as? [String: Any] ?? [:]
                (engine.recordApply(body.compactMapValues { "\($0)" }))
                return (200, Data(#"{"ok": true}"#.utf8))
            default: return (404, Data(#"{"error": "no"}"#.utf8))
            }
        }, engine: engine)

        let request = StorageModel.Request("drop")
        await m.draw(request)
        #expect(await m.apply(request))

        let sent = engine.appliesSoFar()
        #expect(sent.count == 1)
        #expect(sent.first?["token"] == token, "the token is the engine's own, byte for byte")
        #expect(sent.first?["what"] == "drop")

        // Spent. The same confirmation is never handed back a second time.
        #expect(m.plan == nil)
        #expect(!m.hasPlan(for: request))
        #expect(!(await m.apply(request)), "and a second press sends nothing")
        #expect(engine.appliesSoFar().count == 1)
    }

    @Test("stale: the list is redrawn, and nothing is applied")
    func staleRedrawsAndNeverApplies() async throws {
        let engine = FakeEngine()
        let plan = try StorageFixture.data("plan-drop")
        let stale = Data("""
            {"stale": true, "error": "what is on disk changed since that list was drawn \
            — here it is again", "plan": {"what": "drop", "ready": true, "label": "Remove 52 \
            originals and free 1.2 GB", "lines": ["  52 frames"], "token": ""}}
            """.utf8)
        let applied = LockedFlag()
        let m = Self.model(answers: { req in
            switch req.url?.path {
            case "/api/storage/plan":
                return req.httpMethod == "POST" ? (200, Data(#"{"ok": true}"#.utf8)) : (200, plan)
            case "/api/job": return (200, Data(#"{"running": false}"#.utf8))
            case "/api/storage/apply":
                applied.raise()
                return (200, stale)
            default: return (404, Data(#"{"error": "no"}"#.utf8))
            }
        }, engine: engine)

        let request = StorageModel.Request("drop")
        await m.draw(request)
        let ok = await m.apply(request)

        #expect(!ok, "a stale confirmation is never an apply")
        #expect(applied.value, "the engine was asked, and the engine refused")
        #expect(m.wasRedrawn, "and the sheet says so")
        // A fresh list was drawn to replace the spent one.
        #expect(m.plan != nil)
    }

    @Test("a different option is a different list, and the old one stops counting at once")
    func optionsInvalidateTheList() async throws {
        let engine = FakeEngine()
        let unticked = try StorageFixture.data("plan-expire")
        let ticked = try StorageFixture.data("plan-expire-originals")
        let m = Self.model(answers: { req in
            switch req.url?.path {
            case "/api/storage/plan":
                if req.httpMethod == "POST" { return (200, Data(#"{"ok": true}"#.utf8)) }
                let wantsOriginals = req.url?.query?.contains("originals=1") ?? false
                return (200, wantsOriginals ? ticked : unticked)
            case "/api/job": return (200, Data(#"{"running": false}"#.utf8))
            default: return (404, Data(#"{"error": "no"}"#.utf8))
            }
        }, engine: engine)

        let plain = StorageModel.Request("expire")
        let withOriginals = StorageModel.Request("expire", PlanOptions(originals: true))

        await m.draw(plain)
        #expect(m.hasPlan(for: plain))
        #expect(!m.hasPlan(for: withOriginals), "the list he is looking at is not that list")
        #expect(m.plan?.doomed == 0)

        await m.draw(withOriginals)
        #expect(m.hasPlan(for: withOriginals))
        #expect(!m.hasPlan(for: plain))
        #expect(m.plan?.doomed == 40)
        // And the count on the gate is the new list's, not the old one's.
        #expect(ExpireGate(plan: m.plan, listIsCurrent: true, typed: "40").isOpen)
    }

    @Test("the typed number goes to the engine, which decides — the app does not decide for it")
    func theEngineChecksTheTypedNumber() async throws {
        let engine = FakeEngine()
        let ticked = try StorageFixture.data("plan-expire-originals")
        let m = Self.model(answers: { req in
            switch req.url?.path {
            case "/api/storage/plan":
                return req.httpMethod == "POST" ? (200, Data(#"{"ok": true}"#.utf8)) : (200, ticked)
            case "/api/job": return (200, Data(#"{"running": false}"#.utf8))
            case "/api/storage/apply":
                let body = (try? JSONSerialization.jsonObject(with: req.bodyData ?? Data()))
                    as? [String: Any] ?? [:]
                (engine.recordApply(body.compactMapValues { "\($0)" }))
                // What the engine answers when the number does not match.
                return (200, Data(#"{"error": "type 40 to confirm that 40 photographs will cease to exist"}"#.utf8))
            default: return (404, Data(#"{"error": "no"}"#.utf8))
            }
        }, engine: engine)

        let request = StorageModel.Request("expire", PlanOptions(originals: true))
        await m.draw(request)
        let ok = await m.apply(request, typed: "4")

        #expect(!ok)
        #expect(engine.appliesSoFar().first?["typed"] == "4",
                "it is passed through, not compared here")
        #expect(m.refusals[.storage] == "type 40 to confirm that 40 photographs will cease to exist",
                "and the engine's sentence is shown as the engine wrote it")
    }

    @Test("a refusal lands on the storage row and is cleared only by storage")
    func refusalsHaveOneOwner() async throws {
        let engine = FakeEngine()
        let m = Self.model(answers: { req in
            switch req.url?.path {
            case "/api/storage/plan":
                return (200, Data(#"{"error": "a job is already running"}"#.utf8))
            case "/api/job": return (200, Data(#"{"running": false}"#.utf8))
            default: return (404, Data(#"{"error": "no"}"#.utf8))
            }
        }, engine: engine)

        await m.draw(StorageModel.Request("drop"))
        #expect(m.refusals[.storage] == "a job is already running")
        #expect(m.refusals[.verdict] == nil, "a refusal never lands anywhere but where it came from")
    }
}

// MARK: - the stubs

/// One answer function for the whole session, set before it is used.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answer: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data) = Self.answer?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil,
                                       headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// `URLProtocol` strips `httpBody` off a request it hands back; the stream
    /// is where the bytes actually are.
    var bodyData: Data? {
        if let b = httpBody { return b }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func raise() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
