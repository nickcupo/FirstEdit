import SwiftUI
import AppKit

/// §2.11 General — the library folder, the editor, and the update check.
struct GeneralTab: View {
    let settings: SettingsStore
    let hooks: SettingsView.Hooks
    /// A new folder is a new engine: the one path, which asks only when a
    /// job of his would be stopped, and saves the folder only when it
    /// restarts (§2.11).
    let restarter: EngineRestart

    @State private var folder: URL?
    /// What that folder turned out to be, and what is in it. Read once when
    /// the tab opens and again on every choice, never on every redraw: it
    /// walks a directory.
    @State private var resolved: LibraryFolder.Resolution?
    /// An empty folder chosen to start a library in, so the line under the
    /// control can say where new shoots will go instead of saying nothing.
    @State private var newLibrary: URL?
    /// The folder he picked that holds other things and no shoot, kept so the
    /// sentence can name it. Nothing is saved while this is set.
    @State private var refused: URL?
    @State private var editor: String
    @State private var checkForUpdates: Bool
    @State private var appearance: AppAppearance

    init(settings: SettingsStore, hooks: SettingsView.Hooks, restarter: EngineRestart = .shared) {
        self.settings = settings
        self.hooks = hooks
        self.restarter = restarter
        let now = Self.read(settings)
        _folder = State(initialValue: now.folder)
        _resolved = State(initialValue: now.resolved)
        _newLibrary = State(initialValue: now.newLibrary)
        _editor = State(initialValue: StepsModel.defaultEditor(settings))
        _checkForUpdates = State(initialValue: settings.checkForUpdates)
        _appearance = State(initialValue: settings.appearance)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(Strings.Settings.libraryFolder) {
                    HStack(spacing: Tokens.Metric.relatedGap) {
                        if let folder { PathRow(folder).frame(height: 22) }
                        Button(Strings.Settings.choose, action: choose)
                            .accessibilityIdentifier("settings.chooseLibrary")
                    }
                }
                // What it resolved to, and what is there. Either folder — the
                // library or the `shoots` inside it — is a right answer, and
                // this is the line that says which one the engine will be
                // given and how many shoots it found under it.
                if let resolved {
                    Text(Strings.Settings.resolvedLine(resolved))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.libraryResolved")
                }
                if let newLibrary {
                    Text(Strings.Library.newLibrary(LibraryFolder.shelf(under: newLibrary).abbreviatedPath))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.libraryNew")
                }
                if let waiting = restarter.waiting {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.relatedGap) {
                        Label(waiting.sentence(current: folder), systemImage: Symbols.restartWaiting)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(Strings.Settings.dontWait) { restarter.cancelWaiting() }
                            .controlSize(.small)
                    }
                    .accessibilityIdentifier("settings.restartWaiting")
                }
                if let refused {
                    Label(Strings.Settings.noShootsHere(refused.abbreviatedPath), systemImage: Symbols.refusal)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.libraryRefused")
                }
                Text(Strings.Settings.nothingIsMoved)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                // The editors the Presets step can write for, by name. This
                // was an empty text field that took an internal id: typing
                // "PhotoLab" into it was stored and did nothing.
                Picker(Strings.Settings.editor, selection: $editor) {
                    ForEach(Editors.ids, id: \.self) { id in
                        Text(Editors.name(id)).tag(id)
                    }
                }
                .accessibilityLabel(Strings.Settings.editor)
                .onChange(of: editor) { _, v in settings.editor = v }
            }
            // Light or dark, for the whole app. "Match the Mac" is the
            // default and is what he gets without touching anything; the other
            // two are here because the app is used beside PhotoLab and in
            // rooms with the lights off. What this means for the grey behind a
            // photograph is said once, on Choosing, where the grey is chosen.
            Section {
                Picker(Strings.Appearance.settingsLabel, selection: $appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.appearance")
                .onChange(of: appearance) { _, v in AppearanceController.choose(v) }
            }
            Section {
                Toggle(Strings.Settings.checkForUpdates, isOn: $checkForUpdates)
                    .onChange(of: checkForUpdates) { _, v in settings.checkForUpdates = v }
            }
        }
        .formStyle(.grouped)
        // A restart that waited for a job has happened, or been dropped:
        // the control shows the folder the engine is on.
        .onChange(of: restarter.waiting) { _, now in if now == nil { reread() } }
    }

    /// The folder the setting holds, and what is in it. Read when the tab
    /// opens and after a restart, never on a redraw: it walks a directory.
    private static func read(_ settings: SettingsStore) -> (folder: URL?, resolved: LibraryFolder.Resolution?,
                                                            newLibrary: URL?) {
        let chosen = settings.libraryFolder
        let resolved = chosen.flatMap { LibraryFolder.resolve($0) }
        let empty = resolved == nil ? chosen.flatMap { LibraryFolderPicker.emptyLibrary($0) } : nil
        return (chosen, resolved, empty)
    }

    private func reread() {
        let now = Self.read(settings)
        folder = now.folder
        resolved = now.resolved
        newLibrary = now.newLibrary
    }

    /// The same picker the first run and the empty sidebar use, so all three
    /// agree about what a library is, and an empty folder starts one.
    private func choose() {
        switch LibraryFolderPicker.pick(startingAt: folder ?? AppPaths.engineLibrary(settings: settings)) {
        case .cancelled:
            return
        case .noShoots(let url):
            // Turned down here, with the sentence saying what was looked for.
            // Saving it and letting the engine come up empty is what happened
            // before, and from inside the app it was indistinguishable from a
            // library that had gone missing.
            refused = url
        case .chose(let r):
            refused = nil
            adopt(r.root)
        case .empty(let root):
            refused = nil
            adopt(root)
        }
    }

    /// Nothing is saved here: the restart saves the folder when it happens,
    /// so a Cancel, or a restart still waiting for a job, leaves the app and
    /// the engine on the same folder.
    private func adopt(_ root: URL) {
        Task {
            if await restarter.restart(pointingAt: root) == .restarted { reread() }
        }
    }
}
