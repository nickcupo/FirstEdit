import SwiftUI

/// What the cull did, counted from the cull's own column and nothing else.
///
/// Every number here is read from `Row.rating`. His `override` is never
/// consulted, not even as a tie-break: this is the report of the machine's own
/// work, and a report that quietly folded his corrections into it would be the
/// machine taking credit for his eye (DESIGN.md §7.5 and §2.6).
public struct CullReport: Equatable, Sendable {
    public let frames: Int
    /// Rated three or above: the shortlist.
    public let putForward: Int
    /// Rated one: taken back to back and alike, so stacked behind another.
    /// Nothing was hidden for it.
    public let stacked: Int
    /// How many stacks those frames make, when the engine says. Zero means it
    /// has not said, and then the number of stacks is not printed.
    public let stacks: Int
    /// Rated two: nothing wrong with them, and not the best of their moment.
    /// The filmstrip draws these with the dotted circle.
    public let setAside: Int
    /// Rated zero: a fault it can name. The filmstrip draws these with the
    /// triangle. Never added to `setAside`: one number over the two said how
    /// many were set aside and hid how many had anything wrong with them.
    public let faults: Int
    /// The faults by name, most common first, at most `namedReasons` of them.
    public let reasons: [(word: String, count: Int)]
    /// The faults the line does not name — past the first few, or with no
    /// reason written — so the named ones and this always add up to `faults`.
    public let otherFaults: Int
    /// Frames he has marked.
    public let movedSince: Int
    /// The frames behind each named fault, and behind "other", in the order
    /// he shot them: what a click on "eyes closed 131" opens on the light
    /// table (§2.6). Always as many as the count beside the word.
    public let framesByReason: [String: [String]]
    public let otherFrames: [String]

    /// Enough to read at a glance on one line of the 680 pt column.
    public static let namedReasons = 4

    public static func == (a: CullReport, b: CullReport) -> Bool {
        a.frames == b.frames && a.putForward == b.putForward && a.stacked == b.stacked
            && a.stacks == b.stacks && a.setAside == b.setAside && a.faults == b.faults
            && a.otherFaults == b.otherFaults && a.movedSince == b.movedSince
            && a.reasons.map(\.word) == b.reasons.map(\.word)
            && a.reasons.map(\.count) == b.reasons.map(\.count)
    }

    public init(rows: [Row]) {
        frames = rows.count
        var forward = 0, alike = 0, aside = 0, faulty = 0, moved = 0
        var stackIDs: Set<String> = []
        var counts: [String: Int] = [:]
        var order: [String] = []
        var faulted: [(stem: String, word: String?)] = []
        for r in rows {
            if r.override != nil { moved += 1 }
            if r.rating >= VerdictValue.inThreshold { forward += 1; continue }
            if r.rating == 1 {
                alike += 1
                if let s = r.stack, !s.isEmpty { stackIDs.insert(s) }
                continue
            }
            // Its reason ("below the cut") is the tier's name, not a fault,
            // and is never printed.
            if r.rating == 2 { aside += 1; continue }
            faulty += 1
            let raw = (r.reason ?? "").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { faulted.append((r.stem, nil)); continue }
            let word = Strings.Cull.reasonWord(raw)
            faulted.append((r.stem, word))
            if counts[word] == nil { order.append(word) }
            counts[word, default: 0] += 1
        }
        putForward = forward
        stacked = alike
        stacks = stackIDs.count
        setAside = aside
        faults = faulty
        movedSince = moved
        var pairs: [(word: String, count: Int)] = []
        for word in order { pairs.append((word: word, count: counts[word] ?? 0)) }
        pairs.sort { a, b in a.count == b.count ? a.word < b.word : a.count > b.count }
        // A last name standing alone is printed rather than folded into
        // "1 other", which would take the same room and say less.
        let named = pairs.count == Self.namedReasons + 1 ? pairs : Array(pairs.prefix(Self.namedReasons))
        reasons = named
        otherFaults = faulty - named.reduce(0) { $0 + $1.count }
        let shown = Set(named.map(\.word))
        var byReason: [String: [String]] = [:]
        var other: [String] = []
        for f in faulted {
            if let w = f.word, shown.contains(w) { byReason[w, default: []].append(f.stem) } else { other.append(f.stem) }
        }
        framesByReason = byReason
        otherFrames = other
    }

