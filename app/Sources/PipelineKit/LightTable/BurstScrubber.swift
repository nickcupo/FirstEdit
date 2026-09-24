import SwiftUI

/// Where he is in the shoot, and where he has been (§2.5.10).
///
/// 18 pt, under the toolbar, one segment per burst across the full width, with
/// a **minimum 8 pt per segment** and horizontal scrolling past that — today
/// each burst is a 5.94 pt target on his own 155-burst shoot (LT-10), which is
/// narrower than a pointer.
///
/// Click jumps there and **records nothing**. Only leaving a burst forward — R
/// or N, F or → off its last frame, Continue — marks it as looked through, so
/// the count can never be the machine's flattery of work he did not do
/// (§2.5.13, §7.4).
public struct BurstScrubber: View {
    @Bindable var model: ViewerModel
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.increaseContrastOverride) private var contrastOverride
    /// Increase Contrast, from the system unless the harness overrides it.
    private var increased: Bool { contrastOverride ?? (systemContrast == .increased) }
    /// A drag is scrubbing: the strip holds still under the pointer until it
    /// ends, or every burst the drag reached would scroll the next one under
    /// it and the drag would run away along the strip.
    @State private var dragging = false

    public init(model: ViewerModel) { self.model = model }

    public var body: some View {
        GeometryReader { geo in
            let bursts = model.bursts
            let current = model.burstIndex
            let ideal = bursts.isEmpty ? 0 : (geo.size.width - CGFloat(max(0, bursts.count - 1))) / CGFloat(bursts.count)
            let width = max(Tokens.Metric.scrubberMinSegment, ideal)
            let scrolls = width > ideal

            Group {
                if scrolls {
                    // **It keeps the burst he is on in view.** Past about
                    // burst 122 of his 288-burst night at the default window
                    // the current burst was off the right-hand end, with no
                    // scroll bar to say there was more: the one band that says
                    // where he is in the night said nothing for more than half
                    // of it. Centred on arrival; after that it scrolls only
                    // when the burst he is on would leave the strip, and only
                    // as far as it takes, with no animation, so a run of N
                    // does not make it swim and a segment he has just clicked
                    // stays under the pointer. Centring it on every change
                    // slid the clicked segment away the moment he let go.
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            strip(bursts, current: current, width: width)
                        }
                        .onAppear { reveal(current, in: bursts, proxy, anchor: .center) }
                        .onChange(of: current) { _, now in
                            if !dragging { reveal(now, in: bursts, proxy) }
                        }
                        .onChange(of: dragging) { _, now in
                            if !now { reveal(current, in: bursts, proxy) }
                        }
                    }
                } else {
                    strip(bursts, current: current, width: width)
                }
            }
            .frame(width: geo.size.width, height: Tokens.Metric.scrubber)
        }
        .frame(height: Tokens.Metric.scrubber)
        .background(.bar)
        // It reads as a slider, because that is what it is.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.LightTable.burstScrubber)
        .accessibilityValue(Strings.LightTable.scrubberValue(model.burstIndex + 1, model.bursts.count,
                                                             seen: model.currentBurst?.seen ?? false))
        .accessibilityAdjustableAction { direction in
            model.goToBurst(model.burstIndex + (direction == .increment ? 1 : -1))
        }
    }

    /// With no anchor the strip moves the least it can to show the segment,
    /// which for a segment already in view is not at all.
    private func reveal(_ index: Int, in bursts: [Burst], _ proxy: ScrollViewProxy, anchor: UnitPoint? = nil) {
        guard bursts.indices.contains(index) else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { proxy.scrollTo(bursts[index].id, anchor: anchor) }
    }

    /// The segments, as values. Everything a segment draws is in here and
    /// nothing else is, so a press that moves the frame and not the burst —
    /// most of the 1,500 a night — redraws none of them, and a change of burst
    /// redraws two. Each segment used to read the cursor itself, and the
    /// cursor is one observed value, so every arrow, K and D re-ran all 288
    /// segments with their help tags and menus: about 11 ms of main thread a
    /// press on his 288-burst night, most of what made the table feel slow.
    private func strip(_ bursts: [Burst], current: Int, width: CGFloat) -> some View {
        let model = model
        // His keepers as they stand now, by the tally's own rule, not the
        // count the engine sent when the shoot opened (`keptByHim`).
        return ScrubberStrip(segments: Self.segments(bursts, current: current, kept: { model.keptByHim(in: $0) }),
                             width: width, increased: increased,
                             unmark: { model.unmarkBurst(at: $0) },
                             scrub: { x in
                                 if !dragging { dragging = true }
                                 go(to: x, width: width)
                             },
                             ended: { dragging = false })
            .equatable()
    }

    static func segments(_ bursts: [Burst], current: Int,
                         kept: (Burst) -> Int = { $0.kept }) -> [ScrubberSegment.Value] {
        bursts.enumerated().map { i, b in
            ScrubberSegment.Value(id: b.id, index: i, frames: b.frames.count, kept: kept(b), seen: b.seen,
                                  isCurrent: i == current)
        }
    }

    private func go(to x: CGFloat, width: CGFloat) {
        let i = BurstScrubber.index(atX: x, width: width, count: model.bursts.count)
        if i != model.burstIndex { model.goToBurst(i) }
    }

    /// Which burst a point along the strip is over. The segments are `width`
    /// wide with 1 pt between them.
    static func index(atX x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let i = Int(x / max(1, width + 1))
        return min(count - 1, max(0, i))
    }
}

