import Foundation
import Testing
@testable import PipelineKit

/// How a job's ending is put to him when he is not looking: a copy the card
/// was pulled out of is not "finished", and a Python exception is not a
/// sentence.
@Suite("How a job's ending is said")
@MainActor
struct JobEndingWordsTests {

    static let pulled = """
        $ /checkout/.venv/bin/python /checkout/pipeline/ingest.py /Volumes/Untitled 2026-09-23-night --verify in-flight
        copying 1558 files, 40.2 GB, /Volumes/Untitled/DCIM -> /scratch/photos/shoots/2026-09-23-night/raw
        @@ copy 410 1558
        Traceback (most recent call last):
          File "/checkout/pipeline/ingest.py", line 210, in main
        FileNotFoundError: [Errno 2] No such file or directory: '/Volumes/Untitled/DCIM/100MSDCF/DSC0124.ARW'
        """

    static func ingest(code: Int?, stopped: Bool = false, log: String = "") -> Job {
        Job(running: false, stopped: stopped, id: 9, kind: "ingest", shoot: "2026-09-23-night",
            title: "copying the card into 2026-09-23-night", log: log, code: code)
    }

    @Test("an exception's own line is part of the traceback, not the engine's sentence")
    func exceptionIsNotASentence() {
        let j = Self.ingest(code: 1, log: Self.pulled)
        #expect(j.refusalSentence == nil)
        #expect(j.outcome == .failed)
        for line in ["OSError: [Errno 28] No space left on device", "KeyboardInterrupt",
                     "subprocess.CalledProcessError: Command '…' returned non-zero exit status 1."] {
            #expect(Self.ingest(code: 1, log: "$ x\n" + line).refusalSentence == nil, "\(line)")
        }
        let room = "not enough room on Macintosh HD for the copy of 1558 files"
        #expect(Self.ingest(code: 1, log: "$ x\n\n" + room).refusalSentence == room)
    }

    @Test("the title says how it ended, in the app's word for the work, and names the shoot once")
    func titles() {
        let done = Notifications.content(for: Self.ingest(code: 0))
        #expect(done.title == "Copy the Card finished")
        #expect(done.subtitle == "2026-09-23-night")
        #expect(done.body == Strings.Import.canComeOut)

        let failed = Notifications.content(for: Self.ingest(code: 1, log: Self.pulled))
        #expect(failed.title == "Copy the Card did not finish")
        #expect(failed.body == Words.Notify.copyFailedBody)
        #expect(!failed.body.contains("Error"))

        let stopped = Notifications.content(for: Self.ingest(code: nil, stopped: true))
        #expect(stopped.title == "Copy the Card stopped")

        // A check that failed is the engine ending the copy with a sentence:
        // it did not finish, and "stopped" is kept for what he did.
        let check = "The card was not written to; copy it again."
        let refused = Notifications.content(for: Self.ingest(code: 1, log: "$ ingest.py\n" + check))
        #expect(refused.title == "Copy the Card did not finish")
        #expect(refused.body == check)
        // Any other plan that refuses on purpose did not run, and is no failure.
        let plan = Notifications.content(for: Job(running: false, stopped: false, kind: "cull", shoot: "2026-09-19",
                                                  title: "", log: "$ x\nnothing to cull", code: 2))
        #expect(plan.title == "Cull did not run")

        // The shoot is said once, under the title.
        let cull = Notifications.content(for: Job(running: false, stopped: false, kind: "cull",
                                                  shoot: "2026-09-19", title: "", code: 0))
        #expect(cull.title == "Cull finished")
        #expect(cull.subtitle == "2026-09-19")
    }

    @Test("clicking a copy's notification opens the new shoot's Cull, not a Choose Keepers with nothing culled")
    func copyOpensCull() {
        #expect(Notifications.step(for: Self.ingest(code: 0)) == "cull")
        // One that did not finish opens the card's page, never Cull of a half shoot.
        #expect(Notifications.step(for: Self.ingest(code: 1, log: Self.pulled)) == Notifications.cardPage)
        #expect(Notifications.step(for: Self.ingest(code: nil, stopped: true)) == Notifications.cardPage)
        let cull = Job(running: false, stopped: false, kind: "cull", shoot: "2026-09-19", title: "", code: 0)
        #expect(Notifications.step(for: cull) == "keepers")
    }
}
