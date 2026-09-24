import AppKit
import Observation

// One call from the app, and the menu bar, the Dock, the notifications, the
// sleep assertion and the spoken announcements are all wired to the one model
// the app already has.
//
// Everything registered here is app-wide: moving around, the windows, the
// Help menu, stopping a job. Everything that needs a photograph on screen —
// Keep, Drop, the reasons, Compare, the zoom — is registered by the light
// table against the same ids, because only the view that drew the frame may
// say a verdict was taken on it.

@MainActor
public final class CommandHost {
    public static private(set) var current: CommandHost?

    public let center: CommandCenter
    /// The one list of work, for the life of the app. It is here because the
    /// three places a list shows itself - the Dock, the notification when it
    /// empties, and the way to the window it lives in - are all here.
    public let queue = QueueModel()
    private let model: AppModel
    private let assertion = ActivityAssertion()
    private var openActivity: (() -> Void)?
    private var observing = false
    private var queueClient: StudioClient?
    /// The page he was on, so leaving it can take down what the engine said
    /// to a press there.
    private var page: SidebarSelection?
    /// An eject he asked for is still going: the item is greyed until it
    /// answers, so a second ⌘E is not a second unmount of the same card.
    private var ejecting = false

    public init(model: AppModel, center: CommandCenter = .shared) {
        self.model = model
        self.center = center
    }

    /// `openActivity` is the app's own `openWindow(id: "activity")`: opening a
    /// SwiftUI scene is the app's to do, and this object does not reach into
    /// SwiftUI to do it.
    public static func install(model: AppModel, openActivity: @escaping () -> Void) -> CommandHost {
        let host = CommandHost(model: model)
        host.openActivity = openActivity
        host.registerEverything()
        MenuBar.install(center: host.center)
        Notifications.shared.attach()
        Notifications.shared.open = { [weak host] shoot, step in
            guard let model = host?.model else { return }
            if step == Notifications.cardPage {
                model.navigation.selection = model.importModel.card(copiedInto: shoot).map { .card($0) }
                    ?? .step(shoot: shoot, step: "ingest")
            } else {
                model.navigation.selection = step.isEmpty ? .shoot(shoot) : .step(shoot: shoot, step: step)
            }
        }
        Notifications.shared.showActivity = { openActivity() }
        Notifications.shared.cullCounts = { [weak host] shoot in
            guard let client = host?.model.client,
                  let r = try? await client.get(Routes.shootLight(shoot)) else { return nil }
            return (r.info.cull_picks, r.info.frames)
        }
        // One list, reachable from every step page and from the Dock menu.
        Queues.shared = { [weak host] in host?.queue ?? QueueModel() }
        Queues.showTheList = { openActivity() }
        host.queue.finished = { state in Notifications.shared.listFinished(state) }
        // Whichever poll sees work start wakes the other (DESIGN.md §3.6).
        host.queue.pair(with: model.jobs)
        host.observe()
        current = host
        return host
    }

    // MARK: - the job, everywhere it shows

    /// Dock bar, sleep assertion, notification, spoken announcement. One call,
    /// so none of the four can be left behind when a job ends.
    public func jobChanged(_ job: Job?) {
        center.job = job
        assertion.follow(job)
        // The Dock shows the LIST's progress where there is a list, and the
        // job's where there is not (DESIGN.md §2.7): a bar that fills and
        // drops back to nothing four times in an evening says the machine
        // restarted four times.
        QueueDock.show(queue.state, job: job)
        Announcer.shared.jobChanged(job)
        Notifications.shared.jobChanged(job)
    }

    /// The engine came up, or came back. The list is read from it at once:
    /// what he left on it last night is the first thing this owes him.
    private func followTheEngine() {
        guard model.client !== queueClient else { return }
        queueClient = model.client
        queue.attach(model.client)
        queue.forgetWhatWasSaid()
        if model.client != nil { queue.watch() }
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        page = model.navigation.selection
        followTheEngine()
        track()
    }

    private func track() {
        withObservationTracking {
            _ = model.jobs.job
            _ = model.navigation.selection
            _ = model.client
            _ = queue.state
        } onChange: { [weak self] in
            // The weak capture belongs on the closure AppKit keeps, not on the
            // Task inside it: a `[weak self]` there would sit inside a closure
            // that had already captured a strong one, and hold nothing open.
            Task { @MainActor in
                guard let self else { return }
                self.followTheEngine()
                if self.model.navigation.selection != self.page {
                    self.page = self.model.navigation.selection
                    self.model.jobs.leftThePage()
                    self.queue.leftThePage()
                }
                PagePresses.shared.forget(unlessOn: self.model.navigation.selection)
                self.jobChanged(self.model.jobs.job)
                self.refreshSteps()
                self.track()
            }
        }
    }

