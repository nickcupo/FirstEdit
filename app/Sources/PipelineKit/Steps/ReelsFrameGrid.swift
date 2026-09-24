import SwiftUI
import AppKit

/// Every frame of the chosen burst, in shutter order.
///
/// A frame taken out is scrimmed, grey and says Out; a frame not yet exported
/// is drawn as it is, with a small badge when the burst is only partly
/// exported — the two are different facts and must never look alike.
///
/// A single click ticks a frame in or out of the reel — the checkbox in the
/// tile's corner says which — and a shift-click ticks every frame from the
/// last one to it the same way. From the keys it is Choose Keepers' cull: E
/// puts the frame in and D leaves it out, each moving on, and X puts it
/// back; I and O set where the reel starts and ends.
/// Double-click, Space or a firm click opens it large (DESIGN.md §2.6,
/// FLOW-01). A frame not yet exported is never hidden, because a gap in the
/// middle of a burst is the reason a reel comes out short and he can only fix
/// what he can see.
struct ReelsFrameGrid: View {
    @Bindable var model: ReelsModel
    let thumbs: ReelThumbs
    /// The page's scroll view, so the tile the keys move to is brought into
    /// sight rather than left below the fold.
    var scroll: ScrollViewProxy?
    /// The page's keyboard. The frames take it when the page comes on screen,
    /// when a burst is clicked in the list and when a key acts on a frame
    /// (ReelsStep), so ↑ and ↓ are a row of them without first clicking a
    /// tile — which ticked it. The ring is drawn only while they have it.
    var focus: FocusState<ReelsFocus?>.Binding

    private var focused: Bool { focus.wrappedValue == .grid }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
            // Nothing beside the note comes and goes: a button that appeared
            // at the first frame taken out wrapped it to two lines and moved
            // every tile down under the pointer (Put Them All Back is in the
            // summary now, always laid out). With no frames there is nothing
            // for it to be about.
            if !model.frames.isEmpty || model.framesComing > 0 {
                StepNote(Strings.Reels.gridNote)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: ReelsMetric.tile), spacing: Tokens.Metric.relatedGap)],
                      spacing: Tokens.Metric.relatedGap) {
                let badges = model.badgesExports
                ForEach(model.frames) { f in
                    ReelTile(frame: f, isIn: model.isIn(f.stem), isCursor: focused && model.cursor == f.stem,
                             badgesExport: badges,
                             shoot: model.session.name, src: model.source.isEmpty ? nil : model.source,
                             thumbs: thumbs,
                             toggle: { model.toggle(f.stem); focus.wrappedValue = .grid },
                             run: { model.toggleRun(to: f.stem); focus.wrappedValue = .grid },
                             open: { model.openLarge(f.stem) },
                             startHere: { model.startHere(f.stem) },
                             endHere: { model.endHere(f.stem) })
                    .id(f.stem)
                }
                // The burst's frames while the lister is asked about them:
                // their places, so the grid does not empty and spring back.
                if model.frames.isEmpty {
                    ForEach(0..<model.framesComing, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Tokens.Palette.viewerBackground)
                            .aspectRatio(3.0 / 2.0, contentMode: .fit)
                            .accessibilityHidden(true)
                    }
                }
            }
            .background {
                GeometryReader { g in
                    Color.clear.onAppear { model.columns = Self.columns(in: g.size.width) }
                        .onChange(of: g.size.width) { _, w in model.columns = Self.columns(in: w) }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused(focus, equals: .grid)
            // Every key reaches the page through one table, Keepers'
            // (`ReelsKeys`), from anywhere in the window (`ReelsKeySink`):
            // S F and the arrows move, E in, D out, X back in, R and W the
            // next and previous burst, Space large, Q undo — and I and O, the
            // page's own, where the reel starts and ends. The grid holds the
            // keyboard only so ↑ and ↓ are a row of it rather than the list's.
            .onChange(of: model.keysTaken) { reveal() }
        }
    }

    private func reveal() {
        guard let c = model.cursor else { return }
        scroll?.scrollTo(c)
    }

    /// How many tiles a row holds, the way `.adaptive` lays them out.
    static func columns(in width: CGFloat) -> Int {
        let gap = Tokens.Metric.relatedGap
        return max(1, Int((width + gap) / (ReelsMetric.tile + gap)))
    }
}

