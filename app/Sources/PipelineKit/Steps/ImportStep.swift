import SwiftUI
import AppKit

/// Copy the Card (DESIGN.md §2.6).
///
/// The whole page is one promise: nothing on the card is changed, and what
/// afterwards says the copy is good is the copy's own log — never a listing of
/// the folder it landed in. A folder with 1,157 files in it proves a copy
/// happened; it does not prove a copy finished, and the six sentences below are
/// the difference.
public struct ImportStep: View {
    let app: AppModel

    public init(app: AppModel) { self.app = app }

    /// The page for one card. The sidebar's row and the picker on the page
    /// are one choice (`ImportModel.volume`), and the page is built afresh
    /// for each card — each card that goes in, not each place a card mounts,
    /// because every card his camera formats is called Untitled — so a name,
    /// a count or a result is never carried from one card to the next.
    public var body: some View {
        let model = app.importModel
        let volume = model.volume(for: app.navigation.selection, cards: app.library.cards)
        CardPage(app: app, volume: volume)
            .id("\(volume)#\(model.generation[volume, default: 0])")
    }
}

/// One card's page: the form before the copy, the form held still while it
/// runs, and the result after it.
struct CardPage: View {
    let app: AppModel
    let volume: String

    @State private var name = ""
    /// What the field was filled with. Until he types, the reason a name
    /// will not do is not said in red: he has not given one yet.
    @State private var prefill = ""
    @State private var submitted = false
    @State private var selection: TextSelection?
    /// How he checks a copy is his habit and comes back as he left it.
    /// *Don't check* is never carried over (`VerifyChoice.remember`).
    @State private var verify = StepsModel.VerifyChoice(settings: .shared)
    /// The extension's kind question. `nil` until he answers it, which
    /// leaves it on the kind of his newest shoot.
    @State private var extKind: Bool?
    /// The shoot already in the library this card goes into, or nil for a
    /// new one: the copy that stopped, until he chooses otherwise.
    @State private var into: String?
    @State private var intoChosen = false
    @State private var stopping = false
    @State private var optionHeld = false
    @Environment(\.stepOptionKey) private var optionKey
    @FocusState private var nameFocused: Bool

    private var model: ImportModel { app.importModel }
    private var cards: [String] { app.library.cards }
    private var isIn: Bool { cards.contains(volume) }
    private var copy: ImportModel.Copy? { model.copy(for: volume) }
    private var ending: ImportModel.Ending? { copy == nil ? model.endings[volume] : nil }
    private var scan: CardScan? { model.scans[volume] }
    /// The copy that ended here finished: the page is its result.
    private var copied: ImportModel.Ending? {
        guard let ending, ending.copied(row: app.library.row(named: ending.shoot)) else { return nil }
        return ending
    }