    /// The Go menu carries the open shoot's own steps, with the extension's
    /// labels, in the engine's order.
    public func refreshSteps() {
        guard let shoot = model.navigation.shoot,
              let session = model.library.cachedSession(for: shoot)
        else { center.setSteps([]); return }
        center.setSteps(session.steps)
    }

    // MARK: - registering the app-wide rows

    func registerEverything() {
        let nav = model.navigation
        let library = model.library

        // First Edit
        center.register(CommandTable.ID.settings) {
            // macOS 13 renamed this. Ask for the new one, then the old one, so
            // Command-comma opens Settings on every version the app runs on.
            if !NSApp.sendAction(NSSelectorFromString("showSettingsWindow:"), to: nil, from: nil) {
                _ = NSApp.sendAction(NSSelectorFromString("showPreferencesWindow:"), to: nil, from: nil)
            }
        }
        center.register(CommandTable.ID.checkForUpdates) { [model] in
            // With the answer on a sheet, whatever it is (§7.9).
            Task { await model.updates.checkNow() }
        }

        // File — the card. ⌘N goes to the card page (the copy itself is still
        // his press there); ⌘E ejects it, but never while a copy is running
        // off it. Both were rows with nothing behind them, and the card is
        // the first thing every evening.
        let card: () -> String? = {
            if case .card(let c) = nav.selection, library.cards.contains(c) { return c }
            return library.cards.first
        }
        // Always there. With no card in it opens the page that says so, and
        // that page changes the moment one goes in (§2.6): greyed, it was a
        // row he could not use to find out why.
        center.register(CommandTable.ID.newShoot) {
            nav.selection = .card(card() ?? "")
        }
        center.register(CommandTable.ID.eject, isEnabled: { [weak self, model] in
            card() != nil && self?.ejecting == false
                && !CardWatcher.copyNeedsTheCard(job: model.jobs.job, running: model.jobs.isRunning,
                                                 waiting: Queues.state.waiting)
        }) { [weak self, model] in
            guard let self, !ejecting, let c = card() else { return }
            ejecting = true
            Task { @MainActor in
                let why = await CardWatcher.ejectOffTheMainThread(c)
                self.ejecting = false
                if let why {
                    model.library.refusals.set(.library, why)
                    return
                }
                model.library.refusals.clear(.library)
                if case .card(c) = nav.selection { nav.selection = Self.afterEject(model, card: c) }
                await model.library.refreshSoon()
            }
        }

        // File — the two that need no view of their own.
        center.register(CommandTable.ID.showShoot, isEnabled: { nav.shootForCommands != nil }) { [model] in
            Self.open(model, what: "folder")
        }
        center.register(CommandTable.ID.showExports, isEnabled: { nav.shoot != nil }) { [model] in
            Self.open(model, what: "exports")
        }

        // Edit — Find Burst…, over the light table. A sheet on the window, so
        // it needs no view of the light table's to hang from, and the jump is
        // the light table's own. Whether it is live is the light table's
        // question alone, and a sheet already up: the window is found when
        // the row is chosen, so the menu's picture, drawn with no window,
        // shows the row as he sees it.
        let lightTable: () -> ShootSession? = {
            guard nav.step == "keepers", let shoot = nav.shoot,
                  let session = library.cachedSession(for: shoot), session.bursts.count > 1
            else { return nil }
            if let window = NSApp.mainWindow ?? NSApp.keyWindow, window.attachedSheet != nil { return nil }
            return session
        }
        center.register(CommandTable.ID.findBurst, isEnabled: { lightTable() != nil }) {
            guard let session = lightTable(), let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
            FindBurst.ask(on: window, viewer: ViewerModel.shared(for: session, navigation: nav))
        }

        // Edit — Undo, over the light table: the newest of his verdicts,
        // named, through the same press ⌘Z and U make on the stage. Anywhere
        // else, and in a text field, the row is the responder chain's.
        let deciding: () -> ShootSession? = {
            guard nav.step == "keepers", let shoot = nav.shoot else { return nil }
            return library.cachedSession(for: shoot)
        }
        center.register(CommandTable.ID.undo,
                        isEnabled: { deciding()?.undo.canUndo == true },
                        title: { deciding()?.undo.undoName.map(Words.Edit.undoNamed) }) {
            guard let session = deciding() else { return }
            ViewerModel.shared(for: session, navigation: nav).perform(.undo)
        }
        // Redo, the same way: what ⌘Z took back last, named, through the
        // press ⇧⌘Z makes on the light table (§2.5.5).
        center.register(CommandTable.ID.redo,
                        isEnabled: { deciding()?.undo.canRedo == true },
                        title: { deciding()?.undo.redoName.map(Words.Edit.redoNamed) }) {
            guard let session = deciding() else { return }
            ViewerModel.shared(for: session, navigation: nav).perform(.redo)
        }

        // Go
        center.register(CommandTable.ID.allShoots) { nav.selection = .allShoots }
        center.register(CommandTable.ID.learned) { nav.selection = .learned }
        center.register(CommandTable.ID.storagePage) { nav.selection = .storage }
        center.register(CommandTable.ID.nextStep,
                        isEnabled: { [weak self] in nav.canMoveStep(by: 1, in: self?.steps ?? []) }) { [weak self] in
            // At the end of the shoot ⌘] is Continue's key, and records the
            // last burst first, as Continue does (§2.5.2).
            let go: @MainActor () -> Void = { [weak self] in nav.moveStep(by: 1, in: self?.steps ?? []) }
            if !LightTableCommands.nextStep(then: go) { go() }
        }
        center.register(CommandTable.ID.previousStep,
                        isEnabled: { [weak self] in nav.canMoveStep(by: -1, in: self?.steps ?? []) }) { [weak self] in
            nav.moveStep(by: -1, in: self?.steps ?? [])
        }
        center.register(CommandTable.ID.resume,
                        isEnabled: { [model] in nav.shoot != nil || Self.backToHisShoot(model) != nil }) { [model] in
            // From a library page — All Shoots, the learning page, Storage, a
            // card — his shoot, where he was in it, as a click on its row
            // goes (§2.1). The row was greyed on exactly the pages he takes a
            // side trip to and wants the way back from.
            guard let shoot = nav.shoot else {
                if let back = Self.backToHisShoot(model) { nav.selection = back }
                return
            }
            // In a shoot, the step, and nothing else. Where he left off is the light
            // table's own place: the first time it opens in a launch it goes
            // where the engine says (§2.5.13), and after that it is wherever
            // he was when he stepped away. This used to move him to the
            // engine's answer as well, which is only ever read when the shoot
            // is loaded — so ⌘J from Presets, 120 bursts into a long night, put him
            // back on the burst the shoot had opened on.
            nav.selection = .step(shoot: shoot, step: "keepers")
        }
        for position in 1...CommandTable.stepNumberLimit {
            center.register(CommandTable.ID.step(position),
                            isEnabled: { [weak self] in (self?.steps.count ?? 0) >= position },
                            state: { [weak self] in
                                guard let s = self?.steps, s.indices.contains(position - 1) else { return nil }
                                return nav.step == s[position - 1].id
                            }) { [weak self] in
                guard let self, let shoot = nav.shoot, steps.indices.contains(position - 1) else { return }
                nav.selection = .step(shoot: shoot, step: steps[position - 1].id)
            }
        }

        // View — the two toggles the shell already owns.
        center.register(CommandTable.ID.sidebar, state: { nav.sidebarShown }) {
            nav.sidebarShown.toggle()
        }
        center.register(CommandTable.ID.inspector, isEnabled: { nav.hasInspector }, state: { nav.inspectorShown }) {
            nav.toggleInspector()
        }
        for background in ViewerBackground.allCases {
            center.register(CommandTable.ID.background(background),
                            state: { SettingsStore.shared.viewerBackground == background }) {
                SettingsStore.shared.viewerBackground = background
            }
        }
        // The checkmark is on the choice, not on what is currently drawn:
        // "Match the Mac" stays ticked while the Mac is dark.
        for choice in AppAppearance.allCases {
            center.register(CommandTable.ID.appearance(choice),
                            state: { SettingsStore.shared.appearance == choice }) {
                AppearanceController.choose(choice)
            }
        }

        // Shoot — every row but Stop the Job is a step page's own button,
        // pressed from wherever he is (`PagePresses`).
        registerPagePresses()
        center.register(CommandTable.ID.stopJob,
                        isEnabled: { [model] in model.jobs.isRunning }) { [model] in
            Task { await model.jobs.stop() }
        }

        // Window
        center.register(CommandTable.ID.fill, isEnabled: { NSApp.keyWindow != nil }) {
            guard let w = NSApp.keyWindow, let screen = w.screen ?? NSScreen.main else { return }
            w.setFrame(screen.visibleFrame, display: true, animate: !Motion.reduced)
        }
        center.register(CommandTable.ID.centre, isEnabled: { NSApp.keyWindow != nil }) {
            NSApp.keyWindow?.center()
        }
        center.register(CommandTable.ID.activity) { [weak self] in self?.openActivity?() }

        // Help
        center.register(CommandTable.ID.appHelp) { HelpBook.show() }
        center.register(CommandTable.ID.shortcuts) { ShortcutsWindow.show() }
        center.register(CommandTable.ID.showLog,
                        isEnabled: { [model] in model.logURL != nil }) { [model] in
            HelpBook.showLog(model.logURL)
        }
        center.register(CommandTable.ID.report) { [model] in
            HelpBook.report(version: model.updates.info?.current ?? "")
        }
    }

