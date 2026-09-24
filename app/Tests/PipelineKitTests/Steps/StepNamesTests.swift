import Testing
@testable import PipelineKit

/// One name per step. The engine's were "Copy the card", "Choose keepers" and
/// "Done", and the app's own are "Copy the Card", "Choose Keepers" and
/// "Finish": a shoot's sidebar rows re-lettered the moment it loaded, and the
/// last step was Done in the Go menu and Finish in the Keyboard Shortcuts
/// window.
@Suite("What the steps are called")
struct StepNamesTests {
    @Test("the engine's names for the eight steps are the app's own")
    @MainActor func sameNames() throws {
        let r = try Fixture.decode(ShootResponse.self, "shoot-bursts")
        let engine = Dictionary(uniqueKeysWithValues: r.steps.map { ($0.id, $0.label) })
        for id in Fallbacks.baseStepIDs {
            // A capture from an engine before the Instagram step was built in
            // has no row for it; one from after names it as the app does.
            if id == "instagram", engine[id] == nil { continue }
            #expect(engine[id] == Fallbacks.baseLabel(id), "\(id)")
        }
    }
}
