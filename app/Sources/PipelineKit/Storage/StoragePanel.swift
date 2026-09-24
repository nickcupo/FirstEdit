import SwiftUI

/// §2.8 — the storage panel, which lives on Finish.
///
/// Three things are load-bearing here.
///
/// 1. **Every sentence, glyph pair, count and order is the engine's.** The
///    app renders them; it does not recompute them. They encode invariants
///    this side must not re-derive, and DESIGN.md §3.9 says so deliberately.
/// 2. **The frequent actions come first, together.** Then a rule, then 32 pt
///    of clear space, then the group that removes things. Today the
///    destructive control sits 12 px above the button he presses at the end
///    of nearly every shoot (FLOW-06).
/// 3. **No destructive action has a keyboard shortcut**, is in a toolbar, or
///    is ever the default button. The Delete key is bound to nothing here or
///    anywhere else.
public struct StoragePanel: View {
    let shoot: String
    @State private var model: StorageModel
    @State private var sheet: PanelAction?
    @State private var retention: Int = 0
    @State private var retentionAsDefault = false
    /// Whether he came here from the library's Storage page to deal with
    /// this shoot's storage, so the panel brings itself into view.
    @State private var arrived = false

    /// Every action on the panel that shows the engine's list first, and
    /// where each one sits on the ladder. `rung` is `nil` for the two that
    /// take nothing away: they are planned like everything else, and they are
    /// not on the ladder, so they carry none of its weight.
    enum PanelAction: String, Identifiable, Hashable {
        case push, pull, reclaim, drop, expire
        var id: String { rawValue }
        var what: String { rawValue }

        var rung: Rung? {
            switch self {
            case .push, .pull: return nil
            case .reclaim, .drop: return .removesACopy
            case .expire: return .deletesPhotographs
            }
        }
    }

    public init(shoot: String, client: StudioClient?) {
        self.shoot = shoot
        _model = State(initialValue: StorageModel(shoot: shoot, client: client))
    }

    /// For the harness and the tests.
    public init(model: StorageModel) {
        self.shoot = model.shoot
        _model = State(initialValue: model)
    }

