import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - the HUD

/// Two lines at most, 28 pt from the bottom edge, centred.
///
/// It appears when the pointer moves inside this window, when the burst
/// changes, and when Hold goes on or off. It **never** appears on a frame
/// change — a capsule that flashed on every K press would be three hundred
/// flashes an hour.
struct PictureHUD: View {
    let caption: FrameCaption?
    let held: String?
    let extraLine: String?
    let onceLine: String?
    /// Increase Contrast thickens the capsule's border to 1 pt. It never
    /// changes the surround (§4.4, rule 3) and never changes the photograph.
    var moreContrast = false
    var opaque = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                if let caption {
                    Text(caption.line)
                        .font(.title3)
                        .monospacedDigit()
                    if let phrase = caption.verdictPhrase {
                        Label {
                            Text(phrase).font(.callout)
                        } icon: {
                            Image(systemName: caption.his == .kept ? Symbols.hisKeep : Symbols.hisDrop)
                                .foregroundStyle(caption.his == .kept ? Tokens.Palette.kept : Tokens.Palette.out)
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }
                if let held {
                    Text(DisplayStrings.Picture.held(held))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if caption == nil, held == nil, let extraLine {
                    Text(extraLine).font(.callout)
                }
            }
            // The cull's line, when he has asked for it: second line, quieter,
            // and still never over the photograph.
            if let line = caption?.cullsLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if caption != nil, let extraLine {
                Text(extraLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let onceLine {
                Text(onceLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DisplayMetric.hudPadding)
        .frame(minHeight: DisplayMetric.hudHeight)
        .modifier(HUDSurface(opaque: opaque))
        .overlay(
            Capsule().strokeBorder(.separator,
                                   lineWidth: (moreContrast || contrast == .increased) ? 1 : 0)
        )
        .accessibilityElement(children: .combine)
    }
}

/// Liquid Glass on macOS 26, the identical capsule in `.ultraThinMaterial`
/// before it, an opaque capsule of the same shape and position under Reduce
/// Transparency. Nothing reflows by OS version.
private struct HUDSurface: ViewModifier {
    /// Reduce Transparency, and the snapshot harness — `cacheDisplay` gives a
    /// material no live backdrop to sample, so a captured glass capsule is a
    /// smear rather than the shape it really is.
    var opaque = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if opaque || reduceTransparency {
            // The same opaque surface `Design/Materials.swift` falls back to,
            // so the HUD's own text stays legible on it in either appearance.
            content.background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - the two hairlines

/// Two hairlines, two edges, two meanings, never the same line saying two
/// things: where he is in the burst along the bottom, a job's progress along
/// the top.
struct EdgeHairline: View {
    let fraction: Double
    let colour: Color
    var moreContrast = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.clear
                Rectangle()
                    .fill(colour)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: (moreContrast || contrast == .increased)
               ? DisplayMetric.hairlineContrast : DisplayMetric.hairline)
        .accessibilityHidden(true)
    }
}

// MARK: - his verdict, echoed

/// The same filled badge §2.5.9 uses, in the **surround**, bottom-left, never
/// over the photograph. 150 ms spring in, hold 900 ms, fade.
struct VerdictBadge: View {
    let his: VerdictValue.His

    var body: some View {
        Image(systemName: his == .kept ? Symbols.hisKeep : Symbols.hisDrop)
            .font(.system(size: DisplayMetric.badge))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, his == .kept ? Tokens.Palette.kept : Tokens.Palette.out)
            .accessibilityLabel(his == .kept
                                ? DisplayStrings.Picture.youKeptThis
                                : DisplayStrings.Picture.youPutThisOut)
    }
}

// MARK: - the hold

/// The frame this screen is holding, in the surround, for as long as it
/// holds it: the pin over "holding" over the frame's number, top-left
/// against the photograph — the verdict badge's corner mirrored — and never
/// over it. It was only a word in the HUD, its faintest, which shows only
/// while the pointer moves on this screen, so a held screen looked stuck.
struct HoldBadge: View {
    let frame: String
    let ink: Color

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: Symbols.hold).font(.title2)
            Text(DisplayStrings.Picture.holding).font(.caption)
            Text(frame).font(.callout).monospacedDigit()
        }
        .foregroundStyle(ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DisplayStrings.Picture.held(frame))
    }
}

// MARK: - the exit hint

/// *"Esc to come back"* — three seconds on entry, and two whenever the pointer
/// moves after being hidden. A guest can never be stuck in a chrome-less window
/// with no way out.
struct PresentationExitHint: View {
    var opaque = false

    var body: some View {
        Text(DisplayStrings.Picture.escToComeBack)
            .font(.callout)
            .padding(.horizontal, DisplayMetric.hudPadding)
            .frame(height: 36)
            .modifier(HUDSurface(opaque: opaque))
    }
}
