import AppKit
import SwiftUI

/// An extension step, as a page of this app.
///
/// The row in the sidebar, the title in the window and the label on the step
/// are all the extension's own words, fetched at runtime. Everything around
/// the page is the app's: the refusal goes under the page where the action was
/// taken and never into an alert, the confirmation is the app's own sheet, and
/// the viewer the page opens is the app's viewer.
public struct ExtStepView: View {
    let session: ShootSession
    let step: String
    let config: ExtConfig
    let endpoint: EngineHost.Endpoint
    /// A page from somewhere other than a socket — a rendered scene, a test.
    var upstream: (any ExtUpstream)?

    @State private var model = ExtStepModel()
    @Environment(\.colorScheme) private var scheme

    public init(session: ShootSession, step: String, config: ExtConfig,
                endpoint: EngineHost.Endpoint, upstream: (any ExtUpstream)? = nil) {
        self.session = session
        self.step = step
        self.config = config
        self.endpoint = endpoint
        self.upstream = upstream
    }

    public var body: some View {
        Group {
            if let page {
                VStack(spacing: 0) {
                    host(page)
                    if model.refusal != nil {
                        ExtRefusalBar(model: model)
                            .transition(.opacity)
                    }
                    if model.said != nil {
                        ExtSaidBar(model: model)
                            .transition(.opacity)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(label, systemImage: Symbols.extensionStep)
                } description: {
                    Text(Strings.Extensions.noPage)
                }
            }
        }
        .animation(Motion.step, value: model.refusal?.sentence)
        .animation(Motion.step, value: model.said)
        .sheet(item: $model.question) { q in
            ExtConfirmSheet(question: q) { said in
                model.answer(said)
            }
        }
        .sheet(item: $model.viewing) { look in
            ExtViewer.make(session: session, stems: look.stems, startAt: look.startAt,
                           marking: ExtViewerMarking(actions: look.actions, marks: look.marks)) { result in
                model.lookEnded(look.id, result)
            }
        }
        .onAppear { model.bind(session: session, step: step) }
        .navigationTitle(session.name)
    }


    private var label: String { config.labels[step] ?? step }

    private var page: URL? {
        ExtPages.upstream(step: step, shoot: session.name, config: config, engine: endpoint.base)
    }

    @ViewBuilder private func host(_ page: URL) -> some View {
        ExtensionHost(page: page,
                      upstream: upstream ?? ExtHTTPUpstream(key: endpoint.key),
                      bridge: model.bridge,
                      label: label,
                      inspectable: SettingsStore.shared.webInspector,
                      scrolledTo: ExtPlaces.scrolled(shoot: session.name, step: step),
                      onRefusal: { model.refuse($0) })
            .frame(minWidth: 0, idealWidth: 480, maxWidth: .infinity,
                   minHeight: 0, idealHeight: 320, maxHeight: .infinity)
            .accessibilityIdentifier("extension.page.\(step)")
    }
}

/// The host's refusal, under the page where the action was taken: one line
/// tall for a one-line sentence, and his to put away.
public struct ExtRefusalBar: View {
    let model: ExtStepModel

    public init(model: ExtStepModel) { self.model = model }

    /// Three lines of the engine's own sentence plus the Details line, which
    /// is more than any refusal has needed.
    public static let maximumHeight: CGFloat = 96
    /// How far the close button's target reaches past the line it sits on,
    /// above and below: into the bar's padding, never past it.
    static let targetReach: CGFloat = 3

