import SwiftUI

/// A line about a card, over the top of the page (DESIGN.md §2.6): "Untitled
/// is in. ⌘N to copy it." when a card goes in with the sidebar hidden, or how
/// a copy ended when he is on another page.
///
/// It floats over the page, the way the stack invitation sits on the
/// photograph and in the same opaque chip (`viewerChip`, not glass: a
/// translucent line over a bright frame is one he cannot read), rather than
/// taking a band of the window: the band pushed the light table down and in
/// while he was keeping and dropping. It goes by itself (`ImportModel`), and
/// clicking it opens the card's page.
struct CardNotice: View {
    let notice: ImportModel.Notice
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Label {
                Text(notice.line)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: Symbols.memoryCard).foregroundStyle(.secondary)
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.horizontal, Tokens.Metric.relatedGap + 6)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .viewerChip(Capsule())
        .frame(maxWidth: 560)
        .help(Strings.Import.openTheCard)
        .accessibilityHint(Strings.Import.openTheCard)
    }
}
