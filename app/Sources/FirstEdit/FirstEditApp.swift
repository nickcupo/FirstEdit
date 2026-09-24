import SwiftUI
import PipelineKit

/// One window, one library, one job queue, no tabs (DESIGN.md §2.1).
struct FirstEditApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    /// The first-run sheet, asked for once. `--smoke` never asks: a sheet
    /// waiting for an answer is an app that never reports and never quits.
    @State private var firstRun = !SettingsStore.shared.firstRunDone && !AppDelegate.smoke
    @State private var settingsTab: SettingsView.Tab = .general

    var body: some Scene {
        Window(Strings.App.name, id: "main") {
            RootView(app: delegate.model)
                .onAppear {
                    // Window ▸ Activity is a row of the command table, and
                    // opening a SwiftUI scene is this struct's to do.
                    delegate.openActivityWindow = { openWindow(id: "activity") }
                    // Whether the picture model is here is the engine's
                    // answer, and fetching it is a press, wherever it is
                    // offered: the welcome pages, the Cull step, Settings.
                    PictureModel.shared.attach(delegate.model)
                    // A new library folder, from Settings, the first run or
                    // the empty sidebar, is one restart that asks before it
                    // stops a job of his.
                    EngineRestart.shared.attach(.real(delegate.model))
                }
                .sheet(isPresented: $firstRun) {
                    FirstRunSheet(world: .real(libraryCandidate: AppPaths.libraryCandidate()),
                                  finish: { firstRun = false })
                }
        }
        .defaultSize(width: Tokens.Metric.defaultWindow.width, height: Tokens.Metric.defaultWindow.height)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        // No `.commands`: the whole menu bar is `CommandTable`, built in
        // AppKit by `MenuBar.install`. A SwiftUI group here would be a second
        // row with the same key equivalent, and the system would pick one.

        Window(Strings.Job.activity, id: "activity") {
            // The list of work and the history of it, in one window: what is
            // going to happen, and what happened.
            ActivityWindow(jobs: delegate.model.jobs, logURL: delegate.model.logURL,
                           queue: CommandHost.current?.queue,
                           show: { place in
                               // The page, in the main window, brought forward:
                               // a page changed behind Activity is a click
                               // that looked like nothing.
                               delegate.model.navigation.selection = place
                               openWindow(id: "main")
                           })
        }
        // Its minimum is what is in it: the list of work is as tall as its
        // rows, and the history and footer have to fit under it.
        .defaultSize(width: 760, height: 640)
        .windowResizability(.contentMinSize)

        Settings {
            // In a view of its own, so what the engine reports about the
            // extension is read where SwiftUI follows it.
            SettingsWithTheEngine(model: delegate.model, hooks: hooks, tab: settingsTab)
        }
    }

    private func hooks(extensionFolder: URL?) -> SettingsView.Hooks {
        SettingsView.Hooks(
            openLearning: {
                delegate.model.navigation.selection = .learned
                // The page changed behind Settings, which stayed in front and
                // key, so pressing it looked like nothing. Settings is the key
                // window while its button is pressed; it closes, and the main
                // window comes forward on the page.
                NSApp.keyWindow?.performClose(nil)
                openWindow(id: "main")
            },
            showLog: {
                guard let log = delegate.model.logURL else { return }
                NSWorkspace.shared.activateFileViewerSelecting([log])
            },
            showSupportFolder: {
                NSWorkspace.shared.activateFileViewerSelecting([AppPaths.support()])
            },
            extensionFolder: extensionFolder,
            showFirstRunAgain: { firstRun = true },
            supportNote: FirstLaunch.note)
    }
}

/// Settings, told about the extension by the engine rather than by the
/// setting: Advanced said "Not found" while the extension's step was in the
/// sidebar, because the setting is empty unless he pointed it somewhere by
/// hand, and the engine is handed the app's own support folder by default.
struct SettingsWithTheEngine: View {
    let model: AppModel
    let hooks: (URL?) -> SettingsView.Hooks
    let tab: SettingsView.Tab

    var body: some View {
        SettingsView(settings: .shared, hooks: hooks(extensionFolder), tab: tab)
    }

    /// Found when the engine's list carries the extension's configuration; at
    /// the folder the engine was handed, in `EngineHost.environment`'s order.
    private var extensionFolder: URL? {
        guard model.library.ext != nil else { return nil }
        if let chosen = SettingsStore.shared.extensionFolder { return chosen }
        if let given = ProcessInfo.processInfo.environment["PIPELINE_EXT"], !given.isEmpty {
            return URL(fileURLWithPath: (given as NSString).expandingTildeInPath, isDirectory: true)
        }
        return AppPaths.support().appendingPathComponent("extension", isDirectory: true)
    }
}
