import Foundation
import AppKit
import SwiftUI
import Testing
@testable import PipelineKit

/// The panel follows the job it started, and reads itself again when it ends.
///
/// The bug: he pressed Copy the RAWs to iCloud, confirmed 36 GB, and when the
/// copy finished the panel still said "nothing in iCloud · one copy". It was
/// loaded once, when it appeared; `reloadAfterJob` existed and nothing called
/// it. Check Every Original started a job and threw its answer away, so its
/// result never reached the panel either, and pressing it again landed him in
/// a busy notice about his own check.
///
/// Nested inside `RoundTripTests` for the same reason `InTheWay` is: the stub
/// protocol is one answer function for the whole process.
extension RoundTripTests {
@Suite("The job the panel started")
@MainActor
struct Following {

    /// An engine whose one job runs for `polls` looks and then ends with
    /// `log`, and whose storage answer changes once it has.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var looks = 0
        private var reads = 0
        let polls: Int
        let log: String
        init(polls: Int, log: String) { self.polls = polls; self.log = log }
        func look() -> Int { lock.lock(); defer { lock.unlock() }; looks += 1; return looks }
        func read() { lock.lock(); reads += 1; lock.unlock() }
        var storageReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    }

    static func model(_ script: Script, storage: Data) -> StorageModel {
        InTheWay.model(shoot: "2026-09-13-dog", answers: { req in
            switch req.url?.path {
            case "/api/storage/check":
                return (200, Data(#"{"ok": true, "id": 12, "queued": false}"#.utf8))
            case "/api/storage":
                script.read()
                return (200, storage)
            case "/api/job":
                let n = script.look()
                let running = n <= script.polls
                let body: [String: Any] = [
                    "running": running, "id": 12, "kind": "stor-check", "shoot": "2026-09-13-dog",
                    "title": "checking every original of 2026-09-13-dog",
                    "label": running ? "check: 20 of 54" : "", "fraction": running ? 0.37 : 1.0,
                    "code": running ? NSNull() : 0 as Any,
                    "log": "$ pipeline/reclaim.py verify\n" + script.log]
                return (200, try! JSONSerialization.data(withJSONObject: body))
            default:
                return (404, Data(#"{"error": "no"}"#.utf8))
            }
        })
    }

    @Test("Check Every Original is followed to its end, and its last line is said on the panel")
    func theCheckIsFollowed() async throws {
        let script = Script(polls: 2, log: "\n  54 unchanged · 0 drifted · 0 not recorded yet · 0 gone\n")
        let m = Self.model(script, storage: try StorageFixture.data("storage-both"))

        #expect(await m.checkEveryOriginal())
        #expect(m.isFollowing, "the buttons are off from the press, not from the first poll")
        #expect(m.followingID == 12, "it follows the job by the number the engine gave it")

        await m.follow()

        #expect(!m.isFollowing)
        #expect(m.ended == StorageModel.Ended(
            title: "checking every original of 2026-09-13-dog", outcome: .done,
            line: "54 unchanged · 0 drifted · 0 not recorded yet · 0 gone"))
        #expect(script.storageReads == 1, "and the panel is read again the moment it stops")
        #expect(m.storage != nil)
    }

    /// An engine whose copy ends on the first look, and whose storage answer
    /// takes as long to come as a real one does and changes once the copy
    /// has ended.
    static func slowStorage(_ ended: LockedFlag, reads: Script) -> StorageModel {
        InTheWay.model(shoot: "2026-09-13-dog", answers: { req in
            switch req.url?.path {
            case "/api/storage/check":
                return (200, Data(#"{"ok": true, "id": 12, "queued": false}"#.utf8))
            case "/api/storage":
                // 150 ms here; 1.67 s on the real engine for 2026-09-19.
                Thread.sleep(forTimeInterval: 0.15)
                reads.read()
                let after = ended.value
                return (200, (try? after ? StorageFixture.data("storage-both") : Fixture.data("storage")) ?? Data())
            case "/api/job":
                ended.raise()
                let body: [String: Any] = [
                    "running": false, "id": 12, "kind": "stor-push", "shoot": "2026-09-13-dog",
                    "title": "copying the RAWs of 2026-09-13-dog to iCloud", "code": 0,
                    "log": "$ pipeline/archive.py push\n  54 copied and verified, 0 failed."]
                return (200, try! JSONSerialization.data(withJSONObject: body))
            default:
                return (404, Data(#"{"error": "no"}"#.utf8))
            }
        })
    }

    @Test("the panel is read again when the job ends, although letting go of its number cancels the task following it")
    func theReadSurvivesTheTaskBeingReplaced() async throws {
        let ended = LockedFlag()
        let reads = Script(polls: 0, log: "")
        let m = Self.slowStorage(ended, reads: reads)
        await m.load()
        #expect(m.storage?.line.contains("nothing in iCloud") == true)

        #expect(await m.checkEveryOriginal())
        // Exactly what the panel does with `.task(id: model.followingID)`.
        let keyed = TaskKeyedOnFollowingID(m)
        keyed.start()
        // The replacement is a main-actor task of its own, which a busy run
        // can hold back past the moment following ends: wait for both.
        let deadline = ContinuousClock.now + .seconds(20)
        while m.isFollowing || keyed.restarts == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(!m.isFollowing)
        #expect(keyed.restarts >= 1, "the id changed, so the task that followed the job was replaced")
        // The read after the job was answered, not cancelled with its task.
        #expect(m.storage?.line.contains("two copies of every frame") == true,
                "the panel still says \(m.storage?.line ?? "nothing")")
        #expect(m.ended?.line == "54 copied and verified, 0 failed.")
    }

    @Test("the panel itself, hosted, is read again after the job it started")
    func theHostedPanelReadsItselfAgain() async throws {
        let ended = LockedFlag()
        let reads = Script(polls: 0, log: "")
        let m = Self.slowStorage(ended, reads: reads)
        // The real view, with its own `.task` and `.task(id:)`, in a hosting
        // view that is never put in a window: SwiftUI still runs its tasks,
        // and nothing appears on any screen.
        _ = NSApplication.shared
        let host = NSHostingView(rootView: StoragePanel(model: m))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 780)
        func settle(until done: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !done(), ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await settle { m.storage != nil }
        #expect(m.storage?.line.contains("nothing in iCloud") == true)

        #expect(await m.checkEveryOriginal())
        try await settle { m.ended != nil && !m.isFollowing }

        #expect(m.ended?.outcome == .done)
        #expect(!m.isFollowing)
        #expect(m.storage?.line.contains("two copies of every frame") == true,
                "the panel still says \(m.storage?.line ?? "nothing")")
        withExtendedLifetime(host) {}
    }

    @Test("while the panel is read again after the job, every button still waits")
    func theButtonsWaitForTheFreshCounts() async throws {
        let ended = LockedFlag()
        let reads = Script(polls: 0, log: "")
        let m = Self.slowStorage(ended, reads: reads)
        await m.load()
        #expect(await m.checkEveryOriginal())
        let following = Task { await m.follow() }
        // The job has ended and its ending is said; the storage read is still
        // on its way, and the job's number is still held until it lands.
        let deadline = ContinuousClock.now + .seconds(5)
        while m.ended == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(m.ended != nil)
        #expect(m.isFollowing, "no button is judged on the counts from before the job")
        await following.value
        #expect(!m.isFollowing)
        #expect(m.storage?.line.contains("two copies of every frame") == true)
    }

    @Test("a job it follows that is neither running nor waiting any more lets the panel go")
    func aVanishedJobLetsGo() async throws {
        let m = InTheWay.model(shoot: "2026-09-13-dog", answers: { req in
            switch req.url?.path {
            case "/api/storage/check": return (200, Data(#"{"ok": true, "id": 12}"#.utf8))
            case "/api/storage": return (200, (try? StorageFixture.data("storage-both")) ?? Data())
            case "/api/job":
                // An earlier job, long over, and an empty list: 12 is nowhere.
                return (200, Data(#"{"running": false, "id": 9, "queued": false, "kind": "cull", "code": 0}"#.utf8))
            default: return (404, Data(#"{"error": "no"}"#.utf8))
            }
        })
        #expect(await m.checkEveryOriginal())
        await m.follow()
        #expect(!m.isFollowing)
        #expect(m.ended?.outcome == .idle, "it never claims a Done it did not see")
    }

    /// What the studio's log held after each apply on a scratch shoot, as
    /// archive.py and reclaim.py print it when the studio starts them (the
    /// `@@` marks are left out of the log by the studio). The last line is
    /// what the panel says under how the job ended, and it used to be
    /// `./pl archive drop <his home path>` after every copy.
    static let tails: [(log: String, said: String)] = [
        ("""
         $ python archive.py push /scratch/photos/shoots/2026-09-13-dog --apply
           2026-09-13-dog: 3 originals, 0 already up
           would copy 3 frames, 24 KB, to /scratch/icloud/Photo Pipeline Archive
             3/3 copied and verified

           3 copied and verified, 0 failed. iCloud still has to upload them, and Remove the Local RAWs takes none until it has.
         """,
         "3 copied and verified, 0 failed. iCloud still has to upload them, and Remove the Local RAWs takes none until it has."),
        ("""
         $ python archive.py drop /scratch/photos/shoots/2026-09-13-dog --apply
           2026-09-13-dog: 3 frames verified in iCloud, 0 refused

           would free 24 KB by removing 3 originals

           Removed 3 originals and their links; 24 KB back. Bring the RAWs Back brings them down again.
         """,
         "Removed 3 originals and their links; 24 KB back. Bring the RAWs Back brings them down again."),
        ("""
         $ python archive.py pull /scratch/photos/shoots/2026-09-13-dog --apply
           2026-09-13-dog: 3 frames to bring back, 24 KB
             3/3

           3 back, 0 failed.
         """,
         "3 back, 0 failed."),
        ("""
         $ python reclaim.py reclaim /scratch/photos/shoots/2026-09-13-dog --apply
           this would remove, and only this:
             cull/thumbs/                  2 files     16 KB
                                           2 files     16 KB  total

           Removed 2 files, 16 KB. The next cull makes the cache again.
         """,
         "Removed 2 files, 16 KB. The next cull makes the cache again."),
    ]

    @Test("the line under a finished job is the engine's result, never a command to type or a path")
    func theEndingLineIsTheResult() {
        for t in Self.tails {
            let j = Job(running: false, stopped: false, id: 12, kind: "stor-push", log: t.log, code: 0)
            #expect(j.outcome == .done)
            let line = j.refusalSentence ?? ""
            #expect(line == t.said)
            #expect(!line.contains("./pl") && !line.contains("--") && !line.contains("/"), "\(line)")
        }
    }

    @Test("a later job in the slot ends the watch, and it never claims a Done it did not see")
    func aLaterJobEndsIt() async throws {
        let m = InTheWay.model(shoot: "2026-09-13-dog", answers: { req in
            switch req.url?.path {
            case "/api/storage/check": return (200, Data(#"{"ok": true, "id": 12}"#.utf8))
            case "/api/storage": return (200, (try? StorageFixture.data("storage-both")) ?? Data())
            case "/api/job":
                return (200, Data(#"{"running": true, "id": 13, "kind": "cull", "shoot": "x"}"#.utf8))
            default: return (404, Data(#"{"error": "no"}"#.utf8))
            }
        })
        #expect(await m.checkEveryOriginal())
        await m.follow()
        #expect(!m.isFollowing)
        #expect(m.ended?.outcome == .idle)
    }

    @Test("a refused start follows nothing")
    func aRefusalIsNotFollowed() async throws {
        let m = InTheWay.model(shoot: "2026-09-13-dog", answers: { req in
            switch req.url?.path {
            case "/api/storage/check":
                return (200, Data(#"{"error": "that is not one shoot"}"#.utf8))
            default: return (404, Data(#"{"error": "no"}"#.utf8))
            }
        })
        #expect(!(await m.checkEveryOriginal()))
        #expect(!m.isFollowing)
        #expect(m.refusals[.storage] == "that is not one shoot")
    }

    @Test("a storage job of this shoot already running is picked up when the page comes back")
    func aRunningJobIsAdopted() async throws {
        let m = InTheWay.model(shoot: "2026-09-13-dog", answers: { req in
            switch req.url?.path {
            case "/api/job":
                return (200, Data(#"{"running": true, "id": 4, "kind": "stor-push", "shoot": "2026-09-13-dog", "title": "copying the RAWs of 2026-09-13-dog to iCloud"}"#.utf8))
            default: return (404, Data(#"{"error": "no"}"#.utf8))
            }
        })
        await m.adoptRunningJob()
        #expect(m.followingID == 4)
        #expect(m.following?.title == "copying the RAWs of 2026-09-13-dog to iCloud")
    }

    @Test("another shoot's job, or one that is not storage, is not his panel's")
    func othersAreNotAdopted() async throws {
        let m = InTheWay.model(shoot: "2026-09-13-dog", answers: { req in
            switch req.url?.path {
            case "/api/job":
                return (200, Data(#"{"running": true, "id": 4, "kind": "stor-push", "shoot": "2026-09-21"}"#.utf8))
            default: return (404, Data(#"{"error": "no"}"#.utf8))
            }
        })
        await m.adoptRunningJob()
        #expect(m.followingID == nil)
    }
}
}

/// What `.task(id: model.followingID) { await model.follow() }` does on the
/// panel, without a window: when the id changes, the task running is
/// cancelled and a new one is started for the new id, on the next turn of the
/// main actor, as SwiftUI does when it next updates the view.
///
/// The tests that call `follow()` by hand never saw the bug this exists for:
/// clearing the id cancelled the very task that was reading the panel again.
@MainActor
final class TaskKeyedOnFollowingID {
    let model: StorageModel
    private var task: Task<Void, Never>?
    private(set) var restarts = 0

    init(_ model: StorageModel) { self.model = model }

    func start() {
        task = Task { [model] in await model.follow() }
        withObservationTracking { _ = model.followingID } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.task?.cancel()
                self.restarts += 1
                self.start()
            }
        }
    }
}