    // MARK: - the Shoot menu

    /// What the Shoot menu can know about the open shoot with no page on
    /// screen: the session once it has been read, the library's row until
    /// then. Each row is enabled when its page's button would be.
    struct ShootFacts: Equatable {
        let frames: Int
        let culled: Bool
        let finished: Bool
        /// The number that decides what gets a preset and what opens in the
        /// editor (§2.4).
        let willBeEdited: Int
        let presetsWritten: Bool
        /// The steps he can use now. A row whose page the engine has greyed
        /// — Reels on a Mac that cannot cut one, kept for the reels already
        /// in the folder — is grey too, rather than a press that lands on a
        /// page whose button cannot be pressed.
        let steps: [String]
        /// The kinds of work this shoot has running or waiting on the list
        /// (`PagePresses.inHand`): its own cull while it culls, for one.
        var inHand: Set<String> = []
    }

    var facts: ShootFacts? {
        guard let shoot = model.navigation.shoot else { return nil }
        let steps = self.steps.filter(\.enabled).map(\.id)
        let inHand = PagePresses.inHand(shoot: shoot, job: model.jobs.job, list: queue.state)
        if let s = model.library.cachedSession(for: shoot) {
            let i = s.info
            return ShootFacts(frames: i.frames, culled: i.culled, finished: i.finished,
                              willBeEdited: PresetSplits.source.split(s).willBeEdited,
                              presetsWritten: i.presets > 0 && i.sidecars > 0, steps: steps,
                              inHand: inHand)
        }
        guard let r = model.library.row(named: shoot) else { return nil }
        return ShootFacts(frames: r.frames, culled: r.culled, finished: r.finished,
                          willBeEdited: r.will_be_edited ?? r.keepers,
                          presetsWritten: r.presets > 0 && r.sidecars > 0, steps: steps,
                          inHand: inHand)
    }

