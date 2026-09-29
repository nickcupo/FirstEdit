import SwiftUI
import AppKit

/// Which editors this app knows how to write for, and where they are.
///
/// The name and the path are found on this Mac so the picker can say where it
/// looked; nothing here changes what is written, which is the engine's job.
public enum Editors {
    public static let ids = ["dxo", "lightroom", "rawtherapee", "darktable"]

    public static func name(_ id: String) -> String {
        switch id {
        case "lightroom": return "Lightroom Classic"
        case "rawtherapee": return "RawTherapee"
        case "darktable": return "darktable"
        default: return "PhotoLab"
        }
    }

    /// Newest first. PhotoLab's identifier carries its major version, and
    /// LaunchServices matches an identifier without regard to case, so
    /// `com.dxo.PhotoLab10` — what 10 really declares — is found by any
    /// spelling. The list stopped at 8, so on a Mac with only 10 the first-run
    /// sheet said "No editor found" and every Presets page said "Not found".
    private static let bundleIDs: [String: [String]] = [
        "dxo": (6...12).reversed().map { "com.dxo.PhotoLab\($0)" } + ["com.dxo.photolab"],
        "lightroom": ["com.adobe.LightroomClassicCC7", "com.adobe.LightroomClassic"],
        "rawtherapee": ["com.rawtherapee.rawtherapee"],
        "darktable": ["org.darktable.darktable"],
    ]

    /// The start of each editor's application name, lower case with the
    /// spaces taken out: DxO names 8 "DxO PhotoLab 8.app" and 10
    /// "DXOPhotoLab10.app", and a prefix typed the first way found neither.
    private static let names: [String: String] = [
        "dxo": "dxophotolab", "lightroom": "adobelightroomclassic",
        "rawtherapee": "rawtherapee", "darktable": "darktable",
    ]

    /// What has been found so far, or nothing. This only reads what an earlier
    /// look put down — asking the disk is `look(for:)`, which is not done on
    /// the main actor, because /Applications is a folder on a disk and a view
    /// body is not a place to wait for one.
    @MainActor public static func location(_ id: String) -> URL? { known.cache[id] ?? nil }

    /// Whether anything has answered for this editor yet. Until it has, the
    /// page says nothing about where the editor is, rather than saying it is
    /// missing on the strength of a lookup that has not happened.
    @MainActor public static func isKnown(_ id: String) -> Bool { known.cache[id] != nil }

    /// Look on the disk, once per launch per editor, off the main actor. The
    /// answer arrives on the main actor and the page redraws with it.
    @MainActor public static func look(for id: String) {
        guard known.cache[id] == nil, known.asking.insert(id).inserted else { return }
        Task.detached(priority: .utility) {
            let found = find(id)
            await MainActor.run {
                known.cache[id] = .some(found)
                known.asking.remove(id)
            }
        }
    }

    /// Whether an application's file name is this editor's, in any of the
    /// spellings its maker has used.
    nonisolated static func isNamed(_ file: String, _ id: String) -> Bool {
        guard let start = names[id] else { return false }
        let n = file.lowercased().replacingOccurrences(of: " ", with: "")
        return n.hasSuffix(".app") && n.hasPrefix(start)
    }

    /// The version a copy of an editor declares, read as numbers so 10 ranks
    /// above 9: "9" sorts after "10" as text, which is how a Mac with both
    /// was once handed the older one (presets.py `photolab_app` keeps the
    /// same rule). The number in the file name stands in when the bundle says
    /// nothing.
    nonisolated static func version(declared: String?, file: String) -> [Int] {
        let from = declared.flatMap { $0.isEmpty ? nil : $0 } ?? file
        return from.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// The newest of the copies found, or nothing.
    nonisolated static func newest(_ copies: [(url: URL, version: [Int])]) -> URL? {
        copies.max { a, b in a.version.lexicographicallyPrecedes(b.version) }?.url
    }

    /// The blocking part, and the only part: LaunchServices, then the
    /// Applications folders, and the newest of everything either found.
    /// Called from a detached task, and from the first-run sheet, which asks
    /// once before its editor page is drawn.
    nonisolated public static func find(_ id: String) -> URL? {
        var urls: [URL] = []
        for bundle in bundleIDs[id] ?? [] {
            urls += NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundle)
        }
        let fm = FileManager.default
        for dir in [URL(fileURLWithPath: "/Applications"),
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            for file in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where isNamed(file, id) {
                urls.append(dir.appendingPathComponent(file))
            }
        }
        var seen = Set<String>()
        let copies = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }.map { url in
            (url: url, version: version(
                declared: Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String,
                file: url.lastPathComponent))
        }
        return newest(copies)
    }

    /// One place for the answers, so a page redraws when one arrives.
    @MainActor @Observable final class Found {
        var cache: [String: URL?] = [:]
        var asking: Set<String> = []
    }
    @MainActor static let known = Found()

    /// For tests and the snapshot harness, where /Applications is not the
    /// subject and must not decide what a picture looks like.
    @MainActor public static func pretend(_ id: String, at url: URL?) { known.cache[id] = .some(url) }
}