    var body: some View {
        StepScaffold(title: Strings.Import.title, blurb: copied != nil ? nil : Strings.Import.blurb) {
            if let ending = copied {
                result(ending)
            } else if copy != nil || isIn {
                form
            } else {
                if let ending { Form { endingSection(ending) }.formStyle(.grouped).scrollDisabled(true) }
                ContentUnavailableView(Strings.Import.noCard, systemImage: Symbols.memoryCard,
                                       description: Text(Strings.Import.noCardWhy))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tokens.Metric.groupGap)
            }
        } action: {
            StepActionBar {
                leading
            } box: {
                box
            }
        }
        // No copy of the primary in the toolbar: a page's main button is at
        // its bottom right, once (§2.3, §2.6). Two of the same button were two
        // things to read for one action.
        .task { await appear() }
        .onChange(of: scan) { _, s in
            takeTheDay(s)
            if !intoChosen { into = resumeTarget }
        }
        .onChange(of: name) { _, new in
            let tidy = ShootName.tidy(new)
            if tidy != new {
                name = tidy
                selection = TextSelection(insertionPoint: tidy.endIndex)
            }
        }
        .onChange(of: verify) { _, v in if copy == nil { v.remember(in: .shared) } }
        .onChange(of: Queues.state) { _, s in model.listChanged(s) }
        .onChange(of: copy == nil) { _, idle in if idle { stopping = false } }
        .onModifierKeysChanged(mask: .option) { _, new in optionHeld = new.contains(.option) }
    }

    // MARK: - the form

    @ViewBuilder private var form: some View {
        let locked = copy != nil
        Form {
            if let ending { endingSection(ending) }

            Section {
                if cards.count > 1, !locked {
                    // The sidebar's own selection: choosing a card here is
                    // choosing its row there, and the other way round.
                    Picker(Strings.Import.card, selection: Binding(get: { volume },
                                                                  set: { app.navigation.selection = .card($0) })) {
                        ForEach(cards, id: \.self) { c in
                            Text(CardWatcher.volumeName(c)).tag(c)
                        }
                    }
                } else {
                    LabeledContent(Strings.Import.card) {
                        Label(CardWatcher.volumeName(volume), systemImage: Symbols.memoryCard)
                    }
                }
                // Live while the copy runs: it is read when the copy ends.
                Toggle(Strings.Import.ejectAfter, isOn: Binding(get: { model.ejectAfter },
                                                               set: { model.ejectAfter = $0 }))
                if !locked, let already = alreadyCopied {
                    StepNote(already)
                }
            }

            if !locked, !joinable.isEmpty {
                // A shoot this card can go into: the one a copy of it stopped
                // part way into, and the day's shoots not culled yet, for a
                // second camera's card. A new shoot until he says otherwise,
                // except the copy that stopped, which is what he came back for.
                Section {
                    Picker(Strings.Import.copyInto,
                           selection: Binding(get: { target ?? "" },
                                              set: { into = $0.isEmpty ? nil : $0; intoChosen = true })) {
                        Text(Strings.Import.aNewShoot).tag("")
                        ForEach(joinable, id: \.self) { n in
                            Text(n == resumeTarget ? Strings.Import.finishInto(n)
                                 : culling(n) ? Strings.Import.addToBeingCulled(n) : Strings.Import.addTo(n)).tag(n)
                        }
                    }
                    if let t = target {
                        StepNote(t == resumeTarget ? Strings.Import.finishNote(t)
                                 : culling(t) ? Strings.Import.beingCulledNote(t) : Strings.Import.addNote(t))
                    }
                }
            }

            if locked || target == nil {
                Section {
                    VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
                        Text(Strings.Import.name).font(.headline)
                        TextField(Strings.Import.name, text: locked ? .constant(copy?.shoot ?? name) : $name,
                                  selection: $selection, prompt: Text(Strings.Import.namePrompt))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .focused($nameFocused)
                            .disabled(locked)
                            .onSubmit { press() }
                        // The reason is under the field it is about, which is
                        // where a person looks after typing into it (§2.6).
                        if !locked {
                            if let problem = shownProblem {
                                Text(problem)
                                    .font(.callout)
                                    .foregroundStyle(Tokens.Palette.alarm)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if let hint {
                                StepNote(hint)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Tokens.Metric.labelValueGap)
                }
            }

            // A card added to a shoot keeps the shoot's kind: the question
            // is for a new one.
            if let ext = app.library.ext, !ext.ask.question.isEmpty, locked || target == nil {
                // The extension's own question, in the extension's own words,
                // read at runtime and never compiled in. Directly under the
                // name, where it is seen before the button, and on the kind
                // of his newest shoot until he answers it.
                Section {
                    // While a copy runs, its own answer: it can have been
                    // flipped from the page's starting one.
                    Picker(ext.ask.question, selection: Binding(get: { copy.map { $0.kind != nil } ?? kindIsTheExtension },
                                                               set: { extKind = $0 })) {
                        Text(ext.ask.yes).tag(true)
                        Text(ext.ask.no).tag(false)
                    }
                    .pickerStyle(.inline)
                    .disabled(locked)
                    if !ext.ask.blurb.isEmpty { StepNote(ext.ask.blurb) }
                }
            }

            Section {
                Picker(Strings.Import.check,
                       selection: locked ? .constant(StepsModel.VerifyChoice(rawValue: copy?.verify ?? "") ?? verify)
                                         : $verify) {
                    ForEach(StepsModel.VerifyChoice.allCases, id: \.self) { v in
                        Text(v.label).tag(v)
                    }
                }
                .pickerStyle(.inline)
                .disabled(locked)
                StepNote((StepsModel.VerifyChoice(rawValue: copy?.verify ?? "") ?? verify).note)
            }

            if let destination {
                Section {
                    LabeledContent(Strings.Import.goesTo) {
                        PathRow(destination).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        // The scaffold already holds the page to its column; the form fills
        // that, so one narrow row cannot pull every section in with it.
        .frame(maxWidth: .infinity)
    }

    /// A copy of this card that did not finish: the copy's own sentence,
    /// what ended it, and what he can do now.
    @ViewBuilder private func endingSection(_ e: ImportModel.Ending) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
                // The copy's own sentence, with the shoot it is about: the
                // page belongs to the card, and the card is not that shoot.
                Text(Self.unfinished(e, row: app.library.row(named: e.shoot)))
                    .font(.callout)
                    .foregroundStyle(Tokens.Palette.alarm)
                    .fixedSize(horizontal: false, vertical: true)
                if let why = Self.why(e) { StepNote(why) }
                if !isIn {
                    StepNote(Strings.Import.putItBack)
                } else if let row = app.library.row(named: e.shoot), row.culled {
                    // Put back, the copy finishes into the shoot it stopped
                    // in (Copy into, below) — until that shoot is culled.
                    StepNote(Strings.Import.againNeedsANewName(e.shoot))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func unfinished(_ e: ImportModel.Ending, row: ShootRowOK?) -> String {
        if let row, row.ingest.isRecorded,
           let (sentence, _) = IngestNoteView.sentence(row.ingest, frames: row.frames, verify: row.verify) {
            return Strings.Import.about(e.shoot, sentence)
        }
        return Strings.Import.didNotFinish(e.shoot)
    }

    /// What ended a copy that did not finish, in a sentence.
    static func why(_ e: ImportModel.Ending) -> String? {
        if e.outcome == .stopped { return Strings.Import.youStopped }
        if e.engineRestarted { return Strings.Import.engineStopped }
        // The engine's own sentence first, where it wrote one: "not enough
        // room …", or the list's "not in this Mac any more".
        if let s = e.sentence { return s }
        return e.cardCameOut ? Strings.Import.cardCameOut : nil
    }

    // MARK: - after it

    /// The copy finished: the page is its result, not a form with a greyed
    /// button and a red "already in your library" about the shoot he just
    /// made.
    @ViewBuilder private func result(_ e: ImportModel.Ending) -> some View {
        let row = app.library.row(named: e.shoot)
        Form {
            Section {
                VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
                    Label {
                        Text(Self.headline(e, row: row))
                            .font(.title3)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        // A white tick on a solid disc: the hierarchical
                        // tint washed out to a pale ring on a light window.
                        Image(systemName: Symbols.inUse)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Tokens.Palette.kept)
                    }
                    if let row, case .done = row.ingest { StepNote(Strings.Import.nothingChanged) }
                    ForEach(Array((row?.earlier_copies ?? []).enumerated()), id: \.offset) { _, c in
                        EarlierCopyLine(copy: c)
                    }
                    if let line = Self.ejectLine(e) { StepNote(line) }
                    if let line = Self.cullLine(e.shoot, job: app.jobs.job ?? StepJobs.previewJob, list: Queues.state) {
                        StepNote(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Tokens.Metric.labelValueGap)
            }
            Section {
                LabeledContent(Strings.Import.card) {
                    Label(CardWatcher.volumeName(e.card), systemImage: Symbols.memoryCard)
                }
                if let row {
                    LabeledContent(Strings.Overview.frames) { Text("\(row.frames)").countStyle() }
                    LabeledContent(Strings.Import.copiedTo) {
                        PathRow(URL(fileURLWithPath: row.raw.isEmpty ? row.path : row.raw))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(maxWidth: .infinity)
    }

    /// The copy's own sentence where the library has it, which is the only
    /// thing that may say how it was checked.
    static func headline(_ e: ImportModel.Ending, row: ShootRowOK?) -> String {
        if let row, row.ingest.isRecorded,
           let (sentence, _) = IngestNoteView.sentence(row.ingest, frames: row.frames, verify: row.verify) {
            return sentence
        }
        return Strings.Import.copiedInto(e.shoot)
    }

    /// The cull that followed the copy, as the engine's slot and list say:
    /// running, or waiting its turn. Nothing when neither — a shoot already
    /// culled, or an engine that does not follow a copy with one.
    static func cullLine(_ shoot: String, job: Job?, list: QueueState) -> String? {
        if let j = job, j.running, j.kind == "cull", j.shoot == shoot { return Strings.Import.cullRunning }
        if list.running, list.kind == "cull", list.shoot == shoot { return Strings.Import.cullRunning }
        if list.waiting.contains(where: { $0.kind == "cull" && $0.shoot == shoot }) { return Strings.Import.cullWaiting }
        return nil
    }

    static func ejectLine(_ e: ImportModel.Ending) -> String? {
        switch e.eject {
        case .done: return Strings.Import.ejected
        case .failed(let why): return Strings.Import.ejectFailed(why)
        case .going, .notAsked: return nil
        }
    }

    // MARK: - the bar

    @ViewBuilder private var leading: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            if let m = app.jobs.refusals[.job] { RefusalRow(m, owner: .job) }
            if let m = Queues.model(client: app.client).refusals[.job] { RefusalRow(m, owner: .job) }
            if let copy {
                let running = model.job(for: volume)
                if copy.listed, running == nil {
                    Text(model.listedNote ?? Strings.Queue.added(Strings.Import.title))
                        .font(.callout).foregroundStyle(.secondary)
                    if let other = app.jobs.job, other.running, !other.background {
                        Text(Strings.Step.waitingFor(Strings.Queue.named(other))).font(.callout).foregroundStyle(.secondary)
                    }
                } else if copy.cardCameOut || !isIn {
                    Text(Strings.Import.cardCameOutRunning)
                        .font(.callout)
                        .foregroundStyle(Tokens.Palette.alarm)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Above the clock: the line level with the box is the clock.
                if !copy.cardCameOut, isIn {
                    Text(Strings.Import.cullFollows(asLast: anyCulled)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let running { JobTiming(running) }
            } else if isIn, copied == nil {
                // Said before he presses, so the cull starting by itself is
                // not a surprise, and the settings it runs with are named.
                Text(Strings.Import.cullFollows(asLast: anyCulled)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var box: some View {
        if let ending = copied {
            let go = Button(Strings.Import.onToCull(ending.shoot)) { StepSlots.showStep?(ending.shoot, "cull") }
                .lineLimit(1)
                .truncationMode(.middle)
            // Not Return while another card's copy into the shoot did not
            // finish: the red line above says so, as on the card's report.
            if app.library.row(named: ending.shoot)?.copyUnfinished == true {
                go.controlSize(.large)
            } else {
                go.primaryActionStyle()
                    .keyboardShortcut(.defaultAction)
            }
        } else if let copy {
            // Stop only while the engine says this copy is running: the bar
            // before its first answer, or after the app lost sight of it, is
            // the app's own words, and the engine's stop without a number
            // stops whatever is running — which could be his cull.
            JobInPlace(phase: phase(copy),
                       stop: model.job(for: volume) == nil ? nil : {
                           stopping = true
                           Task { await model.stop(volume) }
                       },
                       cancelQueue: { Task { await model.takeOffTheList(volume) } }) {
                EmptyView()
            }
        } else {
            Button { press() } label: {
                // The widest thing it will say, held underneath, so the
                // button is one width before the card has been counted and
                // after: it used to grow under his pointer a moment after the
                // page appeared.
                ZStack {
                    Text(Strings.Import.copyCount(8_888)).hidden()
                    Text(StepPrimaryWords.label(primaryTitle, adds: adds))
                }
            }
            .primaryActionStyle()
            .disabled(!canCopy)
            .keyboardShortcut(.defaultAction)
            .help(adds ? StepPrimaryWords.spoken(primaryTitle, adds: true) : Strings.Import.blurb)
            .accessibilityLabel(StepPrimaryWords.spoken(primaryTitle, adds: adds))
        }
    }

    private func phase(_ copy: ImportModel.Copy) -> StepJobPhase {
        if stopping { return .stopping }
        // A copy off his list is running once its turn has come.
        if let j = model.job(for: volume) { return .running(j) }
        if copy.listed { return .queued }
        // Between the press and the engine's first answer about it, the
        // copy is the words it will be called by rather than a greyed button.
        return .running(Job(running: true, stopped: false, kind: "ingest", shoot: copy.shoot,
                            title: Strings.Import.copying))
    }

    // MARK: - what it does

    private var primaryTitle: String {
        if let t = target {
            if t == resumeTarget, let n = leftToCopy {
                return n > 0 ? Strings.Import.finishCopying(n) : Strings.Import.finishTheCopy
            }
            if let n = scan?.photographs { return Strings.Import.addCount(n) }
        }
        return scan.map { Strings.Import.copyCount($0.photographs) } ?? Strings.Import.copy
    }

    /// The shoot a copy of this card stopped part way into, which the copy
    /// can finish: the engine's count off the card says it holds some of the
    /// card and not all, nothing is copying into it, and it is not culled.
    private var resumeTarget: String? {
        if let t = Self.resumeTarget(scan?.contents, row: { app.library.row(named: $0) }) { return t }
        // The copy of this card this session saw stop, when the engine has
        // not counted the card: the page is still about that copy.
        if let e = ending, !e.copied(row: app.library.row(named: e.shoot)),
           let row = app.library.row(named: e.shoot), !row.culled { return e.shoot }
        return nil
    }

    /// What finishing it copies: the card less what the engine counted in
    /// the shoot, or less the frames the shoot holds when it has not.
    private var leftToCopy: Int? {
        if let c = scan?.contents, c.copiedAs == resumeTarget { return max(0, c.photographs - c.held) }
        guard let t = resumeTarget, let n = scan?.photographs, let row = app.library.row(named: t) else { return nil }
        return max(0, n - row.frames)
    }

    /// Holding some of the card and not all - or all of it, when the last
    /// copy's own log says it did not finish (stopped in its check pass). Not
    /// a card held whole in a shoot where only an earlier card's copy did not
    /// finish: that is another card's copy, and the engine refuses this one.
    static func resumeTarget(_ c: CardContents?, row: (String) -> ShootRowOK?) -> String? {
        guard let c, !c.copiedAs.isEmpty, c.held > 0, !c.copying,
              let r = row(c.copiedAs), !r.culled,
              c.held < c.photographs || r.ingest.isUnfinished else { return nil }
        return c.copiedAs
    }

    /// Every shoot this card may go into: the copy to finish first, then the
    /// shoots of the card's own day not culled yet, for a second camera's card.
    private var joinable: [String] {
        Self.joinable(resume: resumeTarget, day: scan?.day, shoots: app.library.shoots,
                      whole: scan?.contents.flatMap { $0.held > 0 && $0.held >= $0.photographs ? $0.copiedAs : nil })
    }

    /// Not a shoot a copy into which did not finish: only the card whose
    /// copy that was may go into it, to finish it (`resume`), and the engine
    /// refuses any other - a second card added to a shoot whose first stopped
    /// at 412 of 1,558 wrote over that copy's record and started the cull on
    /// half the night. Not the shoot that holds all of this card already
    /// (`whole`): copying it again adds nothing.
    static func joinable(resume: String?, day: String?, shoots: [ShootRowOK], whole: String? = nil) -> [String] {
        var out = resume.map { [$0] } ?? []
        if let day {
            for r in shoots where r.name.hasPrefix(day) && !r.culled && !r.copyUnfinished
                && r.name != whole && !out.contains(r.name) {
                out.append(r.name)
            }
        }
        return out
    }

    /// Where the copy goes when it is not a new shoot.
    private var target: String? { into.flatMap { joinable.contains($0) ? $0 : nil } }

    /// Whether pressing it now puts the copy on his list. Asked the way
    /// every step asks it (`StepPrimaryWords`), and it never waits inside
    /// this page: a request that waited here was thrown away when he left.
    private var adds: Bool { StepPrimaryWords.adds(wouldWait: model.wouldWait, optionHeld: optionHeld || optionKey) }

    private var taken: [String] { app.library.shoots.map(\.name) + app.library.broken.map(\.name) }

    /// The name as it will be sent: a trailing dash, dot or underscore is
    /// what is left of the prefill when he adds nothing, not part of a name.
    private var finalName: String { ShootName.finished(name) }

    var nameProblem: String? { ShootName.problem(finalName, taken: taken) }

    /// Red only once he has typed, or pressed Copy.
    private var shownProblem: String? {
        guard name != prefill || submitted else { return nil }
        return nameProblem
    }

    private var hint: String? {
        guard let day = scan?.day ?? (prefill.isEmpty ? nil : String(prefill.prefix(10))),
              name == prefill else { return nil }
        return taken.contains(day) ? Strings.Import.nameHintTaken(day) : Strings.Import.nameHint(day)
    }

    private var kindIsTheExtension: Bool {
        extKind ?? Self.newestIsTheExtensions(ext: app.library.ext, shoots: app.library.shoots)
    }

    /// The kind question's answer until he gives one: the kind of his newest
    /// shoot, by the day its name starts with, which is how his shoots are
    /// named. It started on "no" for every card, and every shoot of his is
    /// the extension's kind: one card he forgot to flip got the wrong steps.
    static func newestIsTheExtensions(ext: ExtConfig?, shoots: [ShootRowOK]) -> Bool {
        guard let ext, !ext.kind.isEmpty else { return false }
        let dated = shoots.filter { $0.name.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }
        return (dated.max { $0.name < $1.name } ?? shoots.first)?.kind == ext.kind
    }

    private var canCopy: Bool {
        copy == nil && isIn && (target.map { !culling($0) } ?? (nameProblem == nil))
    }

    /// A cull of this shoot is running: the engine adds no card to it until
    /// it is stopped, so the picker says so and Copy waits, rather than
    /// offering "adding this card" and refusing the press.
    private func culling(_ shoot: String) -> Bool {
        Self.beingCulled(shoot, job: app.jobs.job ?? StepJobs.previewJob, list: Queues.state)
    }

    static func beingCulled(_ shoot: String, job: Job?, list: QueueState) -> Bool {
        if let j = job, j.running, j.kind == "cull", j.shoot == shoot { return true }
        return list.running && list.kind == "cull" && list.shoot == shoot
    }

    /// Whether a cull has run on any shoot here: only then is there a last
    /// shoot for the cull after the copy to be set as (`_cull_settings`).
    private var anyCulled: Bool { app.library.shoots.contains { $0.culled } }

    /// Where the copy will land, taken from where the engine already keeps
    /// this library's shoots — never from a guess at a folder in his home. A
    /// path the app made up would be a promise about a place it has not been
    /// told about, and the one thing this row is for is being exact. A name
    /// that will not do yet ends the path in "…": "2026-09-19-" with nothing
    /// added would otherwise show the folder of the shoot already called
    /// 2026-09-19, as if this card were going into it.
    private var destination: URL? {
        let shown = copy?.shoot ?? target ?? (nameProblem == nil ? finalName : "")
        if let sibling = app.library.shoots.first?.path, !sibling.isEmpty {
            return URL(fileURLWithPath: sibling).deletingLastPathComponent()
                .appendingPathComponent(shown.isEmpty ? "…" : shown)
        }
        guard let root = SettingsStore.shared.libraryFolder else { return nil }
        return root.appendingPathComponent("shoots").appendingPathComponent(shown.isEmpty ? "…" : shown)
    }

    /// Whether this card's photographs are already in a shoot. The engine's
    /// count where it answered: all of them, how many, or a copy into it
    /// running or stopped. It matched the path the card mounts at, and his
    /// camera formats every card as "Untitled", so every new card said it had
    /// been copied as the first night's shoot. With no engine to ask, the
    /// page's own look for the card's newest photograph in each shoot.
    private var alreadyCopied: String? {
        if let c = scan?.contents { return Strings.Import.alreadyCopied(c) }
        return scan?.copiedAs.map(Strings.Import.alreadyCopied(as:))
    }

    private func press() {
        submitted = true
        guard canCopy else { return }
        let joining = target
        let kind = joining == nil ? app.library.ext.flatMap { kindIsTheExtension ? $0.kind : nil } : nil
        let (card, shoot, check, adding) = (volume, joining ?? finalName, verify.rawValue, adds)
        if joining == nil { name = shoot }
        Task {
            await model.start(card: card, name: shoot, verify: check, kind: kind, addToTheList: adding,
                              into: joining != nil)
        }
    }

    // MARK: - arriving

    private func appear() async {
        model.arrived()
        // The list may have gone on without a copy he left on it while he
        // was on another page; `onChange` only hears what changes from here.
        model.listChanged(Queues.state)
        // The card's own day, where it has been read. Until it has, the
        // field is empty with the example in it, rather than the Mac's date
        // for a moment that his typing could keep.
        if name.isEmpty, let day = scan?.day {
            prefill = prefill(for: day)
            name = prefill
        }
        if copy == nil, copied == nil, isIn {
            nameFocused = true
            // AppKit selects the whole field when it takes focus; the caret
            // goes to the end on the next turn, so what he types is added to
            // the date rather than typed over it.
            await Task.yield()
            selection = TextSelection(insertionPoint: name.endIndex)
        }
        await model.scan(volume)
        if !intoChosen, copy == nil { into = resumeTarget }
        // Read, and no day on it: the Mac's date is the best there is.
        if scan?.day == nil, name.isEmpty, prefill.isEmpty, model.hasRead(volume), copy == nil {
            prefill = prefill(for: Self.today())
            name = prefill
            selection = TextSelection(insertionPoint: name.endIndex)
        }
    }

    /// The card has been read: the name starts from the day its last evening
    /// started, unless he has typed.
    private func takeTheDay(_ s: CardScan?) {
        guard let day = s?.day, name == prefill else { return }
        let better = prefill(for: day)
        guard better != name else { return }
        prefill = better
        name = better
        selection = TextSelection(insertionPoint: better.endIndex)
    }

    /// The bare day, as his shoots are named, or the day and a dash to type
    /// after when a shoot of that day is already in the library.
    private func prefill(for day: String) -> String {
        taken.contains(day) ? day + "-" : day
    }

    static func today() -> String { CardScan.dayName(Date()) }
}

/// What a shoot may be called.
///
/// The engine's own rule (`/api/ingest`: a letter or a digit, then letters,
/// digits, dots, dashes and underscores, and not a name already in the
/// library), checked here so a name the engine would refuse never gets as far
/// as being sent — and so the reason is under the field while he is still
/// typing, rather than at the foot of the window after a round trip. It
/// allowed a name starting with a dash or a dot, which the engine then
/// refused with a sentence about picking a card.
public enum ShootName {
    public static func problem(_ name: String, taken: [String]) -> String? {
        if name.isEmpty { return Strings.Import.nameEmpty }
        if name.range(of: "^[A-Za-z0-9]", options: .regularExpression) == nil {
            return Strings.Import.nameStart
        }
        if name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) == nil {
            return Strings.Import.nameCharacters
        }
        if taken.contains(name) { return Strings.Import.nameTaken(name) }
        return nil
    }

    /// What he types, as a name can hold it: a space or a slash becomes a
    /// dash as it is typed, so "night 2" is "night-2" rather than a rule in
    /// red about which characters are allowed.
    public static func tidy(_ typed: String) -> String {
        String(typed.drop(while: \.isWhitespace))
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    /// The name as it is sent. A dash, dot or underscore at the end is what
    /// is left of "2026-09-19-" when he adds nothing to it, not part of a
    /// name: his shoots are called "2026-09-19".
    public static func finished(_ name: String) -> String {
        var n = name
        while let last = n.last, "-_.".contains(last) { n.removeLast() }
        return n
    }
}

/// The copy's own note, for a shoot that has one (DESIGN.md §2.6).
///
/// Three of the six sentences report a copy that was not proved, and those
/// three are in the alarm colour. None of them is inferred from the shoot
/// folder: an unproved copy that happens to have left 1,157 files behind still
/// says so.
public struct IngestNoteView: View {
    let note: IngestNote
    let frames: Int
    let verify: String

    public init(note: IngestNote, frames: Int, verify: String) {
        self.note = note; self.frames = frames; self.verify = verify
    }

    public var body: some View {
        if let (text, bad) = Self.sentence(note, frames: frames, verify: verify) {
            Text(text)
                .font(.callout)
                .foregroundStyle(bad ? Tokens.Palette.alarm : Color.secondary)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text(text))
        }
    }

    /// The sentence, and whether it reports a copy nothing has proved.
    public static func sentence(_ note: IngestNote, frames: Int, verify: String) -> (String, Bool)? {
        switch note {
        case .done(let files, let proof):
            return (Strings.Import.done(files, proof: proof), false)
        case .failed(let detail):
            return (Strings.Import.failed(detail), true)
        case .copying:
            return (Strings.Import.copying, false)
        case .stopped(let files, let of):
            return (Strings.Import.stopped(files, of: of), true)
        case .unclear(let log):
            return (Strings.Import.unclear(log), true)
        case .none:
            guard frames > 0 else { return (Strings.Import.copying, false) }
            return (Strings.Import.beforeLogs(frames, verify: verify), false)
        }
    }
}

/// A card copied into the shoot before its last one: a note when that copy
/// finished, and in the alarm colour when it did not.
struct EarlierCopyLine: View {
    let copy: EarlierCopy

    var body: some View {
        if copy.finished {
            StepNote(Strings.Import.earlier(copy))
        } else {
            Text(Strings.Import.earlier(copy))
                .font(.callout)
                .foregroundStyle(Tokens.Palette.alarm)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The `ingest` step of a shoot that already exists: what its copy recorded,
/// and nothing that could be mistaken for a way to copy over it.
public struct ImportReport: StepView {
    let session: ShootSession
    let model: StepsModel

    /// Its copy's own log says it stopped part way, failed its check, or
    /// ended in a way nothing can read: one of the sentences in the alarm
    /// colour - its last card's, or an earlier card's under it.
    static func unproved(_ i: ShootInfo) -> Bool {
        (IngestNoteView.sentence(i.ingest, frames: i.frames, verify: i.verify)?.1 ?? false) || i.copyUnfinished
    }

    public init(session: ShootSession, client: StudioClient, pump: ImagePump) {
        self.session = session
        self.model = StepsModelStore.shared.model(for: session,
                                                  jobs: StepJobs.model(client: client))
    }

    public var body: some View {
        let i = session.info
        StepScaffold(title: Strings.Import.title) {
            Form {
                Section {
                    IngestNoteView(note: i.ingest, frames: i.frames, verify: i.verify)
                    // A second card added to the shoot: the earlier card's
                    // copy, by its own log.
                    ForEach(Array(i.earlier_copies.enumerated()), id: \.offset) { _, c in
                        EarlierCopyLine(copy: c)
                    }
                    if case .done = i.ingest {
                        StepNote(Strings.Import.nothingChanged)
                    }
                }
                Section {
                    if !i.card.isEmpty {
                        LabeledContent(Strings.Import.card) {
                            Label(CardWatcher.volumeName(i.card), systemImage: Symbols.memoryCard)
                        }
                    }
                    LabeledContent(Strings.Overview.frames) { Text("\(i.frames)").countStyle() }
                    LabeledContent(Strings.Import.copiedTo) {
                        PathRow(URL(fileURLWithPath: i.raw)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(maxWidth: StepMetric.column)
        } action: {
            StepActionBar {
                // A real view, however empty. `EmptyView` takes no width, so
                // the bar's leading slot collapsed and the box fell to the
                // middle of the bar, left of where every other step keeps its
                // primary.
                Color.clear.frame(height: 0)
            } box: {
                // The way on, where the primary always is, and Return takes
                // it — when the copy's own log has not said it was cut short
                // or not proved. Then it is a plain button beside the red
                // sentence: Return must not carry him on to culling a shoot
                // that holds 412 of the card's 1,558 frames.
                let cull = Button(Strings.Cull.title + " ›") { StepSlots.showStep?(session.name, "cull") }
                if Self.unproved(i) {
                    cull.controlSize(.large)
                } else {
                    cull.primaryActionStyle()
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
