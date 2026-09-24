import SwiftUI

/// What the primary's own box is holding at this moment.
public enum StepJobPhase: Equatable, Sendable {
    /// The button, as it always is.
    case idle
    /// He asked while something else was running, on a page that does not
    /// put its work on the list (the card page, so far). It goes when that
    /// does, and leaving the page takes it back.
    case queued
    /// This step's work is waiting on the list, this far from the front
    /// (1 is next). It is the engine's list, so it survives his leaving the
    /// page and quitting the app.
    case listed(Int)
    /// He pressed, and the engine has not started it yet. Usually a moment;
    /// up to twenty seconds while the engine stands the idle learning run
    /// down for it.
    case starting
    /// This step's own job.
    case running(Job)
    /// Stop was pressed and the engine has not said so yet.
    case stopping

    /// Which of these the box is showing, without the job's numbers, so a
    /// change of what is in the box can be told from a job moving on.
    var shape: Int {
        switch self {
        case .idle: return 0
        case .queued: return 1
        case .running: return 2
        case .stopping: return 3
        case .listed: return 4
        case .starting: return 5
        }
    }
}

/// A long job, shown where the button that started it was (DESIGN.md §2.7).
///
/// The box is `StepMetric.primaryBox` and it is that size whether it holds a
/// button, a bar or a queued request. Nothing on the page moves when a job
/// starts, and nothing moves when it ends: the old page pushed the control
/// between 150 and 215 pt (FLOW-04), which is the one thing a person who
/// presses the same button eight hundred times a shoot cannot forgive.
///
/// Everything in words here is the engine's. The stage words ("reading the
/// frames", "looking at faces") come from `Job.label`; this view never writes
/// a stage name of its own.
public struct JobInPlace<Idle: View>: View {
    let phase: StepJobPhase
    /// `nil` while the bar is the app's own words for a job the engine has
    /// not named yet: there is nothing of its to stop.
    let stop: (() -> Void)?
    let cancelQueue: () -> Void
    @ViewBuilder let idle: () -> Idle

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the box last changed what it holds. A press on Stop or × this
    /// soon after is the second click of the double-click that started it
    /// (`StepMetric.settle`).
    @State private var changedAt = Date.distantPast

    public init(phase: StepJobPhase, stop: (() -> Void)?, cancelQueue: @escaping () -> Void,
                @ViewBuilder idle: @escaping () -> Idle) {
        self.phase = phase
        self.stop = stop
        self.cancelQueue = cancelQueue
        self.idle = idle
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            switch phase {
            case .idle:
                idle()
            case .queued:
                pill(fraction: nil, words: Strings.Step.waiting, action: cancelQueue,
                     actionSymbol: "xmark", actionLabel: Strings.Step.dontWait)
            case .listed(let place):
                pill(fraction: nil, words: Strings.Step.onTheList(place), action: cancelQueue,
                     actionSymbol: "xmark", actionLabel: Strings.Queue.remove)
            case .starting:
                pill(fraction: nil, words: Strings.Step.starting, action: nil,
                     actionSymbol: "stop.fill", actionLabel: Strings.Step.stop)
            case .running(let job):
                pill(fraction: job.fraction, words: words(job), action: stop,
                     actionSymbol: "stop.fill", actionLabel: Strings.Step.stop)
            case .stopping:
                pill(fraction: nil, words: Strings.Step.stopping, action: nil,
                     actionSymbol: "stop.fill", actionLabel: Strings.Step.stop)
            }
        }
        .frame(width: StepMetric.primaryBox.width, height: StepMetric.primaryBox.height,
               alignment: .bottomTrailing)
        .onChange(of: phase.shape) { _, _ in changedAt = Date() }
    }

    /// The engine's own sentence for where it is, and nothing else. `label` is
    /// "{stage word}: {done} of {total} {unit}"; `stage` is the bare word; and
    /// when the engine has said neither yet, the job's title is what it called
    /// the work when it started it.
    private func words(_ job: Job) -> String {
        if !job.label.isEmpty { return job.label }
        if !job.stage.isEmpty { return job.stage }
        return job.title
    }

    @ViewBuilder
    private func pill(fraction: Double?, words: String, action: (() -> Void)?,
                      actionSymbol: String, actionLabel: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        // Stop and × are on the LEADING edge. The button they replace sits
        // against the trailing edge, so the control that undoes a press is
        // never where the press was.
        HStack(spacing: Tokens.Metric.relatedGap / 2) {
            if let action {
                Button {
                    guard StepMetric.takesPress(since: changedAt) else { return }
                    action()
                } label: {
                    Image(systemName: actionSymbol)
                        .imageScale(.small)
                        .frame(width: Tokens.Metric.minimumHitTarget,
                               height: Tokens.Metric.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(actionLabel)
                .accessibilityLabel(actionLabel)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: Tokens.Metric.minimumHitTarget, height: Tokens.Metric.minimumHitTarget)
            }
            Text(words)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(width: StepMetric.primaryBox.width, height: StepMetric.primaryBox.height)
        .background {
            ZStack(alignment: .leading) {
                shape.fill(.quaternary)
                if let fraction {
                    GeometryReader { geo in
                        shape
                            .fill(Color.accentColor.opacity(0.28))
                            .frame(width: max(0, min(1, fraction)) * geo.size.width)
                            .animation(reduceMotion ? nil : Motion.progress(over: JobModel.runningInterval),
                                       value: fraction)
                    }
                }
                // When nothing is known about how far along it is, nothing is
                // drawn: a full-width tint on a queued request reads as a job
                // that has finished, which is the opposite of the truth.
            }
        }
        .overlay {
            shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.7) : Color.primary.opacity(0.12),
                               lineWidth: contrast == .increased ? 1 : 0.5)
        }
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(words))
        .accessibilityValue(Text(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? ""))
    }
}

