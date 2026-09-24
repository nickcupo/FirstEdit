import SwiftUI
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// Everything the second screen draws, in one observable value.
///
/// The window controller writes it; the views read it. A snapshot scene builds
/// one by hand, which is how all thirteen scenes of §7.5 are rendered without a
/// second display attached.
@MainActor @Observable
public final class PictureViewState {
    public var content: BigPictureContent = .nothing(line: nil)
    public var shoot = ""
    public var pump: ImagePump?
    public var mode: DisplayDirector.Mode = .follow
    public var surround: ViewerBackground = .neutralGrey
    /// Filling a screen, or a floating frame on the built-in.
    public var fills = true
    public var isPresenting = false
    public var isDrawing = true
    public var isFrozen = false
    public var hidePointerWhenStill = true
    /// Set when the system asks for Increase Contrast, and by the snapshot
    /// scene that has to show it on a machine that does not.
    public var increaseContrast = false
    /// Reduce Transparency, and the snapshot harness, which cannot capture a
    /// material. Identical shape, identical place.
    public var opaqueChrome = false

    public var hudVisible = false
    /// A second line: the full-screen refusal, or anything the director needs
    /// to say on this screen rather than an alert.
    public var hudExtraLine: String?
    /// *"The keys stay on the other screen."* — once per launch.
    public var hudOnceLine: String?
    public var badge: VerdictValue.His?
    public var heldStem: String?
    public var chromeRevealed = false
    public var exitHint = false
    /// Bumped to bounce the picture at the end of a deck.
    public var rubberBand = 0
    /// Only while a job is running: the top hairline.
    public var jobFraction: Double?

    public var onPick: ((String) -> Void)?
    public var onDisplay: ((String, Int) -> Void)?

    public init() {}

    /// The darkest variant of whatever he chose, wherever the picture has the
    /// whole screen.
    public var wideSurround: Bool { fills || isPresenting }
    public var surroundColor: Color { DisplaySurround.swiftUIColor(surround, wide: wideSurround) }

    public var windowTitle: String { shoot.isEmpty ? Strings.App.name : shoot }
    public var windowSubtitle: String { content.caption?.windowSubtitle ?? "" }

    /// The filled share of the bottom hairline: where he is in the burst,
    /// without a number.
    public var burstFraction: Double { content.caption?.burstFraction ?? 0 }

    /// What may be drawn straight onto the surround and still be seen.
    public func ink(_ opacity: Double) -> Color {
        DisplaySurround.ink(surround, wide: wideSurround, opacity: opacity)
    }
}

