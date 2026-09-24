import SwiftUI

/// G: the shoot at a glance (§2.5.11).
///
/// The same data as the scrubber, for when he wants to see rather than aim.
/// Covers are 180 × 120 with a 32 pt caption, four columns at 1100 and nine on
/// a 27". Bursts not been through are dimmed; the current one is ringed. ← →
/// move a burst at a time, ↑ ↓ a row, N jumps to the next burst not been
/// through, ⌘Z still undoes, and Return, G, S or Esc goes back to the burst
/// that is ringed. It opens scrolled to that burst — it used to open on burst
/// 1 whatever burst he was in, with his own 250 covers further down.
public struct AllBurstsGrid: View {
    @Bindable var model: ViewerModel
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.increaseContrastOverride) private var contrastOverride
    /// Increase Contrast, from the system unless the harness overrides it.
    private var increased: Bool { contrastOverride ?? (systemContrast == .increased) }

    public init(model: ViewerModel) { self.model = model }

    public var body: some View {
        GeometryReader { geo in
            let columns = LightTableGeometry.allBurstsColumns(width: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                                 spacing: Tokens.Metric.relatedGap * 2),
                                             count: columns),
                              spacing: Tokens.Metric.groupGap) {
                        ForEach(Array(model.bursts.enumerated()), id: \.element.id) { i, burst in
                            cover(burst, index: i)
                                .id(burst.id)
                        }
                    }
                    .padding(Tokens.Metric.windowMargin)
                }
                .onChange(of: model.burstIndex, initial: true) { _, _ in
                    if let id = model.currentBurst?.id { proxy.scrollTo(id, anchor: .center) }
                }
                // ↑ ↓ move a row, so the model has to know how wide one is.
                .onChange(of: columns, initial: true) { _, n in model.allBurstsColumns = n }
            }
        }
        .background(Tokens.Palette.viewerBackground)
        // The captions are written straight onto the surround, which keeps its
        // own grey whatever the app's appearance is: in Light they were dark
        // grey on #3A3A3A, 1.5 : 1.
        .onViewerSurround()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.LightTable.allBursts)
    }

    @ViewBuilder
    private func cover(_ burst: Burst, index: Int) -> some View {
        let isCurrent = index == model.burstIndex
        Button {
            model.goToBurst(index)
            model.leaveMode()
        } label: {
            VStack(spacing: Tokens.Metric.labelValueGap) {
                ZStack {
                    if let stem = burst.cover ?? burst.frames.first {
                        FrameImageView(shoot: model.session.name, stem: stem, fit: .fill,
                                       showing: .aThumbnail, pump: model.session.pump) { _, _ in }
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(height: Tokens.Metric.burstCover.height)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isCurrent ? Color.accentColor : Color.clear,
                                      lineWidth: increased ? 4 : 3)
                }
                // Not been through: dimmed, never hidden and never missing.
                .opacity(burst.seen || isCurrent ? 1 : 0.55)

                Text(Strings.LightTable.burstCaption(index + 1, frames: burst.frames.count,
                                                     kept: model.keptByHim(in: burst)))
                    .font(.footnote)
                    .countStyle()
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .frame(height: Tokens.Metric.burstCaption, alignment: .top)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Strings.LightTable.burstCaption(index + 1, frames: burst.frames.count,
                                                            kept: model.keptByHim(in: burst)))
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}
