import AppKit
import Testing
@testable import PipelineKit

/// The numbers and symbols DESIGN.md §2 fixes. The light table's own layout
/// tests measure the built control bar; these check the table it is built
/// from, so a token that drifts is caught before a view is drawn with it.
@Suite("Design tokens")
struct TokensTests {

    @Test("the control cluster adds up to 753 pt, and Keep and Drop are 160 pt of clear space apart")
    func controlBar() {
        let m = Tokens.Metric.self
        // §2.5.2, in order: Undo 32, gap 24, ‹ 36, gap 16, Drop 112, gap 24,
        // label 112, gap 24, Keep 112, gap 16, › 36, gap 24, rule 1, gap 12,
        // Compare 36, gap 8, Next Burst 128.
        let width = m.undoButton.width + 24 + m.stepButton.width + 16
            + m.verdictButton.width + 24 + m.frameLabel.width + 24 + m.verdictButton.width + 16
            + m.stepButton.width + 24 + 1 + 12 + m.compareButton.width + 8 + m.nextBurstButton.width
        #expect(width == m.controlCluster)
        #expect(width == 753)
        // Drop's inner edge to Keep's inner edge: the frame label sits in it,
        // so the two opposite controls are never adjacent.
        #expect(24 + m.frameLabel.width + 24 == m.verdictClearGap)
        #expect(m.verdictClearGap == 160)
        // The same size, shape and weight: only the symbol, the word and the
        // tint differ.
        #expect(m.verdictButton == CGSize(width: 112, height: 40))
        // Centre to centre.
        #expect(m.verdictButton.width / 2 + m.verdictClearGap + m.verdictButton.width / 2 == 272)
    }

    @Test("the fixed chrome is 222 pt and the viewer gets everything else")
    func bands() {
        let m = Tokens.Metric.self
        #expect(m.toolbar + m.scrubber + m.controlBar + m.filmstrip == 222)
        #expect(m.fixedChrome == 222)
        // §2.5.1: at 1100 × 780 with the sidebar hidden, the picture is 51.4 %
        // of the window. The viewer box in that table is the inset box: the
        // 8 pt runs on all four sides.
        let viewer = CGSize(width: 1100 - 2 * m.viewerInset,
                            height: 780 - m.fixedChrome - 2 * m.viewerInset)
        #expect(viewer == CGSize(width: 1084, height: 542))
        let picture = CGSize(width: (viewer.height * 3 / 2).rounded(.down), height: viewer.height)
        #expect(picture == CGSize(width: 813, height: 542))
        let share = (picture.width * picture.height) / (1100 * 780)
        #expect(abs(share - 0.514) < 0.002)
        // The minimum window still fits the cluster with room each side.
        #expect((m.minimumWindow.width - m.controlCluster) / 2 == 73.5)
    }

    @Test("every symbol the design names exists on this system")
    func symbols() {
        for name in Symbols.all {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    "no SF Symbol called \(name)")
        }
        #expect(Symbols.step("keepers") == Symbols.stepKeepers)
        // An id nobody here knows is the extension's, and says so.
        #expect(Symbols.step("something-else") == Symbols.extensionStep)
        // His marks are filled; the cull's are outlines. They never share one.
        #expect(Set([Symbols.hisKeep, Symbols.hisDrop])
                .isDisjoint(with: [Symbols.cullForward, Symbols.cullAside, Symbols.cullFault, Symbols.agreed,
                              Symbols.agreedOut]))
    }

    @Test("the viewer's surround is the same neutral in both appearances, and darkest in Full Image")
    func viewerBackground() {
        let grey = Tokens.Palette.viewerBackgroundNSColor(.neutralGrey, fullImage: false)
        let greyFull = Tokens.Palette.viewerBackgroundNSColor(.neutralGrey, fullImage: true)
        #expect(grey.brightnessComponentOrOne > greyFull.brightnessComponentOrOne)
        // Compared by value, not by object: every surround is named in sRGB
        // now (DESIGN-displays.md §4.4), so Black is sRGB black and is not the
        // same object as NSColor.black, which is a calibrated one.
        let black = Tokens.Palette.viewerBackgroundNSColor(.black, fullImage: false)
            .usingColorSpace(.sRGB)
        #expect(black?.redComponent == 0 && black?.greenComponent == 0 && black?.blueComponent == 0)
        // And none of them is a calibrated white, which renders as a different
        // grey on each panel — the most visible two-screen fault there is.
        for choice in [ViewerBackground.neutralGrey, .black] {
            for full in [false, true] {
                let c = Tokens.Palette.viewerBackgroundNSColor(choice, fullImage: full)
                #expect(c.colorSpace.colorSpaceModel == .rgb)
            }
        }
    }

    @Test("the six reasons are the engine's own label words, and 'just no' is gone")
    func reasons() {
        #expect(DropReason.allCases.map(\.rawValue)
                == ["shadow", "cut off", "expression", "blur", "exposure", "composition"])
        #expect(DropReason.allCases.map(\.word)
                == ["shadow", "cut off", "face", "blur", "exposure", "framing"])
        #expect(DropReason.forKey(3) == .face)
        #expect(DropReason.forKey(7) == nil)
        #expect(DropReason.face.key == 3)
    }
}

extension NSColor {
    var brightnessComponentOrOne: CGFloat {
        usingColorSpace(.deviceGray)?.whiteComponent ?? 1
    }
}

@Suite("Light, dark, and the surround that does not move")
struct AppearanceTests {
    @Test("The default follows the Mac, and the other two name a real AppKit appearance")
    func choices() {
        #expect(AppAppearance.system.appKitName == nil)
        #expect(AppAppearance.light.appKitName == .aqua)
        #expect(AppAppearance.dark.appKitName == .darkAqua)
        #expect(AppAppearance.allCases.count == 3)
        for c in AppAppearance.allCases {
            #expect(!c.label.isEmpty)
            #expect(!c.symbol.isEmpty)
        }
    }

    @Test("A choice is remembered, and an unset one is 'match the Mac'")
    func remembered() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "appearance-test-\(UUID().uuidString)")!)
        #expect(store.appearance == .system)
        store.appearance = .dark
        #expect(store.appearance == .dark)
        store.appearance = .system
        #expect(store.appearance == .system)
    }

    @Test("The photograph's surround is the same neutral in both appearances")
    func surroundHoldsStill() {
        func greys(_ appearance: NSAppearance) -> (CGFloat, CGFloat) {
            var fit: CGFloat = -1, full: CGFloat = -1
            appearance.performAsCurrentDrawingAppearance {
                // genericGray: -getWhite: throws on an RGB colour space, and a
                // grey is exactly what this asks about.
                fit = Tokens.Palette.viewerBackgroundNSColor(.neutralGrey, fullImage: false)
                    .usingColorSpace(.genericGray)!.whiteComponent
                full = Tokens.Palette.viewerBackgroundNSColor(.neutralGrey, fullImage: true)
                    .usingColorSpace(.genericGray)!.whiteComponent
            }
            return (fit, full)
        }
        let light = greys(NSAppearance(named: .aqua)!)
        let dark = greys(NSAppearance(named: .darkAqua)!)
        // The same number in both, whatever the theme is doing around it.
        #expect(abs(light.0 - dark.0) < 0.001)
        #expect(abs(light.1 - dark.1) < 0.001)
        // And Full Image is the darker of the two, in both.
        #expect(light.1 < light.0)
        #expect(dark.1 < dark.0)
    }
}
