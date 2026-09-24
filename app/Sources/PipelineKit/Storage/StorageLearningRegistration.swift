import SwiftUI

/// Where this crew hands the shell its pages, by id.
///
/// Called once at launch by the app delegate, alongside every other crew's.
/// Nothing in the shell names one of these views, and nothing here names a
/// view another crew owns.
@MainActor
public enum StorageLearningRegistration {

    /// The two library-wide pages the sidebar already has rows for, and the
    /// storage panel for a shoot.
    ///
    /// The panel belongs on Finish (§2.8), and Finish belongs to the workflow
    /// steps crew. Until that step is registered this registers the panel in
    /// its place, so the storage screen is reachable in the app as it stands;
    /// once the steps crew registers `done`, whichever registration runs last
    /// wins, and theirs embeds `StoragePanel` itself.
    public static func register() {
        StepRegistry.registerLibrary("learned") { app in
            AnyView(LearnedView(app: app))
        }
        StepRegistry.registerLibrary("storage") { app in
            AnyView(LibraryStorage(app: app))
        }
        if !StepRegistry.isRegistered("done") {
            StepRegistry.register("done") { session in
                AnyView(FinishStandIn(session: session))
            }
        }
    }
}

/// The Finish step with only the part of it this crew owns on it. The steps
/// crew's own page replaces this whole view; the panel inside it is the same
/// object either way.
struct FinishStandIn: View {
    let session: ShootSession

    var body: some View {
        ScrollView {
            StoragePanel(shoot: session.name, client: session.client)
                .padding(.vertical, Tokens.Metric.groupGap)
        }
        .navigationTitle(session.name)
        .navigationSubtitle(Strings.Steps.done)
    }
}
