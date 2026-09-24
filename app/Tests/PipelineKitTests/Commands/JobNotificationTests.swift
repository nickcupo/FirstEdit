import AppKit
import Foundation
import Testing
import UserNotifications
@testable import PipelineKit

/// What a job's notification says, and where clicking it goes (DESIGN.md §2.7).
@Suite("A job's notification", .serialized)
@MainActor
struct JobNotificationTests {

    static func job(_ kind: String, code: Int?, stopped: Bool = false, log: String = "",
                    title: String = "", background: Bool = false) -> Job {
        Job(running: false, stopped: stopped, id: 7, kind: kind, shoot: "2026-09-19", title: title,
            log: log, fraction: 1, elapsed: 400, code: code, background: background)
    }

    static func capturing() -> (Notifications, () -> [UNNotificationContent]) {
        let n = Notifications()
        n.isAvailable = true
        n.allowed = true
        n.isFrontmost = { false }
        nonisolated(unsafe) var posted: [UNNotificationContent] = []
        n.post = { content, _ in posted.append(content) }
        return (n, { posted })
    }

    /// How a real crash ends: Python prints the traceback and then the
    /// exception's own line, last. A card pulled out halfway through a copy.
    static let cardPulled = """
        $ pipeline/ingest.py /Volumes/EOS_DIGITAL 2026-09-19
        copying 612 of 1,558
        Traceback (most recent call last):
          File "pipeline/ingest.py", line 212, in <module>
            main()
          File "pipeline/ingest.py", line 190, in copy_one
            shutil.copy2(src, dst)
        FileNotFoundError: [Errno 2] No such file or directory: '/Volumes/EOS_DIGITAL/DCIM/100EOS5D/IMG_0613.CR3'
        """

    static let outOfMemory = """
        $ pipeline/cull.py 2026-09-19
        looking at faces: 612 of 1,558 frames
        Traceback (most recent call last):
          File "pipeline/cull.py", line 900, in <module>
            main()
        MemoryError
        """

    @Test("a failure says so, names the work in the app's words and the shoot once")
    func failed() {
        // A card pulled out part way: the copy did not finish, which is
        // neither a crash of the app's nor what he did.
        let crash = Self.job("ingest", code: 1, log: Self.cardPulled, title: "copying the card into 2026-09-19")
        #expect(crash.outcome == .failed)
        let c = Notifications.content(for: crash)
        #expect(c.title == Words.Notify.didNotFinish(Strings.Queue.what("ingest")!))
        #expect(c.title == "Copy the Card did not finish")
        #expect(c.subtitle == "2026-09-19")
        #expect(!c.title.contains("2026-09-19"))
        #expect(!c.title.contains(Words.Notify.finished("")), "a failure is never called finished")
        #expect(c.body == Words.Notify.copyFailedBody)
        #expect(!c.body.contains("FileNotFoundError"), "never the traceback's last line")
    }

    @Test("a crash is never announced as a refusal, whatever its last line says")
    func crashIsNotRefused() {
        let cull = Notifications.content(for: Self.job("cull", code: 1, log: Self.outOfMemory))
        #expect(cull.title == Words.Notify.failed("Cull"))
        #expect(cull.body == Words.Notify.failedBody)
        let killed = Notifications.content(for: Self.job("cull", code: -9,
                                                          log: "$ pipeline/cull.py 2026-09-19\nlooking at faces"))
        #expect(killed.title == Words.Notify.failed("Cull"))
        // The engine's own sentence, said on purpose, is still a refusal and
        // still carries that sentence.
        let said = "No editor found on this Mac: install DxO PhotoLab, then write the presets again."
        let refused = Notifications.content(for: Self.job("presets", code: 1,
                                                          log: "$ pipeline/presets.py 2026-09-19\n\(said)"))
        #expect(refused.title == Words.Notify.refused("Write the Presets"))
        #expect(refused.body == said)
    }

    @Test("a stopped job says stopped")
    func stopped() {
        let c = Notifications.content(for: Self.job("presets", code: nil, stopped: true))
        #expect(c.title == Words.Notify.stopped("Write the Presets"))
        #expect(c.body == Words.Notify.stoppedBody)
    }

    @Test("a finished cull says what it put forward, as §2.7 writes it")
    func culled() {
        let c = Notifications.content(for: Self.job("cull", code: 0, title: "culling 2026-09-19"),
                                      culled: (forward: 150, of: 1558))
        #expect(c.title == "Cull finished")
        #expect(c.subtitle == "2026-09-19")
        #expect(c.body == Words.Notify.culled(150, of: 1558))
    }

    @Test("the cull's numbers are read after it ends, and it is posted once with them")
    func culledIsReadThenPosted() async {
        let (n, posted) = Self.capturing()
        nonisolated(unsafe) var asked: [String] = []
        n.cullCounts = { shoot in asked.append(shoot); return (23, 54) }
        let done = Self.job("cull", code: 0)
        n.jobChanged(done)
        n.jobChanged(done)
        for _ in 0..<8 { await Task.yield() }
        #expect(asked == ["2026-09-19"])
        #expect(posted().count == 1)
        #expect(posted().first?.body == Words.Notify.culled(23, of: 54))
    }

