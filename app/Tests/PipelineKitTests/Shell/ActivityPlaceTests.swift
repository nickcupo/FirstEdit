import Foundation
import Testing
@testable import PipelineKit

/// A row of the Activity history is a way back to where its work is done.
@Suite("An Activity row goes to the page its work is done on")
@MainActor
struct ActivityPlaceTests {

    private func row(_ kind: String, shoot: String = "2026-09-19", background: Bool = false) -> ActivityRow {
        let j = Job(running: false, stopped: false, kind: kind, shoot: shoot, title: kind, code: 1,
                    background: background)
        return ActivityRow(JobModel.Record(id: UUID(), job: j, started: Date(), elapsed: 3, outcome: .failed))
    }

    @Test("the step whose button starts it")
    func steps() {
        #expect(row("ingest").place == .step(shoot: "2026-09-19", step: "ingest"))
        #expect(row("cull").place == .step(shoot: "2026-09-19", step: "cull"))
        #expect(row("presets").place == .step(shoot: "2026-09-19", step: "presets"))
        #expect(row("reel").place == .step(shoot: "2026-09-19", step: "reels"))
    }

    @Test("storage work goes to Finish, where its panel is; other work to the shoot's page")
    func elsewhere() {
        #expect(row("stor-push").place == .step(shoot: "2026-09-19", step: "done"))
        #expect(row("plan-drop").place == .step(shoot: "2026-09-19", step: "done"))
        #expect(row("gather").place == .shoot("2026-09-19"))
    }

    @Test("the machine's own homework goes to the learning page, and work with no shoot nowhere")
    func learningAndNothing() {
        #expect(row("learn", shoot: "", background: true).place == .learned)
        #expect(row("cull", shoot: "").place == nil)
        #expect(ActivityWindow.showTitle(.learned) == Strings.Job.showWhatItHasLearned)
        #expect(ActivityWindow.showTitle(.step(shoot: "x", step: "cull")) == Strings.Job.showTheStep)
        #expect(ActivityWindow.showTitle(.shoot("x")) == Strings.Job.showTheShoot)
    }
}