    public var body: some View {
        if let refusal = model.refusal {
            VStack(spacing: 0) {
                Divider()
                HStack(alignment: .top, spacing: Tokens.Metric.relatedGap) {
                    RefusalRow(refusal.sentence, owner: .extensionPage, detail: refusal.detail)
                        // The height is bounded on purpose. A `Text` that takes
                        // its ideal height is measured at whatever width it is
                        // offered, and the pane's ideal pass offers none — so an
                        // unbounded row asks for a word-per-line column five
                        // hundred points tall, the window grows to it, and the
                        // top of the app goes off the screen. Bounded and then
                        // fixed, the row is as tall as the sentence at the width
                        // it is drawn at — one line — and never more than the
                        // bound: bounded alone it took the whole bound, a 112 pt
                        // bar for one line.
                        .frame(maxWidth: .infinity, maxHeight: Self.maximumHeight, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)
                    // Said once; he can put it away. It also goes on its own
                    // at the page's next load and at the next thing he asks of
                    // the app from the page. The whole 28 pt target takes the
                    // click, and reaches into the bar's own padding rather
                    // than making a one-line bar taller than its sentence.
                    Button {
                        model.clearRefusal()
                    } label: {
                        Image(systemName: "xmark")
                            .imageScale(.small)
                            .frame(width: Tokens.Metric.minimumHitTarget,
                                   height: Tokens.Metric.minimumHitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, -Self.targetReach)
                    .help(Strings.Extensions.dismissRefusal)
                    .accessibilityLabel(Strings.Extensions.dismissRefusal)
                }
                .padding(.horizontal, Tokens.Metric.windowMargin)
                .padding(.vertical, Tokens.Metric.relatedGap)
                .background(.bar)
            }
        }
    }
}

/// What the page said with `alert()`: one line under the page, in the
/// secondary colour, that asks for nothing (DESIGN.md §2.16). It goes by
/// itself after a few seconds, at his next click on the page, when the page
/// loads again and at the next thing the page asks of the app. It was a sheet
/// with an OK to click every time a page said "Six photographs are ready."
public struct ExtSaidBar: View {
    let model: ExtStepModel

    public init(model: ExtStepModel) { self.model = model }

    public var body: some View {
        if let said = model.said {
            VStack(spacing: 0) {
                Divider()
                Label {
                    Text(said)
                        .foregroundStyle(.secondary)
                        // As tall as the sentence and never more than the
                        // refusal's bound, for the same reason (`ExtRefusalBar`).
                        .frame(maxWidth: .infinity, maxHeight: ExtRefusalBar.maximumHeight, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, Tokens.Metric.windowMargin)
                .padding(.vertical, Tokens.Metric.relatedGap)
                .background(.bar)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("extension.said")
            }
        }
    }
}

/// Where each added step's page was scrolled to when he left it, for this
/// run of the app. The page is loaded afresh on each visit, and came back at
/// its top rather than at the card he was on.
@MainActor
public enum ExtPlaces {
    private static var at: [String: CGPoint] = [:]

    public static func note(shoot: String, step: String, x: Double, y: Double) {
        at[key(shoot, step)] = CGPoint(x: x, y: y)
    }

    public static func scrolled(shoot: String, step: String) -> CGPoint? {
        guard let p = at[key(shoot, step)], p.y > 0 || p.x > 0 else { return nil }
        return p
    }

    static func forget() { at = [:] }

    private static func key(_ shoot: String, _ step: String) -> String { shoot + "\u{1F}" + step }
}

// MARK: - what the page can ask for

/// One question the page asked, waiting for his answer.
public struct ExtQuestion: Identifiable, Sendable {
    /// Why the page is asking, which is the only thing that decides how the
    /// sheet is drawn.
    ///
    /// The red button and the hand's width of clearance belong to
    /// `pipeline.confirmDestructive` and to nothing else. A page's own
    /// `alert()` and `confirm()` are ordinary — a message and a plain
    /// question — and drawing them in the alarm colour would spend the one
    /// signal the app has for something that cannot be taken back on a page
    /// saying "Saved".
    public enum Kind: Sendable {
        /// `pipeline.confirmDestructive`: Cancel is the default button and the
        /// other one is red, off to the side, and says what it will do.
        case destructive
        /// The page called `confirm()`. Two ordinary buttons, neither of them
        /// red. (Its `alert()` asks nothing, and is a line under the page:
        /// `ExtSaidBar`.)
        case choice
    }

    public let id = UUID()
    public let title: String
    public let body: String
    public let confirmLabel: String
    public let kind: Kind

    public init(title: String, body: String, confirmLabel: String, kind: Kind = .destructive) {
        self.title = title
        self.body = body
        self.confirmLabel = confirmLabel
        self.kind = kind
    }
}

/// One look at some frames, asked for by the page, with the marks it offers.
public struct ExtLook: Identifiable, Sendable {
    public let id = UUID()
    public let stems: [String]
    public let startAt: Int
    public var actions: [ExtViewerAction] = []
    public var marks: [String: String] = [:]