    /// What a click on one part of the faults line looks through, by the
    /// link that part carries.
    public func frames(for link: URL) -> ViewerModel.FrameList? {
        guard link.scheme == Self.linkScheme else { return nil }
        let key = link.host(percentEncoded: false) ?? ""
        if key == Self.otherKey {
            return otherFrames.isEmpty ? nil
                : ViewerModel.FrameList(name: Strings.LightTable.anotherFault, stems: otherFrames)
        }
        guard let i = Int(key), reasons.indices.contains(i),
              let stems = framesByReason[reasons[i].word], !stems.isEmpty else { return nil }
        return ViewerModel.FrameList(name: reasons[i].word, stems: stems)
    }

    static let linkScheme = "cull-fault"
    static let otherKey = "other"

    /// The faults line with each fault and its count a link to its frames,
    /// and the words around them plain. The same words as `faultsLine`.
    public var faultsLinked: AttributedString {
        var out = AttributedString(Strings.Cull.faults(faults))
        guard !reasons.isEmpty else { return out }
        out += AttributedString(": ")
        var parts: [(String, String)] = reasons.enumerated().map {
            (Self.unbroken("\($0.element.word) \($0.element.count.formatted())"), "\($0.offset)")
        }
        if otherFaults > 0 { parts.append((Self.unbroken(Strings.Cull.otherFaults(otherFaults)), Self.otherKey)) }
        for (n, part) in parts.enumerated() {
            if n > 0 { out += AttributedString(" · ") }
            var piece = AttributedString(part.0)
            piece.link = URL(string: "\(Self.linkScheme)://\(part.1)")
            out += piece
        }
        return out
    }

    /// "283 with a fault it can name: eyes closed 131 · too soft to read 77 ·
    /// 5 other". The named counts and the other always add up to the number
    /// in front.
    ///
    /// Each reason and its count are held together with no-break spaces, so
    /// the line wraps only at a " · ": at 900 pt it broke inside a reason,
    /// "face in" at the end of one line and "shadow 5" on the next.
    public var faultsLine: String {
        var parts = reasons.map { Self.unbroken("\($0.word) \($0.count.formatted())") }
        if otherFaults > 0, !parts.isEmpty { parts.append(Self.unbroken(Strings.Cull.otherFaults(otherFaults))) }
        let head = Strings.Cull.faults(faults)
        return parts.isEmpty ? head : "\(head): \(parts.joined(separator: " · "))"
    }

    /// The words of one "reason count" pair, joined so no line breaks them.
    static func unbroken(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    public var setAsideLine: String { Strings.Cull.setAside(setAside) }

    public var stackedLine: String { Strings.Cull.stacked(stacked, into: stacks) }
}

/// Cull (DESIGN.md §2.6): one slider, one flag, one button — and afterwards
/// the same page becomes the report, because a separate card for the answer is
/// a second place to look for the same thing.
public struct CullStep: StepView {
    @Bindable var model: StepsModel
    let session: ShootSession
    @State private var askAgain = false
    /// The question is being asked of a cull that goes in Up Next rather
    /// than starting: ⌥, or something of his running. Added without asking,
    /// Cull Again… queued a seven-minute re-cull the ellipsis promised to
    /// ask about first.
    @State private var againAdds = false

    public init(session: ShootSession, client: StudioClient, pump: ImagePump) {
        self.session = session
        let m = StepsModelStore.shared.model(for: session, jobs: StepJobs.model(client: client))
        _model = Bindable(wrappedValue: m)
    }

    private var runner: StepJobRunner { model.cullJob }

    /// The report is built from **every row of the shoot**, so it is built
    /// once per change of the shoot and not once per body.
    ///
    /// It used to be a computed property read by `reportView`, which is built
    /// by `settings`, which is built by `body` — and `body` re-runs on every
    /// tick of the focus slider, because the slider binds to `model.focus` and
    /// the label reads it. Measured against the real type in a release build:
    /// 0.056 ms at 300 frames, 0.163 at 900, 0.359 at 2000, plus an array copy
    /// of every row, on every tick of a drag. Nothing in it depends on the
    /// slider.
    @State private var report = CullReport(rows: [])

    private func rebuildReport() {
        report = CullReport(rows: session.order.compactMap { session.rows[$0] })
    }

