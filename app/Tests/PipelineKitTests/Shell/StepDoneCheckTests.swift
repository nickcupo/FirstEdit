import Foundation
import Testing
@testable import PipelineKit

/// "The design's reason for putting the steps in the sidebar was to answer
/// 'where am I and what is left'. Every step row looks the same whether it is
/// done or not." A done step has a check; Choose Keepers counts until it is
/// done (DESIGN.md §2.1).
@Suite("The sidebar says which steps are done")
@MainActor
struct StepDoneCheckTests {

    static func row(doneThrough last: String?) throws -> ShootRowOK {
        let r = try LastPlaceTests.shoots { rows in rows[1]["steps"] = UpToTests.steps(doneThrough: last) }
        return try #require(r.ok.first { $0.name == "2026-09-21" })
    }

    @Test("Choose Keepers counts the bursts until it is done, and then has its check instead")
    func keepersCountThenCheck() throws {
        let row = try Self.row(doneThrough: "cull")
        let open = StepState(id: "keepers", label: "Choose Keepers", done: false, enabled: true)
        let counting = StepSidebarRow(step: open, row: row, bursts: (140, 288))
        #expect(counting.count == "140/288 bursts")
        #expect(counting.spoken == Strings.Overview.burstsOf(140, 288))

        let finished = StepState(id: "keepers", label: "Choose Keepers", done: true, enabled: true)
        let checked = StepSidebarRow(step: finished, row: row, bursts: (288, 288))
        #expect(checked.count == nil, "the check takes the count's place")
        #expect(checked.spoken == "\(Strings.Library.stepDone), \(Strings.Overview.burstsOf(288, 288))")
    }

    @Test("any other step is said to be done in its help and to VoiceOver, and says nothing when it is not")
    func otherSteps() throws {
        let row = try Self.row(doneThrough: "presets")
        let done = StepSidebarRow(step: StepState(id: "presets", label: "Presets", done: true, enabled: true), row: row)
        #expect(done.spoken == Strings.Library.stepDone && done.count == nil)
        let open = StepSidebarRow(step: StepState(id: "edit", label: "Edit in PhotoLab", done: false, enabled: true), row: row)
        #expect(open.spoken.isEmpty && open.count == nil)
    }

    @Test("done is as the library's row last said, which is read again at every N and every job's end")
    func doneFromTheRow() throws {
        let row = try Self.row(doneThrough: "keepers")
        // The session's list, read when the shoot was opened, before the
        // last burst's N.
        let opened = Fallbacks.baseStepIDs.map {
            StepState(id: $0, label: Fallbacks.baseLabel($0), done: ["ingest", "cull"].contains($0), enabled: true)
        }
        let shown = SidebarView.steps(opened, doneAsOf: row)
        #expect(shown.filter(\.done).map(\.id) == ["ingest", "cull", "keepers"])
        #expect(shown.map(\.label) == opened.map(\.label), "only whether each is done changes")

        // An engine that sent no steps on the row leaves the list as it was.
        let silent = try #require(try LastPlaceTests.shoots().ok.first { $0.name == "2026-09-21" })
        #expect(SidebarView.steps(opened, doneAsOf: silent).map(\.done) == opened.map(\.done))
    }
}
