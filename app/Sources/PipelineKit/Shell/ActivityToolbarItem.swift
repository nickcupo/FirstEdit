import SwiftUI

/// The `.status` toolbar item (DESIGN.md §2.3, §2.7): what is running, on
/// every screen, wherever he is.
///
/// It used to be a ring and a title and nothing else — which for the learning
/// run meant the words "learning from your finished shoots" sat in his toolbar
/// for six and a half minutes beside a ring that, because nothing between the
/// 35-second mark and the end ever reported a stage, did not move. There was
/// no way from that item to find out what it was doing or to stop it.
///
/// So: click it and the popover says where the job has got to in the engine's
/// own stage words, roughly how long is left, and gives him Stop. For the
/// learning run it also says that stopping costs nothing, and offers the one
/// screen where the whole business is explained.
///
/// It is about one of three things (`Subject`): a job running; a job that
/// has just ended, which it says rather than vanishing; or, with nothing
/// running, the list of work waiting — held or about to go.
public struct ActivityToolbarItem: View {

    public enum Subject: Equatable {
        case running(Job)
        /// Said with its outcome. "Done" goes by itself after a moment;
        /// anything else stays until he clicks it, which opens Activity.
        case ended(Job)
        /// Nothing running and work on the list. `held` when he held it:
        /// an empty ring beside "Up Next" read as a job stuck at nought.
        case list(held: Bool)
    }

    let subject: Subject
    /// How many pieces of work are waiting on the list behind this one. The
    /// number is here because this item is the way to the list, and a list he
    /// filled and walked away from should say from any screen how much of it
    /// is left (DESIGN.md §2.7).
    let waiting: Int
    let stop: () -> Void
    let openLearning: () -> Void
    let showTheList: (() -> Void)?
    /// The next few on the list, named in the popover of a list with nothing
    /// running.
    var upNext: [QueueItem] = []
    /// Lets a held list go.
    var letGo: (() -> Void)?
    /// An ended job, looked at.
    var dismiss: (() -> Void)?
    /// The short form: the ring or the outcome's symbol and one word, with
    /// the shoot, the time left and the work that ended in the help tag, in
    /// what VoiceOver says and in the popover. For Choose Keepers in a
    /// window narrower than 1440 pt (`statusItemWholeFrom`), where the mode picker
    /// holds the toolbar's middle and the whole line — "Cull 2026-09-21-night
    /// · about 12 minutes left" — pushed it into the title and cut the
    /// subtitle's count to "288 of 288 been through ·…" for as long as the
    /// job ran, and for the rest of the evening after a refusal. The toolbar
    /// offers an item all the width it asks for, so the item has to ask for
    /// less; it cannot be left to fit itself.
    var compact = false

    @State private var shown = false

    /// A job running: the only form there was.
    public init(job: Job, waiting: Int = 0, stop: @escaping () -> Void,
                openLearning: @escaping () -> Void, showTheList: (() -> Void)? = nil) {
        self.init(.running(job), waiting: waiting, stop: stop, openLearning: openLearning,
                  showTheList: showTheList)
    }

    public init(_ subject: Subject, waiting: Int = 0, upNext: [QueueItem] = [],
                stop: @escaping () -> Void, openLearning: @escaping () -> Void,
                showTheList: (() -> Void)? = nil, letGo: (() -> Void)? = nil,
                dismiss: (() -> Void)? = nil, compact: Bool = false) {
        self.subject = subject
        self.compact = compact
        self.waiting = waiting
        self.upNext = upNext
        self.stop = stop
        self.openLearning = openLearning
        self.showTheList = showTheList
        self.letGo = letGo
        self.dismiss = dismiss
    }