    /// The light table, on just the frames one fault covers (§2.6).
    private func lookThrough(_ list: ViewerModel.FrameList) {
        ViewerModel.shared(for: session, navigation: LightTableRegistration.navigation).lookThrough(list)
        StepSlots.showStep?(session.name, "keepers")
    }

    /// Four counts. Everything the report draws moves one of them, and reading
    /// them costs nothing next to walking every row.
    private var reportSignature: [Int] {
        [session.order.count, session.info.kept, session.info.dropped, session.info.cull_picks]
    }

    public var body: some View {
        StepScaffold(title: Strings.Cull.title,
                     blurb: session.info.culled ? nil : Strings.Cull.blurb) {
            if session.info.frames == 0 {
                ContentUnavailableView(Strings.Cull.noFrames, systemImage: Symbols.stepIngest)
                    .frame(maxWidth: .infinity)
            } else {
                settings
            }
        } action: {
            StepActionBar {
                leading
            } box: {
                JobInPlace(phase: runner.phase, stop: { runner.stop() },
                           cancelQueue: { runner.cancelQueued() }) {
                    if session.info.culled, let go = StepSlots.showStep {
                        // Once it has culled, what he does next is choose,
                        // so that is what Return does. Culling again is the
                        // toolbar's, one press of ⌘R away, and never the
                        // default: by habit he pressed Return here after
                        // every cull and got "Cull this shoot again?".
                        Button(Strings.Cull.continueToKeepers) { go(session.name, "keepers") }
                            .primaryActionStyle()
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("step.primary")
                    } else {
                        // "Cull It", or "Add Cull It to the List" while
                        // something is running — and ⌥ always means the list.
                        // It never queues silently: the button says which.
                        StepPrimary(session.info.culled ? Strings.Cull.again : Strings.Cull.run,
                                    wouldWait: model.wouldWait,
                                    disabled: session.info.frames == 0) {
                            press(adding: false)
                        } addToTheList: {
                            press(adding: true)
                        }
                    }
                }
            }
        }
        .toolbar {
            // Cull Again… only, once the shoot is culled: the page's main
            // button is at its bottom right, once, and before a cull that is
            // Cull It (§2.3). The toolbar holds the second thing he may do,
            // never a copy of the first.
            if session.info.culled {
                ToolbarItem(placement: .primaryAction) {
                    // The same two choices as the box would have, worked out in
                    // the same place and from the same modifier.
                    StepPrimaryToolbarButton(Strings.Cull.again,
                                             wouldWait: model.wouldWait,
                                             // Shoot ▸ Cull's own key, read from
                                             // the table that owns it, so the
                                             // button and the menu item cannot
                                             // come to mean two different things.
                                             shortcut: StepPrimaryWords.toolbarKey(for: CommandTable.ID.cull),
                                             // Not while this shoot's own cull
                                             // runs: ⌘R then queued a second
                                             // cull of the shoot being culled.
                                             disabled: session.info.frames == 0 || runner.phase != .idle,
                                             busy: runner.phase != .idle) {
                        press(adding: false)
                    } addToTheList: {
                        press(adding: true)
                    }
                }
            }
        }
        .alert(Strings.Cull.againTitle, isPresented: $askAgain) {
            // Cancel is the default, said here rather than left to the
            // alert: left to itself it makes the button that is not Cancel
            // the default, and a Return pressed by reflex would start a
            // seven-minute re-cull.
            Button(Strings.Cull.cancel, role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button(Strings.Cull.againConfirm(adds: againAdds)) { againAdds ? addIt() : start() }
        } message: {
            Text(Strings.Cull.againBody(session.info.kept, minutes, focus: model.focusSetting, moving: model.peopleMove))
        }
        // Shoot ▸ Cull It and Cull Again… are this button, pressed from the
        // menu (DESIGN.md §2.12).
        .answersMenu([CommandTable.ID.cull, CommandTable.ID.cullAgain], shoot: session.name) { _, option in
            // Its own cull running or already on the list: a press now would
            // be a second cull of this shoot, so it is ignored, as the grey
            // row and the grey toolbar button say.
            guard session.info.frames > 0, runner.phase == .idle,
                  !PagePresses.inHand(shoot: session.name, job: model.jobs.job, list: Queues.state)
                    .contains("cull")
            else { return }
            press(adding: StepPrimaryWords.adds(wouldWait: model.wouldWait, optionHeld: option))
        }
        .task {
            // Nothing takes the keyboard on arrival. The slider did, so the
            // arrow he pressed out of habit, coming from the light table,
            // moved the setting the next cull would run with. Return is the
            // only key the page answers until he picks something.
            rebuildReport()
            model.observeJobs(ext: nil)
        }
        .onChange(of: reportSignature) { _, _ in rebuildReport() }
        // His cull waiting on the list runs with what it was put there with,
        // and the held controls show that, whatever the shoot last said.
        .onChange(of: runner.listed?.item, initial: true) { _, item in
            if let item { model.adoptWaiting(item) }
        }
        .onDisappear { model.stopObserving() }
    }

    // MARK: - the report

    @ViewBuilder private var reportView: some View {
        let r = report
        Section {
            VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
                Text(Strings.Cull.putForward(r.putForward, of: r.frames))
                    .font(.title3)
                    .monospacedDigit()
                // One row for each mark the filmstrip draws, with that mark,
                // so the report teaches what he is about to see there.
                VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
                    if r.faults > 0 {
                        // Each fault and its count is a link: "eyes closed
                        // 131" opens Choose Keepers on just those frames, so
                        // checking that the cull was not too harsh on a
                        // frame caught mid-blink is not a walk through 288
                        // bursts.
                        // `StepRow`'s shape, with words that carry links.
                        Label {
                            Text(r.faultsLinked).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: Symbols.cullFault)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Tokens.Palette.fault)
                        }
                            .help(Strings.LightTable.faultsLinkHelp)
                            .environment(\.openURL, OpenURLAction { url in
                                guard let list = r.frames(for: url) else { return .discarded }
                                lookThrough(list)
                                return .handled
                            })
                    }
                    if r.setAside > 0 { StepRow(Symbols.cullAside, r.setAsideLine) }
                    if r.stacked > 0 { StepRow(Symbols.cullAside, r.stackedLine) }
                }
                .font(.callout)
                .monospacedDigit()
                VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
                    if r.movedSince > 0 { Text(Strings.Cull.markedByHim(r.movedSince, of: r.frames)) }
                    // What the results above came from, as the cull recorded
                    // them once it had written them. Not `info.focus`, which
                    // is written when a cull starts: after a re-cull he
                    // stopped, it named settings nothing on screen came from.
                    // A shoot culled before that was kept says nothing.
                    if let ran = session.info.cull_ran_with {
                        Text(Strings.Cull.culledWith(focus: ran.focus, moving: ran.moving))
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                StepLink(Strings.Cull.learnedLink, go: StepSlots.showLearned)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Tokens.Metric.labelValueGap)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - the two things it can be asked

