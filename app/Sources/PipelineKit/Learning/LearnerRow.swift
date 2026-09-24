import SwiftUI

/// One learner: what it read, what it changes, what it would cost him, and
/// whether it is in use or held.
///
/// **The state word appears once on the row.** The engine's own sentence
/// already opens with it — "Not in use. The new version would…" — so the
/// header carries the symbol and the sentence carries the word, and the two
/// never say the same thing twice. Where the engine sends no sentence, the
/// header shows the word instead, so a state is never colour alone.
struct LearnerRow: View {
    let learner: Learner
    let model: LearnedModel
    /// Opens the read-only review of the affected keepers.
    let showFrames: (Learner) -> Void
    /// Does what a needs line asks, on the shoot it names: brings its RAWs
    /// back, or opens it where its keepers are finished.
    var act: (LearnerNeed) -> Void = { _ in }

    @Environment(\.accessibilityDifferentiateWithoutColor) private var noColour

    private var sentence: String { Self.dated(model.sentence(for: learner), learner.live_since) }

    /// "In use since 2026-09-22." read as "In use since Sep 22.", the same
    /// form the footer's "Last checked Sep 22, 2:10 PM" is in. Only the date
    /// the engine also sent as data is touched, so nothing else in its
    /// sentence is re-read.
    static func dated(_ text: String, _ stamp: String?) -> String {
        guard let stamp, !stamp.isEmpty, let shown = LearnedView.when(stamp), shown != stamp
        else { return text }
        return text.replacingOccurrences(of: stamp, with: shown)
    }
    /// The word goes in the header only when nothing else on the row says it.
    private var headerNeedsWord: Bool {
        sentence.isEmpty || !sentence.lowercased().hasPrefix(learner.status.word.lowercased())
    }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Metric.relatedGap) {
            Image(systemName: learner.status.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .font(.title3)
                .frame(width: 20)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
                header
                detail
                if let m = model.refusals[.learner(learner.id)] {
                    RefusalRow(m, owner: .learner(learner.id))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        // Lit for a moment when the banner's What Changed brings it into view.
        .background(model.highlighted == learner.id ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(Motion.step, value: model.highlighted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(learner.title). \(learner.status.word). "
                            + [sentence, learner.candidate_sentence, learner.needsText]
                                .filter { !$0.isEmpty }.joined(separator: " "))
        .accessibilityIdentifier("learner.\(learner.id)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.relatedGap) {
            Text(learner.title).font(.headline)
            if headerNeedsWord {
                Text(learner.status.word).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: Tokens.Metric.relatedGap)
            if model.busyLearner == learner.id {
                ProgressView().controlSize(.small)
            }
            actions
        }
    }

    /// Colour is never the only signal: the symbol's shape differs by state,
    /// the word is on the row, and with Differentiate Without Color the tint
    /// drops out entirely.
    private var tint: Color {
        if noColour { return .secondary }
        switch learner.status {
        case .in_use: return Tokens.Palette.kept
        case .not_in_use, .stopped: return Tokens.Palette.fault
        case .could_not_check: return .yellow
        case .not_enough, .none, .fixed: return .secondary
        }
    }

    private var candidateTint: Color {
        learner.candidate_status == .could_not_check ? .yellow : Tokens.Palette.fault
    }

    @ViewBuilder private var actions: some View {
        if learner.can_go_back || learner.can_stop || learner.status == .stopped {
            Menu {
                if learner.can_go_back {
                    Button(Strings.Learning.goBack) { Task { await model.goBack(learner) } }
                }
                if learner.status == .stopped {
                    // Turning it back on runs the same check as going back.
                    Button(Strings.Learning.startUsing) { Task { await model.goBack(learner) } }
                } else if learner.can_stop {
                    Button(Strings.Learning.stopUsing) { Task { await model.stopUsing(learner) } }
                }
            } label: {
                Image(systemName: Symbols.more)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Strings.Learning.moreActions)
            .accessibilityIdentifier("learner.\(learner.id).more")
        }
    }

    // MARK: what it read, what it changes, what it would cost

    /// In the order he asks the questions: what this learns and changes,
    /// what the version in use read, whether it is in use, what waits beside
    /// it, what it is short of — and the measurement store's reassurance last,
    /// as a footnote. That reassurance ("All 837 are measured and kept…") used
    /// to come first, above the line saying what the learner even does.
    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !learner.changes.isEmpty {
                Text(learner.changes.capitalizedFirst)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !learner.readWhat.isEmpty {
                Text(learner.readWhat.capitalizedFirst)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !sentence.isEmpty {
                Text(sentence)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
                    .accessibilityIdentifier("learner.\(learner.id).sentence")
            }
            // What is waiting beside what is in use, and what it is short of:
            // the engine's two other lines, each said once, each with its own
            // symbol so "held back for what it would do" and "not enough yet"
            // never read as the same thing (they need opposite things from him).
            if !learner.candidate_sentence.isEmpty {
                Label {
                    Text(learner.candidate_sentence)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: (learner.candidate_status ?? .not_in_use).symbol)
                        // Drawn the way the title's symbol is: the same pause
                        // symbol a few points apart, one washed out and one
                        // saturated, read as two different states.
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(noColour ? Color.secondary : candidateTint)
                        .accessibilityHidden(true)
                }
                .font(.callout)
                .accessibilityIdentifier("learner.\(learner.id).candidate")
            }
            // A shoot the check could not reach for want of picture vectors:
            // a Measure button beside the line, where it ended in a command
            // to type.
            if !learner.check_do.isEmpty {
                HStack(spacing: Tokens.Metric.relatedGap) {
                    ForEach(learner.check_do) { need in
                        Button(Strings.Learning.needButton(need)) { act(need) }
                            .help(Strings.Learning.needHelp(need))
                            .accessibilityIdentifier("learner.\(learner.id).check.\(need.id)")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.leading, 20)
            }
            if !learner.needs_sentence.isEmpty || !learner.needs_lines.isEmpty {
                Label {
                    needs
                } icon: {
                    Image(systemName: LearnerStatus.not_enough.symbol)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("learner.\(learner.id).needs")
            }
            // The one way to what it would cost him, on its own line so the
            // sentence never has to flow around it.
            if learner.hasFramesToShow, let c = learner.check {
                // The label is an explicit `Text`, sized to itself, and the
                // button carries an identity of its own. Passed as a bare
                // string it is SwiftUI's own label view, and inside the whole
                // window — the Form inside the detail column of a split view,
                // which is how he will always see this page — the second
                // row's copy finished layout with the title squeezed to
                // nothing or drawn through the row below it. On its own the
                // same row was fine, which is why this was missed.
                Button {
                    showFrames(learner)
                } label: {
                    Text(Strings.Learning.seeThem(c.frames.count)).fixedSize()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .id("\(learner.id).seeThem")
                .accessibilityIdentifier("learner.\(learner.id).seeThem")
                .padding(.top, 4)
            }
            if !learner.plain_metric.isEmpty {
                Text(learner.plain_metric.capitalizedFirst)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            // The shoots it could not measure against, NAMED ONCE. This drew a
            // Label per shoot, each carrying the same reason the sentence above
            // had already given — six copies of one fact, in words naming a
            // file of ours. The reason belongs to the set, not to each row.
            if let c = learner.check, !c.couldnt_check.isEmpty {
                Text(Strings.Learning.notCheckedOn(c.couldnt_check.map(\.shoot)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .accessibilityIdentifier("learner.\(learner.id).notCheckedOn")
            }
        }
    }
}

extension LearnerRow {
    /// What it is short of: a fact to a line where the engine sends them,
    /// and a button beside each shoot the lines ask him to act on. The one
    /// sentence ran four to seven lines chained with semicolons, and the
    /// line asking him to bring a shoot back ended in a command to type.
    @ViewBuilder var needs: some View {
        VStack(alignment: .leading, spacing: 2) {
            if learner.needs_lines.isEmpty {
                Text(learner.needs_sentence)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(learner.needs_lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !learner.needs_do.isEmpty {
                HStack(spacing: Tokens.Metric.relatedGap) {
                    ForEach(learner.needs_do) { need in
                        Button(Strings.Learning.needButton(need)) { act(need) }
                            .help(Strings.Learning.needHelp(need))
                            .accessibilityIdentifier("learner.\(learner.id).need.\(need.id)")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }
}

/// Something built in, said so it is not mistaken for something that learns.
struct FixedThingRow: View {
    let thing: FixedThing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.relatedGap) {
            // A dot, not a ring: a ring beside a title reads as a control
            // he could turn on, and this is a statement of fact.
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(thing.title).font(.callout)
                if !thing.sentence.isEmpty {
                    Text(thing.sentence)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension String {
    /// "44 reasons you gave…" reads as a sentence when it starts one. Only the
    /// first letter is touched, and only when it is already lower case, so a
    /// name the engine wrote is never re-cased.
    var capitalizedFirst: String {
        guard let f = first, f.isLowercase else { return self }
        return String(f).uppercased() + dropFirst()
    }
}
