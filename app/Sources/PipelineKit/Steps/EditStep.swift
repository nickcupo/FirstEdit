import SwiftUI

/// Edit in PhotoLab (DESIGN.md §2.6).
///
/// A list with symbols, not prose: three facts, each with the place it is and
/// a way to see it. The export count is live — a file-system watcher on the
/// export folder rings the bell and the engine answers with the number,
/// because exports are found in three places and only the engine looks in all
/// of them.
///
/// Open is never the first thing to press while the presets are not on disk.
/// PhotoLab keeps its own record of a folder it has opened, so presets written
/// a minute later do not show — the trap the page's own footnote describes.
/// Without presets the primary writes them first and opens after; while they
/// are being written it opens when they are; opening without them is a
/// deliberate second button.
public struct EditStep: StepView {
    @Bindable var model: StepsModel
    let session: ShootSession
    @State private var refusal: String?
    @FocusState private var focusFirst: Bool

    public init(session: ShootSession, client: StudioClient, pump: ImagePump) {
        self.session = session
        let m = StepsModelStore.shared.model(for: session, jobs: StepJobs.model(client: client))
        _model = Bindable(wrappedValue: m)
    }

    /// The editor the presets are written for: the shoot's own once it has
    /// one, else the one he chose in Settings or on the first-run sheet.
    private var editorID: String { model.editor }
    private var editorName: String { Editors.name(editorID) }
    private var keepers: Int { model.split.willBeEdited }
    private var written: Bool { session.info.presets > 0 && session.info.sidecars > 0 }
    /// The presets of this shoot are being written now, or wait their turn.
    private var writing: Bool { model.presetsJob.mine != nil || model.presetsJob.isQueued }

    private enum Primary { case open, openWhenWritten, waitingToOpen, writeThenOpen }
    private var primary: Primary {
        if writing { return model.openWhenWritten ? .waitingToOpen : .openWhenWritten }
        return written ? .open : .writeThenOpen
    }

    public var body: some View {
        StepScaffold(title: Strings.Edit.titleIn(editorName),
                     blurb: keepers == 0 ? nil : Strings.Edit.blurb(keepers, editor: editorName)) {
            if keepers == 0 {
                ContentUnavailableView(Strings.Edit.nothingToOpen, systemImage: Symbols.stepEdit)
                    .frame(maxWidth: .infinity)
            } else {
                list
            }
        } action: {
            StepActionBar {
                leading
            } box: {
                Button(primaryTitle) { pressPrimary() }
                    .primaryActionStyle()
                    .disabled(primaryDisabled)
                    .keyboardShortcut(.defaultAction)
                    .focused($focusFirst)
            }
        }
        // No copy of the primary in the toolbar (§2.3): ⇧⌘E is Shoot ▸ Open
        // My Keepers, answered below, and Return is the box's.
        // Shoot ▸ Open My Keepers in PhotoLab (⇧⌘E) is this button, from
        // any page (DESIGN.md §2.12) - while the button opens, now or once
        // the presets being written are on disk. With none written it writes
        // them first, and a row named Open must not start that; the row is
        // grey then (`CommandHost`).
        .answersMenu([CommandTable.ID.openInEditor], shoot: session.name) { _, _ in
            // The sidebar row may have been read before the presets changed.
            // Say why that accepted press cannot open, instead of losing it.
            guard toolbarKey != nil else {
                if primary == .writeThenOpen { model.openRefusal = Strings.Edit.presetsNotWritten(editorName) }
                return
            }
            guard !primaryDisabled else { return }
            pressPrimary()
        }
        .task {
            model.watchExports()
            focusFirst = true
        }
        // The presets job ending while he is here: the page reads the shoot
        // again, so the first row ticks without leaving the shoot, and opens
        // the editor if that is what he asked for.
        .onChange(of: model.presetsJob.mine != nil) { was, now in
            if was && !now { presetsEnded() }
        }
        .onDisappear {
            model.stopWatchingExports()
            // A request is his and must not fire at a screen he has left.
            model.openWhenWritten = false
        }
    }

