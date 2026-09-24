import SwiftUI

/// §2.11 — ⌘, Five tabs, each a grouped form.
///
/// Changing the library folder needs the engine restarted, because
/// `PHOTOS_ROOT` is read from the child's environment when it starts. That
/// goes through `EngineRestart`, which asks only when a job of his would be
/// stopped.
public struct SettingsView: View {
    let settings: SettingsStore
    /// What Settings can reach into the app for. Injected, so a snapshot and
    /// a test settle nothing on the real app.
    public struct Hooks: Sendable {
        public var openLearning: (@Sendable @MainActor () -> Void)?
        public var showLog: (@Sendable @MainActor () -> Void)?
        public var showSupportFolder: (@Sendable @MainActor () -> Void)?
        /// Where the running engine loaded its extension from; `nil` when it
        /// loaded none. The engine's answer, not the Settings value.
        public var extensionFolder: URL?
        public var showFirstRunAgain: (@Sendable @MainActor () -> Void)?
        /// What the first launch under this name has to say about the support
        /// folder (`FirstLaunch.note`): renaming the old one failed, or there
        /// are two. `nil` when it went as planned.
        public var supportNote: String?

        public init(openLearning: (@Sendable @MainActor () -> Void)? = nil,
                    showLog: (@Sendable @MainActor () -> Void)? = nil,
                    showSupportFolder: (@Sendable @MainActor () -> Void)? = nil,
                    extensionFolder: URL? = nil,
                    showFirstRunAgain: (@Sendable @MainActor () -> Void)? = nil,
                    supportNote: String? = nil) {
            self.openLearning = openLearning
            self.showLog = showLog
            self.showSupportFolder = showSupportFolder
            self.extensionFolder = extensionFolder
            self.showFirstRunAgain = showFirstRunAgain
            self.supportNote = supportNote
        }
    }

    let hooks: Hooks
    let picture: PictureModel
    let restarter: EngineRestart
    /// The rows whose value is the engine's (`EngineSettings`).
    let engine: EngineSettings
    @State private var tab: Tab

    public enum Tab: String, CaseIterable, Sendable, Hashable {
        case general, choosing, storage, learning, advanced

        var title: String {
            switch self {
            case .general: return Strings.Settings.general
            case .choosing: return Strings.Settings.choosing
            case .storage: return Strings.Settings.storage
            case .learning: return Strings.Settings.learning
            case .advanced: return Strings.Settings.advanced
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .choosing: return Symbols.stepKeepers
            case .storage: return Symbols.storage
            case .learning: return Symbols.learned
            case .advanced: return "wrench.and.screwdriver"
            }
        }
    }

    public init(settings: SettingsStore = .shared, hooks: Hooks = Hooks(), tab: Tab = .general,
                picture: PictureModel = .shared, restarter: EngineRestart = .shared,
                engine: EngineSettings = .shared) {
        self.settings = settings
        self.hooks = hooks
        self.picture = picture
        self.restarter = restarter
        self.engine = engine
        _tab = State(initialValue: tab)
    }

    public var body: some View {
        TabView(selection: $tab) {
            GeneralTab(settings: settings, hooks: hooks, restarter: restarter)
                .tabItem { Label(Tab.general.title, systemImage: Tab.general.symbol) }
                .tag(Tab.general)
            ChoosingTab(settings: settings)
                .tabItem { Label(Tab.choosing.title, systemImage: Tab.choosing.symbol) }
                .tag(Tab.choosing)
            StorageTab(settings: settings, engine: engine)
                .tabItem { Label(Tab.storage.title, systemImage: Tab.storage.symbol) }
                .tag(Tab.storage)
            LearningTab(settings: settings, hooks: hooks, engine: engine)
                .tabItem { Label(Tab.learning.title, systemImage: Tab.learning.symbol) }
                .tag(Tab.learning)
            AdvancedTab(settings: settings, hooks: hooks, picture: picture)
                .tabItem { Label(Tab.advanced.title, systemImage: Tab.advanced.symbol) }
                .tag(Tab.advanced)
        }
        .frame(width: 520)
        .accessibilityIdentifier("settings.\(tab.rawValue)")
    }
}
