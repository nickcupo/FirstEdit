import SwiftUI
import AppKit

/// Choose Keepers — the light table, assembled (§2.5).
///
/// Four fixed bands and the photograph, which gets everything that is left:
/// 51.4 % of the window at 1100 × 780 against 30.1 % today (LT-04), and 94 % on
/// Space. The bands never move, never wrap and never scroll, so the two
/// verdict buttons are in the same place on every screen, at every window size,
/// in every mode.
///
/// **Leaving this step never asks anything and never writes anything.** Today's
/// confirm is the only dialog in the app guarding a non-destructive act
/// (LT-12), and it can write "reviewed" over bursts he never saw (LT-01). The
/// honesty it was carrying lives in the Presets step now, where the consequence
/// actually is.
public struct ChooseKeepersStep: View, StepView {
    @State private var model: ViewerModel
    @Environment(\.undoManager) private var undoManager
    /// The window's lines over the top of the page, which start under the
    /// scrubber as the stage does (`RootView`).
    @Environment(\.topLinesHeight) private var topLines

    public init(session: ShootSession, client: StudioClient, pump: ImagePump) {
        _model = State(wrappedValue: ViewerModel.shared(for: session,
                                                        navigation: LightTableRegistration.navigation))
    }

    public init(model: ViewerModel) {
        _model = State(wrappedValue: model)
    }

    public var body: some View {
        ZStack {
            table
            if model.fullImage {
                FullImageOverlay(model: model)
                    .transition(.opacity)
            }
        }
        .animation(Motion.fullImage, value: model.fullImage)
        // Every key pressed in this window, whatever has the keyboard: the one
        // path to the light table (§2.5.3).
        .background(LightTableKeySink(model: model))
        .sheet(item: Binding(get: { model.reasonNeedingConfirmation.map(ReasonBox.init) },
                             set: { model.reasonNeedingConfirmation = $0?.reason })) { box in
            ReasonOnKeptSheet(model: model, reason: box.reason)
        }
        // The model outlives the step: the undo stack is 200 deep, per shoot,
        // and is **not** cleared by changing step (§2.5.5).
        .toolbar { modePicker }
        // The Frame and View menus act on this light table while it is here.
        .onAppear { LightTableCommands.attach(model) }
        .onDisappear {
            LightTableCommands.detach(model)
            // A fault's frames are looked through from the report's link and
            // put down on the way out (§2.6): back by the sidebar or ⌘[, the
            // light table is the light table again, where K on a burst's last
            // frame goes on and N records it.
            model.stopLookingThrough()
        }
    }

    struct ReasonBox: Identifiable {
        let reason: DropReason
        var id: String { reason.rawValue }
        init(_ r: DropReason) { reason = r }
    }

    // MARK: - the bands

    private var table: some View {
        VStack(spacing: 0) {
            BurstScrubber(model: model)
            viewer
            ControlBar(model: model)
            Filmstrip(model: model, token: filmstripToken)
                .frame(height: Tokens.Metric.filmstrip)
                .background(.bar)
        }
        .background(Tokens.Palette.viewerBackground)
    }

    /// Changes whenever anything the strip draws changes.
    private var filmstripToken: Int {
        var h = Hasher()
        h.combine(model.burstIndex)
        h.combine(model.frameIndex)
        h.combine(model.session.undo.steps.count)
        h.combine(model.compareSelection)
        return h.finalize()
    }