    public var body: some View {
        Form {
            // The job this panel started, first: while it runs, and once when
            // it ends. The panel is read again the moment it stops.
            if model.isFollowing || model.ended != nil {
                Section { StorageJobRow(model: model) }
            }
            if let b = model.busy[.storage], let m = model.refusals[.storage] {
                Section {
                    BusyNotice(sentence: m, busy: b,
                               stopTheOther: { Task { await model.stopTheJobInTheWay() } })
                }
            } else if let m = model.refusals[.storage] {
                Section { RefusalRow(m, owner: .storage) }
            }
            // "Check Every Original" starts its job straight off the panel,
            // so the line about the homework standing down belongs here too.
            if let paused = model.paused {
                Section { PausedNote(paused) }
            }
            whereTheyAre
            renderings
            frequentActions
            retentionLock
            removeAndDelete
        }
        .formStyle(.grouped)
        // Not `columnForm()`, as the library pages are: this panel is never a
        // page of its own. It sits inside Finish's scroll view, which already
        // scrolls the whole pane with its scroller at the window's edge, and
        // the geometry reader that holds a library page's column has no
        // height of its own in there — the panel came out a 10 pt sliver
        // under the exports card, with every button gone.
        .frame(maxWidth: Tokens.Metric.column)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            RevealMarker(armed: arrived && model.storage != nil).frame(height: 1)
        }
        .onAppear { arrived = StorageArrival.take(shoot) }
        .task {
            await model.load()
            retention = model.storage?.retain.days ?? 0
            retentionAsDefault = model.storage?.retain.isLibraryDefault ?? false
            // A job it started before he left the page is still his to see.
            await model.adoptRunningJob()
        }
        // Follows the one job it started, by number, and reads the panel
        // again when that job stops. Cancelled with the page.
        .task(id: model.followingID) { await model.follow() }
        .sheet(item: $sheet) { action in
            if action == .expire {
                ExpireSheet(shoot: shoot, model: model) { sheet = nil }
            } else {
                PlanSheet(rung: action.rung, request: StorageModel.Request(action.what),
                          model: model) { sheet = nil }
            }
        }
        .accessibilityIdentifier("storage.panel")
        // Shoot ▸ Storage is these buttons, pressed from the menu: each opens
        // the same list first, and Check Every Original starts the same check
        // (DESIGN.md §2.12).
        .answersMenu(Self.menuRows.map(\.0), shoot: shoot) { id, _ in
            guard let action = Self.menuRows.first(where: { $0.0 == id })?.1 else {
                Task { _ = await model.checkEveryOriginal() }
                return
            }
            sheet = action
        }
    }

    /// Shoot ▸ Storage, row by row; `nil` is Check Every Original, which has
    /// no list to show.
    static let menuRows: [(CommandID, PanelAction?)] = [
        (CommandTable.ID.copyUp, .push), (CommandTable.ID.bringBack, .pull),
        (CommandTable.ID.checkEvery, nil), (CommandTable.ID.takeBackCache, .reclaim),
        (CommandTable.ID.removeLocal, .drop), (CommandTable.ID.letGo, .expire),
    ]

    // MARK: where they are

    @ViewBuilder private var whereTheyAre: some View {
        Section(Strings.Storage.whereTheyAre) {
            if let s = model.storage {
                Text(s.line)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("storage.line")
                // In the engine's order, and only the states it has frames in.
                ForEach(s.presentStates, id: \.self) { state in
                    StateRow(count: s.states[state] ?? 0,
                             cells: s.glyphs[state] ?? [],
                             words: s.words[state] ?? state)
                }
                // A frame recorded as archived and found nowhere is the one
                // alarm on this panel, and it used to stop at the alarm. The
                // one thing on the panel that names which frames, and says
                // whether anything else changed, is Check Every Original.
                if (s.states["missing"] ?? 0) > 0 {
                    Text(Strings.Storage.missingNext)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("storage.missingNext")
                }
                LabeledContent(Strings.Storage.free) { Text(s.free_text).countStyle() }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
    }

    /// One noun for these bytes everywhere he meets them — the cache — and
    /// one figure for what the button would take: the engine's `bytes_text`,
    /// the same number the button and its sheet carry. The row beside the
    /// button used to say "Can be made again 10.0 GB", which is true and is
    /// not what it takes; he pressed it expecting 10 GB and was offered
    /// 840 KB.
    @ViewBuilder private var renderings: some View {
        if let c = model.storage?.cache {
            Section(Strings.Storage.cacheHeading) {
                LabeledContent(Strings.Storage.derived) { Text(c.derived_text).countStyle() }
                LabeledContent(Strings.Storage.canTakeBackNow) { Text(c.bytes_text).countStyle() }
                if c.last_copy.count > 0 {
                    Text(Strings.Storage.lastCopyWarning(c.last_copy.count, c.last_copy.bytes_text))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The engine's reasons, under a line that says what they are
                // reasons for. They were bare lower-case footnotes that read
                // as alarms about the photographs rather than as why one
                // button will not run.
                if !c.refusals.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Strings.Storage.cacheRefusedHeading)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(c.refusals.enumerated()), id: \.offset) { _, line in
                            Text(line.capitalizedFirst)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("storage.cacheRefused")
                }
                FrameByFrameTable(model: model)
            }
        }
    }

    // MARK: the frequent actions, first

    private var frequentActions: some View {
        Section {
            // Two rows of two, not one row of four: at the 680 pt column the
            // four side by side are 704 pt and the outer two lose their last
            // words to an ellipsis.
            Grid(alignment: .leading, horizontalSpacing: Tokens.Metric.relatedGap,
                 verticalSpacing: Tokens.Metric.relatedGap) {
                GridRow {
                    actionButton(.push, Strings.Storage.push)
                    actionButton(.pull, Strings.Storage.pull)
                }
                GridRow {
                    Button(Strings.Storage.check) {
                        Task { _ = await model.checkEveryOriginal() }
                    }
                    .disabled(model.isFollowing)
                    .help(model.isFollowing ? Strings.Storage.waitForTheJob : "")
                    actionButton(.reclaim, Strings.Storage.reclaim)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("storage.frequent")
            reasons([(.push, Strings.Storage.push), (.pull, Strings.Storage.pull),
                     (.reclaim, Strings.Storage.reclaim)])
        }
    }

    // MARK: a button that can do nothing says why

    private var gate: StorageActionGate? { model.storage.map(StorageActionGate.init) }

    /// Off, with its reason in its help and under the group, when the
    /// engine's own counts say it would do nothing; carrying the engine's
    /// figure for what it would move when it would.
    private func actionButton(_ action: PanelAction, _ name: String) -> some View {
        let why = gate?.reason(action)
        return Button(Strings.Storage.sized(name, gate?.size(action) ?? "")) { sheet = action }
            .disabled(model.isFollowing || why != nil)
            .help(model.isFollowing ? Strings.Storage.waitForTheJob : (why ?? ""))
            .accessibilityHint(why ?? "")
            .accessibilityIdentifier("storage.action.\(action.rawValue)")
    }

    /// Each button that is off, and why, in the order the buttons are drawn.
    @ViewBuilder private func reasons(_ actions: [(PanelAction, String)]) -> some View {
        let lines = model.isFollowing ? [] : actions.compactMap { a, name in
            gate?.reason(a).map { Strings.Storage.why(name, $0) }
        }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("storage.reasons")
        }
    }

    /// A lock, not a trigger. Nothing on this machine is scheduled by writing
    /// it, and the sentence under it says so.
    @ViewBuilder private var retentionLock: some View {
        if let r = model.storage?.retain {
            Section {
                LabeledContent(Strings.Storage.retention) {
                    HStack(spacing: Tokens.Metric.relatedGap) {
                        TextField("", value: $retention, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .monospacedDigit()
                            .accessibilityLabel(Strings.Storage.retention)
                            .accessibilityIdentifier("storage.retentionDays")
                        Text(Strings.Storage.daysWord(retention)).foregroundStyle(.secondary)
                    }
                }
                Toggle(Strings.Storage.useAsDefault, isOn: $retentionAsDefault)
                    .toggleStyle(.checkbox)
                Text(Strings.Storage.retentionIsALock)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onChange(of: retention) { _, days in
                guard days != r.days, days >= 0 else { return }
                Task { await model.setRetention(days: days, asDefault: retentionAsDefault) }
            }
            // Ticking it is the whole act: the number on screen becomes what
            // new shoots get. It used to send nothing until the number was
            // changed afterwards, and it came back unticked on every visit.
            // Unticking takes nothing back — new shoots keep the number they
            // were given — so it sends nothing.
            .onChange(of: retentionAsDefault) { _, ticked in
                guard ticked, !r.isLibraryDefault, retention >= 0 else { return }
                Task { await model.setRetention(days: retention, asDefault: true) }
            }
        }
    }

    // MARK: the group below the rule

    /// Its own group, below a rule, with 32 pt of clear space above it. No
    /// shortcut, no toolbar, no default button, and both labels end in an
    /// ellipsis because a plan comes before anything happens.
    private var removeAndDelete: some View {
        Section {
            // Neither button here is itself destructive: each opens the
            // engine's own list first, which is what the ellipsis says. The
            // red is on the button inside that sheet, where the consequence
            // is written out.
            HStack(spacing: Tokens.Metric.groupGap) {
                actionButton(.drop, Strings.Storage.drop)
                actionButton(.expire, Strings.Storage.expire)
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            reasons([(.drop, Strings.Storage.drop), (.expire, Strings.Storage.expire)])
            Text(Strings.Storage.neverDeletesFolder)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                Text(Strings.Storage.destructiveGroup)
                    .padding(.top, Tokens.Metric.destructiveClearance)
            }
        }
        .accessibilityIdentifier("storage.removeAndDelete")
    }
}