    @ViewBuilder private var list: some View {
        Form {
            Section {
                presetsRow
                StepPathRow(Strings.Edit.folderOfThose, session.info.path + "/edit",
                            what: "edit", open: { open($0) })
                StepRow(Symbols.stepEdit, Strings.Edit.exportedSoFar(model.exported, of: keepers),
                        done: model.exported >= keepers && keepers > 0)
                exportRows
            }
            Section {
                StepNote(Strings.Edit.noPreset)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        // The scaffold already holds the page to its column; the form fills
        // that, so one narrow row cannot pull every section in with it.
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var presetsRow: some View {
        if writing {
            StepRow(Symbols.stepPresets, Strings.Edit.presetsBeingWritten(keepers))
        } else if written {
            StepRow(Symbols.stepPresets, Strings.Edit.keepersWithPresets(keepers), done: true)
        } else {
            StepRow(Symbols.stepPresets, Strings.Edit.noPresetsYet(keepers))
        }
    }

    /// Every folder inside the shoot the engine found exports in, each with
    /// its own Show. Before there are any, where they will be looked for, with
    /// no Show: there is nothing to show yet.
    @ViewBuilder private var exportRows: some View {
        let dirs = session.info.export_dirs
        if dirs.isEmpty {
            LabeledContent(Strings.Edit.exportsGoTo) {
                PathRow(URL(fileURLWithPath: exportPath))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ForEach(dirs, id: \.self) { dir in
                StepPathRow(StepPathRow.exportLabel(dir, shoot: session.info.path, among: dirs.count),
                            dir, what: "exported") { _ in
                    open("exported", path: dir)
                }
            }
        }
    }

    private var exportPath: String {
        session.info.export.isEmpty ? session.info.path + "/export" : session.info.export
    }

    @ViewBuilder private var leading: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            if let refusal = refusal ?? model.openRefusal { RefusalRow(refusal, owner: .navigation) }
            if let j = model.presetsJob.mine {
                // How far the presets have got, in the engine's words, and
                // how long they have left: the box beside this holds a
                // button, not the job's bar.
                Text([j.label.capitalizedFirst, JobTiming(j).text].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if primary == .waitingToOpen {
                Text(Strings.Edit.opensWhenWritten(editorName)).font(.callout).foregroundStyle(.secondary)
            }
            if let note = model.openNote {
                Text(note).font(.callout).foregroundStyle(.secondary)
            } else if let at = model.openedAt, refusal == nil, model.openRefusal == nil {
                Text(Strings.Edit.opened(editorName, at: at)).font(.callout).foregroundStyle(.secondary)
            }
            // Once there is something exported, the way on, as the Presets
            // page has its way on to here.
            if model.exported > 0, primary == .open {
                StepLink(Strings.Edit.continueToFinish) { StepSlots.showStep?(session.name, "done") }
            }
            if keepers > 0, primary != .open {
                Button(Strings.Edit.openWithoutPresets) {
                    model.openWhenWritten = false
                    open("photolab")
                }
                .buttonStyle(.link)
                .font(.callout)
                .disabled(model.buildingEditFolder)
            }
        }
    }

    // MARK: - the primary

    private var primaryTitle: String {
        if model.buildingEditFolder { return Strings.Edit.building }
        switch primary {
        case .open: return Strings.Edit.openIn(editorName)
        case .openWhenWritten: return Strings.Edit.openWhenWritten
        case .waitingToOpen: return Strings.Edit.waitingToOpen
        case .writeThenOpen: return Strings.Edit.writeThenOpen
        }
    }

    /// ⇧⌘E is Open My Keepers, in the Shoot menu and the Keyboard Shortcuts
    /// window, so the button carries it only while pressing it opens, now or
    /// once the presets being written are on disk (§2.12: a key belongs to
    /// one action). With no presets the button writes them first — about two
    /// minutes of work — and a key pressed from habit under the name Open
    /// started it; that is left to the button, and Return on the page's own.
    private var toolbarKey: KeyboardShortcut? {
        switch primary {
        case .open, .openWhenWritten: return KeyboardShortcut("e", modifiers: [.command, .shift])
        case .waitingToOpen, .writeThenOpen: return nil
        }
    }

    private var primaryDisabled: Bool {
        keepers == 0 || model.buildingEditFolder || primary == .waitingToOpen
    }

    private func pressPrimary() {
        switch primary {
        case .open: open("photolab")
        case .openWhenWritten: model.openWhenWritten = true
        case .waitingToOpen: break
        case .writeThenOpen:
            refusal = nil
            model.openWhenWritten = true
            model.writePresets(force: false)
        }
    }

    /// The presets job has ended, however it ended.
    private func presetsEnded() {
        let name = session.name
        Task { @MainActor in
            try? await session.reload(ext: nil)
            guard model.openWhenWritten else { return }
            model.openWhenWritten = false
            let outcome = model.jobs.history.last(where: { $0.job.kind == "presets" && $0.job.shoot == name })?.outcome
            switch outcome {
            case .stopped?, .failed?, .refused?:
                refusal = Strings.Edit.presetsNotWritten(editorName)
            default:
                if written { open("photolab") } else { refusal = Strings.Edit.presetsNotWritten(editorName) }
            }
        }
    }

    // MARK: - asking the engine

    /// Asks the engine to open it. A button that says it will show a folder
    /// must never create one (DESIGN.md §7.10), and the engine is the only
    /// thing that knows which folder this shoot's exports are really in. The
    /// keepers in the editor are the model's (`openKeepers`), which the
    /// Presets page's Return opens as well.
    private func open(_ what: String, path: String? = nil) {
        refusal = nil
        guard what != "photolab" else {
            model.openKeepers()
            return
        }
        model.openRefusal = nil
        model.openNote = nil
        let client = session.client
        let name = session.name
        let body = OpenBody(name: name, what: what, path: path)
        Task { @MainActor in
            do {
                let r = try await client.post(Routes.open, body)
                if let e = r.error, !r.ok {
                    refusal = e
                } else {
                    model.openNote = r.note
                    if let light = try? await client.get(Routes.shootLight(name)) {
                        model.noteExported(light.info.exported)
                    }
                }
            } catch let e as StudioError {
                refusal = e.sentence
            } catch {
                refusal = Strings.API.offline
            }
        }
    }
}
