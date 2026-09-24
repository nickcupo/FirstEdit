import Foundation
import Testing
@testable import PipelineKit

/// One name for a piece of work wherever it is named, and the one line he
/// opened the Activity window to read above the rest of the log.
@Suite("The Activity window names work once and leads with its sentence")
@MainActor
struct ActivityNamesTests {

    @Test("his word for the kind of work, the engine's title only where he has none")
    func names() {
        let cull = Job(running: false, stopped: false, kind: "cull", shoot: "2026-09-13-dog",
                       title: "culling 2026-09-13-dog")
        #expect(cull.what == Strings.Queue.what("cull"))
        #expect(cull.shootAfterWhat == "2026-09-13-dog")
        // No word of the app's: the engine's title, first letter up, and the
        // shoot not said twice when the title already says it.
        let learn = Job(running: true, stopped: false, kind: "learn", shoot: "2026-09-21",
                        title: "learning from 2026-09-21")
        #expect(learn.what == "Learning from 2026-09-21")
        #expect(learn.shootAfterWhat == nil)
    }

    @Test("a row made from the history uses the same name")
    func rowName() {
        let j = Job(running: false, stopped: true, kind: "presets", shoot: "2026-09-19", title: "writing the presets")
        let r = ActivityRow(JobModel.Record(id: UUID(), job: j, started: Date(), elapsed: 12, outcome: .stopped))
        #expect(r.what == Strings.Queue.what("presets"))
        #expect(r.shootAfterWhat == "2026-09-19")
    }

    @Test("the command line is held back for Details, and the sentence leads a job that did not simply finish")
    func log() {
        let log = "$ pipeline/archive.py drop /photos/shoots/x\n  x has never been copied to iCloud.\n"
        let refused = ActivityRow(id: UUID(), what: "Check what would be removed", shoot: "x", started: Date(),
                                  elapsed: 2, outcome: .refused, log: log)
        #expect(refused.headline == "x has never been copied to iCloud.")
        #expect(refused.readableLog == "x has never been copied to iCloud.")
        #expect(refused.commands == "$ pipeline/archive.py drop /photos/shoots/x")
        // The sentence is the whole log: said once, above the line.
        #expect(refused.logUnderHeadline.isEmpty)
        let done = ActivityRow(id: UUID(), what: "Cull", shoot: "x", started: Date(),
                               elapsed: 2, outcome: .done, log: "$ cull\n  put forward 23 of 54.")
        #expect(done.headline == nil)
        #expect(done.logUnderHeadline == "put forward 23 of 54.")
        // More than the sentence: all of it stays under the line.
        let failed = ActivityRow(id: UUID(), what: "Cull", shoot: "x", started: Date(), elapsed: 2,
                                 outcome: .failed, log: "$ cull\n  reading 54 frames\n  out of memory")
        #expect(failed.headline == "out of memory")
        #expect(failed.logUnderHeadline == "reading 54 frames\nout of memory")
    }

    @Test("the Dock menu names the running work the same way")
    func dock() {
        let center = CommandCenter()
        center.job = Job(running: true, stopped: false, kind: "cull", shoot: "2026-09-19",
                         title: "culling 2026-09-19", fraction: 0.38)
        let menu = DockProgress.dockMenu(center: center)
        #expect(menu?.items.first?.title == Words.Dock.running(Strings.Queue.what("cull")!, shoot: "2026-09-19", percent: 38))
        #expect(menu?.items.first?.title.contains("culling") == false)
    }
}