/// Every segment, and the one gesture over them. Equal whenever the bursts,
/// their states and the current one are, so a move inside a burst does not
/// even walk the list.
struct ScrubberStrip: View, Equatable {
    let segments: [ScrubberSegment.Value]
    let width: CGFloat
    let increased: Bool
    let unmark: (Int) -> Void
    let scrub: (CGFloat) -> Void
    let ended: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.segments == b.segments && a.width == b.width && a.increased == b.increased
    }

    /// The strip's own coordinate space, so the index is worked out against
    /// the segments themselves. The drag used to read `value.location.x` in
    /// the gesture's space and divide, which ignores the scroll offset — and
    /// past 137 bursts the strip is inside a horizontal `ScrollView`, so on
    /// his own 155-burst shoot the two disagreed by however far it was
    /// scrolled.
    private static let space = "burst-scrubber"

    var body: some View {
        HStack(spacing: 1) {
            ForEach(segments) { value in
                ScrubberSegment(value: value, width: width, increased: increased) { unmark(value.index) }
                    .equatable()
            }
        }
        .coordinateSpace(name: Self.space)
        // One gesture for the press and the drag together, so a click that
        // wobbles cannot be routed down a different path from one that does
        // not. A parent `DragGesture(minimumDistance: 2)` used to beat each
        // segment's `onTapGesture` the moment the pointer moved 2 pt during
        // the press, and then jumped to whichever burst the raw x landed on
        // rather than the one under the pointer.
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { scrub($0.location.x) }
            .onEnded { _ in ended() })
    }
}

/// One burst on the scrubber, drawn from its value alone.
struct ScrubberSegment: View, Equatable {
    struct Value: Equatable, Identifiable {
        let id: String
        let index: Int
        let frames: Int
        let kept: Int
        let seen: Bool
        let isCurrent: Bool
    }

    let value: Value
    let width: CGFloat
    let increased: Bool
    let unmark: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.value == b.value && a.width == b.width && a.increased == b.increased
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(value.seen ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.15))
            // His keepers, underlined in green. The machine never draws here.
            if value.kept > 0 {
                Rectangle()
                    .fill(Tokens.Palette.kept)
                    .frame(height: 3)
            }
            if value.isCurrent {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: increased ? 3 : 2)
            }
        }
        .frame(width: width, height: Tokens.Metric.scrubber)
        .contentShape(Rectangle())
        // The sentence the popover was carrying, in the place macOS puts a
        // sentence about the thing under the pointer (§2.5.10: the popover
        // ate the next click on the toolbar and asked for a cold RAW decode
        // per burst crossed).
        .help(Strings.LightTable.burstCaption(value.index + 1, frames: value.frames, kept: value.kept))
        // Any burst, at any time, which is the point: N marks a burst and
        // Undo reaches only the most recent one, so an N pressed by mistake
        // an hour ago had nothing that could take it back (DESIGN.md §7.4).
        // Offered only where there is something to take back.
        .contextMenu {
            if value.seen {
                Button(Strings.LightTable.unmarkBurst, action: unmark)
            }
        }
        // A drag is never the only way to reach it.
        .accessibilityActions {
            if value.seen {
                Button(Strings.LightTable.unmarkBurst, action: unmark)
            }
        }
    }
}
