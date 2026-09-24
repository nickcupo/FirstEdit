import SwiftUI

/// What this frame is, in the trailing inspector (⌥⌘I). It reads; it does
/// not decide — the verdicts are the bar's, the keys' and the menu's.
///
/// Two sections that never merge: **what you decided** and **what the cull
/// said**. They carry different shapes, different words and different colours,
/// and no number in one is added to a number in the other. The one figure that
/// combines them anywhere in the app is labelled for what it decides — "will
/// get a preset" — and it is not on this panel.
public struct FrameInspector: View {
    @Bindable var model: ViewerModel

    public init(model: ViewerModel) { self.model = model }

    public var body: some View {
        Group {
            if let stem = model.currentStem, let row = model.session.rows[stem] {
                Form {
                    yours(row, stem: stem)
                    theCull(row)
                    theFrame(row)
                }
                .formStyle(.grouped)
            } else {
                Text(Strings.Shell.nothingToShow)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - his

    @ViewBuilder
    private func yours(_ row: Row, stem: String) -> some View {
        Section(Strings.LightTable.yourCall) {
            LabeledContent(Strings.LightTable.position(model.frameIndex + 1, model.frames.count)) {
                Text(ShootSession.shortStem(stem)).font(.frameNumber)
            }
            HStack {
                Image(systemName: hisSymbol(row))
                    .foregroundStyle(hisColour(row))
                Text(model.hisLine)
            }
            if !row.label.isEmpty {
                LabeledContent(Strings.LightTable.reasonLabel) {
                    Text(DropReason(rawValue: row.label)?.word ?? row.label)
                }
            }
            // No Keep, Drop or Clear the Mark here (§2.5.1). They were three
            // plain buttons side by side, 8 pt apart, uncoloured and with no
            // key shown — the very adjacency the bar was built to avoid — and
            // every one of them is already the bar's, the keys' and the
            // right-click menu's. The inspector says what was decided; it is
            // not a second place to decide it.
        }
    }

    private func hisSymbol(_ row: Row) -> String {
        switch VerdictValue.his(row) {
        case .kept: return Symbols.hisKeep
        case .out: return Symbols.hisDrop
        case .unmarked: return (model.currentBurst?.seen ?? false) ? Symbols.agreed : Symbols.cullAside
        }
    }

    private func hisColour(_ row: Row) -> Color {
        switch VerdictValue.his(row) {
        case .kept: return Tokens.Palette.kept
        case .out: return Tokens.Palette.out
        case .unmarked: return .secondary
        }
    }

    // MARK: - the machine's

    @ViewBuilder
    private func theCull(_ row: Row) -> some View {
        Section(Strings.LightTable.theCull) {
            Text(model.cullLine)
                .foregroundStyle(Tokens.Palette.machine)
            if let focus = row.focus {
                // "161 · most in this burst near 140": the figure means
                // nothing alone, and its hover used to set it against the
                // focus setting of the next cull, 1.9, as "near 1".
                LabeledContent(Strings.LightTable.focusLabel) {
                    Group {
                        if let typical = Sharpness.typical(model.frames, rows: model.session.rows) {
                            Text(Strings.LightTable.focusAgainstTypical(Int(focus), Int(typical.rounded())))
                        } else {
                            Text("\(Int(focus))")
                        }
                    }
                    .countStyle()
                    .foregroundStyle(Tokens.Palette.machine)
                }
            }
            if let stack = model.currentStack {
                LabeledContent(Strings.LightTable.similar(stack.count)) {
                    Button(Strings.LightTable.compare) { model.perform(.compare) }
                        .buttonStyle(.link)
                }
                .help(Strings.LightTable.similarHelp)
            }
        }
    }

    // MARK: - the frame itself

    @ViewBuilder
    private func theFrame(_ row: Row) -> some View {
        Section(Strings.LightTable.thisFrame) {
            if let w = row.dw, let h = row.dh {
                // Pixel counts, not quantities: 6024, never 6,024.
                LabeledContent(Strings.LightTable.size) {
                    Text(verbatim: "\(w) × \(h)").countStyle()
                }
            }
            if let at = row.shot_at, !at.isEmpty {
                LabeledContent(Strings.LightTable.takenAt) { Text(verbatim: Self.readable(at)) }
            }
        }
    }

    /// EXIF writes `2026:09:13 16:34:09`. He reads dates the way the rest of
    /// his Mac writes them; a frame that will not parse is printed as it came,
    /// because a wrong date is worse than an ugly one.
    static func readable(_ exif: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        parser.timeZone = .current
        guard let date = parser.date(from: exif) else { return exif }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
