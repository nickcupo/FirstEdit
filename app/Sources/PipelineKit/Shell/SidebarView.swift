import AppKit
import SwiftUI

/// The sidebar: the library, the memory card, the shoots in progress with
/// their steps, the finished ones, and the update line (DESIGN.md §2.1).
///
/// The steps live here, under their shoot, not in a segmented control: a
/// segmented control cannot hold seven to nine items with extension labels of
/// arbitrary length, and this is the only place that answers "where am I and
/// what is left" without a wizard. Only the selected shoot is expanded.
public struct SidebarView: View {
    let app: AppModel
    @Bindable var nav: Navigation
    /// A new library folder is one restart, which may be waiting for a job;
    /// the wait is said at the foot, where he sees it from every page.
    let restarter: EngineRestart

    public init(app: AppModel, restarter: EngineRestart = .shared) {
        self.app = app
        self.nav = app.navigation
        self.restarter = restarter
    }

    public var body: some View {
        ScrollViewReader { proxy in
            list
                // Once the rows are there to scroll to: the shoot can be
                // reopened before the list has been read.
                .task(id: app.library.loaded ? nav.revealed : nil) {
                    // The shoot he left off in, brought into view once at
                    // launch. No animation: it is where the sidebar opens.
                    // Then forgotten: a task runs again every time its view
                    // appears, and the light table hides and shows this
                    // column by window width, which would scroll back to the
                    // launch shoot while he is in another.
                    if let s = nav.revealed {
                        proxy.scrollTo(s, anchor: .center)
                        nav.didReveal()
                    }
                }
                // The shoot he is in is never inside a collapsed section: one
                // opened from All Shoots, from a notification, or marked
                // finished while he is in it would otherwise be selected and
                // out of sight.
                .onChange(of: selectedIsFinished, initial: true) { _, finished in
                    if finished { nav.finishedExpanded = true }
                }
        }
        // On the column's own root view: inside the reader the split view
        // never saw it, and the sidebar fell to its narrowest.
        .navigationSplitViewColumnWidth(min: Tokens.Metric.sidebarMin,
                                        ideal: Tokens.Metric.sidebarDefault,
                                        max: Tokens.Metric.sidebarMax)
        .accessibilityIdentifier("sidebar")
    }

    private var finishedOpen: Binding<Bool> {
        let lib = app.library
        return Binding(get: { nav.finishedOpen(nothingInProgress: lib.inProgress.isEmpty && lib.broken.isEmpty) },
                       set: { nav.chooseFinished($0) })
    }

    /// Nothing highlighted while the engine starts: All Shoots lit up and
    /// then jumped to his shoot. A click he makes meanwhile is his, and wins.
    private var shownSelection: Binding<SidebarSelection?> {
        Binding(get: { app.isReady ? nav.selection : nil },
                set: { new in Self.choose(new, in: app, byKey: NSApp.currentEvent?.type == .keyDown) })
    }

    /// A row chosen in the list. A click on a shoot's row opens the step he
    /// was last on in it (`AppModel.open(shoot:)`), not a page of numbers
    /// with nothing to press. A key moving through the list — an arrow, or
    /// type-select — rests on the shoot's own row as it always did: sent the
    /// same way, every shoot passed on the way down opened its step page,
    /// which may be Reels walking every export folder, Edit watching for
    /// exports or the light table taking the keyboard, and the list could no
    /// longer rest on a shoot at all. Return on the row then opens its step
    /// (`openChosenShoot`), as it does in All Shoots.
    static func choose(_ new: SidebarSelection?, in app: AppModel, byKey: Bool) {
        if case .shoot(let shoot)? = new, !byKey { app.open(shoot: shoot) } else { app.navigation.selection = new }
    }

    /// Return on a shoot's own row: where he was in it, or the step it is up
    /// to. Whether there was a shoot's row to open.
    @discardableResult
    static func openChosenShoot(in app: AppModel) -> Bool {
        guard case .shoot(let shoot)? = app.navigation.selection else { return false }
        app.navigation.selection = app.place(in: shoot)
        return true
    }

    private var cardForEject: String? { Self.cardForEject(nav.selection, cards: app.library.cards) }

    /// The card ⌘E ejects (`CommandHost`): the one whose page is on screen,
    /// else the first. The row's eject button is on that card alone.
    static func cardForEject(_ selection: SidebarSelection?, cards: [String]) -> String? {
        if case .card(let c) = selection, cards.contains(c) { return c }
        return cards.first
    }