    @ViewBuilder
    private var viewer: some View {
        GeometryReader { geo in
            ZStack {
                switch model.mode {
                case .compare:
                    CompareView(model: model)
                case .allBursts:
                    AllBurstsGrid(model: model)
                case .single, .review:
                    // 8 pt inset on every side, which is what makes the
                    // measured 51.4 % of §2.5.1 the number it is. Full Image
                    // has no inset at all.
                    //
                    // It stays built under Full Image, keeping its picture, so
                    // Full Image fades in over the photograph and back out to
                    // it; while it is covered it measures, loads and reports
                    // nothing (`StageLayerView.inCharge`), and on the way back
                    // it takes the keyboard again, so the arrows and Space work
                    // without a click.
                    StageView(model: model)
                        .padding(Tokens.Metric.viewerInset)
                        .offset(x: bumpOffset)
                        .opacity(flash ? 0.8 : 1)
                        .onChange(of: model.bump) { _, _ in rubberBand() }
                }

                // The sharpening indicator sits in a corner, never over the
                // photograph and never as a spinner.
                if model.sharpening {
                    VStack {
                        HStack {
                            Spacer()
                            Text(Strings.LightTable.sharpening)
                                .font(.footnote)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .viewerChip(Capsule())
                                .padding(Tokens.Metric.relatedGap)
                        }
                        Spacer()
                    }
                }

                // These three belong to the single-frame stage. Compare and
                // All Bursts carry their own words and nothing of the stage's
                // is drawn over them.
                if model.mode != .compare && model.mode != .allBursts {
                    VStack(spacing: Tokens.Metric.labelValueGap) {
                        // Where he left off, in the engine's own sentence
                        // (§2.5.13). It goes on his first press.
                        if let note = model.resumeNote {
                            Text(note)
                                .font(.callout)
                                .padding(.horizontal, Tokens.Metric.relatedGap + 2)
                                .padding(.vertical, 5)
                                .viewerChip()
                                .fixedSize()
                                // Under the restart line and the card's line
                                // when they are up, not behind them: a sliver
                                // of its edge showed under the one, and the
                                // two together hid it.
                                .padding(.top, Tokens.Metric.relatedGap + topLines)
                                .transition(.opacity)
                        } else if let line = model.lookingThroughLine {
                            // The frames a fault in the report covers (§2.6):
                            // which fault, where he is among them, and the
                            // way out — up where the resume note stands, so
                            // it never stacks over the feet with the notices.
                            HStack(spacing: Tokens.Metric.relatedGap) {
                                Text(line).font(.callout)
                                Button(Strings.LightTable.stopLookingThrough) { model.stopLookingThrough() }
                                    .buttonStyle(.link)
                                    .font(.callout)
                            }
                            .padding(.horizontal, Tokens.Metric.relatedGap + 2)
                            .padding(.vertical, 5)
                            .viewerChip()
                            .fixedSize()
                            .padding(.top, Tokens.Metric.relatedGap)
                            .accessibilityElement(children: .combine)
                        }
                        Spacer()
                        // One notice at a time over the photograph, the
                        // most pressing (`ViewerNotice`, §2.5.2).
                        ViewerNotices(model: model) { line in endOfBurst(line) }
                    }
                    .padding(.bottom, Tokens.Metric.relatedGap)
                }
            }
            // `model.viewport` is written by `StageLayerView` alone, which
            // measures the box it actually draws into. This used to write it
            // here as well, from the GeometryReader — the same rect plus the
            // viewer's 8 pt inset on each side — so during a resize every
            // layout pass wrote two values 16 pt apart, and `zoom.percent`,
            // the zoom label and the tier choice were all invalidated twice
            // and could disagree about which `/full` to ask for.
            .onAppear { applyInspectorDefault(contentWidth: geo.size.width) }
            .onChange(of: geo.size) { _, new in applyInspectorDefault(contentWidth: new.width) }
            // §2.1: the sidebar auto-hides on entering Choose Keepers when the
            // window is narrower than 1280 pt, and comes back on leaving for a
            // page that does not do the same. The picture is the app, and
            // 256 pt of it is a lot of photograph at 1100. ⌃⌘S overrides and
            // the override sticks for that window width. The widths are the
            // page's own as SwiftUI just laid it out, never NSApp's idea of
            // which window is in front: see `putsTheSidebarAway(_:in:)`.
            .putsTheSidebarAway(model.navigation, in: geo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// §2.5.1: the inspector opens by itself on a portrait burst, but only in
    /// a window wide enough that the 280 pt it costs comes out of slack rather
    /// than out of the control bar — and never over his own ⌥⌘I, which pins
    /// the choice (`Navigation.inspectorIsHisChoice`).
    private func applyInspectorDefault(contentWidth: CGFloat) {
        // The content column is what the light table was handed plus whatever
        // the inspector is already taking, so the answer does not depend on
        // the answer.
        let whole = contentWidth + (model.navigation.inspectorShown ? Tokens.Metric.inspector : 0)
        model.navigation.setInspectorByDefault(
            LightTableGeometry.inspectorOpensByDefault(aspect: model.shootAspect, contentWidth: whole))
    }

    /// → on the last frame of a burst: an 8 pt rubber-band bounce, or a static
    /// flash under Reduce Motion. No wrap, no burst change.
    @State private var bumpOffset: CGFloat = 0
    @State private var flash = false

    private func rubberBand() {
        guard !Motion.reduced else {
            // Under Reduce Motion the bounce becomes a static flash.
            flash = true
            Task { try? await Task.sleep(for: .milliseconds(120)); flash = false }
            return
        }
        withAnimation(.easeOut(duration: Motion.rubberBandDuration / 2)) {
            bumpOffset = -Motion.rubberBand
        }
        Task {
            try? await Task.sleep(for: .seconds(Motion.rubberBandDuration / 2))
            withAnimation(.easeIn(duration: Motion.rubberBandDuration / 2)) { bumpOffset = 0 }
        }
    }

    @ViewBuilder
    private func endOfBurst(_ line: String) -> some View {
        HStack(spacing: Tokens.Metric.relatedGap) {
            Text(line).font(.callout).fixedSize()
            if model.isLastBurst {
                // Records the last burst as been through, as N would, then
                // goes on (§2.5.13). It used to only go on, so Presets counted
                // the last burst's picks as not looked through and the next
                // launch reopened on it.
                Button(Strings.LightTable.continueToPresets) {
                    Task { await model.continueToPresets() }
                }
                .buttonStyle(.link)
                // The sentence no longer names its key, so the tag does: N
                // and ⌘] are Continue here, and record the burst as Continue
                // does.
                .help(Strings.LightTable.withKey(Strings.LightTable.continueToPresets,
                                                 LightTableKeys.keys(CommandTable.ID.finishBurst,
                                                                     CommandTable.ID.nextStep)))
                .fixedSize()
            } else if let i = model.unmarkedLink {
                Button(Strings.LightTable.goToUnmarked(model.tally.toGo)) { model.goToFrame(i) }
                    .buttonStyle(.link)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Tokens.Metric.relatedGap + 2)
        .padding(.vertical, 5)
        .viewerChip()
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    // MARK: - the toolbar's one addition (§2.3)

    @ToolbarContentBuilder
    private var modePicker: some ToolbarContent {
        // A view of its own, so a press that only moves the frame re-reads
        // the picker and not the whole toolbar. It still reads whether
        // Compare has anything to open, which the frame he is on decides.
        ToolbarItem(placement: .principal) { ModePicker(model: model) }
    }
}

/// Single · Compare · All Bursts, in the toolbar (§2.3).
struct ModePicker: View {
    let model: ViewerModel
    /// Read below so a click the model turns down is drawn as turned down.
    /// Compare with nothing to compare changes nothing the picker reads, so
    /// the segment used to stay lit on Compare with one frame still on the
    /// table: `.disabled` on one segment of a segmented picker never reaches
    /// the control, and the click goes through regardless.
    @State private var resync = 0

    var body: some View {
        let _ = resync
        Picker(Strings.LightTable.viewModes, selection: Binding(get: { value }, set: { set($0) })) {
            // Each segment is an icon with no word, so its help tag is its
            // only name, and it names the key. The whole picker used to carry
            // one tag, "Single", over all three.
            // Esc is the way back to one frame from Compare and All Bursts
            // alike; S is the previous frame, or cover, in every view
            // (§2.5.3).
            Label(Strings.LightTable.single, systemImage: Symbols.single).tag(0)
                .help(Strings.LightTable.modeHelp(Strings.LightTable.single, key: "⎋"))
            Label(Strings.LightTable.compare, systemImage: Symbols.compare).tag(1)
                .help(model.canCompare ? Strings.LightTable.modeHelp(Strings.LightTable.compare, key: "C")
                                       : Strings.LightTable.compareNothingHere)
            Label(Strings.LightTable.allBursts, systemImage: Symbols.allBursts).tag(2)
                .help(Strings.LightTable.modeHelp(Strings.LightTable.allBursts, key: "G"))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(Strings.LightTable.viewModes)
    }

    private var value: Int {
        switch model.mode {
        case .compare: return 1
        case .allBursts: return 2
        default: return 0
        }
    }

    private func set(_ v: Int) {
        switch v {
        case 1:
            // Nothing to open from here: it bounces, as C does, its help tag
            // says why, and the segment goes back to the mode he is in.
            if !model.canCompare { resync &+= 1 }
            model.perform(.compare)
        case 2: model.perform(.allBursts)
        default: model.perform(.single)
        }
        // The picker has taken first responder; the photograph takes it back,
        // so K, D and N are not dead until he clicks the picture (NAT-01).
        KeyFocus.restoreSoon(in: NSApp.keyWindow)
    }
}

/// Where the crew hands the shell its step. The integration crew calls this
/// once at launch; nothing in the shell names the light table.
@MainActor
public enum LightTableRegistration {
    /// The window's own `Navigation`, handed over once so "Continue to Presets"
    /// and the inspector's default state act on the window he is looking at.
    /// This is the crew's whole seam with the shell.
    public private(set) static var navigation: Navigation?

    public static func register(navigation: Navigation? = nil) {
        self.navigation = navigation
        StepRegistry.register("keepers") { session in
            AnyView(ChooseKeepersStep(session: session, client: session.client, pump: session.pump))
        }
        InspectorRegistry.register("keepers") { session in
            AnyView(FrameInspector(model: ViewerModel.shared(for: session, navigation: navigation)))
        }
    }
}
