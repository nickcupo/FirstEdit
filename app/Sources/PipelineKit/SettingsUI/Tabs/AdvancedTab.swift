import SwiftUI

/// §2.11 Advanced — the log, the support folder (and, when the first launch
/// under this name could not bring the old one across as planned, the one
/// line that says where it is), whether an extension is installed, and the
/// web inspector switch (off, NAT-17).
///
/// The extension row states a fact and nothing else. It never names anything
/// the extension contributes: this repository is public and that vocabulary
/// belongs to one that is not.
struct AdvancedTab: View {
    let settings: SettingsStore
    let hooks: SettingsView.Hooks
    let picture: PictureModel

    @State private var webInspector: Bool

    init(settings: SettingsStore, hooks: SettingsView.Hooks, picture: PictureModel = .shared) {
        self.settings = settings
        self.hooks = hooks
        self.picture = picture
        _webInspector = State(initialValue: settings.webInspector)
    }

    var body: some View {
        Form {
            Section {
                Button(Strings.Settings.showLog) { hooks.showLog?() }
                    .disabled(hooks.showLog == nil)
                Button(Strings.Settings.showSupportFolder) { hooks.showSupportFolder?() }
                    .disabled(hooks.showSupportFolder == nil)
                // Under the button that opens the folder it is about.
                if let note = hooks.supportNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.supportNote")
                }
            }
            Section {
                LabeledContent(Strings.Settings.extensionLabel) {
                    if let folder = hooks.extensionFolder {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Strings.Settings.extensionFound)
                            Text(folder.abbreviatedPath)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else {
                        Text(Strings.Settings.extensionNotFound)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("settings.extension")
                Toggle(Strings.Settings.webInspector, isOn: $webInspector)
                    .onChange(of: webInspector) { _, v in settings.webInspector = v }
            }
            // Where the picture model can always be fetched from once the
            // welcome pages have been passed, with or without it. Drawn only
            // once the engine has said: a guess here would be a second answer.
            if let ready = picture.ready {
                Section {
                    LabeledContent(Strings.Settings.pictureModel) {
                        Text(ready ? Strings.Settings.pictureModelHere : Strings.Settings.pictureModelMissing)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("settings.pictureModel")
                    if !ready {
                        PictureModelButton(model: picture, title: Strings.FirstRun.downloadIt, place: .settings)
                    }
                }
            }
            // "Show the first-use tips again" is gone: no tip was ever drawn,
            // so it handed back nothing, then or later.
            Section {
                Button(Strings.Settings.runFirstRunAgain) {
                    settings.firstRunDone = false
                    hooks.showFirstRunAgain?()
                }
                .disabled(hooks.showFirstRunAgain == nil)
            }
        }
        .formStyle(.grouped)
    }
}
