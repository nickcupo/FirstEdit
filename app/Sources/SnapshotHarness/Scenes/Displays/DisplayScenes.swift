import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import PipelineKit

/// The second screen, rendered from the captured fixtures and the scratch
/// library, so every one of these can be looked at before a display is ever
/// plugged in (DESIGN-displays.md §7.5).
///
/// The external is 2560 × 1440; the scenes that show what the *laptop* says are
/// 1512 × 945.
final class DisplayScenes: SceneProvider {

    static let external = CGSize(width: 2560, height: 1440)
    static let laptop = CGSize(width: 1512, height: 945)

    override class var scenes: [SnapshotScene] {
        [
            // 1. The default: the photograph, the surround, two hairlines, and
            //    nothing else at all.
            scene("picture.frame.landscape") { f in state(f) },
            scene("picture.frame.black") { f in
                let s = state(f)
                s.surround = .black
                return s
            },

            // 2. A portrait burst gets 34.6 % of the panel and there is no
            //    trick that fixes it — agreed to here rather than discovered.
            scene("picture.frame.portrait") { f in
                let s = state(f, portrait: true)
                return s
            },

            // 3. The HUD, revealed by the pointer moving.
            scene("picture.frame.hud") { f in
                let s = state(f, his: .kept)
                s.hudVisible = true
                return s
            },
            scene("picture.frame.hud.cull") { f in
                let s = state(f, his: .kept, cullsLine: "the cull put this one forward · sharp, eyes open")
                s.hudVisible = true
                return s
            },
            scene("picture.frame.hud.firstTime") { f in
                let s = state(f)
                s.hudVisible = true
                s.hudOnceLine = DisplayStrings.Picture.keysStayOnTheOtherScreen
                return s
            },

            // 4. His verdict, echoed in the surround, never over the picture.
            scene("picture.frame.verdict") { f in
                let s = state(f, his: .kept)
                s.badge = .kept
                return s
            },
            scene("picture.frame.verdict.out") { f in
                let s = state(f, his: .out)
                s.badge = .out
                return s
            },

            // 5. Compare, where the strip and the buttons stay on the laptop.
            scene("picture.compare.2up") { f in state(f, tiles: 2) },
            scene("picture.compare.4up") { f in state(f, tiles: 4) },

            // 6. The whole burst, his marks and the cull's.
            scene("picture.wholeBurst") { f in state(f, cells: 34) },

            // 7. One frame held while the laptop moves on.
            scene("picture.hold") { f in
                let s = state(f, his: .kept)
                s.heldStem = stems(f).first
                s.hudVisible = true
                return s
            },

            // 8. The three quiet states (§1.5).
            scene("picture.nothing") { f in
                let s = state(f)
                s.content = .nothing(line: DisplayStrings.Picture.shootAndStep(shootName(f), "Cull"))
                return s
            },
            scene("picture.noShoot") { f in
                let s = state(f)
                s.content = .nothing(line: DisplayStrings.Picture.noShootOpen)
                return s
            },
            scene("picture.job") { f in
                let s = state(f)
                s.content = .job(title: "Culling \(shootName(f))", stage: "looking at faces",
                                 fraction: 0.38)
                s.jobFraction = 0.38
                return s
            },
            scene("picture.engineDown") { f in
                let s = state(f)
                s.content = .engineDown(sentence: Strings.Engine.stopped)
                return s
            },

            // 9. Presentation: the photograph and nothing else.
            scene("picture.presentation") { f in
                let s = state(f)
                s.isPresenting = true
                return s
            },
            scene("picture.presentation.hint") { f in
                let s = state(f)
                s.isPresenting = true
                s.exitHint = true
                return s
            },

            // 10. The real title bar, faded in over the photograph.
            SnapshotScene(name: "picture.chromeRevealed", size: external) { f in
                let s = state(f)
                s.chromeRevealed = true
                return .window(AnyView(
                    PictureRootView(state: s)
                        .background(NoChromeForSnapshot(surround: s.surround, wide: s.wideSurround,
                                                        revealed: (s.windowTitle, s.windowSubtitle)))
                ))
            },

            // 11. Increase Contrast thickens the chrome and leaves the surround
            //     and the photograph exactly as they were.
            scene("picture.increaseContrast") { f in
                let s = state(f, his: .kept)
                s.hudVisible = true
                s.increaseContrast = true
                s.jobFraction = 0.62
                return s
            },

            // 12. What the laptop says, in the band that is reserved whether or
            //     not there is anything to say — so the two verdict buttons
            //     never move.
            SnapshotScene(name: "main.noteScreenWentAway", size: laptop) { _ in
                .window(AnyView(NoteBand(note: DisplayStrings.Note.screenWentAway)))
            },
            SnapshotScene(name: "main.noteScreenIsBack", size: laptop) { _ in
                .window(AnyView(NoteBand(note: DisplayStrings.Note.screenIsBack)))
            },
            SnapshotScene(name: "main.noteNone", size: laptop) { _ in
                .window(AnyView(NoteBand(note: nil)))
            },

            // 13. These Screens… — the row worth catching is the 1× one.
            SnapshotScene(name: "screensPanel", size: CGSize(width: 420, height: 260)) { _ in
                .window(AnyView(ScreensPanel(screens: demoScreens, picture: demoExternalKey)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)))
            },
        ]
    }

    // MARK: - building one

    private static func scene(_ name: String,
                              _ make: @escaping @MainActor @Sendable (Fixtures) -> PictureViewState)
    -> SnapshotScene {
        SnapshotScene(name: name, size: external) { f -> Snapshotted in
            // The real window hides its traffic lights until the pointer
            // reaches the top 52 pt; the harness makes an ordinary titled
            // window, so the scene has to say the same thing or the picture
            // would be shown with chrome it does not have.
            let s = make(f)
            return .window(AnyView(PictureRootView(state: s)
                .background(NoChromeForSnapshot(surround: s.surround, wide: s.wideSurround))))
        }
    }

    @MainActor
    private static func shootName(_ f: Fixtures) -> String { f.shoot?.info.name ?? "2026-09-13-dog" }

    @MainActor
    private static func stems(_ f: Fixtures) -> [String] {
        let all = f.shoot?.rows.map(\.stem) ?? []
        return all.isEmpty ? ["TSC04313"] : all
    }

    /// The state for one scene, built from the fixture's own rows so his marks
    /// and the cull's are real values rather than invented ones.
    @MainActor
    private static func state(_ f: Fixtures,
                              his: VerdictValue.His = .unmarked,
                              cullsLine: String? = nil,
                              portrait: Bool = false,
                              tiles: Int = 0,
                              cells: Int = 0) -> PictureViewState {
        let s = PictureViewState()
        // Liquid Glass and `.ultraThinMaterial` both need a live backdrop to
        // sample and `cacheDisplay` gives them none, so a captured glass
        // capsule is a smear rather than a capsule. Every scene draws §7.8's
        // opaque fallback instead: identical shape, identical place, so what is
        // being looked at here is the real geometry.
        s.opaqueChrome = true
        let shoot = shootName(f)
        let order = stems(f)
        s.shoot = shoot
        s.pump = portrait ? portraitPump(f) : f.pump
        s.fills = true

        func caption(_ stem: String, _ index: Int, _ his: VerdictValue.His) -> FrameCaption {
            FrameCaption(shoot: shoot, shortStem: ShootSession.shortStem(stem),
                         indexInBurst: index, framesInBurst: 7, burstNumber: 3,
                         burstsInShoot: 19, his: his, cullsLine: cullsLine)
        }

        if tiles > 0 {
            let picked = Array(order.prefix(tiles))
            s.content = .tiles(picked.enumerated().map { i, stem in
                CompareTile(stem: stem, caption: caption(stem, i + 1, mark(f, stem)))
            }, focus: 1, zoom: .fit)
        } else if cells > 0 {
            let picked = Array(order.prefix(cells))
            s.content = .burst(id: "burst-3", cells: picked.enumerated().map { i, stem in
                BurstCell(stem: stem, shortStem: ShootSession.shortStem(stem),
                          his: mark(f, stem), cull: cullMark(f, stem),
                          stack: i % 5 < 3 ? "stack-\(i / 5)" : nil,
                          isStackTop: i % 5 == 0)
            }, cursor: 11)
        } else {
            let stem = order[0]
            s.content = .frame(stem: stem, caption: caption(stem, 2, his), zoom: .fit)
        }
        return s
    }

    /// His own field, never the cull's.
    @MainActor
    private static func mark(_ f: Fixtures, _ stem: String) -> VerdictValue.His {
        guard let row = f.shoot?.rows.first(where: { $0.stem == stem }) else { return .unmarked }
        return VerdictValue.his(row)
    }

    /// The cull's, hollow and its own.
    @MainActor
    private static func cullMark(_ f: Fixtures, _ stem: String) -> CullMark {
        guard let row = f.shoot?.rows.first(where: { $0.stem == stem }) else { return .none }
        if row.reason?.isEmpty == false { return .fault }
        if row.rating >= 3 { return .forward }
        if row.rating > 0 { return .aside }
        return .none
    }

    // MARK: - a portrait frame, cut from a real one

    /// The library has no portrait burst in it, and a drawn rectangle would not
    /// show him what a portrait frame on a 16:9 panel actually looks like. So
    /// the same photograph is centre-cut to 2:3 on the way through.
    @MainActor
    private static func portraitPump(_ f: Fixtures) -> ImagePump {
        let library = f.library
        return ImagePump(loader: { route in
            guard let library else { throw CocoaError(.fileNoSuchFile) }
            let data = try Fixtures.file(for: route, in: library)
            return DisplayScenes.centreCutToPortrait(data) ?? data
        })
    }

    nonisolated static func centreCutToPortrait(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let height = image.height
        let width = Int((Double(height) * 2.0 / 3.0).rounded())
        guard width < image.width else { return nil }
        let x = (image.width - width) / 2
        guard let cut = image.cropping(to: CGRect(x: x, y: 0, width: width, height: height)) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cut, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - These Screens…

    static let demoExternalKey = ScreenKey(raw: "ext:7789-23313-597x336|2560x1440@2")

    static var demoScreens: ScreenSet {
        ScreenSet(screens: [
            ScreenInfo(key: ScreenKey(raw: "builtin:1552-40784"), name: "Built-in Display",
                       frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                       visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945),
                       backingScale: 2, colorSpaceName: "Color LCD",
                       isBuiltIn: true, isAsleep: false, hasMenuBar: true),
            // The case worth catching: a conversion board presenting no profile
            // of its own, driving the panel at 1×.
            ScreenInfo(key: demoExternalKey, name: "External 5K Panel",
                       frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                       visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1416),
                       backingScale: 1, colorSpaceName: nil,
                       isBuiltIn: false, isAsleep: false, hasMenuBar: false),
        ])
    }
}

