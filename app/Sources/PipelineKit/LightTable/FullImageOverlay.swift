import SwiftUI
import AppKit

/// Space (§2.5.7). *"being able to see a full image for certain situations"* —
/// the second thing he said was wrong, and there is nothing like it today.
///
/// The toolbar, the scrubber, the control bar, the filmstrip and the sidebar
/// all go, and the picture fills the window: **94 % of it** at 1100 × 780
/// against 30.1 % on the stage today. Every key still works and K and D still
/// auto-advance, so a whole burst can be judged in here.
///
/// Moving the pointer brings a HUD up from the bottom for two seconds carrying
/// the same cluster — the same controls in the same order, because the two
/// verdict buttons are in the same place on every screen, in every mode.
///
/// A refused K or D is said here, over the photograph's bottom edge, whether
/// or not the HUD is up: the light table's notices are under this opaque
/// overlay, so a refusal in Full Image was never shown at all.
public struct FullImageOverlay: View {
    @Bindable var model: ViewerModel
    /// When the HUD goes again, and whether it is up. A pointer move pushes
    /// the first out; one sleeping task takes the second down.
    @State private var hudUntil = Date.distantPast
    @State private var hudVisible = false

    /// `hudUntil` is for the snapshot harness, which holds the HUD up to
    /// draw it; the app always starts with it down.
    public init(model: ViewerModel, hudUntil: Date = .distantPast) {
        self.model = model
        _hudUntil = State(initialValue: hudUntil)
        _hudVisible = State(initialValue: hudUntil > Date())
    }

