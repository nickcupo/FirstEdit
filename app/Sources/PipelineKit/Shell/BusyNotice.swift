import SwiftUI

/// A refusal that explains itself, where he pressed (DESIGN.md §2.7, §2.13).
///
/// `RefusalRow` is the right shape for a refusal that is only a sentence. This
/// is the one that is not: another job of his is in the way, and there are two
/// real things he can do about it. So it shows four things `RefusalRow` cannot.
///
/// 1. **The engine's sentence, byte for byte.** It names the job. It is never
///    rewritten here and never shortened.
/// 2. **Where that job has got to** — the engine's own stage words and count,
///    and roughly how long is left. A bar underneath, because the number of
///    frames means nothing on its own at a glance.
/// 3. **Do It After**, which queues it. The engine's queue, its id, and
///    `Don't Wait` to take it back out.
/// 4. **Stop What Is Running**, because sometimes the answer is that the other
///    job was the mistake.
///
/// What it is deliberately NOT: an alert. Nothing here is modal, nothing takes
/// the keyboard, and the rest of the app stays usable — the whole complaint
/// was that he could not see WHY, not that he needed interrupting harder.
///
/// It never appears for the machine's own homework. A background job stands
/// down before the slot is asked for, so by the time anything reaches this
/// view the job in the way is work he asked for himself, which is why the
/// decision is his to make.
public struct BusyNotice: View {
    public let sentence: String
    public let busy: Busy
    /// Queue it. `nil` when the caller has no way to ask again, and then the
    /// button is not offered rather than offered and dead.
    public let wait: (() -> Void)?
    public let stopTheOther: (() -> Void)?
    /// Set once he has chosen to wait: the choices become the line saying so.
    public let waiting: Bool
    public let dontWait: (() -> Void)?

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(sentence: String, busy: Busy, waiting: Bool = false,
                wait: (() -> Void)? = nil, stopTheOther: (() -> Void)? = nil,
                dontWait: (() -> Void)? = nil) {
        self.sentence = sentence
        self.busy = busy
        self.waiting = waiting
        self.wait = wait
        self.stopTheOther = stopTheOther
        self.dontWait = dontWait
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
            Label {
                Text(sentence)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: Symbols.refusal)
                    .symbolRenderingMode(.hierarchical)
            }
            .font(.callout)
            // Not the alarm colour. Nothing has gone wrong: one job is in
            // front of another, which is what one job slot means. The alarm
            // colour is for a refusal he has to act on, and this is a wait.
            .foregroundStyle(.primary)

            // Where the job in the way has got to — but only when the
            // engine's sentence has not already said it. On the routes that
            // name what he was trying to do, the sentence carries the stage
            // and the count itself, and printing them again underneath is
            // the same line twice.
            if showsProgressLine {
                Text(busy.whereItHasGot)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if busy.fraction > 0 {
                ProgressView(value: min(max(busy.fraction, 0), 1))
                    .progressViewStyle(.linear)
                    .animation(reduceMotion ? nil : Motion.progress(over: QueueModel.busyInterval),
                               value: busy.fraction)
                    .accessibilityHidden(true)
            }

            choices
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(announcement)
        .accessibilityIdentifier("busy.\(busy.kind.isEmpty ? "job" : busy.kind)")
    }

    @ViewBuilder private var choices: some View {
        HStack(spacing: Tokens.Metric.relatedGap) {
            if waiting {
                Text(Strings.Job.waitingBehind(busy.title))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let dontWait {
                    Button(Strings.Job.dontWait, action: dontWait)
                        .controlSize(.small)
                }
            } else {
                // The queue first, because waiting is what he wants nine
                // times in ten and it costs him nothing.
                if let wait, busy.can_queue {
                    Button(Strings.Job.waitItsTurn, action: wait)
                        .controlSize(.small)
                        .accessibilityIdentifier("busy.wait")
                }
                if let stopTheOther {
                    Button(Strings.Job.stopTheOther, action: stopTheOther)
                        .controlSize(.small)
                        .accessibilityIdentifier("busy.stopTheOther")
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Whether the line under the sentence would say anything the sentence
    /// has not. `label` is the load-bearing half: where it has got to.
    private var showsProgressLine: Bool {
        !busy.whereItHasGot.isEmpty && !(busy.label.isEmpty || sentence.contains(busy.label))
    }

    /// One sentence for VoiceOver, because the parts of this read as three
    /// unrelated fragments otherwise.
    private var announcement: String {
        showsProgressLine ? sentence + ". " + busy.whereItHasGot : sentence
    }
}

/// The machine's homework stood down so his work could start. One line, in the
/// ordinary text colour, with the engine's own sentence in it.
///
/// It is not a refusal and must never look like one: nothing went wrong, he
/// lost nothing, and the run picks itself up when the Mac is next quiet. It is
/// here so that the thing did not happen silently — he pressed a button, the
/// machine put something down to answer him, and he gets told.
public struct PausedNote: View {
    public let sentence: String
    public init(_ sentence: String) { self.sentence = sentence }

    public var body: some View {
        Label {
            Text(sentence)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: Symbols.notInUse)
                .symbolRenderingMode(.hierarchical)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("job.paused")
    }
}