// MARK: - the laptop's reserved band

/// What the main window says, in the band that is there whether or not there is
/// anything to say. The band above it stands in for the light table, which is
/// another crew's; what this scene proves is that the line arriving does not
/// change the height of anything under it.
private struct NoteBand: View {
    let note: String?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DisplaySurround.swiftUIColor(.neutralGrey, wide: false))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    Text("the light table, unchanged")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.35))
                )
            Divider()
            VStack(spacing: Tokens.Metric.relatedGap) {
                HStack(spacing: 0) {
                    placeholder("Drop", 112)
                    Spacer().frame(width: Tokens.Metric.verdictClearGap)
                    placeholder("Keep", 112)
                }
                DisplayNoteRow(note)
            }
            .padding(.vertical, Tokens.Metric.relatedGap)
            .frame(height: Tokens.Metric.controlBar + DisplayNoteRow.height + Tokens.Metric.relatedGap * 2)
            .frame(maxWidth: .infinity)
        }
    }

    private func placeholder(_ title: String, _ width: CGFloat) -> some View {
        Text(title)
            .font(.headline)
            .frame(width: width, height: Tokens.Metric.verdictButton.height)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The picture window shows no chrome at all until the pointer reaches the top
/// of it. The harness's own window is an ordinary titled one, so this says the
/// same thing to it.
private struct NoChromeForSnapshot: NSViewRepresentable {
    let surround: ViewerBackground
    let wide: Bool
    /// The one scene that shows the chrome he gets when the pointer reaches the
    /// top of the window.
    var revealed: (title: String, subtitle: String)?

    func makeNSView(context: Context) -> NSView {
        Probe(surround: surround, wide: wide, revealed: revealed)
    }
    func updateNSView(_ v: NSView, context: Context) {}

    final class Probe: NSView {
        let surround: ViewerBackground
        let wide: Bool
        let revealed: (title: String, subtitle: String)?
        init(surround: ViewerBackground, wide: Bool, revealed: (title: String, subtitle: String)?) {
            self.surround = surround
            self.wide = wide
            self.revealed = revealed
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            if let revealed {
                w.titleVisibility = .visible
                w.titlebarAppearsTransparent = false
                w.title = revealed.title
                w.subtitle = revealed.subtitle
                for b in [NSWindow.ButtonType.closeButton, .zoomButton] {
                    w.standardWindowButton(b)?.alphaValue = 1
                }
            } else {
                w.titleVisibility = .hidden
                w.titlebarAppearsTransparent = true
                for b in [NSWindow.ButtonType.closeButton, .zoomButton] {
                    w.standardWindowButton(b)?.alphaValue = 0
                }
            }
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            // Light or dark is his and this window follows it, so these render
            // differently in the two appearances — everywhere except the
            // surround itself, which is the same grey in both.
            w.backgroundColor = DisplaySurround.color(surround, wide: wide)
        }
    }
}