/// Presets (DESIGN.md §2.4, §2.6).
///
/// The screen's first sentence is the whole point of it: the number that
/// decides what happens is labelled for what it decides, and the two authors
/// under it are each named. The old page printed their sum and called it his.
public struct PresetsStep: StepView {
    @Bindable var model: StepsModel
    let session: ShootSession
    @State private var askAgain = false
    /// The sheet was asked for by the list's route, so its answer goes on the
    /// list rather than starting now.
    @State private var againAdds = false
    @FocusState private var focusFirst: Bool

    public init(session: ShootSession, client: StudioClient, pump: ImagePump) {
        self.session = session
        let m = StepsModelStore.shared.model(for: session, jobs: StepJobs.model(client: client))
        _model = Bindable(wrappedValue: m)
    }

    private var runner: StepJobRunner { model.presetsJob }
    private var split: PresetSplit { model.split }
    private var written: Bool { session.info.presets > 0 && session.info.sidecars > 0 }
    private var running: Bool { runner.phase != .idle }
    /// The frames the engine said it left exactly as they were (§3.9-8), when
    /// it has said. `nil` is "this engine does not say", which is printed as
    /// nothing at all: the page does not apologise for the engine.
    private var leftAlone: [String]? {
        let lists = session.presets.compactMap(\.left_alone)
        return lists.isEmpty ? nil : Array(Set(lists.flatMap { $0 }))
    }

    /// How many frames carry his own changes, as the last run found them: the
    /// ones a plain write left alone, or the ones Write Them Again wrote under
    /// his changes. A rewrite leaves nothing alone, so after one the sheet
    /// said nothing of his had been found.
    private var hisFrames: Int {
        max(leftAlone?.count ?? 0, session.info.presets_ran?.under ?? 0)
    }