/// The picture window's content: the photograph, the surround, and the little
/// that is allowed near it.
public struct PictureRootView: View {
    @Bindable var state: PictureViewState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: PictureViewState) {
        self.state = state
    }

    public var body: some View {
        ZStack {
            state.surroundColor

            pane
                .offset(x: bounce)
                .animation(reduceMotion ? nil : .spring(duration: 0.12, bounce: 0.4), value: state.rubberBand)

            if !state.isPresenting {
                chrome
            }

            if state.exitHint {
                VStack {
                    Spacer()
                    PresentationExitHint(opaque: state.opaqueChrome)
                        .padding(.bottom, DisplayMetric.hudBottomInset)
                }
                .transition(.opacity)
            }
        }
        // The window is full-size content under a transparent title bar, so
        // without this the photograph would sit the height of that title bar
        // below the middle of the glass — and §1.6's geometry is measured from
        // the window, not from what AppKit thinks is safe.
        .ignoresSafeArea()
        .background(state.surroundColor.ignoresSafeArea())
        .accessibilityLabel(accessibilityLine)
    }

    // MARK: - what is in the middle

    @ViewBuilder
    private var pane: some View {
        switch state.content {
        case .frame(let stem, _, _):
            BigFramePane(shoot: state.shoot, stem: stem, pump: state.pump, onDisplay: state.onDisplay)

        case .tiles(let tiles, let focus, _):
            CompareTilesPane(shoot: state.shoot, tiles: tiles, focus: focus, pump: state.pump,
                             ink: state.ink(1))

        case .burst(_, let cells, let cursor):
            ContactSheetPane(shoot: state.shoot, cells: cells, cursor: cursor,
                             pump: state.pump, surround: state.surround, onPick: state.onPick)

        case .job(let title, let stage, let fraction):
            // The engine's own stage words, verbatim, as everywhere else.
            CentredLines([
                Line(title, .title2, 1),
                Line(stage.isEmpty ? "" : "\(stage) · \(Int(fraction * 100))%", .title3, 0.6),
            ], ink: state.ink(1))

        case .engineDown(let sentence):
            CentredLines([
                Line(sentence, .title2, 1),
                // No buttons here, because this window takes no clicks that do
                // anything.
                Line(DisplayStrings.Picture.buttonsAreOnTheOtherScreen, .callout, 0.6),
            ], ink: state.ink(1))

        case .nothing(let line):
            FadingLine(line: line, ink: state.ink(0.4))
        }
    }

    // MARK: - two hairlines, a capsule and a badge

    @ViewBuilder
    private var chrome: some View {
        VStack(spacing: 0) {
            // A job's progress, only while one is running.
            if let f = state.jobFraction {
                EdgeHairline(fraction: f, colour: .accentColor, moreContrast: state.increaseContrast)
            } else {
                Color.clear.frame(height: DisplayMetric.hairline)
            }
            Spacer(minLength: 0)
            // Where he is in the burst.
            EdgeHairline(fraction: state.burstFraction, colour: state.ink(0.25),
                         moreContrast: state.increaseContrast)
        }
        .ignoresSafeArea()

        if state.hudVisible {
            // Under the photograph, on the surround, when there is a band
            // there to hold it; over the picture's bottom edge only when the
            // frame fills the height of the glass (`DisplayMetric.hudInset`).
            GeometryReader { geo in
                VStack {
                    Spacer()
                    PictureHUD(caption: state.content.caption,
                               held: state.heldStem.map(ShootSession.shortStem),
                               extraLine: state.hudExtraLine,
                               onceLine: state.hudOnceLine,
                               moreContrast: state.increaseContrast,
                               opaque: state.opaqueChrome)
                        .padding(.bottom, hudInset(in: geo.size))
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .transition(reduceMotion ? .identity : .opacity)
        }

        if let held = state.heldStem.map(ShootSession.shortStem) {
            // For as long as the hold lasts, in the surround. It was only a
            // word in the HUD — its faintest — which shows when the pointer
            // moves on this screen, so a held screen looked stuck.
            GeometryReader { geo in
                let bounds = CGRect(origin: .zero, size: geo.size)
                let origin = DisplayMetric.holdOrigin(picture: picture(in: bounds), in: bounds)
                HoldBadge(frame: held, ink: state.ink(0.9))
                    .frame(width: DisplayMetric.holdBadge.width, height: DisplayMetric.holdBadge.height)
                    .position(x: origin.x + DisplayMetric.holdBadge.width / 2,
                              y: origin.y + DisplayMetric.holdBadge.height / 2)
            }
            .transition(reduceMotion ? .identity : .opacity)
        }

        if let badge = state.badge {
            // In the surround, against the photograph's edge. Never over the
            // photograph: his eyes are on this screen when he presses, and a
            // judgement written across a frame changes how the frame looks.
            GeometryReader { geo in
                let bounds = CGRect(origin: .zero, size: geo.size)
                let origin = DisplayMetric.badgeOrigin(picture: picture(in: bounds), in: bounds)
                VerdictBadge(his: badge)
                    .frame(width: DisplayMetric.badge, height: DisplayMetric.badge)
                    .position(x: origin.x + DisplayMetric.badge / 2,
                              y: origin.y + DisplayMetric.badge / 2)
            }
            .transition(reduceMotion ? .identity : .scale(scale: 0.8).combined(with: .opacity))
        }
    }

    /// Where the photograph is in a window this size.
    private func picture(in bounds: CGRect) -> CGRect {
        DisplayMetric.fitted(state.content.caption?.aspect ?? 1.5, in: DisplayMetric.pictureBox(in: bounds))
    }

    /// Only a single frame is placed by `DisplayMetric.fitted`; over Compare's
    /// tiles and the whole burst the HUD keeps its 28 pt.
    private func hudInset(in size: CGSize) -> CGFloat {
        guard case .frame = state.content else { return DisplayMetric.hudBottomInset }
        let bounds = CGRect(origin: .zero, size: size)
        return DisplayMetric.hudInset(picture: picture(in: bounds), in: bounds)
    }

    private var bounce: CGFloat {
        // 8 pt over 120 ms at the end of a deck, and a static offset of
        // nothing under Reduce Motion.
        reduceMotion ? 0 : (state.rubberBand % 2 == 0 ? 0 : Motion.rubberBand)
    }

    /// VoiceOver reaches this window through its window chooser and the Window
    /// menu. It exposes no custom actions: Keep, Drop, Clear the Mark and
    /// Compare are custom actions on the *main* window's frame element, where
    /// they already are, and duplicating them here would give VoiceOver two
    /// routes to the same verdict with two different display gates.
    private var accessibilityLine: String {
        var parts: [String] = []
        if let c = state.content.caption {
            parts.append(c.line)
            if let v = c.verdictPhrase { parts.append(v) }
        }
        parts.append(DisplayStrings.Picture.controlsAreInTheMainWindow)
        return parts.joined(separator: ". ")
    }
}

// MARK: - the panes

#if canImport(AppKit)
struct BigFramePane: NSViewRepresentable {
    let shoot: String
    let stem: String
    let pump: ImagePump?
    let onDisplay: ((String, Int) -> Void)?
    /// A tile is already its own shape, so it is not inset again.
    var inset: CGFloat = DisplayMetric.pictureInset

    func makeNSView(context: Context) -> BigFrameView {
        let v = BigFrameView(frame: .zero)
        v.inset = inset
        v.pump = pump
        v.onDisplay = onDisplay
        v.show(shoot: shoot, stem: stem)
        return v
    }

    func updateNSView(_ v: BigFrameView, context: Context) {
        v.inset = inset
        v.pump = pump
        v.onDisplay = onDisplay
        v.show(shoot: shoot, stem: stem)
    }

    static func dismantleNSView(_ v: BigFrameView, coordinator: ()) { v.tearDown() }
}

struct ContactSheetPane: NSViewRepresentable {
    let shoot: String
    let cells: [BurstCell]
    let cursor: Int
    let pump: ImagePump?
    let surround: ViewerBackground
    let onPick: ((String) -> Void)?

    func makeNSView(context: Context) -> ContactSheetView {
        let v = ContactSheetView(frame: .zero)
        v.pump = pump
        v.surround = surround
        v.onPick = onPick
        v.show(shoot: shoot, cells: cells, cursor: cursor)
        return v
    }

    func updateNSView(_ v: ContactSheetView, context: Context) {
        v.pump = pump
        v.surround = surround
        v.onPick = onPick
        v.show(shoot: shoot, cells: cells, cursor: cursor)
    }
}
#endif

/// Compare, on the big screen, while the strip and the buttons stay on the
/// laptop. Two tiles here are 1260 × 840 pt against 538 × 359 in the default
/// laptop window — 5.5× the area, on screens of the same scale.
struct CompareTilesPane: View {
    let shoot: String
    let tiles: [CompareTile]
    let focus: Int
    let pump: ImagePump?
    let ink: Color

    var body: some View {
        let columns = tiles.count <= 2 ? max(1, tiles.count) : 2
        GeometryReader { geo in
            let font = Self.captionFont(tileWidth: Self.tileWidth(columns: columns, in: geo.size.width))
            VStack(spacing: DisplayMetric.tileGutter) {
                ForEach(Array(rows(of: columns).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: DisplayMetric.tileGutter) {
                        ForEach(row) { tile in
                            tileView(tile, font: font)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            .padding(DisplayMetric.pictureInset)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    static func tileWidth(columns: Int, in width: CGFloat) -> CGFloat {
        let n = CGFloat(max(1, columns))
        return (width - DisplayMetric.pictureInset * 2 - DisplayMetric.tileGutter * (n - 1)) / n
    }

    /// The captions grow with the tiles. `.callout` under a 1260 pt tile on
    /// a 27" panel was the size of a menu's small print, read from where he
    /// sits, and it is the frame number he is choosing between.
    static func captionFont(tileWidth: CGFloat) -> Font {
        if tileWidth >= 1000 { return .title2 }
        if tileWidth >= 700 { return .title3 }
        return .callout
    }

    private func rows(of columns: Int) -> [[CompareTile]] {
        stride(from: 0, to: tiles.count, by: columns).map {
            Array(tiles[$0..<min($0 + columns, tiles.count)])
        }
    }

    @ViewBuilder
    private func tileView(_ tile: CompareTile, font: Font) -> some View {
        let isFocus = tiles.firstIndex(of: tile) == focus
        VStack(spacing: 6) {
            #if canImport(AppKit)
            BigFramePane(shoot: shoot, stem: tile.stem, pump: pump, onDisplay: nil, inset: 0)
                .aspectRatio(tile.aspect, contentMode: .fit)
                .overlay(
                    // The ring hugs the photograph itself, not the column of
                    // surround it is centred in.
                    RoundedRectangle(cornerRadius: 3)
                        .inset(by: -DisplayMetric.cursorRing / 2)
                        .strokeBorder(Color.accentColor,
                                      lineWidth: isFocus ? DisplayMetric.cursorRing : 0)
                )
            #else
            Color.clear.aspectRatio(tile.aspect, contentMode: .fit)
            #endif
            HStack(spacing: 8) {
                Text(tile.caption.shortStem)
                    .font(font.monospaced())
                    .foregroundStyle(ink.opacity(0.8))
                if let phrase = tile.caption.verdictPhrase {
                    Label {
                        Text(phrase).font(font)
                    } icon: {
                        Image(systemName: tile.caption.his == .kept ? Symbols.hisKeep : Symbols.hisDrop)
                    }
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(tile.caption.his == .kept
                                     ? Tokens.Palette.kept : Tokens.Palette.out)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tile.caption.line)
    }
}

// MARK: - when there is nothing to show (§1.5)

struct Line: Identifiable {
    let id = UUID()
    let text: String
    let font: Font
    let opacity: Double
    init(_ text: String, _ font: Font, _ opacity: Double) {
        self.text = text
        self.font = font
        self.opacity = opacity
    }
}

struct CentredLines: View {
    let lines: [Line]
    let ink: Color
    init(_ lines: [Line], ink: Color) { self.lines = lines; self.ink = ink }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(lines.filter { !$0.text.isEmpty }) { line in
                Text(line.text)
                    .font(line.font)
                    .foregroundStyle(ink.opacity(line.opacity))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(DisplayMetric.pictureInset * 2)
    }
}

/// One line, and after a minute with no change, nothing at all. A line sitting
/// on a panel for three hours is not something a photo app should do to a
/// display.
struct FadingLine: View {
    let line: String?
    let ink: Color
    @State private var faded = false

    var body: some View {
        Group {
            if let line, !faded {
                Text(line)
                    .font(.title3)
                    .foregroundStyle(ink)
            } else {
                Color.clear
            }
        }
        .task(id: line) {
            faded = false
            guard line != nil else { return }
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            faded = true
        }
    }
}