    public var body: some View {
        ZStack {
            Tokens.Palette.fullImageBackground
                .ignoresSafeArea()

            // Its own stage over the light table's, which keeps its picture
            // underneath and waits while it is covered
            // (`StageLayerView.inCharge`). A click on the margin round the
            // picture returns to the same frame, the same zoom and the same
            // filmstrip scroll; the stage takes that click, because it fills
            // the window.
            StageView(model: model, role: .fullImage)
                .ignoresSafeArea()

            VStack(spacing: Tokens.Metric.relatedGap) {
                Spacer()
                // A refusal about the frame on screen always; one left
                // standing from a frame he has moved on from only with the
                // HUD, where the bar it concerns is.
                if showsRefusal {
                    VerdictRefusal(model: model)
                }
                // The strip after D, as on the table. D moves on here too,
                // and a digit pressed while the strip is up goes to the
                // frame it names; with no strip drawn here the same D then 4
                // meant the frame he dropped on the table and the next one
                // in Full Image.
                ReasonStrip(model: model)
                    .padding(.bottom, hudVisible ? 0 : Tokens.Metric.windowMargin)
                if hudVisible {
                    hud
                        // Under Reduce Motion it fades; it does not slide (§2.14).
                        .transition(Motion.reduced ? .opacity
                                                   : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, Tokens.Metric.windowMargin)
            .animation(Motion.fullImage, value: hudVisible)
        }
        // A pointer move keeps the HUD up for two seconds. Every move used to
        // write the time, and a timer re-drew the overlay — and with it the
        // stage — four times a second for as long as Full Image was up; now a
        // move writes only when the time is nearly spent, and nothing runs
        // while the pointer is still.
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            let now = Date()
            if !hudVisible || hudUntil.timeIntervalSince(now) < 1.5 {
                hudUntil = now.addingTimeInterval(2)
                if !hudVisible { hudVisible = true }
            }
        }
        .task(id: hudUntil) {
            let wait = hudUntil.timeIntervalSinceNow
            guard wait > 0 else { return }
            try? await Task.sleep(for: .seconds(wait))
            if !Task.isCancelled { hudVisible = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.LightTable.fullImage)
    }

    private var showsRefusal: Bool {
        model.session.refusals[.verdict] != nil && (hudVisible || ViewerNotice.refusalIsHere(model))
    }

    /// The same cluster, on glass. Identical geometry to the bar, so nothing he
    /// has learned moves by one point between the two modes. The caption is
    /// the pill's alone: the bar's copy here has none of its own.
    private var hud: some View {
        VStack(spacing: 2) {
            // Its own opaque pill: the HUD is glass, and a frame number in
            // glass over a bright sky is a number he cannot read.
            HStack(spacing: 8) {
                Text(model.frameCaption)
                if model.showsSuggestion { CullSuggestionBadge() }
            }
                .font(.callout)
                .padding(.horizontal, Tokens.Metric.relatedGap)
                .padding(.vertical, 2)
                .viewerChip(Capsule())
            ControlBar(model: model, inHUD: true)
                .frame(width: ControlBarLayout.width + Tokens.Metric.windowMargin * 2)
        }
        .padding(.vertical, Tokens.Metric.relatedGap)
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// The three-second strip after D (§2.5.3, §2.13).
///
/// It blocks nothing: the next frame is already up and K, D and N all work
/// through it. Six reasons, all of them nameable faults — "just no" is gone,
/// because a reason that is taste and not a fault trains the cull on nothing.
/// A frame he simply does not like is Dropped with no reason, which was always
/// expressible.
public struct ReasonStrip: View {
    @Bindable var model: ViewerModel
    @State private var now = Date()

    public init(model: ViewerModel) { self.model = model }

    private var showing: Bool {
        guard let until = model.reasonStripUntil, model.reasonStripStem != nil else { return false }
        return now < until
    }

    public var body: some View {
        Group {
            if showing, let stem = model.reasonStripStem {
                // It names the frame D put out, because D has already moved
                // him on: a reason pressed now goes to that frame, not to the
                // one on screen. Each button is the key and its word together.
                HStack(spacing: Tokens.Metric.relatedGap) {
                    Text(Strings.LightTable.reasonPromptFor(ShootSession.shortStem(stem)))
                        .font(.footnote)
                        .lineLimit(1)
                        .help(Strings.LightTable.reasonOptional)
                    ForEach(DropReason.allCases, id: \.self) { r in
                        Button(Strings.LightTable.reasonButton(r.key, r.word)) { model.perform(.reason(r.key)) }
                            .buttonStyle(.borderless)
                            .font(.footnote)
                            .fixedSize()
                            .accessibilityLabel(r.word)
                    }
                }
                .padding(.horizontal, Tokens.Metric.relatedGap + 2)
                .padding(.vertical, 5)
                .viewerChip()
                .transition(.opacity)
            }
        }
        .animation(Motion.badge, value: showing)
        .task(id: model.reasonStripUntil) {
            guard model.reasonStripUntil != nil else { return }
            while !Task.isCancelled && showing {
                try? await Task.sleep(for: .milliseconds(200))
                now = Date()
            }
            now = Date()
        }
        .accessibilityElement(children: .contain)
    }
}

/// A reason pressed on a frame he kept asks first — a reason implies out, and
/// putting out something he kept is not something to do silently.
///
/// **The same digit again puts it out** (§2.5.3). He pressed 4 on purpose to
/// change his mind about a kept frame; Put It Out had no key, so doing what
/// he had asked for took the mouse every time. Return and Esc still leave it
/// kept, so the answer a reflex gives is the safe one, and a digit held down
/// from the press that asked is not a second press.
public struct ReasonOnKeptSheet: View {
    @Bindable var model: ViewerModel
    let reason: DropReason

    public init(model: ViewerModel, reason: DropReason) {
        self.model = model
        self.reason = reason
    }

    /// The reason's own digit, which answers Put It Out.
    var key: KeyEquivalent { KeyEquivalent(Character(String(reason.key))) }

    /// Whether the press that fired Put It Out is his answer: a click, or a
    /// fresh press of the digit. The repeat of the digit that raised the
    /// question, still held, reaches this sheet once it is in front, and is
    /// not an answer (§2.5.3, a held key counts once).
    static func isAnAnswer(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return true }
        return !event.isARepeat
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.groupGap) {
            Text(Strings.LightTable.reasonOnKeptTitle).font(.headline)
            Text(Strings.LightTable.reasonOnKeptBody(reason.word)).font(.body)
            Text(Strings.LightTable.reasonOnKeptAgain(reason.key))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(Strings.LightTable.putItOut) {
                    guard Self.isAnAnswer(model.currentEvent()) else { return }
                    Task { await model.confirmReason(reason) }
                }
                .keyboardShortcut(key, modifiers: [])
                .help(Strings.LightTable.withKey(Strings.LightTable.putItOut, String(reason.key)))
                Button(Strings.LightTable.leaveItKept) {
                    model.reasonNeedingConfirmation = nil
                }
                .keyboardShortcut(.defaultAction)
            }
            // Esc answers "Leave It Kept" too. Return already did; Esc did
            // nothing, and putting a kept frame out was the only thing the
            // keyboard could reach here besides the default.
            .background {
                Button("") { model.reasonNeedingConfirmation = nil }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
        .padding(Tokens.Metric.windowMargin)
        .frame(width: 420)
    }
}
