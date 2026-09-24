import Testing
import Foundation
@testable import PipelineKit

// He stacks four things and goes to bed; the cull fails. The banner said "4
// finished" and the window said "4 finished", and nothing he could see
// without opening a log said one of them had not. What a pass came to is
// counted by outcome now, and each piece carries the history's own word.

@Suite("What a finished list came to")
@MainActor
struct QueueOutcomeTests {

    static let pass = QueueState(
        listed: 5, fraction: 1, pass: 4,
        done: [QueueDone(id: 1, kind: "ingest", shoot: "2026-09-19"),
               QueueDone(id: 2, kind: "cull", shoot: "2026-09-19", outcome: "failed"),
               QueueDone(id: 3, kind: "presets", shoot: "2026-09-13-dog"),
               QueueDone(id: 4, kind: "gather", shoot: "2026-09-13-dog", outcome: "stopped")],
        skipped: [QueueSkipped(id: 5, kind: "stor-push", shoot: "2026-09-19",
                               whyNot: "2026-09-19 has not been culled yet")])

    @Test("each piece is counted by how it ended")
    func tallied() {
        let t = Self.pass.tally
        #expect(t == QueueState.Tally(done: 2, failed: 1, stopped: 1, skipped: 1))
        #expect(t.wentWrong)
        // Worst first, and only the failures are the alarm's.
        #expect(Strings.Queue.summary(t) == "1 failed, 1 skipped, 1 stopped, 2 done")
        #expect(Strings.Queue.summaryParts(t).map(\.failed) == [true, false, false, false])
        #expect(!Strings.Queue.summary(t).contains("finished"))
        #expect(Strings.Queue.summary(.init(done: 4)) == "4 done")
        #expect(Strings.Queue.summary(.init()) == "0 done")
        #expect(Strings.Queue.summary(.init(failed: 1)) == "1 failed")
        #expect(!QueueState.Tally(done: 3, stopped: 1).wentWrong)
    }

    @Test("a list job that said no on purpose is counted as refused, not failed")
    func refusedIsNotFailed() {
        // The engine wrote every non-zero exit down as "failed": a check
        // that found no manifest was "1 failed" in red, beside a history
        // row that said Refused.
        let pass = QueueState(done: [QueueDone(id: 5, kind: "stor-check", shoot: "2026-09-13-dog", outcome: "refused"),
                                     QueueDone(id: 6, kind: "cull", shoot: "2026-09-19")])
        #expect(pass.done[0].ended == .refused)
        #expect(pass.tally == QueueState.Tally(done: 1, refused: 1))
        #expect(Strings.Queue.summary(pass.tally) == "1 refused, 1 done")
        #expect(Strings.Queue.summaryParts(pass.tally).allSatisfy { !$0.failed })
        // Its reason is only in the window, so the banner opens it.
        #expect(pass.tally.wentWrong)
        #expect(pass.doneWorstFirst.map(\.id) == [5, 6])
        let c = Notifications.content(for: pass)
        #expect(c.body.split(separator: "\n").first.map(String.init)
                == Strings.Queue.refusedLine("Check every original · 2026-09-13-dog"))
    }

    @Test("the engine's words become the history's outcomes")
    func outcomes() {
        #expect(QueueDone(id: 1, kind: "cull", outcome: "done").ended == .done)
        #expect(QueueDone(id: 1, kind: "cull", outcome: "failed").ended == .failed)
        #expect(QueueDone(id: 1, kind: "cull", outcome: "stopped").ended == .stopped)
        #expect(QueueDone(id: 1, kind: "cull", outcome: "refused").ended == .refused)
        #expect(QueueDone(id: 1, kind: "cull", outcome: "").ended == .done)
    }

    @Test("what went wrong is listed first, and otherwise in the order it ran")
    func worstFirst() {
        #expect(Self.pass.doneWorstFirst.map(\.id) == [2, 4, 1, 3])
    }

    @Test("the banner says what failed, first, and opens the window that says why")
    func theBanner() {
        let c = Notifications.content(for: Self.pass)
        #expect(c.title == "1 failed, 1 skipped, 1 stopped, 2 done")
        let lines = c.body.split(separator: "\n").map(String.init)
        #expect(lines.first == Strings.Queue.failedLine("Cull · 2026-09-19"))
        #expect(lines.contains(Strings.Queue.skippedLine("Copy the RAWs to iCloud · 2026-09-19")))
        #expect(lines.contains(Strings.Queue.stoppedLine("\(Strings.Queue.what("gather")!) · 2026-09-13-dog")))
        #expect(lines.contains("Copy the Card · 2026-09-19"))
        // The skipped reason lives in the window, not in a truncated banner.
        #expect(!c.body.contains("has not been culled"))
    }

    @Test("a job's own banner says how it ended, not that it finished")
    func aJobsBanner() throws {
        let crashed = Job(running: false, stopped: false, id: 9, kind: "cull", shoot: "2026-09-19",
                          title: "culling 2026-09-19", log: "$ x\nMemoryError", code: 1)
        let c = Notifications.content(for: crashed)
        #expect(c.title == Words.Notify.failed("Cull"))
        #expect(c.subtitle == "2026-09-19")
        #expect(!c.title.contains("finished"))
        // The app's word, not the engine's title with the shoot in it twice.
        #expect(!c.title.contains("culling"))
        let done = Job(running: false, stopped: false, id: 9, kind: "cull", shoot: "2026-09-19",
                       title: "culling 2026-09-19", code: 0)
        #expect(Notifications.content(for: done).title == Words.Notify.finished("Cull"))
        let stopped = Job(running: false, stopped: true, id: 9, kind: "cull", shoot: "2026-09-19")
        #expect(Notifications.content(for: stopped).title == Words.Notify.stopped("Cull"))
    }
}

