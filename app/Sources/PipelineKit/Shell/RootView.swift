import SwiftUI

/// The one window: sidebar, the selected page, and a trailing inspector.
///
/// Two columns plus an inspector, not three: a third permanent 220 pt column
/// for seven fixed rows comes straight out of the photograph (DESIGN.md §2.1).
public struct RootView: View {
    let app: AppModel
    @Bindable var nav: Navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let restarter: EngineRestart

    public init(app: AppModel, restarter: EngineRestart = .shared) {
        self.app = app
        self.nav = app.navigation
        self.restarter = restarter
    }


    /// The one truth about whether the sidebar is showing. It was private
    /// `@State` here, so §2.1's "the sidebar auto-hides on entering Choose
    /// Keepers below 1280 pt" could not take effect and View ▸ Show Sidebar
    /// toggled something nothing read. It is 220 pt of photograph.
    private var columns: Binding<NavigationSplitViewVisibility> {
        Binding(get: { nav.sidebarShown ? .all : .detailOnly },
                set: { nav.sidebarShown = ($0 != .detailOnly) })
    }

    /// Shown where the page has one (`Navigation.hasInspector`), and written
    /// back only there: a page without one leaves the flag as he left it.
    private var inspector: Binding<Bool> {
        Binding(get: { nav.inspectorOnScreen },
                set: { shown in if nav.hasInspector { nav.inspectorShown = shown } })
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: columns) {
            SidebarView(app: app, restarter: restarter)
        } detail: {
            detail
                .toolbar { toolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: inspector) {
            InspectorHost(app: app)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        // The minimum is the window's, and this frame is laid out inside the
        // safe area, which is the window less the 52 pt toolbar. Asking for
        // the whole 620 here asked for 672 of window: below that, SwiftUI
        // centred a 620 pt root in the shorter safe area and the light table
        // ran (672 − height) / 2 pt off the bottom — 26 pt at the minimum —
        // cutting the filmstrip's captions. §2.5.1's arithmetic already counts
        // the toolbar inside the 620.
        .frame(minWidth: Tokens.Metric.minimumWindow.width,
               minHeight: Tokens.Metric.minimumWindow.height - Tokens.Metric.toolbar)
        .background(WindowChrome(keysBelongToTheStage: { [nav] in nav.step == "keepers" },
                                 widthChanged: { width = $0 }))
        // Check for Updates… and the sidebar's "Update to … available ›".
        .sheet(isPresented: Bindable(app.updates).sheetShown) {
            UpdateSheet(updates: app.updates, jobs: app.jobs)
        }
        .onChange(of: nav.selection) { old, new in
            // Selecting a shoot opens its session, so its steps come from the
            // engine rather than from the fixed list.
            if let s = new?.shoot, app.library.cachedSession(for: s) == nil {
                Task { _ = try? await app.library.session(for: s) }
            }
            // Leaving a step is when what he did there shows up in the
            // sidebar's "kept" and in All Shoots.
            if case .step = old { Task { await app.library.refreshSoon() } }
            // A line about a card at the top of the window is spent when he
            // goes anywhere.
            app.importModel.navigated()
            // The restart line has been read by the time he goes elsewhere.
            if old != new { app.banner = nil }
        }
    }

    @ViewBuilder private var detail: some View {
        switch app.engineState {
        case .running where !app.isReady:
            // Running, but the library has not been read and the window has
            // not yet been put back where he left it. A page drawn now would
            // be All Shoots for a moment and then his shoot — or a shoot page
            // asking an engine it has no key for yet.
            EngineStartingView()
        case .running:
            StepDetail(app: app)
                // The page's own line at the top of the photograph — "Back
                // where you left off" — goes under this column rather than
                // behind it: under the restart line only a sliver of its
                // edge showed, and with the card's line as well it was gone.
                .environment(\.topLinesHeight, topLinesHeight)
                // A step page that puts the sidebar away in a narrow window,
                // as Reels does, reads the window's navigation from here.
                .environment(app.navigation)
                // Over the page, not a safe-area inset: the inset took 22 pt
                // from the photograph and reflowed the light table under it.
                // The restart line and the card's line are one column, so
                // both at once stack rather than print over each other; on
                // the light table the column starts under the burst scrubber,
                // a row he clicks to jump, which the card's line covered for
                // its 8 s as the restart line once did.
                .overlay(alignment: .top) {
                    VStack(spacing: Tokens.Metric.relatedGap) {
                        if let banner = bannerLine {
                            restartLine(banner)
                        }
                        if let notice = app.importModel.notice {
                            CardNotice(notice: notice) { app.importModel.openNotice() }
                                .padding(.top, bannerLine == nil ? Tokens.Metric.relatedGap : 0)
                                .padding(.horizontal, Tokens.Metric.windowMargin)
                                .transition(.opacity)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topLinesHeight = $0 }
                    .padding(.top, nav.step == "keepers" ? Tokens.Metric.scrubber : 0)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: app.importModel.notice)
        case .starting, .stopped:
            EngineStartingView()
        case .failed(let why):
            EngineDownView(reason: why, logURL: app.logURL) {
                Task { await app.restartEngine() }
            }
        }
    }

    /// The engine's restart after a crash, a band across the page with its
    /// close button.
    private func restartLine(_ banner: String) -> some View {
        HStack(spacing: Tokens.Metric.relatedGap) {
            Text(banner)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                app.banner = nil
            } label: {
                Image(systemName: "xmark")
                    .frame(width: Tokens.Metric.minimumHitTarget,
                           height: Tokens.Metric.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(Strings.Shell.closeBanner)
            .accessibilityLabel(Strings.Shell.closeBanner)
        }
        .padding(.leading, Tokens.Metric.windowMargin)
        .padding(.trailing, 6)
        .background(.bar)
    }

    /// The line over the page: the engine's restart after a crash, which
    /// goes by itself. A library folder waiting for work to end is said at
    /// the foot of the sidebar, with its Don't Wait (`EngineRestart`).
    private var bannerLine: String? { app.banner }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // While a job runs; for a moment after one ends, or until he looks
        // when it did not simply finish; and while a list he filled is
        // waiting with nothing running, because a held list with four things
        // on it is exactly the moment he wants a way back to it.
        if let subject = activitySubject {
            ToolbarItem(placement: .status) {
                ActivityToolbarItem(subject, waiting: Queues.waiting, upNext: Queues.state.waiting,
                                    stop: { Task { await app.jobs.stop() } },
                                    openLearning: { nav.selection = .learned },
                                    showTheList: Queues.showTheList,
                                    letGo: { Task { await Queues.model(client: app.client).hold(false) } },
                                    dismiss: { app.dismissEnded() },
                                    compact: Self.statusItemIsShort(step: nav.step, windowWidth: width))
            }
        }
        if nav.hasInspector {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    nav.toggleInspector()
                } label: {
                    Label(Strings.Shell.inspector, systemImage: Symbols.inspector)
                }
                .help(Strings.Shell.inspector)
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }

    /// The window's width, for the toolbar's status item, told by
    /// `WindowChrome` from AppKit.
    @State private var width: CGFloat = 0

    /// How tall the column of lines over the top of the page is — the
    /// restart line, the card's line, both or neither — for the page to put
    /// its own top line under it.
    @State private var topLinesHeight: CGFloat = 0

    /// The status item in its short form: on Choose Keepers, whose mode
    /// picker holds the toolbar's middle, in a window narrower than
    /// `statusItemWholeFrom`. Wider, or on any other page, the whole line
    /// fits beside the title.
    static func statusItemIsShort(step: String?, windowWidth: CGFloat) -> Bool {
        step == "keepers" && windowWidth < Tokens.Metric.statusItemWholeFrom
    }

    /// What the `.status` item is about: the running job; else a job that
    /// has just ended; else — nothing running, the list not empty — the list
    /// itself. It built a job that was not running and titled it "Up Next",
    /// which drew an empty progress ring: a job stuck at nought.
    private var activitySubject: ActivityToolbarItem.Subject? {
        if let j = app.jobs.job, j.running { return .running(j) }
        if let j = app.justEnded { return .ended(j) }
        guard Queues.waiting > 0 else { return nil }
        return .list(held: Queues.state.held)
    }

    /// Window title = shoot name; subtitle = the step and his count. The
    /// native two-line title, which is where this belongs.
    private var title: String {
        if !app.isReady { return Self.notReady(app.engineState, reopening: app.shootBeingReopened).title }
        return nav.shoot ?? Strings.App.name
    }

    private var subtitle: String {
        if !app.isReady { return Self.notReady(app.engineState, reopening: app.shootBeingReopened).subtitle }
        guard let shoot = nav.shoot else {
            switch nav.selection {
            case .allShoots: return Strings.Library.allShoots
            case .learned: return Strings.Library.learned
            case .storage: return Strings.Library.storage
            // The card page named neither the step nor the card: the window
            // said only "First Edit".
            case .card(let volume):
                return [Fallbacks.baseLabel("ingest"), URL(fileURLWithPath: volume).lastPathComponent]
                    .joined(separator: " · ")
            default: return ""
            }
        }
        return Self.subtitle(step: nav.step, stepLabel: nav.step.flatMap { id in
            app.library.cachedSession(for: shoot)?.steps.first { $0.id == id }?.label ?? Fallbacks.baseLabel(id)
        }, kept: app.library.row(named: shoot)?.kept ?? 0, bursts: app.bursts(for: shoot))
    }

    /// The title bar before the window has a page of the engine's to name.
    /// Starting: the shoot being reopened and "Starting…", not All Shoots,
    /// which the window is not going to show. Stopped: the app's name and
    /// nothing under it — the page says the engine stopped, and the title bar
    /// said "Starting…" over it, for an engine that was not starting at all.
    static func notReady(_ state: EngineHost.State, reopening: String?) -> (title: String, subtitle: String) {
        if case .failed = state { return (Strings.App.name, "") }
        return (reopening ?? Strings.App.name, Strings.Engine.starting)
    }

    /// On Choose Keepers, the number that moves all evening first and no step
    /// name — "140 of 288 bursts · 368 you kept": at the 900 pt minimum, or
    /// whenever the mode picker takes the middle of the toolbar, the title
    /// bar cut the end off, and the end was the bursts count — "Choose
    /// keepers · 368 you kept · 288 of 288…" —
    /// while the step's name is the page he is looking at, ticked in Go and
    /// highlighted in the sidebar. Elsewhere, the step and his count.
    static func subtitle(step: String?, stepLabel: String?, kept: Int, bursts: (seen: Int, of: Int)?) -> String {
        var parts: [String] = []
        if step == "keepers" {
            // With its unit: "140 of 288 been through" beside "1 of 32 in
            // burst 265" did not say that 288 counts bursts.
            if let b = bursts, b.of > 0 { parts.append(Strings.Overview.burstsOf(b.seen, b.of)) }
            if kept > 0 { parts.append(Strings.Library.kept(kept)) }
            if parts.isEmpty, let stepLabel { parts.append(stepLabel) }
            return parts.joined(separator: " · ")
        }
        if let stepLabel { parts.append(stepLabel) }
        if kept > 0 { parts.append(Strings.Library.kept(kept)) }
        return parts.joined(separator: " · ")
    }
}

extension EnvironmentValues {
    /// The height of the lines the window has put over the top of the page
    /// (the engine's restart, a card that went in), 0 with none up. On
    /// Choose Keepers the column starts under the burst scrubber, as the
    /// stage does, so a line of the stage's own at its top moves down by
    /// exactly this much.
    @Entry public var topLinesHeight: CGFloat = 0
}
