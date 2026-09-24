import SwiftUI

/// §2.11 Learning — two switches and one way in.
///
/// Both switches go to the engine, which decides when learning runs: at the
/// engine's start in its environment, and to the running engine the moment
/// either changes. They were written to the defaults and read by nothing.
struct LearningTab: View {
    let settings: SettingsStore
    let hooks: SettingsView.Hooks
    let engine: EngineSettings

    @State private var automatically: Bool
    @State private var onlyWhenIdle: Bool

    init(settings: SettingsStore, hooks: SettingsView.Hooks, engine: EngineSettings = .shared) {
        self.settings = settings
        self.hooks = hooks
        self.engine = engine
        _automatically = State(initialValue: settings.learnAutomatically)
        _onlyWhenIdle = State(initialValue: settings.learnOnlyWhenIdle)
    }

    var body: some View {
        Form {
            Section {
                Toggle(Strings.Settings.learnAutomatically, isOn: $automatically)
                    .onChange(of: automatically) { _, v in
                        settings.learnAutomatically = v
                        send()
                    }
                    .accessibilityIdentifier("settings.learnAutomatically")
                Toggle(Strings.Settings.learnOnlyWhenIdle, isOn: $onlyWhenIdle)
                    .disabled(!automatically)
                    .onChange(of: onlyWhenIdle) { _, v in
                        settings.learnOnlyWhenIdle = v
                        send()
                    }
                Text(Strings.Settings.learningIsChecked)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Button(Strings.Settings.openLearning) { hooks.openLearning?() }
                    .disabled(hooks.openLearning == nil)
                    .accessibilityIdentifier("settings.openLearning")
            }
        }
        .formStyle(.grouped)
    }

    private func send() {
        let (a, i) = (automatically, onlyWhenIdle)
        Task { await engine.sendLearning(automatically: a, onlyWhenIdle: i) }
    }
}