// The list went by four names - "the List", "Up Next", "Activity", "the
// Activity item" - and some of its rows contradicted the buttons that put
// them there. One name now, and each row says what its button promised.
@Suite("The list has one name")
struct QueueOneNameTests {

    @Test("every control that fills the list, and what it says after, names Up Next")
    func oneName() {
        let lines = [Strings.Queue.addInstead, Strings.Queue.addInsteadSpoken("Cull It"),
                     Strings.Queue.addedHelp, Strings.Queue.added("Cull"), Strings.Queue.remove,
                     Strings.Queue.clearQuestion(6), Strings.Queue.waitingSpoken(3),
                     Strings.Job.waitItsTurn]
        for line in lines {
            #expect(line.contains(Strings.Queue.title), "\(line)")
            #expect(!line.lowercased().contains("the list"), "\(line)")
            #expect(!line.contains("Activity item"), "\(line)")
        }
        // The picture model's download is a job, not work waiting its turn:
        // the first run says the toolbar shows it, and names no list at all.
        #expect(!Strings.FirstRun.downloading.lowercased().contains("the list"))
        #expect(!Strings.FirstRun.downloading.contains("Activity item"))
        // ⌥ on a step and the busy notice's choice are the same act.
        #expect(Strings.Job.waitItsTurn == Strings.Queue.addInstead)
        #expect(!Words.Shoot.stopJob.lowercased().contains("job"))
    }

    @Test("beside a button that adds, a line says what it waits for")
    func whyItAdds() {
        // "Add It to the List" under "About a minute." left him to work out
        // that something else was running and what "it" was.
        func job(_ kind: String, _ shoot: String, _ title: String) -> Job {
            Job(running: true, stopped: false, kind: kind, shoot: shoot, title: title)
        }
        let busy = Strings.Queue.whyItAdds(running: job("presets", "2026-09-13-dog", "presets for 2026-09-13-dog"),
                                           held: false)
        #expect(busy == "Happening now: Write the presets · 2026\u{2011}09\u{2011}13\u{2011}dog. This goes after it in Up Next.")
        // The list's word for the work, never the engine's title: that
        // brought back "gathering", which the list had retired.
        let gather = Strings.Queue.whyItAdds(running: job("gather", "2026-09-19", "gathering the keepers of 2026-09-19"),
                                             held: false)
        #expect(gather?.contains(Strings.Queue.what("gather")!) == true)
        #expect(gather?.lowercased().contains("gathering") == false)
        // Work the app has no word for keeps the engine's title.
        #expect(Strings.Queue.whyItAdds(running: job("update", "", "downloading version 0.2.0"), held: false)
                == "Happening now: Downloading version 0.2.0. This goes after it in Up Next.")
        #expect(Strings.Queue.whyItAdds(running: job("", "", ""), held: false)?.contains(Strings.Queue.title) == true)
        #expect(Strings.Queue.whyItAdds(running: nil, held: true)?.contains(Strings.Queue.title) == true)
        // Nothing in the way and nothing held: the button is the step's own
        // verb, and there is nothing to explain.
        #expect(Strings.Queue.whyItAdds(running: nil, held: false) == nil)
    }

    @Test("a row says what its button promised, in the app's own words")
    func rowsMatchTheirButtons() {
        #expect(Strings.Queue.what("gather")?.contains("PhotoLab") == true)
        #expect(Strings.Queue.what("spread")?.lowercased().contains("preset") == true)
        #expect(Strings.Queue.what("spread")?.lowercased().contains("spread") == false)
        #expect(Strings.Queue.cannotRun != "This will be skipped")
    }
}
