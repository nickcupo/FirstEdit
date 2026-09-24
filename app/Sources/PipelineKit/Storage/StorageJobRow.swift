import SwiftUI

/// The job the panel started, at the top of the panel: while it runs, what it
/// is doing and how far along; when it ends, how it ended, once.
///
/// Every word on it is the engine's — its title for the job, its stage words,
/// its time left and the last line the command printed. The app adds the bar
/// and the outcome word, and nothing else. It is here because the panel used
/// to load once, when it appeared: a copy of 36 GB to iCloud finished and the
/// panel still said "nothing in iCloud · one copy" until he left the page and
/// came back (§2.8).
struct StorageJobRow: View {
    let model: StorageModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The ending first: it is set the moment the job stops, while the panel
    /// is still being read again and the job's number is still held.
    var body: some View {
        if let e = model.ended {
            ended(e)
        } else if model.isFollowing {
            running(model.following)
        }
    }

    private func running(_ j: Job?) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            Text((j?.title).flatMap { $0.isEmpty ? nil : $0.capitalizedFirst } ?? Strings.Storage.jobStarting)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            let where_ = [j?.label ?? "", j?.remaining_text ?? ""].filter { !$0.isEmpty }
                .joined(separator: " · ")
            if !where_.isEmpty {
                Text(where_)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Determinate once the engine has a fraction to give, and honest
            // about not having one before that.
            if let f = j?.fraction, f > 0 {
                ProgressView(value: min(max(f, 0), 1))
                    .progressViewStyle(.linear)
                    .animation(reduceMotion ? nil : Motion.progress(over: StorageModel.followInterval),
                               value: f)
                    .accessibilityHidden(true)
            } else {
                ProgressView().progressViewStyle(.linear).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("storage.job.running")
    }

    private func ended(_ e: StorageModel.Ended) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.relatedGap) {
            Image(systemName: symbol(e.outcome))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint(e.outcome))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Strings.Storage.jobEnded(e.outcome, e.title))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if !e.line.isEmpty {
                    Text(e.line.capitalizedFirst)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button {
                model.clearEnded()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            // Not while the panel is still being read again after the job:
            // dismissing then would leave the job's own row with nothing in it.
            .disabled(model.isFollowing)
            .help(Strings.Storage.dismiss)
            .accessibilityLabel(Strings.Storage.dismiss)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storage.job.ended")
    }

    /// A symbol and a word, never colour alone. Refused is in the ordinary
    /// text colour: a command that said no on purpose did not fail (§2.7).
    private func symbol(_ o: Job.Outcome) -> String {
        switch o {
        case .done: return "checkmark.circle"
        case .stopped: return "stop.circle"
        case .refused: return "hand.raised"
        case .failed: return Symbols.brokenShoot
        case .idle, .running: return "circle.dotted"
        }
    }

    private func tint(_ o: Job.Outcome) -> Color {
        switch o {
        case .failed: return Tokens.Palette.alarm
        case .done: return Tokens.Palette.kept
        default: return .secondary
        }
    }
}