/// One frame: the picture, the checkbox in its corner, its number, and — when
/// it has not been through PhotoLab and that tells him something — a badge
/// saying so.
struct ReelTile: View {
    let frame: ReelFrame
    let isIn: Bool
    let isCursor: Bool
    /// Whether "Not exported" is worth a badge on this burst: only when some
    /// of it is and some is not. All or none, the draft line says it once.
    var badgesExport = true
    let shoot: String
    let src: String?
    let thumbs: ReelThumbs
    let toggle: () -> Void
    let run: () -> Void
    let open: () -> Void
    let startHere: () -> Void
    let endHere: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack(alignment: .topLeading) {
            Group {
                if frame.visible {
                    ReelThumbView(thumbs: thumbs, shoot: shoot, stem: frame.stem, src: src,
                                  version: frame.exported ? "exported" : "")
                } else {
                    ZStack {
                        Tokens.Palette.viewerBackground
                        Text(Strings.Reels.noPicture).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(3.0 / 2.0, contentMode: .fit)
            // Out of the reel reads as out at a glance: grey under a scrim.
            // Not exported is not dimmed at all. Both were drawn by dimming
            // (35 % and 62 %), so a burst mostly not exported looked as if he
            // had taken every frame out.
            .saturation(isIn ? 1 : 0)
            .overlay { if !isIn && frame.visible { Color.black.opacity(0.55) } }

            Image(systemName: isIn ? "checkmark.square.fill" : "square")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(isIn ? Color.white : Color.white.opacity(0.9),
                                 isIn ? Tokens.Palette.kept : Color.black.opacity(0.35))
                .shadow(color: .black.opacity(0.5), radius: 1.5)
                .padding(6)
                .opacity(frame.visible ? 1 : 0)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) { caption }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(isCursor ? Color.accentColor : Color.primary.opacity(0.12),
                               lineWidth: isCursor ? 2.5 : 0.5)
        }
        .overlay { TileClicks(toggle: toggle, run: run, open: open) }
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(isIn ? Strings.Reels.inReel : Strings.Reels.leftOut))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isIn ? .isSelected : [])
        .accessibilityAction { toggle() }
        .accessibilityAction(named: Text(Strings.Reels.openLarge)) { open() }
        .accessibilityAction(named: Text(Strings.Reels.startHere)) { startHere() }
        .accessibilityAction(named: Text(Strings.Reels.endHere)) { endHere() }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.45), in: Capsule())
    }

    private var label: String {
        var parts = [ShootSession.shortStem(frame.stem)]
        if !frame.visible { parts.append(Strings.Reels.noPicture) } else if !frame.exported { parts.append(Strings.Reels.notExported) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var caption: some View {
        HStack(spacing: 4) {
            Text(ShootSession.shortStem(frame.stem))
                .font(.frameNumber)
            Spacer(minLength: 2)
            if frame.visible && !isIn {
                badge(Strings.Reels.outBadge)
            } else if frame.visible && !frame.exported && badgesExport {
                badge(Strings.Reels.notExported)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 1)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
    }
}

/// The tile's clicks, read from AppKit so each one does its own thing at once.
///
/// SwiftUI's two tap gestures would hold every single click back until the
/// double-click interval had passed, and he ticks frames far more often than
/// he opens them. So the first click acts at once; if it turns out to be the
/// first half of a double-click, or the start of a firm click, the second
/// half undoes it and opens the frame instead. The tick he sees is always the
/// one that stays.
struct TileClicks: NSViewRepresentable {
    let toggle: () -> Void
    let run: () -> Void
    let open: () -> Void

    func makeNSView(context: Context) -> ClickView {
        let v = ClickView()
        update(v)
        return v
    }

    func updateNSView(_ v: ClickView, context: Context) { update(v) }

    private func update(_ v: ClickView) {
        v.toggle = toggle
        v.run = run
        v.open = open
    }

    final class ClickView: NSView {
        var toggle: () -> Void = {}
        /// Shift-click: every frame from the last one clicked to this one.
        var run: () -> Void = {}
        var open: () -> Void = {}
        /// Whether this press has already opened the frame, so a firm click
        /// held down does not open it twice.
        private var opened = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            opened = false
            if event.modifierFlags.contains(.shift) {
                // A run is a decision, not a look: the second click of a
                // shift-double-click neither undoes it nor opens anything.
                if event.clickCount == 1 { run() }
                opened = true
                return
            }
            if event.clickCount >= 2 {
                // The first click of the pair already toggled; put it back.
                if event.clickCount == 2 { toggle() }
                opened = true
                open()
            } else {
                toggle()
            }
        }

        override func pressureChange(with event: NSEvent) {
            guard event.stage >= 2, !opened else { return }
            opened = true
            toggle()        // the click that began the firm press toggled
            open()
        }

        override func isAccessibilityElement() -> Bool { false }
    }
}