    public var body: some View {
        Button {
            if case .ended = subject {
                // What it said is in Activity, with the job selected; the
                // item has done its job once he has gone to look.
                dismiss?()
                showTheList?()
            } else {
                shown.toggle()
            }
        } label: {
            label
        }
        .buttonStyle(.borderless)
        .help(spoken)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("toolbar.activity")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            switch subject {
            case .running(let job):
                ActivityPopover(job: job, waiting: waiting,
                                stop: { shown = false; stop() },
                                openLearning: { shown = false; openLearning() },
                                showTheList: showTheList.map { go in { shown = false; go() } })
            case .list(let held):
                UpNextPopover(held: held, heldAfter: Queues.state.heldAfter, waiting: waiting, upNext: upNext,
                              letGo: letGo.map { go in { shown = false; go() } },
                              showTheList: showTheList.map { go in { shown = false; go() } })
            case .ended:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var label: some View {
        HStack(spacing: 6) {
            switch subject {
            case .running(let job):
                // No animation: at 16 pt the ease between two polls is motion
                // nobody can see, and SwiftUI redrew it every frame for the
                // whole length of every job, on the thread his keys use.
                ProgressView(value: min(max(job.fraction, 0), 1))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                if compact {
                    Text(job.what).font(.callout).lineLimit(1).fixedSize()
                } else {
                    ViewThatFits(in: .horizontal) {
                        name(job, left: job.remaining_text)
                        name(job, left: "")
                    }
                }
            case .ended(let job):
                Image(systemName: OutcomeLabel.symbol(job.outcome))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(OutcomeLabel.tint(job.outcome))
                // Short, the outcome is the word: the symbol alone does not
                // say Refused from Failed at a glance.
                Text(compact ? ActivityWindow.word(job.outcome)
                             : Strings.StatusItem.ended(job.what, ActivityWindow.word(job.outcome)))
                    .font(.callout)
                    .lineLimit(1)
            case .list(let held):
                Image(systemName: held ? "pause.circle" : "list.bullet")
                    .symbolRenderingMode(.hierarchical)
                Text(held ? Strings.StatusItem.held(waiting) : Strings.Queue.title)
                    .font(.callout)
                    .lineLimit(1)
            }
            if waiting > 0, subject != .list(held: true) {
                // A count, not a badge with a word in it: the toolbar has
                // one line of room and the word is in the help tag and in
                // what VoiceOver says.
                Text("\(waiting)")
                    .font(.caption)
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                    .accessibilityHidden(true)
            }
        }
    }

    /// The work's one name, and what is left when there is room for it:
    /// the popover's facts were a click away while the toolbar had space.
    private func name(_ job: Job, left: String) -> some View {
        HStack(spacing: 4) {
            Text(job.what).lineLimit(1)
            if let shoot = job.shootAfterWhat {
                Text(shoot).foregroundStyle(.secondary).lineLimit(1)
            }
            if !left.isEmpty {
                Text("· \(left)").foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
        .font(.callout)
        .fixedSize()
    }

    private var spoken: String {
        switch subject {
        case .running(let job):
            let whereItHasGot = [job.label.isEmpty ? job.stage : job.label, job.remaining_text]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            return [[job.what, job.shootAfterWhat ?? ""].filter { !$0.isEmpty }.joined(separator: " "),
                    whereItHasGot, waiting > 0 ? Strings.Queue.waitingSpoken(waiting) : ""]
                .filter { !$0.isEmpty }.joined(separator: ". ")
        case .ended(let job):
            return [Strings.StatusItem.ended(job.what, ActivityWindow.word(job.outcome)),
                    job.shootAfterWhat ?? "", Strings.StatusItem.clickToSee]
                .filter { !$0.isEmpty }.joined(separator: ". ")
        case .list(let held):
            return held ? [Strings.StatusItem.held(waiting), Strings.Queue.heldLine(Queues.state.heldAfter)]
                            .joined(separator: ". ")
                        : Strings.Queue.waitingSpoken(waiting)
        }
    }
}

/// What the toolbar's Activity item opens (DESIGN.md §2.7): the same facts,
/// Stop, and — for the machine's own homework — the one screen that explains
/// the whole business.
///
/// Its own view so it can be photographed. A popover does not appear in a
/// still of a window, and a presentation nobody can look at is one nobody
/// checks.
public struct ActivityPopover: View {
    let job: Job
    let waiting: Int
    let stop: () -> Void
    let openLearning: () -> Void
    let showTheList: (() -> Void)?

    public init(job: Job, waiting: Int = 0, stop: @escaping () -> Void,
                openLearning: @escaping () -> Void, showTheList: (() -> Void)? = nil) {
        self.job = job
        self.waiting = waiting
        self.stop = stop
        self.openLearning = openLearning
        self.showTheList = showTheList
    }

    /// Where it has got to and what is left, both the engine's, joined and
    /// nothing more. Empty halves are left out rather than filled in.
    private var whereItHasGot: String {
        [job.label.isEmpty ? job.stage : job.label, job.remaining_text]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
            HStack(spacing: Tokens.Metric.relatedGap) {
                Text(job.what).font(.headline)
                if let shoot = job.shootAfterWhat {
                    Text(shoot).font(.headline).foregroundStyle(.secondary)
                }
            }
            if !whereItHasGot.isEmpty {
                Text(whereItHasGot)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProgressView(value: min(max(job.fraction, 0), 1))
                .progressViewStyle(.linear)
                .frame(width: 260)
                .accessibilityHidden(true)
            if job.background {
                // Why it is there at all, and why stopping it is free. Said
                // here because this is often the first he knows of it.
                Text(Strings.Learning.safeToStop)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if waiting > 0 {
                // What is behind this one, and the way to it. Said here
                // because this popover is often the first he knows that the
                // list he filled an hour ago is still going.
                Text(Strings.Queue.waitingSpoken(waiting))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 260, alignment: .leading)
            }
            HStack(spacing: Tokens.Metric.relatedGap) {
                Button(Strings.Job.stop, action: stop)
                    .accessibilityIdentifier("toolbar.activity.stop")
                if job.background {
                    Button(Strings.Job.showWhatItHasLearned, action: openLearning)
                        .accessibilityIdentifier("toolbar.activity.learning")
                }
                // The way to the log and the list, always: it was offered
                // only when something was waiting, and the log is in the
                // same window.
                if let showTheList {
                    Button(waiting > 0 ? Strings.StatusItem.showTheList : Strings.StatusItem.showActivity,
                           action: showTheList)
                        .accessibilityIdentifier("toolbar.activity.list")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Tokens.Metric.windowMargin)
        .accessibilityIdentifier("toolbar.activity.popover")
    }
}

/// The popover of a list with nothing running: what is next, and the two
/// things he can do about it. It offered Stop, which with nothing running
/// did nothing, and no Continue.
public struct UpNextPopover: View {
    let held: Bool
    /// What held it, when it was not his Hold.
    let heldAfter: HeldAfter?
    let waiting: Int
    let upNext: [QueueItem]
    let letGo: (() -> Void)?
    let showTheList: (() -> Void)?

    public init(held: Bool, heldAfter: HeldAfter? = nil, waiting: Int, upNext: [QueueItem],
                letGo: (() -> Void)?, showTheList: (() -> Void)?) {
        self.held = held; self.heldAfter = heldAfter; self.waiting = waiting; self.upNext = upNext
        self.letGo = letGo; self.showTheList = showTheList
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
            Text(held ? Strings.StatusItem.held(waiting) : Strings.Queue.title).font(.headline)
            if held {
                Text(Strings.Queue.heldLine(heldAfter))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(upNext.prefix(3)) { item in
                    HStack(spacing: 4) {
                        Text(item.what)
                        Text(item.shoot).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .lineLimit(1)
                }
                if waiting > 3 {
                    Text(Strings.StatusItem.andMore(waiting - 3))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: Tokens.Metric.relatedGap) {
                if held, let letGo {
                    Button(Strings.Queue.letGo, action: letGo)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("toolbar.activity.letGo")
                }
                if let showTheList {
                    Button(Strings.StatusItem.showTheList, action: showTheList)
                        .accessibilityIdentifier("toolbar.activity.list")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Tokens.Metric.windowMargin)
        .accessibilityIdentifier("toolbar.activity.upNext")
    }
}
