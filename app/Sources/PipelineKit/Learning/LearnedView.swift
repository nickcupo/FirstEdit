import SwiftUI

/// §2.9 — one sidebar item, one page.
///
/// This is the concrete answer to *"the retraining is confusing"*: one place,
/// plain words, every per-frame decision visible, one button to go back.
///
/// It is a grouped `Form`, the same shape as the storage panel, so the two
/// library-wide screens read as one app rather than two.
public struct LearnedView: View {
    let app: AppModel
    @State private var model: LearnedModel
    @State private var reviewing: Learner?
    /// The shoot a needs line asked him to bring back, with its own storage
    /// model, while its list is on screen.
    @State private var pulling: Pulling?
    /// How many times Learn Now has been pressed on this page. The page's one
    /// watch is keyed on it, so a press starts a fresh watch that SwiftUI
    /// cancels with the page.
    @State private var learnPresses = 0

    struct Pulling: Identifiable {
        let model: StorageModel
        var id: String { model.shoot }
    }

    public init(app: AppModel) {
        self.app = app
        _model = State(initialValue: LearnedModel(client: app.client))
    }

    /// For the harness and the tests: a page that already has its answer.
    public init(app: AppModel, model: LearnedModel) {
        self.app = app
        _model = State(initialValue: model)
    }

    public var body: some View {
        // The window's own title bar already says where he is (§2.1), so this
        // page does not say it again. What it does say, at the top, is what
        // every change on it is measured against.
        GeometryReader { geo in
            VStack(spacing: 0) {
                ScrollViewReader { scroll in
                    Form {
                        if let m = model.refusals[.learning] {
                            Section { RefusalRow(m, owner: .learning) }
                        }
                        if let banner = model.banner {
                            Section { bannerRow(banner, scroll) }
                        }
                        content
                    }
                    .formStyle(.grouped)
                    .columnForm()
                }
                // Learn Now is the page's main button, at its bottom right,
                // once, as on every step (§2.3): it was in the far corner of
                // the toolbar, and again beside the line saying what was
                // ready to learn from whenever something was.
                StepActionBar {
                    barLine
                } box: {
                    learnNowButton
                }
                .environment(\.stepColumnWidth, Self.barWidth(in: geo.size.width))
            }
        }
        .task(id: learnPresses) {
            if learnPresses == 0 { await model.load() }
            // Only while there is a run to watch, and it stops itself when
            // there is not — or when he leaves the page.
            await model.watchWhileItRuns()
        }
        .sheet(item: $reviewing) { learner in
            ReviewModeHost(learner: learner, model: model, app: app) { reviewing = nil }
        }
        // A needs line's Bring … Back…: the same list, sheet and button as
        // the shoot's own storage panel, opened here, so bringing a shoot
        // back to be learned from is not a trip to its Finish page and back.
        .sheet(item: $pulling) { p in
            PlanSheet(rung: nil, request: StorageModel.Request("pull"), model: p.model) {
                pulling = nil
                Task { await model.load() }
            }
        }
    }

    /// The bar's two edges on the form's cards: the page column (`columnForm`)
    /// less the grouped form's own inset each side.
    static func barWidth(in width: CGFloat) -> CGFloat {
        max(240, min(Tokens.Metric.column, width) - 2 * StepMetric.formInset)
    }

    /// Prominent while there is a finished shoot it has not learned from; a
    /// plain button of the same size when there is none, since a run then
    /// only checks again what it has.
    @ViewBuilder private var learnNowButton: some View {
        let button = Button(action: learnNow) {
            Label(Strings.Learning.learnNow, systemImage: Symbols.learnNow)
        }
        if (model.learned?.new_shoots ?? 0) > 0 {
            learnNowTraits(button.primaryActionStyle())
        } else {
            learnNowTraits(button.controlSize(.large))
        }
    }

    private func learnNowTraits(_ button: some View) -> some View {
        button
            .labelStyle(.titleAndIcon)
            // Off while a run is going, and while the record will not read:
            // learning would only refuse, for the reason already on the page.
            .disabled(model.learned?.running == true || model.learned?.unreadable == true)
            .help(model.learned?.unreadable == true ? Strings.Learning.learnNowWaitsForRecord
                                                    : Strings.Learning.headline)
            .accessibilityIdentifier("learning.learnNow")
    }


    /// Beside Learn Now: when it last looked, and what is waiting to be
    /// learned from, by name. Nothing while the record will not read, or with
    /// no engine to ask.
    @ViewBuilder private var barLine: some View {
        if let l = model.learned, !l.unreadable {
            footer(l)
        } else {
            // A real view, however empty: `EmptyView` takes no width, and the
            // box would fall to the middle of the bar.
            Color.clear.frame(height: 0)
        }
    }

    /// Asks for the run, then hands the watching to the page's own task. The
    /// request is short and stands alone; the watch can last hours when the
    /// run is queued behind his work, and must end with the page.
    private func learnNow() {
        Task {
            await model.run()
            learnPresses += 1
        }
    }

