import SwiftUI

/// Where the seven workflow steps are handed to the shell.
///
/// One call, at launch, from the app delegate. Nothing in the shell names a
/// step of this crew's, and nothing here names a step of anyone else's.
@MainActor
public enum WorkflowSteps {
    public static func register() {
        StepRegistry.register("ingest", ImportReport.self)
        StepRegistry.register("cull", CullStep.self)
        StepRegistry.register("presets", PresetsStep.self)
        StepRegistry.register("edit", EditStep.self)
        StepRegistry.register("instagram", InstagramStep.self)
        StepRegistry.register("reels", ReelsStep.self)
        StepRegistry.register("done", FinishStep.self)
        StepRegistry.registerLibrary("card") { app in AnyView(ImportStep(app: app)) }
    }

    /// The seven ids this crew answers for, for the test that says the shell
    /// can reach every one of them.
    public static let ids = ["ingest", "cull", "presets", "edit", "instagram", "reels", "done"]
}
