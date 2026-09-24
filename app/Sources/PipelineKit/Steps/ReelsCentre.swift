import SwiftUI

/// The middle region: the last reel cut, playing at 9:16, beside what the
/// chosen burst is; and under them every frame of the burst.
struct ReelsCentre: View {
    @Bindable var model: ReelsModel
    let thumbs: ReelThumbs
    /// The page is too narrow for a third column, so the inspector is drawn
    /// here, under the frames.
    let inspectorBelow: Bool
    var focus: FocusState<ReelsFocus?>.Binding
    @State private var showAbout = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Metric.groupGap) {
                    HStack(alignment: .top, spacing: Tokens.Metric.groupGap) {
                        ReelPreview(model: model,
                                    height: inspectorBelow ? ReelsMetric.playerNarrow : ReelsMetric.player)
                        summary
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if inspectorBelow {
                        ReelsFormatBar(model: model, showAbout: $showAbout)
                    }
                    if model.format.isBurst {
                        ReelsFrameGrid(model: model, thumbs: thumbs, scroll: proxy, focus: focus)
                    }
                    if inspectorBelow {
                        Divider()
                        ReelsInspector(model: model, showAbout: $showAbout, showFormats: false)
                    }
                }
                .padding(Tokens.Metric.groupGap)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: - what the burst is

    @ViewBuilder private var summary: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
            if let e = model.loadError {
                RefusalRow(e, owner: .job)
            } else if model.options == nil {
                HStack(spacing: Tokens.Metric.relatedGap) {
                    ProgressView().controlSize(.small)
                    Text(Strings.Reels.reading).foregroundStyle(.secondary)
                }
            } else if model.format == .timelapse {
                timelapseSummary
            } else {
                burstSummary
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var timelapseSummary: some View {
        Text(model.tag.isEmpty ? Strings.Reels.wholeDay : model.tag)
            .font(.title3)
        let n = model.timelapseFrames
        if n >= ReelWait.least {
            Text(Strings.Reels.frames(n))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            Text(Strings.Reels.nothingTagged).foregroundStyle(.secondary)
        }
        // The row of formats says it under itself when the page is narrow.
        if !inspectorBelow {
            Text(Strings.Reels.formatNote(.timelapse))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var burstSummary: some View {
        let o = model.options
        if let b = model.chosenBurst {
            Text(Strings.Reels.burst(b.burst))
                .font(.title3)
                .monospacedDigit()
            if model.framesBurst == b.burst, !model.frames.isEmpty {
                Text(Strings.Reels.inTheCut(model.chosen.count, of: model.usable.count))
                    .monospacedDigit()
            } else {
                HStack(spacing: Tokens.Metric.relatedGap) {
                    ProgressView().controlSize(.small)
                    Text(Strings.Reels.reading).foregroundStyle(.secondary)
                }
            }
            // Laid out while the frames are read as well, so their arrival
            // moves nothing below it.
            trimButtons
            // Which of the two the reel will be made from, before he presses
            // anything: a draft off the RAWs is named so on disk, and has to
            // be named so here.
            if model.wait?.burst == b.burst {
                // The wait's own line says how much of it is exported.
                EmptyView()
            } else if model.isDraft {
                Label {
                    Text(Strings.Reels.draft(b.frames - b.exported, of: b.frames))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "doc.badge.clock").foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            } else {
                Label(Strings.Reels.fromExports, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            waitOrSpread(b)
        } else if let o, o.exports_found == 0 {
            Text(Strings.Reels.nothingExported)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let o, o.exports_found > 0, model.chosenBurst == nil {
            Text(Strings.Reels.exportsFound(o.exports_found)).foregroundStyle(.secondary)
        }
    }

    /// Every frame out, or every frame back. Both are always laid out, and
    /// the one with nothing to do is only hidden, so the first frame taken
    /// out never moves anything under his pointer.
    @ViewBuilder private var trimButtons: some View {
        let noneIn = model.chosen.isEmpty
        let noneOut = model.chosen.count == model.usable.count
        HStack(spacing: Tokens.Metric.relatedGap) {
            Button(Strings.Reels.leaveAllOut) { model.leaveAllOut() }
                .disabled(noneIn)
            Button(Strings.Reels.putBackAll) { model.putAllBack() }
                .opacity(noneOut ? 0 : 1)
                .disabled(noneOut)
                .accessibilityHidden(noneOut)
        }
        .controlSize(.small)
    }

    /// Finishing the burst in PhotoLab, or waiting for him to. The wait is
    /// shown whichever burst he is looking at, and names its own: he may be
    /// browsing another while PhotoLab exports.
    @ViewBuilder private func waitOrSpread(_ b: BurstOption) -> some View {
        if let w = model.wait {
            VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.relatedGap) {
                    if !w.settled { ProgressView().controlSize(.small) }
                    Text(Self.waitLine(w))
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: Tokens.Metric.relatedGap) {
                    // On the burst it waits on, the step's primary is Cut Now
                    // already; a second one beside it would be the same press.
                    if !model.waitingHere {
                        Button(Strings.Reels.cutNow) { model.cutNow() }
                            .disabled(!w.ready || w.settled)
                    }
                    Button(Strings.Reels.stopWaiting) { model.stopWaiting() }
                }
                .controlSize(.small)
                if model.frozenChanged {
                    Text(Strings.Reels.frozen)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if b.exported < b.frames {
            VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
                if let note = model.waitNote {
                    Text(note)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Not while a reel is being cut or presets are being written:
                // one job at a time, and this one would only queue behind it.
                Button(Strings.Reels.spread) { model.finishInPhotoLab() }
                    .disabled(model.spreadJob.phase != .idle || model.reelJob.phase != .idle)
                    .help(Strings.Reels.spreadHelp)
                StepNote(Strings.Reels.spreadNote)
            }
        }
    }

    /// One line for the whole wait: writing the presets, waiting, how many of
    /// the burst have come and when what has come will be cut, or cutting.
    /// A reel of some of the burst's frames also says Cut Now is his once
    /// those are in: the count is the burst's, so the wait alone would hold
    /// his six frames until the whole burst or the pause.
    static func waitLine(_ w: ReelWait) -> String {
        if !w.ready { return Strings.Reels.preparing(w.burst) }
        if w.settled { return Strings.Reels.cutting(w.burst, w.seen, of: w.target) }
        var line = w.arriving ? Strings.Reels.soFar(w.burst, w.seen, of: w.target) : Strings.Reels.waiting(w.burst)
        if w.arriving, let d = w.cutsIn { line += " " + Strings.Reels.cutsIn(Int(d.components.seconds)) }
        if let n = w.reelFrames, let total = w.target, n < total {
            line += " " + Strings.Reels.someOfTheBurst(n, of: total)
        }
        // It never gives up by itself; the line says it has slowed, so a
        // minute's wait for the cut after a late export is not a surprise.
        if w.slowing > 1 {
            line += " " + Strings.Reels.slower(minutes: w.idleSeconds / 60,
                                               every: Int(ReelWait.interval.components.seconds) * w.slowing)
        }
        return line
    }
}
