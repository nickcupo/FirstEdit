import SwiftUI

/// The two-cell glyph: **this Mac**, then **iCloud**, in that fixed order,
/// always, with the engine's exact sentence beside it.
///
/// The engine chooses the pair. Nothing here works one out, and nothing here
/// reorders them — the order is the whole meaning, and a panel that sorted by
/// anything else would be saying something the engine did not.
///
/// Shape carries the meaning as well as fill, so Differentiate Without Color
/// and Increase Contrast lose nothing: filled square, hollow square, an empty
/// slot, a slashed square for gone.
public struct StateGlyph: View {
    public let cells: [StorageCell]
    public let words: String

    @Environment(\.accessibilityDifferentiateWithoutColor) private var noColour
    @Environment(\.colorSchemeContrast) private var contrast

    public init(cells: [StorageCell], words: String = "") {
        self.cells = cells
        self.words = words
    }

    public static let side: CGFloat = 13

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
                Cell(cell: cell, stroke: stroke)
                    .accessibilityHidden(true)
                    .help(i == 0 ? Strings.Storage.thisMac : Strings.Storage.iCloud)
            }
        }
        .frame(minWidth: Self.side * 2 + 3, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    /// Increase Contrast thickens the outline, the same way the verdict
    /// badges and the stack bracket do.
    private var stroke: CGFloat { contrast == .increased ? 2 : 1 }

    private var label: String {
        let here = cells.first ?? .none
        let up = cells.count > 1 ? cells[1] : .none
        let phrase = "\(Strings.Storage.thisMac): \(word(here)). \(Strings.Storage.iCloud): \(word(up))."
        return words.isEmpty ? phrase : "\(phrase) \(words)"
    }

    private func word(_ c: StorageCell) -> String {
        switch c {
        case .full: return Strings.StorageGlyph.full
        case .hollow: return Strings.StorageGlyph.hollow
        case .none: return Strings.StorageGlyph.absent
        case .gone: return Strings.StorageGlyph.gone
        case .some: return Strings.StorageGlyph.some
        }
    }

    struct Cell: View {
        let cell: StorageCell
        let stroke: CGFloat

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            ZStack {
                switch cell {
                case .full:
                    shape.fill(.primary)
                case .hollow:
                    shape.strokeBorder(.primary, lineWidth: stroke)
                case .some:
                    // Half of them: a square filled to the waterline.
                    shape.strokeBorder(.primary, lineWidth: stroke)
                    GeometryReader { g in
                        shape.fill(.primary)
                            .frame(height: g.size.height / 2)
                            .offset(y: g.size.height / 2)
                            .clipShape(shape)
                    }
                case .none:
                    shape.strokeBorder(.quaternary, style: StrokeStyle(lineWidth: stroke, dash: [2, 2]))
                case .gone:
                    shape.strokeBorder(Tokens.Palette.alarm, lineWidth: stroke)
                    Path { p in
                        p.move(to: CGPoint(x: 2, y: StateGlyph.side - 2))
                        p.addLine(to: CGPoint(x: StateGlyph.side - 2, y: 2))
                    }
                    .stroke(Tokens.Palette.alarm, lineWidth: stroke)
                }
            }
            .frame(width: StateGlyph.side, height: StateGlyph.side)
        }
    }
}

/// One state of the panel: its glyph pair, its count and the engine's words.
public struct StateRow: View {
    public let count: Int
    public let cells: [StorageCell]
    public let words: String

    public init(count: Int, cells: [StorageCell], words: String) {
        self.count = count; self.cells = cells; self.words = words
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.relatedGap) {
            StateGlyph(cells: cells, words: words)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text("\(count)")
                .countStyle()
                .frame(minWidth: 40, alignment: .trailing)
            Text(words)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

extension Strings {
    /// What a glyph means, said out loud. VoiceOver reads these; nothing
    /// draws them.
    public enum StorageGlyph {
        private static func s(_ key: String, _ value: String, _ comment: String) -> String {
            Bundle.main.localizedString(forKey: key, value: value, table: nil)
        }
        public static var full: String { s("glyph.full", "there, with its bytes", "A filled cell.") }
        public static var hollow: String { s("glyph.hollow", "there, but its bytes are not", "A hollow cell.") }
        public static var absent: String { s("glyph.absent", "not there", "An empty cell.") }
        public static var gone: String { s("glyph.gone", "recorded there and not found", "A crossed cell.") }
        public static var some: String { s("glyph.some", "some of them", "A half-filled cell.") }
    }
}
