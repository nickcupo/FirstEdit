import Foundation
import Testing
@testable import PipelineKit

/// The window's subtitle: on Choose Keepers the bursts count that moves all
/// evening comes first, where the title bar cannot cut it off, and the step's
/// name — the page he is looking at — is left out.
@Suite("The window subtitle leads with what moves")
@MainActor
struct SubtitleTests {

    @Test("Choose Keepers: the bursts he has been through, with their unit, then his count, no step name")
    func keepers() {
        let s = RootView.subtitle(step: "keepers", stepLabel: Strings.Steps.keepers, kept: 368, bursts: (140, 288))
        #expect(s == Strings.Overview.burstsOf(140, 288) + " · " + Strings.Library.kept(368))
        #expect(s.hasPrefix("140 of 288 bursts"))
        #expect(!s.contains(Strings.Steps.keepers))
    }

    @Test("the toolbar's status item is short on Choose Keepers below 1440 pt, and whole wider or elsewhere")
    func statusItem() {
        #expect(RootView.statusItemIsShort(step: "keepers", windowWidth: 900))
        #expect(RootView.statusItemIsShort(step: "keepers", windowWidth: 1100))
        #expect(RootView.statusItemIsShort(step: "keepers", windowWidth: 1280))
        #expect(!RootView.statusItemIsShort(step: "keepers", windowWidth: 1440))
        #expect(!RootView.statusItemIsShort(step: "presets", windowWidth: 900))
        #expect(!RootView.statusItemIsShort(step: nil, windowWidth: 900))
    }

    @Test("any other step: its name, then his count")
    func otherSteps() {
        let s = RootView.subtitle(step: "presets", stepLabel: Strings.Steps.presets, kept: 368, bursts: (140, 288))
        #expect(s == Strings.Steps.presets + " · " + Strings.Library.kept(368))
        #expect(RootView.subtitle(step: "cull", stepLabel: Strings.Steps.cull, kept: 0, bursts: nil) == Strings.Steps.cull)
    }

    @Test("before the engine is ready: Starting under the shoot being reopened, and nothing over a stopped engine's page")
    func notReady() {
        let starting = RootView.notReady(.starting, reopening: "2026-09-19")
        #expect(starting.title == "2026-09-19")
        #expect(starting.subtitle == Strings.Engine.starting)
        #expect(RootView.notReady(.starting, reopening: nil).title == Strings.App.name)
        let down = RootView.notReady(.failed("No module named 'cv2'"), reopening: "2026-09-19")
        #expect(down.title == Strings.App.name)
        #expect(down.subtitle.isEmpty)
    }
}