    private func registerPagePresses() {
        typealias ID = CommandTable.ID
        // Cull It, Cull Again… and Write the Presets are grey while that
        // shoot's own cull or presets is running or waiting on the list: a
        // press then would queue the same work a second time.
        let rules: [(CommandID, (ShootFacts) -> Bool)] = [
            (ID.cull, { $0.frames > 0 && !$0.culled && !$0.inHand.contains("cull") }),
            (ID.cullAgain, { $0.frames > 0 && $0.culled && !$0.inHand.contains("cull") }),
            (ID.writePresets, { ($0.willBeEdited > 0 || $0.presetsWritten) && !$0.inHand.contains("presets") }),
            // Only while the Edit page's button opens: now, or once the
            // presets being written are on disk. With none written it writes
            // them first, two minutes of work under a row named Open.
            (ID.openInEditor, { $0.willBeEdited > 0 && ($0.presetsWritten || $0.inHand.contains("presets")) }),
            (ID.finished, { !$0.finished }),
            (ID.copyUp, { _ in true }), (ID.bringBack, { _ in true }), (ID.checkEvery, { _ in true }),
            (ID.takeBackCache, { _ in true }), (ID.removeLocal, { _ in true }), (ID.letGo, { _ in true }),
        ]
        // While work of his runs, the rows whose page's button would then add
        // to Up Next say so, as the button does: "Add Cull It to Up Next".
        // The row used to say Cull It and add, where the button said what
        // pressing it would do. Write the Presets says it asks once they are
        // written, as its page's Write Them Again… does.
        let adding: Set<CommandID> = [ID.cull, ID.cullAgain, ID.writePresets]
        for (id, rule) in rules {
            center.register(id, isEnabled: { [weak self] in
                guard let f = self?.facts, let step = PagePresses.step(for: id), f.steps.contains(step)
                else { return false }
                return rule(f)
            }, title: { [weak self] in
                guard adding.contains(id), let c = CommandTable.command(id) else { return nil }
                let again = id == ID.writePresets && self?.facts?.presetsWritten == true
                return Self.rowTitle(again ? Words.Shoot.writePresetsAgain : c.title,
                                     adds: StepPrimaryWords.wouldWait)
            }) { [weak self] in
                self?.press(id)
            }
        }
        // Cut a Reel cuts the burst the Reels page has chosen, and only there:
        // from anywhere else it goes to Reels, where the burst and its frames
        // are chosen. Cutting whatever burst the page would happen to open on
        // is work he did not choose.
        center.register(ID.cutAReel, isEnabled: { [weak self] in
            guard let self, let f = facts, f.steps.contains("reels") else { return false }
            guard onReels, let reels = reelsModel else { return true }
            return reels.canCut
        }, title: { [weak self] in
            // It adds only where it cuts: on Reels. Anywhere else it goes there.
            guard let self, onReels else { return Words.Shoot.cutAReel }
            return Self.rowTitle(Words.Shoot.cutAReel, adds: StepPrimaryWords.wouldWait)
        }) { [weak self] in
            guard let self, let shoot = model.navigation.shoot else { return }
            if onReels { press(ID.cutAReel) } else { model.navigation.selection = .step(shoot: shoot, step: "reels") }
        }
    }