    @ViewBuilder private var settings: some View {
        Form {
            if session.info.culled {
                reportView
                // Once it has culled, the two settings matter only for Cull
                // Again, so they are folded away under the report rather than
                // standing at full size between him and what he reads next.
                // Open or shut, per shoot, as he left it.
                Section {
                    DisclosureGroup(isExpanded: $model.cullSettingsShown) {
                        VStack(alignment: .leading, spacing: Tokens.Metric.groupGap) {
                            if let note = inUseNote { StepNote(note) }
                            focusControls
                            Divider()
                            movingControls
                        }
                        .disabled(inUseNote != nil)
                        .padding(.top, Tokens.Metric.labelValueGap)
                    } label: {
                        Text(Strings.Cull.settingsForAgain)
                    }
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
                        if let note = inUseNote {
                            StepNote(note)
                        } else if !session.info.cull_from.isEmpty {
                            // His last shoot's settings, said as such: every
                            // new shoot opened on 1.9 and off, and he set
                            // them back every evening.
                            StepNote(Strings.Cull.asLastTime(session.info.cull_from))
                        }
                        focusControls
                    }
                }
                .disabled(inUseNote != nil)
                Section {
                    movingControls
                }
                .disabled(inUseNote != nil)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        // The scaffold already holds the page to its column; the form fills
        // that, so one narrow row cannot pull every section in with it.
        .frame(maxWidth: .infinity)
    }

    /// While his cull runs or waits, the two settings are the ones it was
    /// sent with, and are held still. They stayed live, so a nudge during a
    /// seven-minute run changed nothing about it and silently changed the next.
    private var inUseNote: String? { Self.settingsNote(runner.phase) }

    /// Nil exactly when the settings can be changed.
    static func settingsNote(_ phase: StepJobPhase) -> String? {
        switch phase {
        case .idle: return nil
        case .starting: return Strings.Cull.settingsStarting
        case .running, .stopping: return Strings.Cull.settingsInUse
        case .queued, .listed: return Strings.Cull.settingsWaiting
        }
    }

    @ViewBuilder private var focusControls: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            LabeledContent {
                // The word first and the number last, so the number stays
                // put against the edge while the word beside it changes
                // length under a drag.
                HStack(spacing: Tokens.Metric.relatedGap) {
                    Text(Strings.Cull.focusWord(model.focusSetting))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f", model.focusSetting))
                        .monospacedDigit()
                }
                .lineLimit(1)
            } label: {
                Text(Strings.Cull.focus)
            }
            // No `step`: a stepped slider on the Mac is an NSSlider with a
            // tick per step that only stops on them, so the knob jumped from
            // one of 19 notches to the next. It follows his hand; the number
            // is rounded where it is printed and where it is sent.
            Slider(value: $model.focus, in: 1.2...3.0) {
                Text(Strings.Cull.focus)
            } minimumValueLabel: {
                Text(Strings.Cull.focusLenientEnd).font(.footnote).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(Strings.Cull.focusStrictEnd).font(.footnote).foregroundStyle(.secondary)
            }
            .labelsHidden()
            .accessibilityLabel(Text(Strings.Cull.focus))
            .accessibilityValue(Text("\(String(format: "%.1f", model.focusSetting)), \(Strings.Cull.focusWord(model.focusSetting))"))
            StepNote(Strings.Cull.focusNote)
        }
    }

