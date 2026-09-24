import AppKit
import SwiftUI
import PipelineKit

/// Start the engine at launch; stop it, exactly as today, at quit.
///
/// This is also where every crew's work is handed to the shell. Nothing in the
/// library names another crew's view, so each one registers what it owns here,
/// once, in an order that is written down below and matters in two places.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `--smoke`: report what the sidebar shows, then quit (tools/smoke.sh).
    nonisolated(unsafe) static var smoke = false

    let model: AppModel
    /// The picture on the other screen (DESIGN-displays.md). Built here
    /// because it needs the pump and the job queue, which are the app's.
    let screens = ScreenWatcher()
    private(set) var displays: DisplayDirector!
    private var commands: CommandHost?

    override init() {
        let support = AppPaths.support()
        // The smoke run walks every shoot; it must not leave the next real
        // launch opening on whichever one it walked last.
        model = AppModel(engine: EngineHost(bundle: .main, support: support, settings: .shared),
                         memory: Self.smoke ? nil : .shared)
        super.init()
        displays = DisplayDirector(settings: .shared, pump: nil, jobs: model.jobs, screens: screens)
        model.onQuitRequested = {
            // The updater printed QUIT: an update is about to swap the app.
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Before the first window paints, so it never flips in front of him.
        AppearanceController.apply()
        registerEveryCrew()
        // The stage has the keyboard before the first frame paints (NAT-01).
        KeyFocus.restoreAll()
        // The menu bar, the Dock's progress, the notifications and the spoken
        // announcements, all from one command table.
        commands = CommandHost.install(model: model) { [weak self] in self?.openActivity() }
        DisplayRegistration.register(director: displays)
        screens.startObserving()
        // After the screen list is known, so the picture comes back on a
        // screen that is actually attached.
        displays.restoreAtLaunch()
        Task {
            await model.launch()
            if Self.smoke { await reportAndQuit() }
        }
        // Two support folders, and the one in use has no work in it: said
        // once, after the first window.
        FirstLaunch.afterLaunch()
    }

    /// Every crew's pages, in one place and in this order.
    ///
    /// Two orderings matter. The storage crew registers a stand-in Finish page
    /// only while nothing else has claimed `done`, and the steps crew's own
    /// Finish page embeds the storage panel — so the steps crew goes second
    /// and wins. And the extension's pages are registered later still, from
    /// `onConnected`, because they are whatever the engine says they are.
    private func registerEveryCrew() {
        StepJobs.shared = { [model] in model.jobs }
        StorageLearningRegistration.register()
        WorkflowSteps.register()
        LightTableRegistration.register(navigation: model.navigation)

        // The slots the steps crew leaves for pages it does not own.
        StepSlots.storagePanel = { session in
            AnyView(StoragePanel(shoot: session.name, client: session.client))
        }
        StepSlots.showLearned = { [model] in model.navigation.selection = .learned }
        StepSlots.showStep = { [model] shoot, step in
            model.navigation.selection = .step(shoot: shoot, step: step)
        }
        StepSlots.showActivity = { [weak self] in self?.openActivity() }

        // `ExtViewer.maker` is left unset on purpose: the light table has not
        // published a viewer that opens on a bare list of stems, so an
        // extension page still gets the extension host's own full look. The
        // seam is there for the day it does.

        model.onConnected = { [weak self] app in
            ExtensionHostRegistration.follow(app)
            self?.displays.attach(pump: app.pump)
        }
        displays.onScreensChanged = { [weak self] in
            guard let self else { return }
            DisplayRegistration.screensChanged(director: self.displays)
        }
    }

    /// Opening a SwiftUI scene is the App struct's to do, so it hands the
    /// closure down rather than this reaching up into SwiftUI.
    var openActivityWindow: (@MainActor () -> Void)?

    private func openActivity() { openActivityWindow?() }

    /// The Dock menu is a delegate method: a library cannot install one.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        DockProgress.dockMenu()
    }

    /// SwiftUI replaces the main menu when its scenes change, and the stage
    /// has to get the keyboard back after a trip to PhotoLab.
    func applicationDidBecomeActive(_ notification: Notification) {
        MenuBar.reinstallIfNeeded()
        KeyFocus.restoreAll()
    }

    /// ⌘W with a job running keeps the app alive and working. Without one, the
    /// last window closing ends the app, as it always has.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.jobs.isRunning
    }

    private var quitConfirmed = false

    /// ⌘Q with a job running asks once, in the one alert the design keeps:
    /// Keep Working is the default.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitConfirmed || Self.smoke { return .terminateNow }
        Task { @MainActor in
            let running = await model.jobIsRunning()
            guard running else {
                quitConfirmed = true
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            let a = NSAlert()
            a.messageText = Strings.Quit.title(kind: model.jobs.job?.kind ?? "")
            a.informativeText = Strings.Quit.body(kind: model.jobs.job?.kind ?? "")
            a.addButton(withTitle: Strings.Quit.keepWorking)
            a.addButton(withTitle: Strings.Quit.quit)
            let quit = a.runModal() == .alertSecondButtonReturn
            quitConfirmed = quit
            NSApp.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // SIGTERM, three seconds, SIGKILL — synchronously, on the way out.
        screens.stop()
        model.engine?.terminateNow()
        if Self.smoke { print("ENGINE stopped"); fflush(stdout) }
    }

    // MARK: - smoke

    private func note(_ s: String) { print(s); fflush(stdout) }

    private func reportAndQuit() async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(60)
        while !model.library.loaded, clock.now < deadline {
            if case .failed(let why) = model.engineState { note("FAIL engine: \(why)"); exit(1) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard model.library.loaded else { note("FAIL the library never loaded"); exit(1) }
        if case .running(let e) = model.engineState {
            note("ENGINE running on \(e.base.absoluteString) pid \(model.engine?.childPID ?? 0)")
        }
        // Open the Finished section as he would with a click, so every shoot
        // is a drawn row.
        model.navigation.selection = .allShoots
        model.navigation.finishedExpanded = true
        let names = model.library.rows.map(\.name)
        var rows = 0
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(100))
            guard let w = SmokeProbe.mainWindow() else { continue }
            rows = SmokeProbe.sidebarRowsDrawn(in: w)
            // A drawn row for every shoot, at least.
            if rows >= names.count { break }
        }
        note("LIBRARY \(names.count) shoots")
        note("SIDEBAR \(rows) rows drawn")

        // And each one opens: selecting it puts its name in the window's own
        // title, which is AppKit's, not the model's.
        var opened: [String] = []
        for name in names {
            model.navigation.selection = .shoot(name)
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(50))
                if SmokeProbe.mainWindow()?.title == name { break }
            }
            if SmokeProbe.mainWindow()?.title == name { opened.append(name) }
        }
        note("SIDEBAR \(opened.count) shoots: \(opened.joined(separator: ", "))")
        note("SMOKE quitting")
        NSApp.terminate(nil)
    }
}