    private var onReels: Bool { model.navigation.step == "reels" }

    /// A Shoot row's title: its own, or the sentence its page's button speaks
    /// when a press would add to Up Next, the ellipsis still last where the
    /// press asks first.
    static func rowTitle(_ title: String, adds: Bool) -> String {
        StepPrimaryWords.spoken(title, adds: adds)
    }

    /// The Reels page's own model, once the page has made it.
    private var reelsModel: ReelsModel? {
        guard let shoot = model.navigation.shoot, let s = model.library.cachedSession(for: shoot)
        else { return nil }
        return ReelsModelStore.shared.existing(for: s)
    }

    /// Asks the row's page to press its button, and goes there.
    private func press(_ id: CommandID) {
        guard let shoot = model.navigation.shoot, let step = PagePresses.step(for: id) else { return }
        PagePresses.shared.ask(id, shoot: shoot, optionHeld: NSEvent.modifierFlags.contains(.option))
        model.navigation.selection = .step(shoot: shoot, step: step)
    }

    private var steps: [StepState] {
        guard let shoot = model.navigation.shoot else { return [] }
        if let session = model.library.cachedSession(for: shoot) { return session.steps }
        return Fallbacks.listSteps(canCutReels: model.library.row(named: shoot)?.can_cut_reels ?? true,
                                   ext: model.library.ext)
    }

    /// Where ⌘J goes from a library page: the shoot he was last in, still in
    /// the library, on the step he was last on there. `nil` — nothing to go
    /// back to — greys the row.
    static func backToHisShoot(_ model: AppModel) -> SidebarSelection? {
        guard model.navigation.shoot == nil, let shoot = model.navigation.lastShoot,
              model.library.row(named: shoot) != nil else { return nil }
        return model.place(in: shoot)
    }

    /// Where ⌘E leaves him when the page of the card he ejected was showing.
    /// Straight after a copy of that card, the new shoot's Cull — what the
    /// page's Open the Shoot link does, and the next thing he does with a card
    /// that has been copied. It used to be All Shoots every time, which threw
    /// the copy's result and the way to the new shoot away. With nothing
    /// copied from this card there is nothing to go on to, and the card's page
    /// has nothing left to show: the shoot the engine says came from another
    /// card is not this one's, however recently it was copied.
    static func afterEject(_ model: AppModel, card: String) -> SidebarSelection {
        if let j = model.jobs.job, j.kind == "ingest", j.outcome == .done, !j.shoot.isEmpty,
           let row = model.library.row(named: j.shoot), !row.culled, row.card == card {
            return .step(shoot: j.shoot, step: "cull")
        }
        return .allShoots
    }

    private static func open(_ model: AppModel, what: String) {
        guard let shoot = model.navigation.shootForCommands, let client = model.client else { return }
        Task {
            do {
                let r = try await client.post(Routes.open, OpenBody(name: shoot, what: what))
                if let e = r.error { model.library.refusals.set(.library, e) } else { model.library.refusals.clear(.library) }
            } catch let e as StudioError {
                model.library.refusals.set(.library, e.sentence)
            } catch {}
        }
    }
}