    @Test("clicking it goes where the work leaves him, or where it started when it did not finish")
    func whereItGoes() {
        #expect(Notifications.step(for: Self.job("ingest", code: 0)) == "cull")
        // A copy that did not finish opens the card's page, which says what
        // reached the shoot and why it stopped.
        #expect(Notifications.step(for: Self.job("ingest", code: 1, log: Self.cardPulled)) == Notifications.cardPage)
        #expect(Notifications.step(for: Self.job("cull", code: 0)) == "keepers")
        #expect(Notifications.step(for: Self.job("cull", code: nil, stopped: true)) == "cull")
        #expect(Notifications.step(for: Self.job("presets", code: 0)) == "edit")
        #expect(Notifications.step(for: Self.job("reel", code: 0)) == "reels")
        #expect(Notifications.step(for: Self.job("stor-push", code: 0)) == "done")
        #expect(Notifications.step(for: Self.job("plan-drop", code: 2, log: "nothing was pushed.")) == "done")
        #expect(Notifications.step(for: Self.job("someone-elses", code: 0)) == "",
                "work the app has no step for opens the shoot itself")
    }

    @Test("a failure opens the Activity window as well, where its reason is")
    func failureOpensActivity() {
        let (n, posted) = Self.capturing()
        n.jobChanged(Self.job("cull", code: 1, log: Self.outOfMemory))
        #expect(posted().first?.userInfo["activity"] as? Bool == true)
        #expect(posted().first?.userInfo["step"] as? String == "cull")
        let (m, fine) = Self.capturing()
        m.jobChanged(Self.job("presets", code: 0))
        #expect(fine().first?.userInfo["activity"] as? Bool == false)
        #expect(fine().first?.userInfo["step"] as? String == "edit")
    }

    @Test("no banner for PhotoLab opening in front of him, nor for the machine's own homework")
    func notAnnounced() {
        let (n, posted) = Self.capturing()
        n.jobChanged(Self.job("spread", code: 0, title: "preparing burst 93 for PhotoLab"))
        n.jobChanged(Self.job("learn-learn", code: 0, background: true))
        #expect(posted().isEmpty)
    }

    @Test("an extension's work, which the app has no word for, is named by the engine's title")
    func unknownKind() {
        let c = Notifications.content(for: Self.job("someone-elses", code: 0, title: "making copies"))
        #expect(c.title == Words.Notify.finished("Making copies"))
    }

    @Test("VoiceOver hears how it ended, and a second shoot's cull is its own start")
    func spoken() {
        let a = Announcer()
        nonisolated(unsafe) var said: [String] = []
        a.speak = { said.append($0) }
        a.jobChanged(Job(running: true, stopped: false, id: 1, kind: "cull", shoot: "a"))
        a.jobChanged(Job(running: false, stopped: false, id: 1, kind: "cull", shoot: "a", log: Self.outOfMemory, code: 1))
        a.jobChanged(Job(running: true, stopped: false, id: 2, kind: "cull", shoot: "b"))
        #expect(said == [Words.Spoken.jobStarted("Cull"), Words.Notify.failed("Cull"),
                         Words.Spoken.jobStarted("Cull")])
    }

    @Test("a title is in title case, and a storage plan is named for what it checks")
    func titleCase() {
        #expect(JobWords.titled(Self.job("presets", code: 0)) == "Write the Presets")
        #expect(JobWords.titled(Self.job("gather", code: 0)) == "Build the PhotoLab Folder")
        #expect(JobWords.titled(Self.job("stor-push", code: 0)) == "Copy the RAWs to iCloud")
        #expect(JobWords.titled(Self.job("stor-pull", code: 0)) == "Bring the RAWs Back")
        #expect(JobWords.titled(Self.job("plan-push", code: 0)) == "Check What Would Be Copied")
        #expect(JobWords.titled(Self.job("plan-reclaim", code: 0)) == "Check What Cache Would Be Taken Back")
        // The row the notification opens names the plan the same way.
        #expect(Strings.Queue.what("plan-drop") == "Check what would be removed")
        #expect(Set(["plan-push", "plan-pull", "plan-drop", "plan-expire", "plan-reclaim"]
            .compactMap(Strings.Queue.what)).count == 5, "each plan its own words")
        #expect(JobWords.titled(Self.job("someone-elses", code: 0, title: "making copies")) == "Making copies")
        // The list keeps its own sentence case.
        #expect(JobWords.what(Self.job("presets", code: 0)) == "Write the presets")
    }

    @Test("the Dock menu names the work and the shoot once")
    func dock() {
        // No space before the sign: US English writes 38%.
        #expect(Words.Dock.running("Cull", shoot: "2026-09-19", percent: 38) == "Cull · 2026-09-19 — 38%")
        #expect(Words.Dock.running("Cull", shoot: "", percent: 38) == "Cull — 38%")
    }
}