/// Elapsed and remaining, on the leading side of the action bar where there
/// is room for them — both the engine's.
///
/// The elapsed time is whatever the engine last said. It is never recomputed
/// from the wall clock, so a finished job's time does not go on ageing while
/// it sits on screen (DESIGN.md §7.11) — `JobModel` freezes it and this prints
/// what it froze. The time left is the engine's own sentence, printed as
/// written: this worked out a figure of its own from the fraction, so the bar
/// said "1:13 left" while the toolbar and the list said "about 4 minutes left"
/// for the same cull at the same moment.
public struct JobTiming: View {
    let job: Job

    public init(_ job: Job) { self.job = job }

    public var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .accessibilityLabel(Text(text))
            // Against the trailing edge, so the clock is beside the bar it
            // belongs to rather than a column away from it. A refusal keeps
            // the leading edge, because right-aligned prose is unreadable.
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    var text: String { JobTiming.text(job) }

    /// "0:53 · about 4 minutes left", or "0:53" while the engine will not
    /// guess.
    nonisolated public static func text(_ job: Job) -> String {
        var parts = [clock(job.elapsed)]
        let left = job.remaining_text.trimmingCharacters(in: .whitespaces)
        if job.running, !left.isEmpty { parts.append(left) }
        return parts.joined(separator: " · ")
    }

    /// "4:07". Minutes and seconds up to an hour, then hours.
    ///
    /// Arithmetic on the engine's own numbers, so it is nonisolated: it is
    /// `JobTiming`'s conformance to `View` that would otherwise pin these two
    /// to the main actor, and a test that only formats seconds should not have
    /// to hop there to do it.
    nonisolated public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

}

/// How this step's last job ended, beside its button, when that is
/// something to say: stopped, refused with the engine's own sentence, or
/// failed. A job that finished says nothing here; the page shows what it
/// made.
///
/// Failed is the one in the alarm colour, with its word and symbol and the
/// way to its log. It had no line at all: a cull that ran out of memory put
/// the page back to "About a minute." and Cull It, as if he had never
/// pressed it, while the toolbar item that had been running simply went
/// away (DESIGN.md §2.7).
public struct JobEndedNote: View {
    let job: Job
    /// The page's own sentence for a crash, where it can say more than the
    /// shared one: the Cull page adds that nothing he marked was changed.
    let failed: String

    /// `nil` for a job that finished, or has not ended: nothing to say.
    public init?(_ job: Job?, failed: String = Strings.Step.failedNote) {
        guard let job, Self.says(job) else { return nil }
        self.job = job
        self.failed = failed
    }

    public static func says(_ job: Job) -> Bool {
        switch job.outcome {
        case .stopped, .failed: return true
        case .refused: return job.refusalSentence != nil
        case .idle, .running, .done: return false
        }
    }

