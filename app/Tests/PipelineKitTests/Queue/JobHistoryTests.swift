import Testing
import Foundation
@testable import PipelineKit

// The Activity window's history: one row per piece of work the engine ran,
// each closed with how it ended.
//
// It matched rows by kind and shoot, so the presets written a second time -
// and failing - never got a row: the first run's green "Done" stood for both.
// A job the list replaced with its next one between two polls, and a job
// whose engine crashed under it, stayed "Running" for the rest of the evening.

@Suite("The history of this session's work")
@MainActor
struct JobHistoryTests {

    static let full = "$ pipeline/presets.py 2026-09-19\nOSError: [Errno 28] No space left on device"

    @Test("a second run of the same work is a row of its own, even one no poll saw running")
    func reRunsAreRows() {
        let jobs = JobModel()
        jobs.take(Job(running: false, stopped: false, id: 4, kind: "presets", shoot: "2026-09-19", code: 0))
        jobs.take(Job(running: false, stopped: false, id: 5, kind: "presets", shoot: "2026-09-19",
                      log: Self.full, code: 1))
        #expect(jobs.history.count == 2)
        #expect(jobs.history.map(\.outcome) == [.done, .failed])
        // Twenty more readings of the same ended job add nothing.
        jobs.take(Job(running: false, stopped: false, id: 5, kind: "presets", shoot: "2026-09-19",
                      log: Self.full, code: 1))
        #expect(jobs.history.count == 2)
    }

    @Test("a job the list replaced between two polls is closed with the word the list wrote down")
    func overtakenByTheList() {
        let jobs = JobModel()
        jobs.take(Job(running: true, stopped: false, id: 7, kind: "cull", shoot: "2026-09-19", elapsed: 300))
        jobs.take(Job(running: true, stopped: false, id: 8, kind: "presets", shoot: "2026-09-19",
                      listDone: [QueueDone(id: 7, kind: "cull", shoot: "2026-09-19", outcome: "failed")]))
        #expect(jobs.history.map(\.outcome) == [.failed, .running])
        // Its time is the last one read, frozen.
        #expect(jobs.history[0].elapsed == 300)
    }

    @Test("with nothing to say how it ended, it is Ended - not Done, and not Running for ever")
    func overtakenUnknown() {
        let jobs = JobModel()
        var ended: [Int] = []
        jobs.onJobEnded = { ended.append($0.id) }
        jobs.take(Job(running: true, stopped: false, id: 7, kind: "presets", shoot: "a"))
        jobs.take(Job(running: true, stopped: false, id: 8, kind: "cull", shoot: "b"))
        #expect(jobs.history[0].outcome == .idle)
        #expect(ActivityWindow.word(.idle) == Strings.Activity.ended)
        // The shoot it was about is read again, as for any ending.
        #expect(ended == [7])
    }