    private var selectedIsFinished: Bool {
        guard let shoot = nav.shoot else { return false }
        return app.library.finished.contains { $0.name == shoot }
    }

    private var list: some View {
        let lib = app.library
        return List(selection: shownSelection) {
            Section(Strings.Library.library) {
                Label(Strings.Library.allShoots, systemImage: Symbols.allShoots)
                    .tag(SidebarSelection.allShoots)
                Label(Strings.Library.learned, systemImage: Symbols.learned)
                    .tag(SidebarSelection.learned)
                Label(Strings.Library.storage, systemImage: Symbols.storage)
                    .tag(SidebarSelection.storage)
            }

            if !lib.cards.isEmpty {
                Section(Strings.Library.memoryCard) {
                    ForEach(lib.cards, id: \.self) { card in
                        CardSidebarRow(app: app, path: card, ejectsThisOne: card == cardForEject)
                            .tag(SidebarSelection.card(card))
                    }
                }
            }

            // A heading over nothing says nothing: with every shoot finished
            // the section is left out, as Finished is when it is empty.
            if !lib.inProgress.isEmpty || !lib.broken.isEmpty {
                Section(Strings.Library.inProgress) {
                    ForEach(lib.inProgress) { row in
                        shootRow(row, symbol: Symbols.shootInProgress)
                    }
                    ForEach(lib.broken) { row in
                        BrokenSidebarRow(row: row)
                            .tag(SidebarSelection.shoot(row.name))
                            .contextMenu { BrokenShootContextMenu(row: row) }
                    }
                }
            }
            // An empty library says so in one line. The sentence, the folder
            // and the button are the page's (`EmptyLibrary`), which has the
            // room: here they were five lines at 220 pt, the path broken
            // over two, saying "put a memory card in" under the card.
            if lib.isEmpty {
                Text(Strings.Library.empty)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
                    .accessibilityIdentifier("sidebar.empty")
            }

            if !lib.finished.isEmpty {
                Section(isExpanded: finishedOpen) {
                    ForEach(lib.finished) { row in
                        shootRow(row, symbol: Symbols.shootFinished)
                    }
                } header: {
                    // The count says what a closed section holds. Beside
                    // the heading, as Up Next carries its own: the trailing
                    // edge is where the section's hover chevron appears.
                    HStack(spacing: 6) {
                        Text(Strings.Library.finished)
                        Text("\(lib.finished.count)").monospacedDigit().foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, .medium)
        .onKeyPress(.return) { Self.openChosenShoot(in: app) ? .handled : .ignored }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                // What the library's own commands were refused — Show the
                // Shoot in Finder, Eject — once the list is up. They are
                // library-wide, so this is where they land; before, they were
                // written where nothing drew them and the menu item simply
                // did nothing.
                if lib.loaded, let why = lib.refusals[.library] {
                    RefusalRow(why, owner: .library)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A new library folder waiting for a job to end. It was said
                // only in Settings ▸ General, so with Settings closed the
                // engine restarted on another library with no warning.
                if let waiting = restarter.waiting {
                    // Don't Wait under the sentence, lined up with its words.
                    // No fixedSize here: inside the split view's column it
                    // left the whole window undrawn.
                    Label {
                        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
                            Text(waiting.sentence(current: nil))
                                .foregroundStyle(.secondary)
                            Button(Strings.Settings.dontWait) { restarter.cancelWaiting() }
                                .controlSize(.small)
                        }
                    } icon: {
                        Image(systemName: Symbols.restartWaiting).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("sidebar.restartWaiting")
                }
                if let footer = app.updates.footer {
                    // The › is a promise: it opens the update sheet (§7.9).
                    Button { Task { await app.updates.show() } } label: {
                        Label(footer, systemImage: Symbols.update)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func shootRow(_ row: ShootRowOK, symbol: String) -> some View {
        let expanded = Binding<Bool>(
            get: { nav.expandedShoot == row.name },
            set: { open in nav.expandedShoot = open ? row.name : (nav.expandedShoot == row.name ? nil : nav.expandedShoot) }
        )
        DisclosureGroup(isExpanded: expanded) {
            ForEach(steps(for: row)) { step in
                StepSidebarRow(step: step, row: row, bursts: step.id == "keepers" ? app.bursts(for: row.name) : nil)
                    .tag(SidebarSelection.step(shoot: row.name, step: step.id))
            }
        } label: {
            ShootSidebarRow(row: row, symbol: symbol)
                .tag(SidebarSelection.shoot(row.name))
                .contextMenu { ShootContextMenu(app: app, row: row) }
        }
        .id(row.name)
    }

    /// The shoot's steps (`AppModel.steps(of:)`: the open session's, the
    /// engine's on the row, or the fixed vocabulary with no done-ness
    /// claimed), each done as the library's row last said.
    private func steps(for row: ShootRowOK) -> [StepState] {
        Self.steps(app.steps(of: row.name), doneAsOf: row)
    }

    /// Whether each step is done, from the library's row where it says: the
    /// row is read again at every N, at the end of every job and on leaving
    /// a step, where the open session is read when the shoot is opened, so a
    /// check would otherwise wait for a reload that nothing asked for.
    static func steps(_ steps: [StepState], doneAsOf row: ShootRowOK) -> [StepState] {
        guard let told = row.steps else { return steps }
        let done = Dictionary(told.map { ($0.id, $0.done) }, uniquingKeysWith: { a, _ in a })
        return steps.map { s in
            guard let d = done[s.id], d != s.done else { return s }
            return StepState(id: s.id, label: s.label, done: d, enabled: s.enabled,
                             why_disabled: s.why_disabled, source: s.source)
        }
    }
}

struct ShootSidebarRow: View {
    let row: ShootRowOK
    let symbol: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1)
                subtitle
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: symbol).symbolRenderingMode(.hierarchical)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shoot.\(row.name)")
    }

    /// His number, green — never the cull's, never a sum. A copy that stopped
    /// part way says so instead: "412 frames" read like a whole night. One
    /// still going says that, with no count: the row is read again only when
    /// the library is, and a count from then is not where the copy is now.
    @ViewBuilder private var subtitle: some View {
        if case .copying = row.ingest {
            Text(Strings.Library.copying)
        } else if case .stopped(let files, let of) = row.ingest {
            Text(Strings.Library.copyStopped(files, of)).monospacedDigit()
        } else if row.kept > 0 {
            HStack(spacing: 0) {
                Text(Strings.Library.frames(row.frames))
                Text(" · ")
                Text(Strings.Library.kept(row.kept)).foregroundStyle(Tokens.Palette.kept)
            }
            .monospacedDigit()
        } else {
            Text(Strings.Library.frames(row.frames)).monospacedDigit()
        }
    }
}

/// A step under its shoot: its name, and at the trailing edge what is left —
/// on Choose Keepers the bursts been through, until it is done — or a check
/// once the engine says the step is done (DESIGN.md §2.1). Every row looked
/// the same done or not, so "what is left" meant opening steps to find out.
struct StepSidebarRow: View {
    let step: StepState
    let row: ShootRowOK
    /// Been through, of how many: live from the open session (`AppModel.bursts`).
    var bursts: (seen: Int, of: Int)?

    var body: some View {
        // The step's name first, the count only where it fits beside it.
        // "288/288" cut "Choose keepers" to "Choose keep…" in the 240 pt
        // sidebar, and the name is what he is looking for in the list; the
        // count is also in the window's subtitle and stays in the row's help
        // and its spoken value.
        //
        // The middle form, with the count 4 pt from the name rather than 8,
        // is for the row he is on: selected, its name is drawn heavier, and
        // at the 240 pt default those few points dropped the count from
        // exactly the row he was looking at while every other row kept it.
        ViewThatFits(in: .horizontal) {
            row(withCount: true)
            row(withCount: true, tight: true)
            row(withCount: false)
        }
        .foregroundStyle(step.enabled ? .primary : .secondary)
        .accessibilityValue(spoken)
        .help(step.enabled ? spoken : (step.why_disabled?.asSentence ?? Strings.Steps.notYet))
        .accessibilityHint(step.enabled ? "" : (step.why_disabled?.asSentence ?? Strings.Steps.notYet))
        .accessibilityIdentifier("step.\(row.name).\(step.id)")
    }

    private var spokenCount: String? {
        guard step.id == "keepers", let b = bursts, b.of > 0 else { return nil }
        return Strings.Overview.burstsOf(b.seen, b.of)
    }

    /// Done, and on Choose Keepers the count, in the help and to VoiceOver.
    var spoken: String {
        [step.done ? Strings.Library.stepDone : nil, spokenCount].compactMap { $0 }.joined(separator: ", ")
    }

    /// Choose Keepers counts until it is done; a done step has its check.
    var count: String? {
        guard !step.done, step.id == "keepers", let b = bursts, b.of > 0 else { return nil }
        return "\(b.seen)/\(b.of)"
    }

    private func row(withCount: Bool, tight: Bool = false) -> some View {
        HStack(spacing: tight ? Tokens.Metric.labelValueGap : Tokens.Metric.relatedGap) {
            Label(step.label, systemImage: Symbols.step(step.id))
                .symbolRenderingMode(.hierarchical)
                .lineLimit(1)
                .fixedSize(horizontal: withCount, vertical: false)
            Spacer(minLength: 0)
            if withCount, let count {
                Text(count)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else if withCount, step.done {
                Image(systemName: Symbols.stepIsDone)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if step.source == .extensionProvided {
                Image(systemName: Symbols.extensionStep)
                    .opacity(0.6)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A mounted card: its name, and — on hover, or while its page is open — the
/// eject that ⌘E runs (DESIGN.md §2.1). Ejecting meant knowing ⌘E.
///
/// Only on the card ⌘E means, and not while a copy is running off the card
/// or waiting its turn on the list: the button is File ▸ Eject the Memory
/// Card, which is greyed then, and an eject button that did nothing would be
/// worse than none.
struct CardSidebarRow: View {
    let app: AppModel
    let path: String
    let ejectsThisOne: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Tokens.Metric.relatedGap) {
            Label(CardWatcher.volumeName(path), systemImage: Symbols.memoryCard)
                .lineLimit(1)
            Spacer(minLength: 0)
            if canEject, hovering || app.navigation.selection == .card(path) {
                Button {
                    _ = CommandCenter.shared.run(CommandTable.ID.eject)
                } label: {
                    Image(systemName: Symbols.eject)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(Words.File.eject)
                .accessibilityLabel(Words.File.eject)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if canEject {
                Button(Words.File.eject) { _ = CommandCenter.shared.run(CommandTable.ID.eject) }
            }
        }
    }

    private var canEject: Bool {
        ejectsThisOne && !CardWatcher.copyNeedsTheCard(job: app.jobs.job, running: app.jobs.isRunning,
                                                       waiting: Queues.state.waiting)
    }
}

/// A red row with the engine's own sentence and the offending path.
struct BrokenSidebarRow: View {
    let row: ShootRowBroken

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1)
                Text(row.broken).font(.subheadline).lineLimit(2)
            }
        } icon: {
            Image(systemName: Symbols.brokenShoot)
        }
        .foregroundStyle(Tokens.Palette.alarm)
        .help(row.broken_file ?? row.path)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shoot.\(row.name)")
    }
}

extension Symbols {
    /// Beside a step the engine says is done, in the count's place.
    static let stepIsDone = "checkmark.circle.fill"
}

extension StepState {
    /// A base step under the app's own name for it (DESIGN.md §2.4), unless
    /// the extension names it; an extension's own step under its own label.
    ///
    /// The engine sends labels of its own for the seven base steps, in
    /// sentence case and with Finish called "Done", and the app showed them
    /// once a shoot was open and its own before: the last step changed name
    /// the moment he opened a shoot, the Go menu mixed "Choose keepers" into
    /// Title Case items, and "Done" in the menu was not what the Keyboard
    /// Shortcuts window called ⌘7. Every screen reads `ShootSession.steps`,
    /// so naming them once there names them everywhere.
    @MainActor func namedByTheApp(_ ext: ExtConfig?) -> StepState {
        guard source == .base else { return self }
        let name = ext?.labels[id] ?? Fallbacks.baseLabel(id)
        guard name != label else { return self }
        return StepState(id: id, label: name, done: done, enabled: enabled,
                         why_disabled: why_disabled, source: source)
    }
}

extension Fallbacks {
    /// The same list, from a sidebar row, before the shoot has been opened.
    public static func listSteps(canCutReels: Bool, ext: ExtConfig?) -> [StepState] {
        let info = try? ShootInfo(fields: Fields([
            "name": .string(""), "path": .string(""), "can_cut_reels": .bool(canCutReels),
        ]))
        return info.map { listSteps($0, ext) } ?? []
    }
}
