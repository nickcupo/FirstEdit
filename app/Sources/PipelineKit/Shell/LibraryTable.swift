import SwiftUI

/// All Shoots: a real `Table`, one row a shoot, in the engine's order.
///
/// The two authors are two columns under two names. Where a shoot's photographs
/// are is the engine's own phrase, not a figure worked out here.
struct LibraryTable: View {
    let app: AppModel
    @State private var selection: ShootRowOK.ID?

    var body: some View {
        let lib = app.library
        Group {
            if !lib.loaded, let why = lib.refusals[.library] {
                // The list could not be read. It said "Looking for your
                // shoots…" with a spinner, forever, with the engine's sentence
                // held where nothing drew it. Laid out as the engine-down page
                // and the empty library are, centred with its one action under
                // it, rather than a red line and a button stuck in the corner
                // of an empty page.
                ContentUnavailableView {
                    Label(Strings.Library.couldNotRead, systemImage: Symbols.refusal)
                } description: {
                    Text(why.asSentence).textSelection(.enabled)
                } actions: {
                    Button(Strings.Library.lookAgain) { Task { await lib.refreshSoon() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .accessibilityIdentifier("refusal.\(RefusalOwner.library.id)")
            } else if !lib.loaded {
                ProgressView(Strings.Library.loading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lib.shoots.isEmpty && lib.broken.isEmpty {
                EmptyLibrary(app: app)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // The widths are what each column's heading and its
                    // widest ordinary cell need, measured at the minimum
                    // window: the ideals add up to what the 644 pt beside the
                    // sidebar leaves once the table's 17 pt between columns
                    // is taken off, so nothing scrolls sideways and no heading
                    // is cut — "The cull put for…" was, when Up to came in.
                    Table(lib.shoots, selection: $selection) {
                        TableColumn(Strings.Overview.shoot) { r in
                            Label(r.name, systemImage: r.finished ? Symbols.shootFinished : Symbols.shootInProgress)
                                .symbolRenderingMode(.hierarchical)
                        }
                        // Room for a dated name whole: beside Up to it was
                        // squeezed to "2026-09-…".
                        .width(min: 102, ideal: 110)
                        // Where each shoot is up to: the question he opens
                        // All Shoots to answer, which no column did.
                        TableColumn(Strings.Library.upTo) { r in
                            UpToCell(row: r, bursts: app.bursts(for: r.name), ext: lib.ext)
                        }
                        .width(min: 100, ideal: 108, max: 220)
                        // Counts line up on their last digit, under a heading
                        // that does too, as Finder's sizes do.
                        TableColumn(Strings.Overview.frames) { r in
                            Text("\(r.frames)").countStyle()
                        }
                        .width(min: 48, ideal: 52, max: 90)
                        .alignment(.numeric)
                        TableColumn(Strings.Overview.youKept) { r in
                            Text("\(r.kept)").countStyle()
                                .foregroundStyle(r.kept > 0 ? Tokens.Palette.kept : .secondary)
                        }
                        .width(min: 52, ideal: 56, max: 90)
                        .alignment(.numeric)
                        TableColumn(Strings.Overview.cullPutForward) { r in
                            Text(r.culled ? "\(r.cull_picks)" : "—").countStyle().foregroundStyle(.secondary)
                        }
                        .width(min: 112, ideal: 120, max: 170)
                        .alignment(.numeric)
                        // The engine's phrase can be longer than the column
                        // at the minimum window ("1157 frames missing"); the
                        // help has it whole.
                        TableColumn(Strings.Overview.where_) { r in
                            Text(r.storage?.phrase ?? "").foregroundStyle(.secondary)
                                .help(r.storage?.phrase ?? "")
                        }
                        .width(min: 72, ideal: 80)
                    }
                    .contextMenu(forSelectionType: ShootRowOK.ID.self) { ids in
                        if let id = ids.first, let row = lib.row(named: id) {
                            ShootContextMenu(app: app, row: row)
                        }
                    } primaryAction: { ids in
                        // Where he was in it, or the step it is up to — the
                        // column beside the name says which.
                        if let id = ids.first { app.open(shoot: id) }
                    }
                    // The row he picked is the shoot the File menu's Show the
                    // Shoot in Finder means; it was private to the table, so
                    // the item stayed grey with a shoot selected.
                    .onChange(of: selection, initial: true) { _, id in app.navigation.shootInFocus = id }
                    .onDisappear { app.navigation.shootInFocus = nil }
                    if !lib.broken.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
                            ForEach(lib.broken) { b in BrokenShootLine(row: b) }
                        }
                        .padding(Tokens.Metric.windowMargin)
                    }
                }
            }
        }
        // No title of its own. The window is titled by `RootView`, which puts
        // the app's name on the first line and the section on the second; a
        // title set here won the first line too and the window read
        // "All Shoots / All Shoots". Learning and Storage never set one.
    }
}

/// All Shoots' "Up to": the first of the shoot's steps the engine says is not
/// done and can be started, by the name the sidebar gives it, and on Choose
/// Keepers how many bursts he has been through, as the sidebar's row counts
/// them. A finished shoot says so. An engine that sent no steps says nothing:
/// done-ness is the engine's, never worked out here.
struct UpToCell: View {
    let row: ShootRowOK
    let bursts: (seen: Int, of: Int)?
    let ext: ExtConfig?

    var body: some View {
        Group {
            if row.finished {
                Text(Strings.Library.finished).foregroundStyle(.secondary)
            } else if let (label, count) = Self.parts(row, bursts: bursts, ext: ext) {
                // The count where it fits beside the name, drawn as the
                // sidebar's row draws it; the name wins, and the count stays
                // in the help.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Tokens.Metric.labelValueGap) {
                        Text(label)
                        if let count {
                            Text(count).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Text(label)
                }
                .help(Self.words(row, bursts: bursts, ext: ext) ?? label)
            } else {
                Text(verbatim: "")
            }
        }
        .lineLimit(1)
    }

    /// The step's name, and on Choose Keepers "140/288 bursts".
    @MainActor static func parts(_ row: ShootRowOK, bursts: (seen: Int, of: Int)?,
                                 ext: ExtConfig?) -> (label: String, count: String?)? {
        guard let next = row.upTo?.namedByTheApp(ext) else { return nil }
        guard next.id == "keepers", let b = bursts, b.of > 0 else { return (next.label, nil) }
        return (next.label, Strings.Library.reviewedBursts(b.seen, b.of))
    }

    /// What the cell says, as one line: its help, and what VoiceOver reads.
    @MainActor static func words(_ row: ShootRowOK, bursts: (seen: Int, of: Int)?, ext: ExtConfig?) -> String? {
        guard let (label, _) = parts(row, bursts: bursts, ext: ext) else { return nil }
        guard let b = bursts, b.of > 0, row.upTo?.id == "keepers" else { return label }
        return Strings.Library.upToBursts(label, b.seen, b.of)
    }
}

extension ShootRowOK {
    /// The step the shoot is up to: the first the engine says is not done
    /// and can be started. `nil` on a finished shoot, and from an engine that
    /// did not send its steps.
    public var upTo: StepState? {
        guard !finished, let steps else { return nil }
        return steps.first { !$0.done && $0.enabled }
    }
}

/// Nothing in the library: with a card in, the one thing to do with it; with
/// none, where the engine looked and the one thing that fixes a wrong folder.
///
/// It said "Put a memory card in" with the card already in the sidebar, in
/// the sidebar too, and its only button was in the 220 pt sidebar, five lines
/// deep with the path broken over two of them.
struct EmptyLibrary: View {
    let app: AppModel
    var restarter: EngineRestart = .shared
    /// What the page says about the folder the engine looked in.
    @State private var looked: Looked?

    var body: some View {
        if let card = app.library.cards.first {
            ContentUnavailableView {
                Label(Strings.EmptyLibrary.cardIsIn(URL(fileURLWithPath: card).lastPathComponent),
                      systemImage: Symbols.memoryCard)
            } description: {
                Text(Strings.EmptyLibrary.copyIt)
            } actions: {
                Button(Fallbacks.baseLabel("ingest")) { app.navigation.selection = .card(card) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("library.copyTheCard")
            }
        } else {
            ContentUnavailableView {
                Label(Strings.Library.empty, systemImage: Symbols.stepIngest)
            } description: {
                // A library he has just started, empty or holding nothing but
                // the `shoots` folder the engine makes, is said as Settings and
                // the welcome pages say it, not as a folder where nothing
                // could be found: picking an empty folder here restarted the
                // engine on it and then described his choice as a failure.
                if let looked, looked.isNew {
                    Text(Strings.Library.newLibrary(looked.shelf.abbreviatedPath))
                        .accessibilityIdentifier("library.newLibrary")
                } else {
                    Text(Strings.Library.emptyWhy)
                    if let looked {
                        Text(Strings.Library.emptyWhere(looked.shelf.abbreviatedPath))
                            + Text(" ") + Text(Strings.Library.emptyLookedFor)
                    }
                }
                if let refused = app.library.refusals[.library] {
                    Text(refused).foregroundStyle(.secondary)
                }
            } actions: {
                Button(Strings.Library.chooseAnotherFolder) { chooseLibrary() }
                    .accessibilityIdentifier("library.chooseLibrary")
            }
            // Looked at again for each engine the app talks to — a new folder
            // is a new engine — and off the main actor: both are directory
            // walks, and they were made in the body, on every redraw.
            .task(id: app.client.map(ObjectIdentifier.init)) {
                looked = await Self.look(app.engineLibrary)
            }
        }
    }

    /// Where the engine looked, and whether it is a library he has just
    /// started.
    struct Looked: Equatable {
        let shelf: URL
        let isNew: Bool
    }

    nonisolated static func look(_ engineLibrary: @escaping @Sendable () -> URL) async -> Looked {
        await Task.detached(priority: .utility) {
            let root = engineLibrary()
            if let started = LibraryFolderPicker.emptyLibrary(root) {
                return Looked(shelf: LibraryFolder.shelf(under: started), isNew: true)
            }
            return Looked(shelf: LibraryFolder.shelf(under: root), isNew: false)
        }.value
    }

    /// The same picker Settings uses, opening on the library in use. A new
    /// folder is a new engine, and it reaches the engine by the one restart,
    /// which asks before it stops a job of his (`EngineRestart`). An empty
    /// folder starts a library; one that holds other things and no shoot is
    /// turned down here in a sentence, where it used to do nothing at all.
    private func chooseLibrary() {
        let root: URL
        switch LibraryFolderPicker.pick(startingAt: app.engineLibrary()) {
        case .chose(let r): root = r.root
        case .empty(let u): root = u
        case .noShoots(let u):
            app.library.refusals.set(.library, Strings.Settings.noShootsHere(u.abbreviatedPath))
            return
        case .cancelled: return
        }
        app.library.refusals.clear(.library)
        Task { await restarter.restart(pointingAt: root) }
    }
}

/// A shoot whose decisions file will not parse: the engine's own sentence, the
/// offending path in muted text, and a way to the file. One bad shoot costs one
/// row (DESIGN.md §7.13).
struct BrokenShootLine: View {
    let row: ShootRowBroken

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            Label(row.name, systemImage: Symbols.brokenShoot)
                .foregroundStyle(Tokens.Palette.alarm)
                .font(.headline)
            // Wrapped by the width it is given, three lines at most, the
            // whole sentence in the help tag. `.fixedSize(vertical:)` here,
            // under a `Table` that takes all the height it is offered, left
            // the split view with no height it could settle on: the whole
            // window drew blank — no table, no sidebar, not this line — which
            // is the one bad shoot costing the whole list (§7.13).
            Text(row.broken)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.broken)
            if let f = row.broken_file {
                HStack(spacing: Tokens.Metric.relatedGap) {
                    Text(f).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button(Strings.Library.showTheFile) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)])
                    }
                    .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
