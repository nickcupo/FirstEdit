import Testing
import Foundation
@testable import PipelineKit

// The job poll and the list's poll, made to wake each other.
//
// The toolbar, the step's own progress, Stop (⌘.), the Dock and the lock that
// keeps the Mac awake all read the job poll; the step's button and the list
// read the list's. The engine starts the list's next piece of work by itself,
// and he starts work by hand: whichever poll happened to be running was the
// only one that knew, so a cull he walked away from ran with no progress
// anywhere, ⌘. greyed, and the Mac free to sleep in the middle of it.

@Suite("The two polls wake each other", .serialized)
@MainActor
struct QueuePairingTests {

    /// An engine with one job running, off the list. Counts what it is asked.
    final class Running: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var paths: [String] = []
        static let lock = NSLock()
        static let job = Data("""
        {"running": true, "stopped": false, "id": 7, "kind": "cull", "shoot": "2026-09-19", \
        "title": "culling 2026-09-19", "fraction": 0.2, "queue_from_list": true}
        """.utf8)
        static let queue = Data("""
        {"queue": [], "held": false, "listed": 1, "fraction": 0.2, "pass": 1, "done": [], \
        "skipped": [], "running": true, "from_list": true, "id": 7, "kind": "cull", \
        "title": "culling 2026-09-19", "shoot": "2026-09-19", "job_fraction": 0.2}
        """.utf8)
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let path = request.url?.path ?? ""
            Self.lock.withLock { Self.paths.append(path) }
            let body = path == "/api/job" ? Self.job : path == "/api/queue" ? Self.queue : Data("{}".utf8)
            let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["content-type": "application/json"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func reset() { lock.withLock { paths = [] } }
        static func asked(_ path: String) -> Int { lock.withLock { paths.filter { $0 == path }.count } }
    }

    static func client() -> StudioClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Running.self]
        return StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"),
                            session: URLSession(configuration: config))
    }

    /// How long a woken poll's first reading may take to land. The first
    /// reading is asked the moment a poll is woken, so on a quiet machine it
    /// lands in milliseconds; the bound is for a full run of the suite, where
    /// the main actor is shared with every other test and one interval
    /// (1.2 s) was missed three runs in five.
    static let firstReading: Duration = .seconds(10)

    /// Waits up to `limit` for `done`, a few milliseconds at a time.
    static func within(_ limit: Duration, _ done: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + limit
        while clock.now < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    @Test("work the list starts by itself is on the toolbar at the job poll's first reading")
    func theListWakesTheJobPoll() async {
        Running.reset()
        let client = Self.client()
        let jobs = JobModel(client: client)
        let queue = QueueModel(client: client)
        queue.pair(with: jobs)
        #expect(!jobs.isWatching)

        // The list's poll is the one that saw it: he pressed Continue on a
        // held list, or added a cull with nothing running, and walked away.
        queue.take(QueueState(listed: 1, pass: 1, running: true, fromList: true, id: 7,
                              kind: "cull", title: "culling 2026-09-19", shoot: "2026-09-19"))
        #expect(jobs.isWatching)
        let seen = await Self.within(Self.firstReading) { jobs.isRunning }
        #expect(seen, "the toolbar, ⌘., the Dock and the keep-awake lock never heard of it")
        #expect(jobs.job?.id == 7)
        jobs.cancelWatching()
        queue.cancelWatching()
    }

    @Test("a job he starts by hand turns every step's button into an add")
    func theJobPollWakesTheList() async {
        Running.reset()
        let client = Self.client()
        let jobs = JobModel(client: client)
        let queue = QueueModel(client: client)
        queue.pair(with: jobs)
        #expect(!queue.wouldWait)

        jobs.take(Job(running: true, stopped: false, id: 7, kind: "cull", shoot: "2026-09-19"))
        #expect(queue.isWatching)
        let seen = await Self.within(Self.firstReading) { queue.wouldWait }
        #expect(seen, "Cull It would have started a second cull instead of adding it")
        jobs.cancelWatching()
        queue.cancelWatching()
    }

    @Test("a poll that is already alive is left alone, so the two cannot drive each other")
    func noFeedbackLoop() async {
        Running.reset()
        let client = Self.client()
        let jobs = JobModel(client: client)
        let queue = QueueModel(client: client)
        queue.pair(with: jobs)
        jobs.watch()
        queue.watch()
        // Both polls see work running and wake the other on every reading.
        // If waking restarted a live poll, each would ask again at once and
        // this would be dozens of reads, not one or two.
        try? await Task.sleep(for: .milliseconds(600))
        #expect(Running.asked("/api/job") <= 2)
        #expect(Running.asked("/api/queue") <= 2)
        jobs.cancelWatching()
        queue.cancelWatching()
        #expect(!jobs.isWatching && !queue.isWatching)
    }

    @Test("attaching the engine the list already has leaves its poll alone")
    func sameEngineIsNothing() {
        // A step reaches the list through `Queues.model(client:)` from its
        // body, which attaches it on every redraw. That cancelled the poll
        // each time, and wrote observed state from inside a body, which
        // redrew the body: the step pages never finished drawing offscreen.
        let client = Self.client()
        let queue = QueueModel(client: client)
        queue.watch()
        queue.attach(client)
        #expect(queue.isWatching)
        // Another engine is another matter: the old poll goes.
        queue.attach(Self.client())
        #expect(!queue.isWatching)
    }

    @Test("a cancelled poll that finishes late does not mark its replacement stopped")
    func aLatePollKeepsItsPlace() async {
        let jobs = JobModel(client: Self.client())
        jobs.watch()
        jobs.watch()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(jobs.isWatching)
        jobs.cancelWatching()
        #expect(!jobs.isWatching)
    }
}