    /// What a needs line asks, done from the line.
    private func act(_ need: LearnerNeed) {
        switch need.act {
        case .pull:
            pulling = Pulling(model: StorageModel(shoot: need.shoot, client: app.client))
        case .finish:
            app.navigation.selection = .step(shoot: need.shoot, step: "edit")
        case .vectors:
            Task {
                await model.measure(need.shoot)
                // His job now: the toolbar, Stop (⌘.) and the Dock follow it.
                app.jobs.watch()
            }
        }
    }

    private func checkedAgainst(_ l: Learned) -> String {
        l.keepers > 0 ? Strings.Learning.checkedAgainst(l.keepers, l.shoots)
                      : Strings.Learning.nothingKeptYet
    }

    @ViewBuilder private var content: some View {
        if let l = model.learned {
            if l.unreadable {
                unreadable(l)
            } else if Self.nothingLearned(l) {
                firstRun(l)
            } else if l.learners.isEmpty && l.fixed.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(Strings.Learning.nothingFinishedYet, systemImage: Symbols.learned)
                    } description: {
                        Text(Strings.Learning.nothingFinishedYetWhy)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                panel(l)
            }
        } else if model.loading {
            Section { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
        } else {
            // No engine behind this page: the headline is still true, and the
            // screen says nothing it cannot support.
            Section {
                Text(Strings.Learning.headline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Every learner the engine sent has learned nothing — the page he meets
    /// the first time. The engine always sends its three learners, so the
    /// designed empty state never appeared: he got a header, three rows and a
    /// footer that all said "Nothing", while the shoot he had just finished
    /// sat unnamed in "1 new shoot to learn from".
    static func nothingLearned(_ l: Learned) -> Bool {
        !l.learners.isEmpty && l.learners.allSatisfy { $0.status == .none && $0.candidate_sentence.isEmpty }
    }

    /// One short section: what is ready to be learned from, with the button,
    /// or what would make something ready; then one line for each thing it
    /// will learn, instead of three identical rows saying nothing yet.
    @ViewBuilder private func firstRun(_ l: Learned) -> some View {
        Section {
            Text(l.headline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if l.running {
                runningRow(l)
            } else if l.queued {
                Label(model.inTheWay.map(Strings.Learning.queuedBehind) ?? Strings.Learning.queued,
                      systemImage: Symbols.notEnough)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if l.new_shoots > 0 {
                // What is ready, and Learn Now, are the bar's (§2.9).
                EmptyView()
            } else {
                Text(Strings.Learning.nothingFinishedYetWhy)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(Strings.Learning.nothingLearnedYet).font(.headline).foregroundStyle(.primary)
        }
        Section(Strings.Learning.whatItWillLearn) {
            ForEach(l.learners) { learner in
                VStack(alignment: .leading, spacing: 2) {
                    Text(learner.title).font(.callout)
                    if !learner.changes.isEmpty {
                        Text(learner.changes.capitalizedFirst)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // How to give it something to learn from, where the
                    // engine says: its lines after the "not enough yet" one.
                    ForEach(Array(learner.needs_lines.dropFirst().enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .id(learner.id)
            }
        }
        if !l.fixed.isEmpty {
            Section(Strings.Learning.fixedHeader) {
                ForEach(l.fixed) { FixedThingRow(thing: $0) }
            }
        }
    }

    @ViewBuilder private func panel(_ l: Learned) -> some View {
        Section {
            Text(l.headline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if l.running {
                runningRow(l)
            } else if l.queued {
                // What it is waiting behind, by the engine's own name for it.
                Label(model.inTheWay.map(Strings.Learning.queuedBehind) ?? Strings.Learning.queued,
                      systemImage: Symbols.notEnough)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(checkedAgainst(l)).font(.headline).foregroundStyle(.primary)
        }

        Section {
            ForEach(l.learners) { learner in
                LearnerRow(learner: learner, model: model, showFrames: { reviewing = $0 }, act: act)
                    .id(learner.id)
            }
        }

        if !l.fixed.isEmpty {
            Section(Strings.Learning.fixedHeader) {
                ForEach(l.fixed) { FixedThingRow(thing: $0) }
            }
        }
    }

    /// §2.9, while it runs: what it is learning from, what it is doing now,
    /// how far along, roughly what is left, why it is safe to stop, and Stop.
    ///
    /// Six months of this row saying "Learning…" over a bar that never moved
    /// is the whole reason he could not tell a working machine from a stuck
    /// one. Every string in here is the engine's — it is the thing that knows
    /// what the run is doing — and the app adds the bar, the button, and
    /// nothing else.
    private func runningRow(_ l: Learned) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.relatedGap) {
                Text(headline(l))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Tokens.Metric.relatedGap)
                if model.stopping {
                    Text(Strings.Learning.stopping)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Button(Strings.Learning.stopLearning) {
                        Task { await model.stopLearning() }
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("learning.stop")
                }
            }
            // Where it has got to, in the engine's own stage words, and
            // roughly how long is left — or neither half, when the engine
            // will not say. Nothing is invented to fill the line.
            if let where_ = l.job?.whereItHasGot, !where_.isEmpty {
                Text(where_)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProgressView(value: min(max(l.job?.fraction ?? 0, 0), 1))
                .progressViewStyle(.linear)
                .accessibilityHidden(true)
            // Why he can press Stop without thinking about it. Said before
            // he decides, not after.
            Text(l.job?.safe_to_stop.isEmpty == false ? l.job!.safe_to_stop
                                                      : Strings.Learning.safeToStop)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken(l))
        .accessibilityIdentifier("learning.running")
    }

    /// "Learning from 2026-09-21". The engine's, where it sent one.
    private func headline(_ l: Learned) -> String {
        if let title = l.job?.title, !title.isEmpty { return title }
        return l.new_shoot_names.first.map { Strings.Learning.learningFrom($0, l.keepers) }
            ?? Strings.Learning.learningNow
    }

    /// One sentence for VoiceOver. §2.15: progress is announced at the start
    /// and the finish, not on every tick, so this is the label on the group
    /// rather than a live region.
    private func spoken(_ l: Learned) -> String {
        [headline(l), l.job?.whereItHasGot ?? ""].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// When it last looked, and what is waiting to be learned from — by
    /// name, in the bar beside Learn Now. It said "1 new shoot to learn
    /// from" with Learn Now in the far corner of the toolbar. While a run is
    /// going the second half is left off: the running row above already
    /// names the shoot it is learning from.
    private func footer(_ l: Learned) -> some View {
        Text(Self.footerLine(l))
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(3)
    }

    static func footerLine(_ l: Learned) -> String {
        let checked = l.last_checked.flatMap(Self.when).map(Strings.Learning.lastChecked) ?? Strings.Learning.neverChecked
        return l.running ? checked : checked + " · " + Self.waiting(l)
    }

    /// "Ready to learn from 2026-09-19", naming the shoots the engine named.
    static func waiting(_ l: Learned) -> String {
        guard l.new_shoots > 0 else { return Strings.Learning.nothingNew }
        guard !l.new_shoot_names.isEmpty else { return Strings.Learning.newShoots(l.new_shoots) }
        return Strings.Learning.readyToLearnFrom(l.new_shoot_names)
    }

    /// "22 Sep, 14:10", in his own locale and time zone. An ISO stamp on
    /// screen is a machine talking to itself.
    ///
    /// The engine writes local time with no zone on it, sometimes with a
    /// fraction, and sometimes only a date. A stamp this cannot read is
    /// printed as it arrived rather than guessed at.
    static func when(_ stamp: String) -> String? {
        guard !stamp.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
                       "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = format
            guard let date = f.date(from: stamp) else { continue }
            let day = date.formatted(.dateTime.day().month(.abbreviated))
            return format == "yyyy-MM-dd"
                ? day
                : day + ", " + date.formatted(.dateTime.hour().minute())
        }
        return stamp
    }

    /// The record itself will not read. The engine's sentence, the parser's
    /// reason under Details, the file itself as a path he can click and a
    /// button that shows it in Finder — and no action that depends on what
    /// could not be read. The sentence used to begin with his whole home
    /// folder, in lower case, over a path that did nothing when clicked.
    private func unreadable(_ l: Learned) -> some View {
        Section {
            RefusalRow((l.error ?? Strings.Learning.nothingCanBeRead).capitalizedFirst,
                       owner: .learning, detail: l.unreadable_why)
            if let file = l.record ?? (l.folder.isEmpty ? nil : l.folder) {
                LabeledContent(l.record == nil ? Strings.Learning.folder : Strings.Learning.recordIs) {
                    HStack(spacing: Tokens.Metric.relatedGap) {
                        PathRow(URL(fileURLWithPath: file))
                        Button(Strings.Learning.showInFinder) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
                        }
                        .accessibilityIdentifier("learning.unreadable.showInFinder")
                    }
                }
            }
        }
    }

    /// What the run that just ended did, in one line (§2.9). What Changed
    /// brings the first row it changed into view and lights it; it used to
    /// be the banner's only button and only dismissed it — though nothing
    /// ever put a banner up to dismiss.
    private func bannerRow(_ text: String, _ scroll: ScrollViewProxy) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.relatedGap) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("learning.banner")
            Spacer(minLength: 0)
            if let first = model.bannerLearner {
                Button(Strings.Learning.whatChanged) {
                    withAnimation(Motion.step) { scroll.scrollTo(first, anchor: .top) }
                    Task { await model.highlight(first) }
                }
                .controlSize(.small)
            }
            Button {
                model.clearBanner()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(Strings.Learning.dismissBanner)
            .accessibilityLabel(Strings.Learning.dismissBanner)
        }
    }
}