    public var body: some View {
        StepScaffold(title: Strings.Presets.title, blurb: Strings.Presets.blurb) {
            if split.willBeEdited == 0 && !written {
                ContentUnavailableView(Strings.Presets.noneYet, systemImage: Symbols.stepPresets)
                    .frame(maxWidth: .infinity)
            } else {
                form
            }
        } action: {
            StepActionBar {
                leading
            } box: {
                JobInPlace(phase: runner.phase, stop: { runner.stop() },
                           cancelQueue: { runner.cancelQueued() }) {
                    if written {
                        // Once they are written, what he does next is edit,
                        // so that is what Return does: his keepers open in
                        // the editor, as the Edit page's Open does, and the
                        // Edit page comes up to say so and count the exports.
                        // By habit he pressed Return here and got "Write the
                        // presets again?", and a second Return started two
                        // minutes of the same work. Writing them again is the
                        // toolbar's, and never the default.
                        Button(model.buildingEditFolder ? Strings.Edit.building
                                                        : Self.primaryWord(written: true, editor: model.editor)) {
                            openInEditor()
                        }
                        .primaryActionStyle()
                        .lineLimit(1)
                        .disabled(split.willBeEdited == 0 || model.buildingEditFolder)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("step.primary")
                    } else {
                        StepPrimary(Self.primaryWord(written: false, editor: model.editor),
                                    wouldWait: model.wouldWait,
                                    disabled: split.willBeEdited == 0) {
                            press(adding: false)
                        } addToTheList: {
                            press(adding: true)
                        }
                    }
                }
            }
        }
        .toolbar {
            // Write Them Again… only, once they are written: before that the
            // page's one main button, bottom right, writes them (§2.3).
            if written {
                ToolbarItem(placement: .primaryAction) {
                    StepPrimaryToolbarButton(Strings.Presets.again,
                                             wouldWait: model.wouldWait,
                                             // None: the table gives Shoot ▸ Write
                                             // the Presets no key, and a button
                                             // does not invent one.
                                             shortcut: StepPrimaryWords.toolbarKey(for: CommandTable.ID.writePresets),
                                             // Not while this shoot's own presets
                                             // are being written: a press then
                                             // queued the same work again.
                                             disabled: runner.phase != .idle,
                                             busy: runner.phase != .idle) {
                        press(adding: false)
                    } addToTheList: {
                        press(adding: true)
                    }
                }
            }
        }
        .alert(Strings.Presets.againTitle, isPresented: $askAgain) {
            Button(Strings.Cull.cancel, role: .cancel) {}
            // Both routes ask the same question and send the same rewrite.
            // The list's route sent a plain write, which skips every frame
            // that already has a preset: a two-minute run that wrote nothing.
            Button(Strings.Presets.againConfirm(adds: againAdds)) { againAdds ? addIt(force: true) : start(force: true) }
        } message: {
            Text(Strings.Presets.againBody(hisFrames))
        }
        // Shoot ▸ Write the Presets is this button, pressed from the menu
        // (DESIGN.md §2.12).
        .answersMenu([CommandTable.ID.writePresets], shoot: session.name) { _, option in
            // Its own presets running or already on the list: a press now
            // would write them a second time, so it is ignored.
            guard split.willBeEdited > 0 || written, runner.phase == .idle,
                  !PagePresses.inHand(shoot: session.name, job: model.jobs.job, list: Queues.state)
                    .contains("presets")
            else { return }
            press(adding: StepPrimaryWords.adds(wouldWait: model.wouldWait, optionHeld: option))
        }
        .task {
            model.observeJobs(ext: nil)
            focusFirst = true
            Editors.look(for: model.editor)
        }
        .onChange(of: model.editor) { _, id in Editors.look(for: id) }
        .onDisappear { model.stopObserving() }
    }

    // MARK: - the honest split