// What the engine said to a press belongs under the button he pressed. The
// steps all read one slot, so a refusal on one page sat in red under every
// other step's button until some job next started.
@Suite("A refusal stays on the page that raised it")
@MainActor
struct RefusalPlaceTests {

    @Test("leaving the page takes down the job's refusal, the job in the way and the homework note")
    func leavingThePage() {
        let jobs = JobModel()
        jobs.refusals.set(.job, "No editor found on this Mac.")
        jobs.busy.set(.job, Busy(kind: "cull", title: "culling 2026-09-19", shoot: "2026-09-19"))
        jobs.leftThePage()
        #expect(jobs.refusals[.job] == nil)
        #expect(jobs.busy[.job] == nil)
        // Anyone else's refusal is theirs to clear.
        jobs.refusals.set(.storage, "not yours")
        jobs.leftThePage()
        #expect(jobs.refusals[.storage] == "not yours")
    }

    @Test("a refused add goes with the page; the list's own refusals stay in its window")
    func theListKeepsItsOwn() {
        let queue = QueueModel()
        queue.refusals.set(.job, "Removing the local RAWs is not something to leave on a list.")
        queue.refusals.set(.list, "That order is not the list any more.")
        queue.leftThePage()
        #expect(queue.refusals[.job] == nil)
        #expect(queue.refusals[.list] != nil)
    }
}

/// A double-click on "Add It to the List" added two identical culls: the
/// engine accepts duplicates, and nothing on this side stopped the second.
@Suite("A double-click is one add", .serialized)
@MainActor
struct QueueDoubleClickTests {

    final class Adds: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var posts = 0
        static let lock = NSLock()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let isAdd = request.httpMethod == "POST" && request.url?.path == "/api/queue"
            var n = 0
            Self.lock.withLock { if isAdd { Self.posts += 1 }; n = Self.posts }
            let body = isAdd
                ? Data(#"{"ok": true, "added": {"id": \#(40 + n), "kind": "cull", "shoot": "d"}, "list": {"queue": [], "running": false}}"#.utf8)
                : Data(#"{"queue": [], "running": false}"#.utf8)
            let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["content-type": "application/json"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    static func model() -> QueueModel {
        Adds.lock.withLock { Adds.posts = 0 }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Adds.self]
        let model = QueueModel(client: StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"),
                                                   session: URLSession(configuration: config)))
        let now = ContinuousClock.now
        model.nowForAdds = { now }
        return model
    }

    @Test("two clicks at once, or one just after the other, send one add")
    func oneAdd() async {
        let q = Self.model()
        async let a = q.add(kind: "cull", shoot: "d", options: ["focus": .number(1.9)])
        async let b = q.add(kind: "cull", shoot: "d", options: ["focus": .number(1.9)])
        _ = await (a, b)
        let again = await q.add(kind: "cull", shoot: "d", options: ["focus": .number(1.9)])
        #expect(Adds.lock.withLock { Adds.posts } == 1)
        #expect(again?.id == 41, "the second click is answered with the first add")
        q.cancelWatching()
    }

    @Test("the same work can be added again after the double-click interval")
    func afterTheInterval() async {
        let q = Self.model()
        var now = ContinuousClock.now
        q.nowForAdds = { now }
        let first = await q.add(kind: "cull", shoot: "d")
        now = now.advanced(by: .milliseconds(999))
        let bounce = await q.add(kind: "cull", shoot: "d")
        #expect(bounce?.id == first?.id)
        #expect(Adds.lock.withLock { Adds.posts } == 1)
        now = now.advanced(by: .milliseconds(1))
        let next = await q.add(kind: "cull", shoot: "d")
        #expect(next?.id == 42)
        #expect(Adds.lock.withLock { Adds.posts } == 2)
        q.cancelWatching()
    }

    @Test("different work, or other options, is its own add")
    func differentWork() async {
        let q = Self.model()
        _ = await q.add(kind: "cull", shoot: "d", options: ["focus": .number(1.9)])
        _ = await q.add(kind: "cull", shoot: "d", options: ["focus": .number(1.2)])
        _ = await q.add(kind: "presets", shoot: "d")
        #expect(Adds.lock.withLock { Adds.posts } == 3)
        q.cancelWatching()
    }
}