    public var body: some View {
        switch job.outcome {
        case .failed:
            VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
                Label {
                    Text(failed).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: Symbols.brokenShoot).symbolRenderingMode(.hierarchical)
                }
                .font(.callout)
                .foregroundStyle(Tokens.Palette.alarm)
                StepLink(Strings.Step.showTheLog, go: StepSlots.showActivity)
                    .help(Strings.Step.showTheLogHelp)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("step.jobFailed")
        case .refused:
            // Refused on purpose. The engine's sentence, in the ordinary
            // colour, because it is a guard working and not a crash.
            Text("\(Strings.Step.refusedNote): \(job.refusalSentence ?? "")")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        default:
            Text(Strings.Step.stoppedNote).font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - what a step does with the one job queue

/// One step's view of the engine's single queue.
///
/// It answers three questions and nothing else: is the job that is running
/// *mine*, may I start one now, and what happened to the one I started. The
/// poll itself belongs to `JobModel`, which is the app's only one.
@MainActor @Observable
public final class StepJobRunner {
    /// The engine's job kinds this step owns. `ingest` before the shoot has a
    /// name has no shoot on it, which is why the shoot is matched loosely.
    public let kinds: Set<String>
    public private(set) var shoot: String
    private let jobs: JobModel
    /// What he asked for while something else was running, held on the page
    /// because the page did not put it on the list. A step that puts its
    /// work on the list passes `orAdd` to `run` and never lands here.
    private var pending: (@MainActor () async -> Void)?
    /// The app's one list, where this step's work waits when it waits. Set by
    /// `StepsModel`. Reading it is how the box shows a place on the list;
    /// putting work there is the step's own `orAdd`.
    public var list: (@MainActor () -> QueueModel?)?
    private var waitTask: Task<Void, Never>?
    public private(set) var stopping = false
    /// Pressed, and the engine has not started it yet: from the press until
    /// the poll sees the job running, the engine refuses it, or
    /// `startingLimit` after the engine answered. Presses in between are
    /// ignored. The button stayed live until the start's answer came back,
    /// which is seconds while the engine stands the idle learning run down,
    /// and the press again that "it felt slow" asked for the same cull a
    /// second time and drew the engine's refusal of it beside his own cull.
    public private(set) var starting = false
    /// How long "Starting…" waits for the poll to see a job the engine said
    /// it started. A job over before the poll ever saw it running would
    /// otherwise hold the box for good.
    static let startingLimit: Duration = .seconds(2)
    /// A job to report instead of asking the model, for the snapshot harness
    /// and for previews. Production never sets it.
    public var preview: Job?
    /// The last job of this step's kind that this session saw end.
    public private(set) var lastEnded: Job?

    public init(kinds: Set<String>, shoot: String, jobs: JobModel) {
        self.kinds = kinds
        self.shoot = shoot
        self.jobs = jobs
        self.preview = StepJobs.previewJob
    }

    /// The running job, when it is this step's.
    public var mine: Job? {
        if let p = preview { return p.running && kinds.contains(p.kind) ? p : nil }
        guard let j = jobs.job, j.running, kinds.contains(j.kind) else { return nil }
        guard j.shoot.isEmpty || j.shoot == shoot else { return nil }
        return j
    }

    /// Another job of HIS, running now — the only kind that is ever a reason
    /// to wait.
    ///
    /// The machine's own homework is deliberately not one. The engine stands
    /// a background job down the moment he asks for anything, so a step that
    /// sat here showing "Waiting…" behind the learning run would be waiting
    /// for something that has already got out of its way — and it would be
    /// the same wrong answer as "a job is already running", drawn in a nicer
    /// box. His work goes now.
    public var other: Job? {
        if let p = preview { return p.running && !kinds.contains(p.kind) && !p.background ? p : nil }
        guard let j = jobs.job, j.running, !j.background, mine == nil else { return nil }
        return j
    }

    /// This step's work for this shoot, waiting on the list, and its place in
    /// the line (1 is next). Read from the engine's list, so what the box says
    /// and what the list window shows are one thing.
    public var listed: (item: QueueItem, place: Int)? {
        guard let q = list?() else { return nil }
        let waiting = q.state.waiting
        guard let i = waiting.firstIndex(where: { kinds.contains($0.kind) && $0.shoot == shoot }) else {
            return nil
        }
        return (waiting[i], i + 1)
    }

    /// Asked for and not started: held on the page, or waiting on the list.
    public var isQueued: Bool { pending != nil || listed != nil }

    public var phase: StepJobPhase {
        if stopping { return .stopping }
        if let mine { return .running(mine) }
        if starting { return .starting }
        if pending != nil { return .queued }
        if let l = listed { return .listed(l.place) }
        return .idle
    }

    /// Where the refusal of a start goes: the job board, which the step reads
    /// and clears only its own entries of.
    public var refusals: RefusalBoard { jobs.refusals }

    /// The job in the way, when the engine named one, and the line about the
    /// homework it stood down so this step's work could start.
    public var busy: Busy? { jobs.busy[.job] }
    public var paused: String? { jobs.paused[.job] }

    /// Start this step's job, or queue it honestly behind the one that is
    /// running. Nothing is refused to him with a shrug: either it runs, or it
    /// is waiting and says what for.
    ///
    /// `orAdd` is how this step puts its work on the list. With it, a request
    /// made while something of his is running goes there — the engine's list,
    /// which shows it, keeps it when he goes to another page or quits, and
    /// starts it in its turn. Without it the request waits on this page: it
    /// was the only way before, and it was dropped without a word the moment
    /// he looked at another shoot while he waited.
    public func run(orAdd add: (@MainActor () -> Void)? = nil,
                    _ body: @escaping @MainActor () async -> Void) {
        // The same press again, while the first is on its way.
        guard !starting else { return }
        stopping = false
        if other != nil, let add {
            pending = nil
            waitTask?.cancel()
            waitTask = nil
            add()
            return
        }
        guard other != nil else {
            pending = nil
            waitTask?.cancel()
            waitTask = nil
            // Now, not in the task: a second click is the next event, and
            // it must find this set.
            starting = true
            Task { [weak self] in await self?.start(body) }
            return
        }
        pending = body
        waitTask?.cancel()
        waitTask = Task { [weak self] in
            // The poll is `JobModel`'s. This only watches what it reports.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                guard self.pending != nil else { return }
                if self.other == nil, let go = self.pending {
                    self.pending = nil
                    await self.start(go)
                    return
                }
            }
        }
    }

    /// Sends the start and holds "Starting…" until it has one.
    ///
    /// Set before the first suspension, so a press that lands while the
    /// engine is still answering is ignored. After the answer the box keeps
    /// "Starting…" until the poll sees the job — `JobModel.start` only
    /// begins the poll when the answer comes back — so the button does not
    /// flash back between the two. A refusal is on the board by then, and
    /// ends it at once; so does another job of his, which means this one did
    /// not take the slot.
    private func start(_ body: @MainActor () async -> Void) async {
        starting = true
        let before = jobs.job?.id
        await body()
        let deadline = ContinuousClock.now + Self.startingLimit
        while ContinuousClock.now < deadline, mine == nil, other == nil,
              refusals[.job] == nil, !endedSince(before) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        starting = false
    }

    /// Whether a job of this step's kind that is not `before` has already
    /// ended — one short enough that the poll never saw it running.
    private func endedSince(_ before: Int?) -> Bool {
        guard let j = jobs.job, !j.running, j.id > 0, j.id != before else { return false }
        return kinds.contains(j.kind) && (j.shoot.isEmpty || j.shoot == shoot)
    }

    /// Take back what is waiting: the request held on the page, or this
    /// step's work on the list.
    public func cancelQueued() {
        if pending != nil {
            pending = nil
            waitTask?.cancel()
            waitTask = nil
            return
        }
        if let l = listed, let q = list?() {
            Task { await q.remove(l.item.id) }
        }
    }

    public func stop() {
        stopping = true
        Task { [jobs] in
            await jobs.stop()
            self.stopping = false
        }
    }

    /// Called by the step when the poll reports a job of its kind has ended,
    /// so the step can reload the shoot and print what happened.
    public func noteEnded(_ job: Job) { lastEnded = job }

    public func rename(shoot: String) { self.shoot = shoot }

    /// The step calls this when it goes away, because a request held on the
    /// page must not fire at a screen he has left. Work on the list is the
    /// list's, and is not touched.
    public func teardown() {
        pending = nil
        waitTask?.cancel()
        waitTask = nil
    }
}