    /// Where it ends when nothing else says: where it began, as it began.
    var unchanged: ExtViewerResult {
        ExtViewerResult(index: startAt, stem: stems[startAt], marks: marks)
    }
}

/// The page's side of the bridge, and the app's side of the pane.
@MainActor @Observable
public final class ExtStepModel: ExtBridgeDelegate, ExtPageDialogs {
    public var refusal: (sentence: String, detail: String?)?
    public var question: ExtQuestion?
    public var viewing: ExtLook?
    /// What the page last said with `alert()`, while it is up (`ExtSaidBar`).
    public var said: String?
    /// How long a line the page said stays, unless something takes it down
    /// first. Long enough to read a sentence twice.
    static var saidLingers: Duration = .seconds(6)
    /// A line younger than this is about what comes straight after it: the
    /// page loading again keeps it, and a second line joins it rather than
    /// replacing it. `alert('Published'); location.reload()` showed its
    /// sentence for no time at all once alert() stopped waiting for an OK,
    /// and two alerts in a row showed only the second.
    static let saidTogether: Duration = .seconds(1)
    /// At most this many lines at once, the newest last.
    static let saidAtMost = 3
    private var saidGoes: Task<Void, Never>?
    private var saidAt: ContinuousClock.Instant?
    private var saidLines: [String] = []

    public let bridge = ExtBridge()
    private var shoot = ""
    private var step = ""
    private var pending: CheckedContinuation<Bool, Never>?
    /// Questions asked while one was on screen, in the order they came.
    private var waiting: [(ExtQuestion, CheckedContinuation<Bool, Never>)] = []
    /// The page waiting on the look that is open.
    private var looking: (id: UUID, answer: CheckedContinuation<ExtViewerResult, Never>)?
    private let state: ExtStateStore

    public init(state: ExtStateStore = .shared) {
        self.state = state
        bridge.delegate = self
        bridge.dialogs = self
        bridge.onRefusal = { [weak self] sentence in
            self?.refusal = (sentence, nil)
        }
        // A new load of the page is a new start: what was refused on the
        // last one, or said by it, is not about this one — unless it was
        // said just before, about this very load.
        bridge.onNavigation = { [weak self] in
            self?.refusal = nil
            self?.pageLoadsAgain()
        }
        // His next click on the page has read what it said.
        bridge.onPressed = { [weak self] in self?.stopSaying() }
    }

    /// A line the page said, up for `saidLingers`, and spoken. Said within
    /// `saidTogether` of the last, it joins it.
    public func say(_ message: String) {
        let now = ContinuousClock.now
        if said == nil || !Self.isRecent(saidAt, now) { saidLines = [] }
        saidLines = Array((saidLines + [message]).suffix(Self.saidAtMost))
        saidAt = now
        let shown = saidLines.joined(separator: "\n")
        said = shown
        Announcer.shared.speak(message)
        saidGoes?.cancel()
        saidGoes = Task { [weak self] in
            try? await Task.sleep(for: Self.saidLingers)
            guard !Task.isCancelled, let self, self.said == shown else { return }
            self.stopSaying()
        }
    }

    public func stopSaying() {
        saidGoes?.cancel()
        saidGoes = nil
        said = nil
        saidAt = nil
        saidLines = []
    }

    /// The page loading again: a line said just before stays and goes by
    /// itself, and anything older is about the page that has gone.
    func pageLoadsAgain() {
        guard !Self.isRecent(saidAt, .now) else { return }
        stopSaying()
    }

    private static func isRecent(_ at: ContinuousClock.Instant?, _ now: ContinuousClock.Instant) -> Bool {
        guard let at else { return false }
        return now - at < saidTogether
    }

    public func bind(session: ShootSession, step: String = "") {
        shoot = session.name
        self.step = step
    }

    public func scrolled(x: Double, y: Double) {
        guard !shoot.isEmpty, !step.isEmpty else { return }
        ExtPlaces.note(shoot: shoot, step: step, x: x, y: y)
    }

    public func refuse(_ error: ExtHostError) {
        refusal = (error.sentence, error.detail)
    }

    public func clearRefusal() { refusal = nil }

    // MARK: ExtBridgeDelegate

    public func viewFrames(_ stems: [String], startAt: Int, actions: [ExtViewerAction] = [],
                           marks: [String: String] = [:]) async -> ExtViewerResult {
        refusal = nil
        stopSaying()
        // A second look asked for while one is open ends the first where it
        // was opened, and the page that asked for it hears so.
        if let open = viewing { lookEnded(open.id, open.unchanged) }
        let look = ExtLook(stems: stems, startAt: startAt, actions: actions, marks: marks)
        viewing = look
        return await withCheckedContinuation { c in looking = (look.id, c) }
    }

    /// The viewer closed on this look. Once per look; a look already
    /// replaced has nothing left to answer.
    public func lookEnded(_ id: UUID, _ result: ExtViewerResult) {
        guard let l = looking, l.id == id else { return }
        looking = nil
        if viewing?.id == id { viewing = nil }
        l.answer.resume(returning: result)
    }

