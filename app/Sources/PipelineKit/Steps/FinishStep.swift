import SwiftUI

/// Finish (DESIGN.md §2.6).
///
/// Pressing it records his keepers and marks the shoot finished, in that
/// order, because a shoot marked finished with nothing recorded is the one
/// state that cannot be mended by pressing the button again. The keepers are
/// what every later change to the cull is checked against, all of them; what
/// the cull learns from is only the frames he exported, which the engine
/// writes down as it marks the shoot finished.
///
/// If recording would replace a larger set with a smaller one, the engine
/// refuses and says so, and the question is put to him with both numbers in
/// it — in the app's own words, because the engine's sentence was written for
/// the web page: it named a file, a Re-read button that is gone, and deleting
/// by hand. Nothing of his is narrowed without him choosing it.
public struct FinishStep: StepView {
    @Bindable var model: StepsModel
    let session: ShootSession
    @State private var refusal: String?

    public init(session: ShootSession, client: StudioClient, pump: ImagePump) {
        self.session = session
        let m = StepsModelStore.shared.model(for: session, jobs: StepJobs.model(client: client))
        _model = Bindable(wrappedValue: m)
    }

    private var finished: Bool { session.info.finished || model.finishedNow }

    public var body: some View {
        StepScaffold(title: Strings.Finish.title) {
            exportsCard
            // The storage panel of §2.8 belongs to the storage crew and is
            // drawn here when it has been handed over. Nothing is drawn in its
            // place: an empty box promising storage would be worse than none.
            if let panel = StepSlots.storagePanel { panel(session) }
        } action: {
            StepActionBar {
                leading
            } box: {
                // It prints in place: where the button was, the fact that it
                // is done. The sentence that says what was recorded is beside
                // it, because it is three lines long and this box is one.
                if finished {
                    Label(finishedOn, systemImage: Symbols.stepDone)
                        .font(.callout)
                        .foregroundStyle(Tokens.Palette.kept)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .accessibilityAddTraits(.isStaticText)
                } else {
                    Button(model.finishing ? Strings.Finish.recording : Strings.Finish.markFinished) {
                        finish(confirmNarrowing: false)
                    }
                    .primaryActionStyle()
                    .disabled(model.finishing)
                    // Return finishes a shoot only once something is
                    // exported. With nothing out, pressing it by habit on
                    // arrival recorded his marks as the keepers and started
                    // the learning run on a shoot he had not edited.
                    .keyboardShortcut(session.info.exported > 0 ? .defaultAction : nil)
                }
            }
        }
        // No copy of the primary in the toolbar (§2.3). A finished shoot kept
        // a greyed Finish This Shoot there that read as a status beside the
        // green "Finished on 22 Sep." at the bottom.
        .alert(shrinkTitle, isPresented: shrinkShown) {
            Button(model.shrink?.had.map(Strings.Finish.shrinkKeepCount) ?? Strings.Finish.shrinkKeep,
                   role: .cancel) {
                // Keeping what is recorded is the whole of the answer: the
                // shoot is still marked finished, and nothing is rewritten.
                model.shrink = nil
                markFinishedOnly()
            }
            // Return and Escape both keep what is recorded. The role alone
            // only claims Escape, and which button a plain alert makes the
            // default is SwiftUI's business — this says it, so the key that
            // gets pressed without reading cannot be the one that narrows
            // his keepers.
            .keyboardShortcut(.defaultAction)
            Button(model.shrink?.now.map(Strings.Finish.shrinkUseCount) ?? Strings.Finish.shrinkUse) {
                model.shrink = nil
                finish(confirmNarrowing: true)
            }
        } message: {
            Text(shrinkBody)
        }
        // Shoot ▸ This Shoot Is Finished is this button, pressed from the
        // menu (DESIGN.md §2.12).
        .answersMenu([CommandTable.ID.finished], shoot: session.name) { _, _ in
            guard !finished, !model.finishing else { return }
            finish(confirmNarrowing: false)
        }
    }

    // MARK: - what is on the disk

