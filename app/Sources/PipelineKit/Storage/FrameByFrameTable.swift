import SwiftUI

/// Every original, one by one — a lazy fold, fetched only on the first open.
///
/// 1,157 rows are never built for a panel nobody has unfolded, which is the
/// engine's own reason for serving this on its own route.
struct FrameByFrameTable: View {
    let model: StorageModel
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            content
        } label: {
            Text(Strings.Storage.frameByFrame)
        }
        .onChange(of: open) { _, nowOpen in
            if nowOpen { Task { await model.loadFrames() } }
        }
        .accessibilityIdentifier("storage.frameByFrame")
    }

    @ViewBuilder private var content: some View {
        if let rows = model.frames {
            Table(rows) {
                TableColumn(Strings.Storage.frame) { r in
                    Text(r.name).font(.frameNumber)
                }
                TableColumn(Strings.Storage.size) { r in
                    Text(r.bytes_text).countStyle()
                }
                .width(min: 70, ideal: 80, max: 110)
                TableColumn(Strings.Storage.whereItIs) { r in
                    HStack(spacing: Tokens.Metric.relatedGap) {
                        StateGlyph(cells: r.cells, words: r.words)
                        Text(r.words).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(minHeight: 180, idealHeight: 260)
        } else if model.loadingFrames {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tokens.Metric.groupGap)
        } else {
            Color.clear.frame(height: 1)
        }
    }
}
