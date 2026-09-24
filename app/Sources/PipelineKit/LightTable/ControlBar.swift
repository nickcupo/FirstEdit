import SwiftUI

/// The bar under the picture (§2.5.2).
///
/// 56 pt, its own surface, **fixed**: it never wraps, never scrolls and never
/// moves. Below 1100 pt of content it grows a 24 pt caption lane above the
/// cluster, so the caption and the tally never sit on the photograph. Today's
/// equivalent row wraps to two lines at the app's own default window size and
/// the wrapped row is then clipped to a 26 px sliver (LT-03), which is why
/// nothing here is in an `HStack` that could decide to break.
/// Every control is placed at the exact x `ControlBarLayout` computes, and the
/// cluster is centred on the content column as it is with the inspector shut,
/// so Keep and Drop do not move when the inspector opens (§2.5.2).
public struct ControlBar: View {
    @Bindable var model: ViewerModel
    /// The Full Image HUD's copy of the bar: the cluster alone. The HUD
    /// carries the frame's caption in its own pill, and the refusal is drawn
    /// by Full Image itself, so this copy has neither the captions nor the
    /// lane. Handed the HUD's 793 pt it grew the lane, said the caption twice
    /// and stood 24 pt taller over the feet of the frame.
    let inHUD: Bool
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.increaseContrastOverride) private var contrastOverride
    /// Increase Contrast, from the system unless the harness overrides it.
    private var increased: Bool { contrastOverride ?? (systemContrast == .increased) }

    public init(model: ViewerModel, inHUD: Bool = false) {
        self.model = model
        self.inHUD = inHUD
    }

    public var body: some View {
        Group {
            if inHUD {
                clusterBand
            } else {
                // Beside the cluster from 1100 pt of column, on a lane of the
                // bar's own below that. Chosen from the width the bar is
                // offered, so it is the right height on its first frame: read
                // back from a measurement, it started out as if it had 1100 pt
                // and could draw a frame without the lane before the answer
                // came, the photograph above it then dropping by 24 pt.
                ViewThatFits(in: .horizontal) {
                    clusterBand
                        .frame(minWidth: ControlBarLayout.captionsNeed(inspector: inspector))
                    VStack(spacing: 0) {
                        captionLane
                        clusterBand
                    }
                }
            }
        }
        .background(.bar)
        .overlay(alignment: .top) {
            if increased { Divider() }
        }
        // In Compare and All Bursts the refusal sits directly above the two
        // buttons that raised it. Over the single frame it is one of the
        // viewer's notices instead (`VerdictRefusal`), so it is never drawn
        // across the end-of-burst line, as it was at this fixed offset; in
        // Full Image, Full Image draws it.
        .overlay(alignment: .top) {
            if !inHUD && (model.mode == .compare || model.mode == .allBursts) { refusal }
        }
        // A named group, so VoiceOver says where it is before the first
        // button; it was a container with no name at all.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.LightTable.frameControls)
    }

    /// What the inspector is taking off the column beside the bar. The HUD's
    /// copy is over the whole window and has none.
    private var inspector: CGFloat {
        !inHUD && model.navigation.inspectorOnScreen ? Tokens.Metric.inspector : 0
    }

    /// The 56 pt band the cluster is placed in, to the point.
    private var clusterBand: some View {
        GeometryReader { geo in
            let layout = ControlBarLayout(contentWidth: geo.size.width, inspector: inspector)
            ZStack(alignment: .topLeading) {
                // The bar's own full width, so the stack is the width of the
                // content column and every offset below is measured from its
                // leading edge. Without it the stack shrinks to its widest
                // child and the whole cluster slides — which is exactly the
                // class of drift §2.5.2 exists to rule out.
                Color.clear
                    .frame(width: geo.size.width, height: layout.height)
                if layout.showsSideCaptions && !inHUD {
                    // Against the cluster on both sides: the caption ends
                    // 16 pt before Undo as the tally starts 16 pt after Next
                    // Burst. Set from the box's leading edge, a short caption
                    // on a wide window stood some 150 pt out from Undo and
                    // lined up with nothing.
                    caption
                        .frame(width: layout.leadingCaption.width, height: layout.height, alignment: .trailing)
                        .offset(x: layout.leadingCaption.minX)
                    tally
                        .frame(width: layout.trailingTally.width, height: layout.height, alignment: .leading)
                        .offset(x: layout.trailingTally.minX)
                }
                cluster(layout)
            }
            .frame(width: geo.size.width, height: layout.height, alignment: .topLeading)
        }
        .frame(height: Tokens.Metric.controlBar)
    }

    // MARK: - the cluster

    @ViewBuilder
    private func cluster(_ layout: ControlBarLayout) -> some View {
        let stack = model.currentStack
        Group {
            place(.undo, layout) {
                StageButton(symbol: Symbols.undo, label: Strings.LightTable.undo,
                            size: Tokens.Metric.undoButton.width,
                            enabled: model.session.undo.canUndo,
                            help: Strings.LightTable.withKey(
                                model.session.undo.undoName.map { "\(Strings.LightTable.undo) \($0)" }
                                    ?? Strings.LightTable.undo,
                                LightTableKeys.key("edit.undo"))) {
                    model.perform(.undo)
                }
            }
            // ‹ and › go wherever ← and → go, which is across bursts: greyed
            // only at the two ends of the shoot. › on a burst's last frame is
            // Next Burst, and its tag says so.
            place(.previous, layout) {
                StageButton(symbol: Symbols.previous, label: Strings.LightTable.previousFrame,
                            size: Tokens.Metric.stepButton.width,
                            enabled: canGoBack, help: previousHelp) { model.perform(.previousFrame) }
            }
            // Nothing can be decided from All Bursts: it shows covers, and the
            // frame a verdict would land on is hidden behind them.
            place(.drop, layout) {
                VerdictButton(.drop) { model.perform(.drop) }.disabled(model.mode == .allBursts)
            }
            place(.label, layout) {
                FrameLabel(position: model.positionText, stackCount: stack?.count,
                           his: model.currentRow.map(VerdictValue.his) ?? .unmarked)
            }
            place(.keep, layout) {
                VerdictButton(.keep) { model.perform(.keep) }.disabled(model.mode == .allBursts)
            }
            place(.next, layout) {
                StageButton(symbol: Symbols.next, label: Strings.LightTable.nextFrame,
                            size: Tokens.Metric.stepButton.width,
                            enabled: canGoOn, help: nextHelp) { model.perform(.nextFrame) }
            }
            // A rule, so Keep and Next Burst never read as a pair.
            place(.divider, layout) {
                Rectangle().fill(.quaternary)
                    .frame(width: 1, height: ControlBarLayout.Item.divider.size.height)
            }
            place(.compare, layout) {
                StageButton(symbol: Symbols.compare, label: Strings.LightTable.compare,
                            size: Tokens.Metric.compareButton.width,
                            badge: compareCount, enabled: model.canCompare,
                            help: model.pickedForCompare == nil ? Strings.LightTable.compareHelp
                                                                : Strings.LightTable.comparePickedHelp) {
                    model.perform(.compare)
                }
            }
            place(.nextBurst, layout) { nextBurst }
        }
    }

    /// A control the column has no room for is **not drawn**, rather than
    /// drawn where the pointer cannot reach it. `ControlBarLayout.shedStages`
    /// says which ones those are and in what order; each has a key and a menu
    /// item that go on working.
    @ViewBuilder
    private func place<V: View>(_ item: ControlBarLayout.Item, _ layout: ControlBarLayout,
                                @ViewBuilder _ content: () -> V) -> some View {
        if layout.shows(item) {
            let f = layout.frame(item)
            content()
                .frame(width: f.width, height: f.height)
                .offset(x: f.minX, y: f.minY)
        }
    }

    /// What `.bordered` at `.regular` puts either side of a label, measured
    /// off the render.
    static let borderedBezelPadding: CGFloat = 8

    private var nextBurst: some View {
        Button {
            model.perform(.nextBurst)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: Symbols.nextBurst).symbolRenderingMode(.hierarchical)
                Text(nextBurstTitle)
            }
            .font(.body)
            // The bordered bezel adds 8 pt either side of its label, so a
            // label as wide as the button drew a bezel 142 pt wide in a 128 pt
            // place: 7 pt over each side, touching Compare and eating into
            // the gap before the tally, which measured 12.5 pt, not 16.
            .frame(width: Tokens.Metric.nextBurstButton.width - Self.borderedBezelPadding * 2,
                   height: Tokens.Metric.nextBurstButton.height - 2)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(width: Tokens.Metric.nextBurstButton.width, height: Tokens.Metric.nextBurstButton.height)
        // No key held here: N is read by the light table's one key path,
        // where a held N finishes one burst and not every burst it repeats
        // over (§2.5.3).
        .disabled(!model.canGoToNextBurst)
        .help(Strings.LightTable.withKey(nextBurstHelp, LightTableKeys.key(CommandTable.ID.finishBurst)))
        .accessibilityLabel(nextBurstTitle)
        .accessibilityHint(nextBurstHelp)
    }

    /// On the last burst the button is On to Presets, and never greyed: N
    /// there finishes the burst, if it is not finished yet, and goes on to
    /// Presets, as the line's Continue to Presets does (§2.5.2). It used to
    /// be Finish Burst, which recorded the burst and stayed, and then went
    /// grey with nothing left to finish, so the end of every shoot was one
    /// more trip to the link or ⌘].
    ///
    /// Not in All Bursts: there N goes to a burst he has not been through and
    /// finishes nothing (§2.5.11), so the button keeps saying Next Burst.
    /// Nor while he looks through a fault's frames, where N finishes nothing
    /// either and goes to the next burst that has any of them (§2.6).
    var nextBurstTitle: String {
        model.nextBurstLeavesForPresets ? Strings.LightTable.onToPresets : Strings.LightTable.nextBurst
    }

    private var nextBurstHelp: String {
        model.nextBurstLeavesForPresets ? Strings.LightTable.onToPresetsHelp : Strings.LightTable.nextBurstHelp
    }

    /// The refusal, where the action was taken, a hand's width above the
    /// press that raised it.
    private var refusal: some View {
        VerdictRefusal(model: model)
            .offset(y: -(Tokens.Metric.controlBar / 2 + 6))
    }

    /// `07179 · burst 265`, beside the cluster and on the lane alike.
    private var barCaption: String {
        guard let stem = model.currentStem else { return "" }
        return Strings.LightTable.barCaption(ShootSession.shortStem(stem), burst: model.burstIndex + 1)
    }

    /// How many frames Compare would open on, or nothing when it would only
    /// bounce: the frames he ⌘-clicked in the strip when he has picked two or
    /// more, the stack otherwise (§2.5.12). With a pair picked outside any
    /// stack the button was greyed, and so was Frame ▸ Compare, while C
    /// opened exactly that pair.
    var compareCount: Int? {
        if let picked = model.pickedForCompare { return picked.count }
        guard let n = model.currentStack?.count, n > 1 else { return nil }
        return n
    }

    // MARK: - the step arrows

    /// ‹ and › do what ← and → do, and those cross bursts: ← off a burst's
    /// first frame lands on the last frame of the one before, → off its last
    /// frame finishes it and opens the next. The buttons were greyed at every
    /// burst's ends — a quarter of the time on his four-frame bursts — while
    /// the keys on the same frame carried on, so the mouse was told it could
    /// not go where the keyboard went. Only the two ends of the shoot stop.
    var canGoBack: Bool { model.frameIndex > 0 || model.burstIndex > 0 }
    /// On the last frame of the last burst → still finishes that burst, as
    /// N does, until it is finished; after that there is nowhere to go.
    var canGoOn: Bool { !model.isLastFrameOfBurst || model.canFinishBurst }

    /// The chevrons' tags name their keys from the menu bar's table, the left
    /// hand's first: `Previous frame (S or ←)`. On a burst's last frame ›
    /// does what R does, and names R and N as well.
    var previousHelp: String {
        typealias ID = CommandTable.ID
        let words = model.frameIndex == 0 && model.burstIndex > 0 ? Strings.LightTable.previousBurstEndHelp
                                                                  : Strings.LightTable.previousFrameHelp
        return Strings.LightTable.withKey(words, LightTableKeys.key(ID.previousFrame))
    }

    var nextHelp: String {
        typealias ID = CommandTable.ID
        guard model.isLastFrameOfBurst, model.lookingThrough == nil else {
            return Strings.LightTable.withKey(Strings.LightTable.nextFrameHelp, LightTableKeys.key(ID.nextFrame))
        }
        return model.isLastBurst
            ? Strings.LightTable.withKey(Strings.LightTable.nextFrameFinishesLastHelp,
                                         LightTableKeys.key(ID.nextFrame))
            : Strings.LightTable.withKey(Strings.LightTable.nextFrameFinishesHelp,
                                         LightTableKeys.keys(ID.nextFrame, ID.finishBurst))
    }

    // MARK: - the two side captions

    /// `04330 · burst 3` over the cull's own line. Where he is in the burst,
    /// `2 of 7`, is the frame label's between Drop and Keep: said here as
    /// well, it pushed the burst number off the end at 1100 pt
    /// (`04330 · 2 of 7 in burst…`), and that number is said nowhere else.
    private var caption: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(barCaption)
                .font(.callout)
                .lineLimit(1)
            if model.showHeldKeyTip {
                Text(Strings.Verdict.heldKey)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let note = model.session.keyNote {
                Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            } else {
                // The cull speaks in grey, in its own words, and never in a
                // shape he uses.
                // The cull's own sentence, shrunk a little rather than cut:
                // "the cull: clear win — only frame" losing its last word is
                // the machine being made to sound less sure than it is.
                Text(model.cullLine)
                    .font(.footnote)
                    .foregroundStyle(Tokens.Palette.machine)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Below 1100 pt of content the caption and the tally, on one line of the
    /// bar's own above the cluster: `04330 · burst 3 · the cull: maybe` at
    /// the leading margin and `Kept 5 · Out 1 · 1 to go` at the trailing one.
    /// `2 of 7` is the frame label's, in the cluster just below.
    ///
    /// They used to move onto the photograph instead, as a chip the whole
    /// width of the viewer across its bottom edge — which on a portrait frame
    /// ran far past both sides of the picture, and on every frame covered the
    /// feet at the bottom of the frame, where "cut off" is judged. The
    /// picture gives up 24 pt of height here rather than have anything drawn
    /// over it.
    private var captionLane: some View {
        HStack(spacing: Tokens.Metric.relatedGap) {
            Text(barCaption)
                .lineLimit(1)
                .layoutPriority(2)
            Text("·").foregroundStyle(.tertiary)
            secondLine
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: Tokens.Metric.groupGap)
            Text(model.tallyText)
                .countStyle()
                .lineLimit(1)
                .layoutPriority(2)
            if let zoom = model.zoomLabel {
                Text(zoom).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
            }
        }
        .font(.callout)
        .padding(.horizontal, Tokens.Metric.barMargin)
        .frame(height: ControlBarLayout.captionLane)
        .accessibilityElement(children: .combine)
    }

    /// Under the frame caption, or after it in the lane: the held-key line,
    /// the key note, or the cull's own sentence in grey — the cull speaks in
    /// its own words, and never in a shape he uses.
    @ViewBuilder
    private var secondLine: some View {
        if model.showHeldKeyTip {
            Text(Strings.Verdict.heldKey).foregroundStyle(.secondary)
        } else if let note = model.session.keyNote {
            Text(note).foregroundStyle(.secondary)
        } else {
            Text(model.cullLine).foregroundStyle(Tokens.Palette.machine)
        }
    }

    /// His tally, and the zoom label when it is not Fit — the label always says
    /// where 1:1 is pointing.
    private var tally: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Shrunk a little rather than cut, as the cull's line is: cut,
            // "Kept 15 · Out 1 · 16 agreed" lost the one word that says those
            // frames are the cull's call and not work to go. And a group's
            // gap clear of Next Burst, which it used to start 2.5 pt from and
            // read as part of: at the default window that leaves this lane
            // 137 pt, and the worst two-figure count, "Kept 32 · Out 12 · 16
            // agreed", is 162, so it may shrink to 84 %.
            Text(model.tallyText)
                .font(.callout)
                .countStyle()
                .lineLimit(1)
                .minimumScaleFactor(0.84)
            if let zoom = model.zoomLabel {
                Text(zoom)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A verdict refused, in the alarm colour, whole (§2.5.4).
///
/// §2.5.4 puts it on the control bar's second line, and at 1100 pt that line
/// is 145 pt wide — which cut "its RAW is archived, or its rendering was taken
/// back" in half, and a refusal he cannot finish reading does not explain
/// itself. So it is a chip of the width it needs, centred on the content
/// column, which is where Drop and Keep are: over the single frame it is the
/// first of the viewer's notices, and in Compare and All Bursts it sits over
/// the bar. It is cleared only by its owner. The row itself is the shell's
/// `RefusalRow`, so the alarm colour, the owner tag and the Details
/// disclosure are the same here as everywhere else.
public struct VerdictRefusal: View {
    let model: ViewerModel

    public init(model: ViewerModel) { self.model = model }

    public var body: some View {
        if model.session.refusals[.verdict] != nil {
            model.session.refusals.row(.verdict)
                .padding(.horizontal, Tokens.Metric.relatedGap + 2)
                .padding(.vertical, 5)
                .viewerChip()
                .fixedSize()
                .transition(.opacity)
        }
    }
}

/// Which one line sits over the bottom of the photograph (§2.5.2).
///
/// One at a time, the most pressing first: a refused verdict about the frame
/// on screen; the strip after D, for its three seconds, because it is asking
/// him something about the frame he has just left; the end of the burst; a
/// refusal still standing from a frame he has since left; while he is
/// ⌘-clicking frames to compare, the line about those, which is what C opens;
/// then the invitation to Compare, for as long as it can do what it says from
/// where he stands — before the stack it names or inside it, where C and a
/// click open it; past the stack it could only bounce. They used to stack up: on the last
/// frame after a D the invitation, the strip and the end-of-burst line covered
/// the bottom of the picture together, and the refusal, at a fixed height over
/// the bar, was drawn across the middle of the end line.
///
/// A refusal stays until its owner clears it (§7.7), which moving never does,
/// so one raised three frames back ranks behind the end of the burst: first,
/// it hid the end-of-burst line on every frame after, and on the shoot's last
/// frame the only Continue to Presets on the screen.
public enum ViewerNotice: Equatable {
    case refusal
    case reason
    case endOfBurst(String)
    case picked(String)
    case invitation(Int)

    @MainActor
    public static func current(_ m: ViewerModel, at now: Date = Date()) -> ViewerNotice? {
        let refused = m.session.refusals[.verdict] != nil
        if refused && refusalIsHere(m) { return .refusal }
        // The strip names the frame D put out; with none to name it is not up.
        if m.reasonStripStem != nil, let until = m.reasonStripUntil, now < until { return .reason }
        if let line = m.endOfBurstLine { return .endOfBurst(line) }
        if refused { return .refusal }
        if let line = m.pickedLine { return .picked(line) }
        if let n = m.stackInvitation { return .invitation(n) }
        return nil
    }

    /// Whether the verdict refusal standing was raised on the frame on
    /// screen. One that says nothing of where it was raised counts as here.
    @MainActor
    public static func refusalIsHere(_ m: ViewerModel) -> Bool {
        guard m.session.refusals[.verdict] != nil else { return false }
        guard let place = m.session.refusals.place(.verdict) else { return true }
        return place == m.currentStem
    }
}

/// The one notice over the photograph, drawn: `ViewerNotice` decides which.
///
/// It keeps its own clock for the strip after D, so the line underneath comes
/// back the moment the strip's three seconds are up rather than at the next
/// press. The end-of-burst line is the step's own, handed in, because its
/// links go to places only the step knows.
public struct ViewerNotices<EndOfBurst: View>: View {
    @Bindable var model: ViewerModel
    let endOfBurst: (String) -> EndOfBurst
    @State private var now = Date()

    public init(model: ViewerModel, @ViewBuilder endOfBurst: @escaping (String) -> EndOfBurst) {
        self.model = model
        self.endOfBurst = endOfBurst
    }

    public var body: some View {
        Group {
            switch ViewerNotice.current(model, at: now) {
            case .refusal:
                VerdictRefusal(model: model)
            case .reason:
                ReasonStrip(model: model)
            case .endOfBurst(let line):
                endOfBurst(line)
            case .picked(let line):
                // In the invitation's place: two of these are what C opens,
                // not the stack the invitation names.
                Text(line)
                    .font(.callout)
                    .padding(.horizontal, Tokens.Metric.relatedGap + 2)
                    .padding(.vertical, 5)
                    .viewerChip(Capsule())
            case .invitation(let n):
                // An invitation, never an automatic view change: a view
                // arriving under a moving hand is how a keystroke lands in
                // the wrong place. It opens the stack it names, from
                // wherever he is before it.
                Button(Strings.LightTable.stackInvitation(n)) { model.compareInvitedStack() }
                    .buttonStyle(.link)
                    .font(.callout)
                    .padding(.horizontal, Tokens.Metric.relatedGap + 2)
                    .padding(.vertical, 5)
                    .viewerChip(Capsule())
            case nil:
                EmptyView()
            }
        }
        .task(id: model.reasonStripUntil) {
            now = Date()
            guard let until = model.reasonStripUntil, until > now else { return }
            try? await Task.sleep(for: .seconds(until.timeIntervalSince(now)))
            now = Date()
        }
    }
}
