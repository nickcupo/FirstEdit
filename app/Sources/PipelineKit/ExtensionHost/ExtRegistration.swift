import SwiftUI

/// How an added step becomes a page of this app.
///
/// **With no extension installed, nothing here runs.** `register(nil)`
/// registers nothing, `steps(nil)` is empty and no view in the app reaches for
/// an `ExtConfig` that is not there. That is what a person who clones the
/// public repository gets, and it is the whole app.
@MainActor
public enum ExtensionHostRegistration {

    /// Which step ids currently have a page registered, in the order the
    /// extension declared them.
    public private(set) static var registered: [String] = []

    /// Registers one page view per step the extension declares, against the
    /// engine it is talking to. Called again whenever either changes; the
    /// steps that went away are left behind rather than kept.
    @discardableResult
    public static func register(_ config: ExtConfig?, endpoint: EngineHost.Endpoint?) -> [String] {
        guard let config, let endpoint else {
            registered = []
            return []
        }
        let ids = ExtPages.steps(config)
        for id in ids {
            StepRegistry.register(id) { session in
                AnyView(ExtStepView(session: session, step: id, config: config, endpoint: endpoint))
            }
        }
        registered = ids
        return ids
    }

    /// Keeps the registration in step with the library and the engine. The
    /// integration crew calls this once; nothing else has to know.
    public static func follow(_ app: AppModel) {
        register(app.library.ext, endpoint: app.engineState.endpoint)
    }
}