    public func confirmDestructive(title: String, body: String, confirmLabel: String) async -> Bool {
        refusal = nil
        stopSaying()
        return await ask(ExtQuestion(title: title, body: body, confirmLabel: confirmLabel, kind: .destructive))
    }

    // MARK: ExtPageDialogs

    /// `alert()`: a line under the page, and the page goes on at once. There
    /// is nothing to answer, so nothing waits for him.
    public func pageSaid(_ message: String) async {
        say(message)
    }

    public func pageAsked(_ question: String) async -> Bool {
        stopSaying()
        return await ask(ExtQuestion(title: question, body: "", confirmLabel: Strings.Extensions.ok, kind: .choice))
    }

    /// Put one question on screen and wait for his answer.
    ///
    /// One at a time, in the order they were asked: a question asked while
    /// another is on screen waits its turn, and is put up when he has answered
    /// the one before it — never swapped in under his hand, and never
    /// answered for him. It used to be answered no without being shown, so a
    /// page asking about items one after another skipped every one that came
    /// while a sheet was up.
    private func ask(_ asked: ExtQuestion) async -> Bool {
        await withCheckedContinuation { c in
            if pending == nil {
                question = asked
                pending = c
            } else {
                waiting.append((asked, c))
            }
        }
    }

    public func answer(_ said: Bool) {
        question = nil
        let c = pending
        pending = nil
        c?.resume(returning: said)
        guard !waiting.isEmpty else { return }
        let (next, answer) = waiting.removeFirst()
        pending = answer
        question = next
    }

    public func state(get key: String) -> String? {
        state.get(shoot: shoot, key: key)
    }

    public func state(set key: String, _ value: String?) {
        state.set(shoot: shoot, key: key, value: value)
    }
}

/// The app's own sheet, drawn two ways because a page asks two kinds of
/// thing, and only one of them is dangerous.
///
/// `pipeline.confirmDestructive` draws §2.8's sheet: **Cancel is the default
/// button**, the confirm button carries the consequence in its own words, has
/// the destructive role, reads in the alarm colour and sits a hand away from
/// anything else, with no keyboard shortcut on the thing that cannot be taken
/// back.
///
/// A page's own `confirm()` is drawn as the app rather than as WebKit, but as
/// *ordinary* — two plain buttons, nothing red. The alarm colour means
/// something in this app, and a page asking "Start again?" must not be allowed
/// to spend it. Its `alert()` is not a sheet at all (`ExtSaidBar`).
public struct ExtConfirmSheet: View {
    let question: ExtQuestion
    let answer: (Bool) -> Void
    @FocusState private var defaultFocused: Bool

    public init(question: ExtQuestion, answer: @escaping (Bool) -> Void) {
        self.question = question
        self.answer = answer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.groupGap) {
            Text(question.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if !question.body.isEmpty {
                Text(question.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(Tokens.Metric.windowMargin)
        .frame(width: 460, alignment: .leading)
        .onAppear { defaultFocused = true }
        .onExitCommand { answer(escapeSays) }
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var buttons: some View {
        switch question.kind {
        case .destructive:
            // The one that cannot be taken back is not the default button,
            // is not where the hand already is, and says what it will do.
            // Return is Cancel; Escape is Cancel; nothing else is bound.
            HStack(spacing: 0) {
                Spacer(minLength: Tokens.Metric.relatedGap)
                Button(role: .destructive) {
                    answer(true)
                } label: {
                    Text(question.confirmLabel).foregroundStyle(Tokens.Palette.alarm)
                }
                Spacer().frame(width: Tokens.Metric.destructiveClearance)
                Button(Strings.Extensions.cancel) { answer(false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .focused($defaultFocused)
            }
        case .choice:
            // An ordinary question: the two answers sit together, the yes is
            // the default because nothing is lost by it, and neither is red.
            HStack(spacing: Tokens.Metric.relatedGap) {
                Spacer(minLength: Tokens.Metric.relatedGap)
                Button(Strings.Extensions.cancel) { answer(false) }
                Button(question.confirmLabel) { answer(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .focused($defaultFocused)
            }
        }
    }

    /// Escape takes the safe way out: no.
    private var escapeSays: Bool { false }

    private var identifier: String {
        switch question.kind {
        case .destructive: "extension.confirm"
        case .choice: "extension.choice"
        }
    }
}