    @ViewBuilder private var exportsCard: some View {
        let i = session.info
        Form {
            Section {
                if i.exported > 0 {
                    StepRow(Symbols.stepEdit, Strings.Finish.exports(i.exported), done: true)
                    // One row per folder, each with its own Show, as on the
                    // Edit page. A comma-joined sentence of paths could not
                    // be opened, and ran to three ragged lines on a deep one.
                    if !i.export_dirs.isEmpty {
                        ForEach(i.export_dirs, id: \.self) { dir in
                            StepPathRow(StepPathRow.exportLabel(dir, shoot: i.path, among: i.export_dirs.count),
                                        dir, what: "exported") { _ in show(dir) }
                        }
                    } else if !i.export_where.isEmpty {
                        // Outside the shoot — iCloud, or a folder moved since.
                        StepNote(i.export_where)
                    }
                } else {
                    StepRow(Symbols.stepEdit, Strings.Finish.noExports)
                    StepNote(Strings.Finish.noExportsWhere(i.export.isEmpty ? i.path + "/export" : i.export))
                }
                // Only once something has recorded them. Before that this
                // engine's `keepers` is the sum of his marks and the cull's,
                // and printing it here would name a number that has not been
                // written and call it his.
                if let n = recorded {
                    StepRow(Symbols.hisKeep, Strings.Finish.recordedKeepers(n, from: recordedFrom), done: true)
                }
                // Two numbers, said apart: every keeper above is what a change
                // to the cull is checked against; only these teach it. The
                // engine says "exported"; "recorded" is an older engine's,
                // from before its keepers stopped standing in for exports.
                if let n = i.taught, n > 0, i.taught_from == "exported" || i.taught_from == "recorded" {
                    StepRow(Symbols.learned, Strings.Finish.learnsFrom(n, recorded: i.taught_from == "recorded"))
                }
            }
            if !finished {
                Section { StepNote(Strings.Finish.keepRawsNote) }
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
            if let refusal { RefusalRow(refusal, owner: .navigation) }
            if finished {
                // Wrapped by line limit, not by `fixedSize`: a text that
                // fixes its own size inside the action bar asks for its whole
                // sentence on one line, and the bar — and with it the page —
                // lays out at a width nothing can draw.
                Text(finishedSentence)
                    .font(.callout)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                // What Finish did about learning: now, or the engine's own
                // words about a run that waits, printed as it wrote them;
                // nothing when he has switched automatic learning off.
                if let line = model.learningLine, !line.isEmpty {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                StepLink(Strings.Finish.learnedLink, go: StepSlots.showLearned)
            }
        }
    }

    /// What was recorded, when something recorded it: this session's own
    /// answer from `/api/selects`, or a finished shoot's frozen set.
    private var recorded: Int? {
        if let n = model.recordedKeepers { return n }
        // The engine names this number `recorded_keepers` now; `keepers` is
        // the same count on today's engine and the fallback for an older one.
        // Never `kept`, which is his own presses and a different number.
        let frozen = session.info.recorded_keepers ?? session.info.keepers
        return session.info.finished && frozen > 0 ? frozen : nil
    }

    /// Where the recorded keepers came from, as the engine recorded it.
    private var recordedFrom: String { model.recordedFrom ?? session.info.recorded_from }

    /// What was recorded — the answer key every check measures against — and
    /// what the cull learns from, the frames he exported, as the engine
    /// counts them (`taught`).
    private var finishedSentence: String {
        recorded.map {
            Strings.Finish.finished($0, from: recordedFrom, taught: session.info.taught,
                                    taughtFrom: session.info.taught_from)
        } ?? Strings.Finish.finishedNoCount
    }

    private var finishedOn: String {
        session.info.finished_on.isEmpty ? Strings.Finish.alreadyFinished : Strings.Finish.finishedOn(session.info.finished_on)
    }

    /// The app's own sentence from the two numbers; the engine's only when
    /// they could not be read out of it.
    private var shrinkBody: String {
        guard let s = model.shrink else { return "" }
        return RecordedKeepers.body(for: s.sentence) ?? s.sentence
    }

    private var shrinkShown: Binding<Bool> {
        Binding(get: { model.shrink != nil }, set: { if !$0 { model.shrink = nil } })
    }

    private var shrinkTitle: String {
        guard let s = model.shrink, let had = s.had, let now = s.now else { return Strings.Finish.shrinkTitle }
        return Strings.Finish.shrinkTitleCounts(had, now)
    }

    // MARK: - doing it

    private func finish(confirmNarrowing: Bool) {
        refusal = nil
        model.finishing = true
        let client = session.client
        let name = session.name
        Task { @MainActor in
            defer { model.finishing = false }
            do {
                let r = try await client.post(Routes.selects, SelectsBody(name: name, confirm: confirmNarrowing ? true : nil))
                if r.confirm == true, let sentence = r.error {
                    // The engine declined on purpose and named both numbers in
                    // its own sentence. It is put to him with them, and the
                    // shoot is not marked finished until he has answered.
                    let counts = RecordedKeepers.counts(in: sentence)
                    model.shrink = StepsModel.ShrinkQuestion(sentence: sentence, had: counts.0, now: counts.1)
                    return
                }
                if let e = r.error, r.n == nil {
                    refusal = e
                    return
                }
                model.recordedKeepers = r.n
                model.recordedFrom = r.from.isEmpty ? nil : r.from
                markFinishedOnly()
            } catch let e as StudioError {
                refusal = e.sentence
            } catch {
                refusal = Strings.API.offline
            }
        }
    }

    /// Show one of the folders the engine found this shoot's exports in.
    private func show(_ dir: String) {
        refusal = nil
        let client = session.client
        let body = OpenBody(name: session.name, what: "exported", path: dir)
        Task { @MainActor in
            do {
                let r = try await client.post(Routes.open, body)
                if let e = r.error, !r.ok { refusal = e }
            } catch let e as StudioError {
                refusal = e.sentence
            } catch {
                refusal = Strings.API.offline
            }
        }
    }

    /// The line under the finished sentence, from the engine's answer about
    /// the learning run Finish asked for (Settings ▸ Learning).
    nonisolated static func learningLine(_ l: LearningStart?) -> String? {
        guard let l, !l.off else { return nil }
        if l.running { return Strings.Finish.learningNow }
        if l.queued, let note = l.note, !note.isEmpty { return note }
        return nil
    }

    private func markFinishedOnly() {
        let client = session.client
        let name = session.name
        Task { @MainActor in
            do {
                let r = try await client.post(Routes.kind, KindBody(name: name, finished: true))
                if let e = r.error, !r.ok { refusal = e; return }
                model.finishedNow = true
                // The engine starts (or queues) the learning run itself when a
                // shoot is marked finished, and says so here. NOTHING in the
                // app posts /api/learned/run after this: two starts is two
                // jobs, and the one that loses is his.
                model.learningLine = Self.learningLine(r.learning)
                try? await session.reload(ext: nil)
            } catch let e as StudioError {
                refusal = e.sentence
            } catch {
                refusal = Strings.API.offline
            }
        }
    }

}

/// Reading the engine's refusal well enough to put its two numbers on two
/// buttons.
///
/// This only looks for the counts. With both, the sheet is written from them;
/// when it cannot find them the engine's sentence is shown as it wrote it and
/// the buttons say what they do in words instead. Nothing is guessed.
public enum RecordedKeepers {

    /// The engine names the file it refuses to overwrite, and that name is the
    /// path to selects.json inside a shoot folder called after its own date:
    /// `…/2026-09-13-dog/cull/selects.json`. Counting digit runs from the front
    /// of the sentence reads that date, or a number in the library's path, and
    /// puts it on a button as if it were his frames. So the counts are only
    /// taken from the words around them, and a path is never scanned at all.
    /// The sheet's body in the app's words, or nil when the two numbers
    /// cannot be read out of the engine's sentence and it is shown instead.
    public static func body(for sentence: String) -> String? {
        let (had, now) = counts(in: sentence)
        guard let had, let now else { return nil }
        return Strings.Finish.shrinkBody(had, now, exportsGone: exportsGone(in: sentence))
    }

    /// Whether the refusal is the finished shoot's whose exports cannot be
    /// found — the one whose cause is known — by the same words `counts`
    /// reads it by.
    public static func exportsGone(in sentence: String) -> Bool {
        number(in: sentence, after: "holds", before: "frames chosen") != nil
    }

    public static func counts(in sentence: String) -> (Int?, Int?) {
        // "…this would replace N chosen frames with M;…"
        if let had = number(in: sentence, after: "replace", before: "chosen frames with"),
           let now = number(in: sentence, after: "chosen frames with", before: nil) {
            return (had, now)
        }
        // "…this finished shoot's keeper list holds N frames chosen from
        //  exports that cannot be found now, and recording again would
        //  replace it with M frames…" — and the older "{path} holds N…".
        let had = number(in: sentence, after: "holds", before: "frames chosen")
        let now = number(in: sentence, after: "replace it with", before: nil)
        if had != nil || now != nil { return (had, now) }
        // Any other refusal the engine grows: its numbers are read, but only
        // after every path-shaped word is out of the sentence.
        return firstTwo(in: withoutPaths(sentence))
    }

    /// The first whole number that stands between two anchors. `before` nil
    /// means the number must follow `after` immediately, allowing only words
    /// that are not numbers in between.
    private static func number(in sentence: String, after: String, before: String?) -> Int? {
        let lower = sentence.lowercased()
        guard let start = lower.range(of: after.lowercased()) else { return nil }
        var tail = String(sentence[start.upperBound...])
        if let before {
            guard let end = tail.lowercased().range(of: before.lowercased()) else { return nil }
            tail = String(tail[..<end.lowerBound])
        }
        // Only the words right after the anchor, so a later sentence cannot
        // answer for this one.
        let words = tail.split(whereSeparator: { $0 == " " || $0 == "\n" }).prefix(4)
        for word in words {
            // The punctuation the sentence hangs on a number ("3;", "12,") is
            // not part of it; a word that is anything else than digits — a
            // date in a folder name, a version — is not a count.
            let token = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if !token.isEmpty, token.allSatisfy(\.isNumber), let n = Int(token) { return n }
        }
        return nil
    }

    private static func withoutPaths(_ sentence: String) -> String {
        sentence.split(whereSeparator: { $0 == " " || $0 == "\n" })
            .filter { !$0.contains("/") }
            .joined(separator: " ")
    }

    private static func firstTwo(in sentence: String) -> (Int?, Int?) {
        var numbers: [Int] = []
        for piece in sentence.split(whereSeparator: { !$0.isNumber }) {
            if let n = Int(piece) { numbers.append(n) }
            if numbers.count == 2 { break }
        }
        guard numbers.count >= 2 else { return (nil, nil) }
        return (numbers[0], numbers[1])
    }
}
