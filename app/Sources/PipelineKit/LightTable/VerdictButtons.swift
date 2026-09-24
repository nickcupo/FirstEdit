import SwiftUI

/// Keep and Drop: the only two custom controls in the app (§2.2), and the two
/// he said were wrong.
///
/// They are the same size, the same shape and the same weight — 112 × 40, both
/// of them — and only the symbol, the word and the tint differ. Keep is on the
/// right, because affirmative is on the right. Keep is accent-tinted and
/// prominent; Drop is bordered with a red-tinted symbol and **not** a red fill,
/// because Drop is not destructive: it records that a frame is out and deletes
/// nothing. **Neither is the window's default button**, so Return does not
/// decide a photograph.
///
/// **Neither holds its key, either.** K and D reach the light table by one
/// path, `LightTableKeys`, which is where a held key is counted once; a bare
/// shortcut here took the key first and kept every frame a held K landed on.
/// The key is in the help tag instead.
public struct VerdictButton: View {
    public enum Kind { case keep, drop }

    let kind: Kind
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.increaseContrastOverride) private var contrastOverride
    /// Increase Contrast, from the system unless the harness overrides it.
    private var increased: Bool { contrastOverride ?? (systemContrast == .increased) }

    public init(_ kind: Kind, action: @escaping () -> Void) {
        self.kind = kind
        self.action = action
    }

    private var word: String { kind == .keep ? Strings.Verdict.keep : Strings.Verdict.drop }
    private var symbol: String { kind == .keep ? Symbols.keep : Symbols.drop }
    private var help: String {
        kind == .keep
            ? Strings.LightTable.withKey(Strings.Verdict.keep, LightTableKeys.key(CommandTable.ID.keep))
            : Strings.LightTable.withKey(Strings.Verdict.dropHelp, LightTableKeys.key(CommandTable.ID.drop))
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(kind == .drop ? AnyShapeStyle(Tokens.Palette.out) : AnyShapeStyle(.primary))
                Text(word)
                    .font(.body.weight(.semibold))
            }
            .frame(width: Tokens.Metric.verdictButton.width - 2,
                   height: Tokens.Metric.verdictButton.height - 2)
        }
        .buttonStyle(VerdictButtonStyle(kind: kind, increased: increased))
        .frame(width: Tokens.Metric.verdictButton.width, height: Tokens.Metric.verdictButton.height)
        .help(help)
        .accessibilityLabel(word)
        .accessibilityIdentifier("verdict.\(kind == .keep ? "keep" : "drop")")
    }
}

/// Glass on macOS 26, bordered before it, **at the same frame** — so nothing
/// reflows by OS version and the 160 pt between them is 160 pt everywhere.
struct VerdictButtonStyle: ButtonStyle {
    let kind: VerdictButton.Kind
    let increased: Bool
    /// A style draws its own disabled look or none at all: greyed in All
    /// Bursts, where there is no frame on screen to decide.
    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if kind == .keep {
                    shape.fill(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1))
                } else {
                    shape.fill(.quaternary.opacity(configuration.isPressed ? 0.7 : 0.45))
                }
            }
            .foregroundStyle(kind == .keep ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
            .overlay {
                shape.strokeBorder(kind == .keep ? Color.accentColor : Color.primary.opacity(0.35),
                                   lineWidth: increased ? 2 : 1)
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// The frame label, in the 160 pt of clear space between them.
///
/// It is the reason the two opposite controls are never adjacent: something
/// that names what is being decided sits between them. On a frame in a stack it
/// carries the "4 similar" badge as well.
///
/// And what he has already decided about this frame, in the filmstrip's own
/// marks — the filled green check or red cross, beside the position. Nothing on
/// the stage said so before: now that ← walks back across bursts he lands on
/// frames he has decided all the time, and a kept frame looked exactly like
/// one he had never touched.
public struct FrameLabel: View {
    let position: String
    let stackCount: Int?
    let his: VerdictValue.His
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.increaseContrastOverride) private var contrastOverride
    /// Increase Contrast, from the system unless the harness overrides it.
    private var increased: Bool { contrastOverride ?? (systemContrast == .increased) }

    public init(position: String, stackCount: Int?, his: VerdictValue.His = .unmarked) {
        self.position = position
        self.stackCount = stackCount
        self.his = his
    }

    public var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                switch his {
                case .kept:
                    Image(systemName: Symbols.hisKeep).foregroundStyle(Tokens.Palette.kept)
                        .accessibilityLabel(Strings.LightTable.youKept)
                case .out:
                    Image(systemName: Symbols.hisDrop).foregroundStyle(Tokens.Palette.out)
                        .accessibilityLabel(Strings.LightTable.youPutOut)
                case .unmarked:
                    EmptyView()
                }
                Text(position)
                    .countStyle()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .help(his == .kept ? Strings.LightTable.youKept
                  : his == .out ? Strings.LightTable.youPutOut : "")
            if let stackCount, stackCount > 1 {
                Text(Strings.LightTable.similar(stackCount))
                    .font(.footnote)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .glassSurface(Capsule())
                    .overlay {
                        if increased { Capsule().strokeBorder(.primary, lineWidth: 1) }
                    }
                    .help(Strings.LightTable.similarHelp)
            }
        }
        .frame(width: Tokens.Metric.frameLabel.width, height: Tokens.Metric.frameLabel.height)
        .accessibilityElement(children: .combine)
    }
}

/// A round 32 or 36 pt control: Undo, ‹, ›, Compare. Every one has a key and
/// every key has one of these, which is the half of §2.5 that does not exist
/// today at all (LT-01, LIGHTTABLE-M01). The key is named in the help tag and
/// read by the light table's one key path, never held by the button.
public struct StageButton: View {
    let symbol: String
    let label: String
    let size: CGFloat
    let badge: Int?
    let enabled: Bool
    let help: String?
    let action: () -> Void

    public init(symbol: String, label: String, size: CGFloat, badge: Int? = nil, enabled: Bool = true,
                help: String? = nil, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.size = size
        self.badge = badge; self.enabled = enabled
        self.help = help; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.body)
                .frame(width: size, height: size)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text("\(badge)")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 3)
                            .background(Capsule().fill(.quaternary))
                    }
                }
        }
        .buttonStyle(.borderless)
        .frame(width: size, height: size)
        .disabled(!enabled)
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}