    @ViewBuilder private var movingControls: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            Toggle(Strings.Cull.moving, isOn: $model.peopleMove)
            StepNote(Strings.Cull.movingNote)
        }
    }

    @ViewBuilder private var leading: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            if let m = model.jobs.refusals[.job] { RefusalRow(m, owner: .job) }
            // The list refused to take it - a sentence the engine wrote, in
            // the place he pressed, rather than a control that is not there.
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
            if let j = runner.mine {
                JobTiming(j)
            } else if let ended = JobEndedNote(runner.lastEnded, failed: Strings.Cull.failed) {
                // Stopped, refused with the engine's sentence, or failed -
                // the last in the alarm colour with the way to its log, and
                // the cull's own word that nothing he marked was changed. It
                // fell through to the time estimate, so a cull that died
                // looked exactly like one never started.
                ended
            } else if !session.info.culled, !app_ready {
                PictureModelOffer()
            } else if !session.info.culled {
                Text(Strings.Cull.estimate(minutes)).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// The picture model is on this Mac, or the engine has not said it is
    /// not: its `ready` on the library read (§2.10).
    private var app_ready: Bool { PictureModel.shared.ready != false }

    /// The engine's own rate: about 230 frames a minute.
    private var minutes: Int { max(1, Int((Double(session.info.frames) / 230.0).rounded(.up))) }

    /// The primary, by every route to it — the box, the toolbar and Shoot ▸
    /// Cull It / Cull Again… — started or added to Up Next. Culling a shoot
    /// again asks first, whichever way it goes.
    private func press(adding: Bool) {
        if session.info.culled {
            againAdds = adding
            askAgain = true
        } else if adding {
            addIt()
        } else {
            start()
        }
    }

    /// The same work, described rather than started: the kind and the
    /// options, which the engine builds a command from when the turn comes.
    private func addIt() {
        model.addToTheList(kind: "cull", options: [
            "style": .string(model.peopleMove ? "action" : "normal"),
            "focus": .number(model.focusSetting),
        ])
    }

    private func start() {
        model.clearAdded()
        let body = CullBody(name: session.name,
                            style: model.peopleMove ? "action" : "normal",
                            focus: model.focusSetting)
        let jobs = model.jobs
        let client = session.client
        // Behind something of his that is running, it goes on the list — not
        // into a wait held by this page, which he loses by looking elsewhere.
        runner.run(orAdd: { addIt() }) {
            await jobs.start {
                let r = try await client.post(Routes.cull, body)
                if let e = r.error, !r.ok { throw StudioError.refused(e) }
            }
        }
    }
}