    @ViewBuilder private var splitCard: some View {
        let s = split
        Section {
            VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
                Text(Strings.Presets.willBeEdited(s.willBeEdited))
                    .font(.title3)
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
                    Label(Strings.Presets.splitYours(s.kept), systemImage: Symbols.hisKeep)
                        .foregroundStyle(Tokens.Palette.kept)
                    if s.agreed > 0 {
                        Label(Strings.Presets.splitAgreed(s.agreed), systemImage: Symbols.agreed)
                            .foregroundStyle(.secondary)
                    }
                    if s.notLookedThrough > 0 {
                        // The old page's one red clause, kept: a frame nobody
                        // has opened is the cull's guess and nothing else.
                        Label(Strings.Presets.splitNotLookedThrough(s.notLookedThrough),
                              systemImage: Symbols.cullFault)
                            .foregroundStyle(Tokens.Palette.fault)
                    }
                }
                .font(.callout)
                .monospacedDigit()

                // Only where the engine can be told to: a toggle that can
                // never be turned on, with a note blaming "this engine", was
                // read on every shoot.
                if s.agreed > 0, StepCapabilities.current.presetsCanLeaveOutAgreed {
                    Toggle(Strings.Presets.leaveThoseOut(s.agreed), isOn: $model.leaveOutAgreed)
                        .focused($focusFirst)
                        .disabled(running)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Tokens.Metric.labelValueGap)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var form: some View {
        Form {
            splitCard
            Section {
                // One row: which editor, and what it gets. Where it is
                // installed is the picker's help, and "not on this Mac" is
                // said only when the disk has answered that it is not.
                Picker(Strings.Presets.writtenFor, selection: $model.editor) {
                    ForEach(Editors.ids, id: \.self) { id in
                        Text(Editors.name(id)).tag(id)
                    }
                }
                .help(Editors.location(model.editor).map { Strings.Presets.foundAt($0.path) } ?? "")
                StepNote(Strings.Presets.editorNote(model.editor))
                if Editors.isKnown(model.editor), Editors.location(model.editor) == nil {
                    StepNote(Strings.Presets.notFound)
                }
            }
            .disabled(running)
            Section {
                Toggle(Strings.Presets.alsoDropped, isOn: $model.alsoDropped)
                StepNote(Strings.Presets.alsoDroppedCost(max(0, session.info.frames - split.willBeEdited)))
            }
            // What is set here goes with the next run, not the one running.
            .disabled(running)
            Section {
                LabeledContent(Strings.Presets.destination) {
                    PathRow(URL(fileURLWithPath: session.info.raw))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        // The scaffold already holds the page to its column; the form fills
        // that, so one narrow row cannot pull every section in with it.
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var leading: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            if let m = model.jobs.refusals[.job] { RefusalRow(m, owner: .job) }
            if let m = model.queue.refusals[.job] { RefusalRow(m, owner: .job) }
            if let added = model.added {
                Text(added).font(.callout).foregroundStyle(.secondary)
            }
            if runner.listed != nil, model.queue.isHeld {
                Text(Strings.Queue.heldNote).font(.callout).foregroundStyle(.secondary)
            } else if runner.isQueued, let other = runner.other {
                Text(Strings.Step.waitingFor(Strings.Queue.named(other), ahead: max(0, (runner.listed?.place ?? 1) - 1)))
                    .font(.callout).foregroundStyle(.secondary)
            } else if runner.phase == .idle, model.added == nil,
                      let why = Strings.Queue.whyItAdds(running: runner.other, held: model.queue.isHeld) {
                // Why the button reads "Add to Up Next" (§2.7).
                Text(why).font(.callout).foregroundStyle(.secondary)
            }
            // How the last run ended, when it did not finish. It had no line
            // here at all, so the presets written again and failing left the
            // first run's counts standing as if nothing had happened.
            let ended = runner.mine == nil ? JobEndedNote(runner.lastEnded) : nil
            if let j = runner.mine {
                JobTiming(j)
            } else if let ended {
                ended
            }
            if runner.mine == nil, written {
                if ended == nil {
                    // What the last run did, when the engine recorded it; what
                    // is on the disk otherwise. The disk count read the same
                    // after a run that wrote nothing. The engine's note on how
                    // the looks were set is DxO's own words, so it is the
                    // line's help, not a sentence on the page.
                    Text(ranSentence)
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(3)
                        .help(session.info.presets_note)
                } else {
                    // After a run that did not finish, what is on disk and the
                    // way on, and not the last good run's account under the
                    // sentence he has to read: the bar is not a page.
                    Text(Strings.Presets.written(session.info.presets, onto: session.info.sidecars))
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                // No "Edit in PhotoLab ›" beside it: the primary opens the
                // keepers and goes there, and ⌘] goes there without opening.
            } else if runner.mine == nil, ended == nil, split.willBeEdited > 0 {
                Text(Strings.Presets.estimate(minutes)).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var ranSentence: String {
        if let ran = session.info.presets_ran {
            return Strings.Presets.ran(wrote: ran.wrote, changed: ran.changed, already: ran.already, under: ran.under)
        }
        let written = Strings.Presets.written(session.info.presets, onto: session.info.sidecars)
        guard let left = leftAlone, !left.isEmpty else { return written }
        return written + " " + Strings.Presets.leftAlone(left.count)
    }

    /// About how long a first write takes: 368 keepers took about two minutes
    /// on his 2026-09-19 shoot. Said the way the Cull page says its own.
    private var minutes: Int { max(1, Int((Double(split.willBeEdited) / 200.0).rounded(.up))) }

    /// The primary, by either route. Writing them again asks first, whichever
    /// route it goes by.
    private func press(adding: Bool) {
        if written {
            againAdds = adding
            askAgain = true
        } else if adding {
            addIt(force: false)
        } else {
            start(force: false)
        }
    }

    private func addIt(force: Bool) { model.addPresetsToTheList(force: force) }

    /// What the box at the bottom right says: Write the Presets, and once
    /// they are written, Open My Keepers in the editor they are written for.
    nonisolated static func primaryWord(written: Bool, editor: String) -> String {
        written ? Strings.Edit.openIn(Editors.name(editor)) : Strings.Presets.write
    }

    /// The keepers open in his editor, and the Edit page comes up, where the
    /// opening, a refusal and the exports as they come are all said.
    private func openInEditor() {
        model.openKeepers()
        StepSlots.showStep?(session.name, "edit")
    }

    private func start(force: Bool) { model.writePresets(force: force) }
}
