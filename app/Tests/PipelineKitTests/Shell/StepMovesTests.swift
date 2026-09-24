import Testing
@testable import PipelineKit

/// ⌘[ from a shoot's own page went forward to Copy the Card, and ⌘] on the
/// last step was an enabled item that did nothing. The page now comes before
/// the first step, and both ends grey.
@Suite("⌘[ and ⌘] walk the shoot's page and its steps, and stop at the ends")
@MainActor
struct StepMovesTests {

    @Test("the page, then the steps, in order")
    func walk() {
        let steps = Fallbacks.listSteps(canCutReels: true, ext: nil)
        let nav = Navigation(selection: .shoot("s"))
        #expect(!nav.canMoveStep(by: -1, in: steps), "nothing before the page")
        nav.moveStep(by: -1, in: steps)
        #expect(nav.selection == .shoot("s"))
        nav.moveStep(by: 1, in: steps)
        #expect(nav.selection == .step(shoot: "s", step: "ingest"))
        nav.moveStep(by: -1, in: steps)
        #expect(nav.selection == .shoot("s"), "⌘[ from the first step is the shoot's page")
        nav.selection = .step(shoot: "s", step: "done")
        #expect(!nav.canMoveStep(by: 1, in: steps), "nothing after Finish")
        #expect(nav.canMoveStep(by: -1, in: steps))
        nav.selection = .allShoots
        #expect(!nav.canMoveStep(by: 1, in: steps))
    }
}
