import Testing
import Foundation
@testable import PipelineKit

// First Edit ▸ Check for Updates… checked and said nothing, whatever the
// answer - up to date, newer, or GitHub answering 404 - and the sidebar's
// "Update to … available ›" was a label that went nowhere. The answer is now
// a sheet, and Download and Install are on it (DESIGN.md §7.9).

@Suite("Check for Updates… answers", .serialized)
@MainActor
struct UpdateTests {

    /// An engine whose answers a test sets, per route.
    final class Engine: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var answers: [String: String] = [:]
        nonisolated(unsafe) static var asked: [String] = []
        static let lock = NSLock()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url!
            let key = url.path + (url.query.map { "?" + $0 } ?? "")
            let body = Self.lock.withLock { () -> String in
                Self.asked.append(key)
                return Self.answers[key] ?? Self.answers[url.path] ?? "{}"
            }
            let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                    headerFields: ["content-type": "application/json"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func set(_ a: [String: String]) { lock.withLock { answers = a; asked = [] } }
        static var questions: [String] { lock.withLock { asked } }
    }

    static func coordinator() -> UpdateCoordinator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Engine.self]
        let u = UpdateCoordinator()
        u.attach(StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"),
                              session: URLSession(configuration: config)))
        return u
    }

    static let newer = #"{"newer": true, "current": "0.1.2", "latest": "0.2.0", "url": "https://github.com/x/a.dmg", "staged": false}"#

    @Test("up to date is said, not left to be guessed from silence")
    func upToDate() async {
        Engine.set(["/api/update": #"{"newer": false, "current": "0.1.2", "latest": "0.1.2", "staged": false}"#])
        let u = Self.coordinator()
        await u.checkNow()
        #expect(u.sheetShown)
        #expect(u.answer == .upToDate("0.1.2"))
        // The menu item asks GitHub, not the engine's memory of it.
        #expect(Engine.questions == ["/api/update?force=1"])
    }

    @Test("a newer version is offered, with the one he has")
    func available() async {
        Engine.set(["/api/update": Self.newer])
        let u = Self.coordinator()
        await u.checkNow()
        #expect(u.answer == .available("0.2.0", current: "0.1.2"))
        #expect(u.footer != nil)
    }

    @Test("a check that got no answer says so, with the engine's own sentence")
    func refused() async {
        Engine.set(["/api/update": #"{"error": "GitHub answered 404 when asked for the latest release"}"#])
        let u = Self.coordinator()
        await u.checkNow()
        #expect(u.answer == .refused("GitHub answered 404 when asked for the latest release"))
    }

    @Test("with no engine to ask, the sheet does not say Checking for ever")
    func noEngine() async {
        let u = UpdateCoordinator()
        await u.checkNow()
        #expect(u.sheetShown)
        #expect(u.answer == .refused(Strings.API.offline))
    }

    @Test("a refused download keeps the version and the button on the sheet")
    func downloadRefused() async {
        Engine.set(["/api/update": Self.newer,
                    "/api/update/download": #"{"error": "a cull is running"}"#])
        let u = Self.coordinator()
        await u.checkNow()
        let started = await u.download()
        #expect(!started)
        #expect(u.actionRefusal == "a cull is running")
        #expect(u.answer == .available("0.2.0", current: "0.1.2"))
    }

    @Test("when the download ends the sheet looks again, without asking GitHub, and offers Install")
    func downloadEnded() async {
        Engine.set(["/api/update": Self.newer])
        let u = Self.coordinator()
        await u.checkNow()
        Engine.set(["/api/update": #"{"newer": true, "current": "0.1.2", "latest": "0.2.0", "staged": true}"#])
        await u.downloadEnded(Job(running: false, stopped: false, id: 3, kind: "update", code: 0))
        #expect(u.answer == .staged("0.2.0"))
        #expect(u.actionRefusal == nil)
        #expect(Engine.questions == ["/api/update"])
    }

    @Test("a download that crashed says it did not finish, and Download is offered again")
    func downloadFailed() async {
        Engine.set(["/api/update": Self.newer])
        let u = Self.coordinator()
        await u.checkNow()
        await u.downloadEnded(Job(running: false, stopped: false, id: 3, kind: "update",
                                  log: "Traceback (most recent call last):\nOSError: [Errno 28] No space left on device",
                                  code: 1))
        #expect(u.actionRefusal == Strings.Update.downloadFailed)
        #expect(u.answer == .available("0.2.0", current: "0.1.2"))
    }

    @Test("the footer's › opens the sheet on what is known, brought up to date")
    func footerOpens() async {
        Engine.set(["/api/update": Self.newer])
        let u = Self.coordinator()
        await u.show()
        #expect(u.sheetShown)
        #expect(Engine.questions == ["/api/update"])
        #expect(u.answer == .available("0.2.0", current: "0.1.2"))
    }
}