    @Test("a job whose engine went away is Failed, with a line under its log that says why")
    func theEngineWentAway() {
        let jobs = JobModel()
        jobs.take(Job(running: true, stopped: false, id: 7, kind: "cull", shoot: "2026-09-19",
                      log: "$ pipeline/cull.py 2026-09-19\nlooking at faces: 612 of 1,558", elapsed: 201))
        jobs.attach(StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "new")))
        #expect(jobs.history[0].outcome == .failed)
        #expect(jobs.history[0].elapsed == 201)
        #expect(jobs.history[0].job.log.hasSuffix(Strings.Activity.engineStoppedWhileRunning))
        #expect(!jobs.history[0].job.running)
    }

    @Test("the restarted engine's first answer closes what the old one was running")
    func aFreshEngineSaysNothingRuns() {
        let jobs = JobModel()
        jobs.take(Job(running: true, stopped: false, id: 7, kind: "cull", shoot: "2026-09-19"))
        jobs.take(Job(running: false, stopped: false))
        #expect(jobs.history[0].outcome == .failed)
    }

    @Test("a number the restarted engine uses again is a new row, not the old one's")
    func numbersAreOnlyUniqueWithinOneEngine() {
        let jobs = JobModel()
        jobs.take(Job(running: false, stopped: false, id: 3, kind: "cull", shoot: "a", code: 0))
        jobs.attach(StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "new")))
        jobs.take(Job(running: true, stopped: false, id: 3, kind: "presets", shoot: "b"))
        #expect(jobs.history.count == 2)
        #expect(jobs.history[0].outcome == .done)
    }

    @Test("Started is when the engine started it, not when the app first looked")
    func startedIsTheEngines() {
        let jobs = JobModel()
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        jobs.take(Job(running: true, stopped: false, id: 7, kind: "cull", shoot: "a", startedAt: at))
        #expect(jobs.history[0].started == at)
    }

    @Test("the engine's start time and the list's outcomes decode off /api/job")
    func decodes() throws {
        let j = try Fixture.decodeJSON(Job.self, """
        {"running": true, "stopped": false, "id": 8, "kind": "presets", "shoot": "d", \
        "started": 1790000000.25, "queue_done": [{"id": 7, "kind": "cull", "title": "culling d", \
        "shoot": "d", "outcome": "failed"}]}
        """)
        #expect(j.startedAt == Date(timeIntervalSince1970: 1_790_000_000.25))
        #expect(j.listDone.map(\.ended) == [.failed])
        let old = try Fixture.decodeJSON(Job.self, #"{"running": false, "stopped": false, "started": null}"#)
        #expect(old.startedAt == nil)
        #expect(old.listDone.isEmpty)
    }

    @Test("the log shown first is the newest failure's, and its row is picked")
    func theFailureIsReadFirst() {
        func row(_ n: Int, _ o: Job.Outcome) -> ActivityRow {
            ActivityRow(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")!, what: "", shoot: "",
                        started: Date(), elapsed: 0, outcome: o, log: "\(n)")
        }
        let copy = row(1, .done), cull = row(2, .failed), presets = row(3, .done)
        // A failed cull, then presets that went fine: the cull's log, not the
        // presets' two lines under a table that did not say whose they were.
        #expect(ActivityWindow.firstToRead([copy, cull, presets]) == cull.id)
        #expect(ActivityWindow.firstToRead([copy, presets]) == presets.id)
        #expect(ActivityWindow.firstToRead([]) == nil)
    }

    @Test("after a failure he has read, or a no he saw under its button, the window opens on what is running")
    func whatIsRunningOnceTheNewsIsRead() {
        func row(_ n: Int, _ o: Job.Outcome, fromList: Bool = false) -> ActivityRow {
            ActivityRow(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")!, what: "", shoot: "",
                        started: Date(), elapsed: 0, outcome: o, log: "\(n)", fromList: fromList)
        }
        // "no archive manifest", said under the button he pressed, then a cull.
        let check = row(1, .refused), presets = row(2, .done), cull = row(3, .running)
        #expect(ActivityWindow.firstToRead([check, presets, cull]) == cull.id)
        // A crash he has not read yet comes first, even with the list's next
        // piece running: the banner sent him here for it.
        let crashed = row(4, .failed), next = row(5, .running)
        #expect(ActivityWindow.firstToRead([crashed, next]) == crashed.id)
        // Once it has been in front of him, the running one.
        #expect(ActivityWindow.firstToRead([crashed, next], read: [crashed.id]) == next.id)
        // A no the list got while he was away is news; he saw nothing of it.
        let listNo = row(6, .refused, fromList: true)
        #expect(ActivityWindow.firstToRead([listNo, next]) == listNo.id)
    }

    // MARK: - across quits

    static let lastNight = """
    {"run": "1790050000-99", "days": 3, "jobs": [\
    {"run": "1790000000-12", "id": 3, "kind": "presets", "title": "presets for 2026-09-19", \
    "shoot": "2026-09-19", "why": "", "background": false, "from_list": true, \
    "started": 1790000900.0, "ended": 1790000909.0, "elapsed": 9, "outcome": "done", "code": 0, \
    "log": "$ pipeline/presets.py 2026-09-19\\nwrote 23 presets."}, \
    {"run": "1790000000-12", "id": 2, "kind": "cull", "title": "culling 2026-09-19", \
    "shoot": "2026-09-19", "why": "", "background": false, "from_list": true, \
    "started": 1790000420.0, "ended": 1790000791.0, "elapsed": 371, "outcome": "failed", "code": 1, \
    "log": "$ pipeline/cull.py 2026-09-19\\nMemoryError"}, \
    {"run": "1790050000-99", "id": 7, "kind": "cull", "title": "culling 2026-09-20", \
    "shoot": "2026-09-20", "why": "", "background": false, "from_list": false, \
    "started": 1790050100.0, "ended": 1790050200.0, "elapsed": 100, "outcome": "done", "code": 0, \
    "log": ""}]}
    """

    @Test("last night's jobs are there in the morning, before this session's, with their outcomes and logs")
    func earlierSessions() throws {
        let e = try Fixture.decodeJSON(EarlierJobs.self, Self.lastNight)
        // This engine's own jobs are followed as they happen, not read back.
        #expect(e.beforeThisRun.map(\.id) == [3, 2])
        let jobs = JobModel()
        jobs.take(Job(running: true, stopped: false, id: 1, kind: "ingest", shoot: "2026-09-21"))
        jobs.adoptEarlier(e.beforeThisRun)
        #expect(jobs.history.map(\.job.kind) == ["cull", "presets", "ingest"], "oldest first, then this session")
        #expect(jobs.history.map(\.outcome) == [.failed, .done, .running])
        #expect(jobs.history[0].elapsed == 371)
        #expect(jobs.history[0].job.log.hasSuffix("MemoryError"))
        #expect(jobs.history[0].started == Date(timeIntervalSince1970: 1_790_000_420))
        // Read twice, it is still there once.
        jobs.adoptEarlier(e.beforeThisRun)
        #expect(jobs.history.count == 3)
        // This session's job, seen again, updates its own row and not an
        // earlier run's with the same number.
        jobs.take(Job(running: false, stopped: false, id: 2, kind: "cull", shoot: "2026-09-21", code: 0))
        #expect(jobs.history.filter(\.earlier).map(\.outcome) == [.failed, .done])
    }

    @Test("an earlier session's failure is shown but is not news, and its start carries the day")
    func earlierIsNotNews() throws {
        let e = try Fixture.decodeJSON(EarlierJobs.self, Self.lastNight)
        let jobs = JobModel()
        jobs.adoptEarlier(e.beforeThisRun)
        let rows = jobs.history.map(ActivityRow.init)
        #expect(rows.allSatisfy { $0.earlier && !$0.isNews })
        // Nothing this session: the window opens on the newest.
        #expect(ActivityWindow.firstToRead(rows) == rows.last?.id)
        let day = Calendar(identifier: .gregorian)
        let started = rows[0].started
        #expect(rows[0].startedText(now: started, calendar: day) == started.formatted(.dateTime.hour().minute()))
        let tomorrow = started.addingTimeInterval(86_400)
        #expect(rows[0].startedText(now: tomorrow, calendar: day)
                == started.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
    }
}
