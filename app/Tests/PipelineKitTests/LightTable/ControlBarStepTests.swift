import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// §2.5.2: ‹ and › go where ← and → go. The keys cross bursts; the buttons
/// were greyed at every burst's ends, so on his four-frame bursts the bar told
/// the mouse "no further" a quarter of the time while the key carried on.
@Suite("The control bar's step arrows", .serialized)
@MainActor
struct ControlBarStepTests {

    @Test("‹ is live on a burst's first frame when there is a burst before, and only the shoot's first frame stops it")
    func backCrossesBursts() throws {
        let m = try ViewerTests.model()
        m.goToBurst(1)
        m.goToFrame(0)
        #expect(ControlBar(model: m).canGoBack)
        m.goToBurst(0)
        m.goToFrame(0)
        #expect(!ControlBar(model: m).canGoBack)
        m.goToFrame(1)
        #expect(ControlBar(model: m).canGoBack)
    }

    @Test("› is live on a burst's last frame when there is a burst after, and on the shoot's last frame until that burst is finished")
    func onCrossesBursts() async throws {
        let m = try ViewerTests.model()
        m.goToBurst(0)
        m.goToFrame(m.frames.count - 1)
        #expect(ControlBar(model: m).canGoOn)
        m.goToBurst(m.bursts.count - 1)
        m.goToFrame(m.frames.count - 1)
        // → there records the last burst as N does, so › does too, once.
        #expect(ControlBar(model: m).canGoOn == m.canFinishBurst)
        m.goToFrame(0)
        #expect(m.frames.count == 1 || ControlBar(model: m).canGoOn)
    }

    @Test("pressing ‹ on a burst's first frame lands on the last frame of the burst before, as ← does")
    func pressingBackCrosses() async throws {
        let m = try ViewerTests.model()
        m.goToBurst(1)
        m.goToFrame(0)
        await ViewerTests.press(m, .previousFrame)
        #expect(m.burstIndex == 0)
        #expect(m.frameIndex == m.frames.count - 1)
    }

    /// Next Burst and Frame ▸ Next Burst were both greyed on the last burst,
    /// so only a bare N reaching the photograph could finish it and nothing
    /// said so: his count stopped at 287 of 288. Then they finished it and
    /// stayed, so the end of every shoot still took the link or ⌘].
    @Test("on the last burst Next Burst is On to Presets: it records the burst, goes on, and is never greyed")
    func lastBurstGoesOnToPresets() async throws {
        let session = ShootSession(response: try ViewerTests.response(), ext: nil,
                                   client: LiveCountsTests.client(),
                                   pump: ImagePump(budget: .base, loader: { _ in Data() }),
                                   queue: VerdictQueue(sender: { _ in .failure(.offline) }))
        let m = ViewerModel(session: session, navigation: Navigation())
        m.navigation.selection = .step(shoot: session.name, step: "keepers")
        let last = m.bursts.count - 1
        m.goToBurst(last)
        #expect(m.currentBurst?.seen == false)
        #expect(ControlBar(model: m).nextBurstTitle == Strings.LightTable.onToPresets)
        #expect(LightTableCommands.enabled(.nextBurst, m))
        #expect(LightTableCommands.title(.nextBurst, m) == Strings.LightTable.continueToPresets,
                "the menu row says where it goes")
        await ViewerTests.press(m, .nextBurst)
        #expect(m.currentBurst?.seen == true, "the last burst is been through")
        #expect(m.navigation.step == "presets")

        // Finished, it still goes on, and records nothing a second time.
        m.navigation.selection = .step(shoot: session.name, step: "keepers")
        #expect(!m.canFinishBurst)
        #expect(LightTableCommands.enabled(.nextBurst, m), "greyed with nothing left to finish, and N went on")
        let steps = m.session.undo.steps.count
        await ViewerTests.press(m, .nextBurst)
        #expect(m.session.undo.steps.count == steps, "a second N records nothing")
        #expect(m.navigation.step == "presets")
    }

    /// In All Bursts N goes to a burst he has not been through and finishes
    /// nothing, so the button there may not say it goes anywhere else.
    @Test("Next Burst says On to Presets on the last burst, except in All Bursts")
    func onToPresetsOnlyWhereItGoes() throws {
        let m = try ViewerTests.model()
        m.goToBurst(m.bursts.count - 1)
        #expect(ControlBar(model: m).nextBurstTitle == Strings.LightTable.onToPresets)
        m.mode = .allBursts
        #expect(ControlBar(model: m).nextBurstTitle == Strings.LightTable.nextBurst)
        #expect(LightTableCommands.title(.nextBurst, m) == nil)
        m.mode = .single
        m.goToBurst(0)
        #expect(ControlBar(model: m).nextBurstTitle == Strings.LightTable.nextBurst)
        #expect(LightTableCommands.title(.nextBurst, m) == nil)
    }

    @Test("the label fits the button it is drawn in")
    func onToPresetsFits() {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let w = (Strings.LightTable.onToPresets as NSString).size(withAttributes: [.font: font]).width
        // The label's box is the button less its bezel, and the symbol and
        // its 6 pt gap sit beside the words.
        let box = Tokens.Metric.nextBurstButton.width - ControlBar.borderedBezelPadding * 2
        #expect(w + 18 + 6 <= box, "\(w) pt of words in a \(box) pt label")
    }

    @Test("the line at the end of the shoot does not name the key its own link beside it already offers")
    func endOfShootSaysItOnce() {
        let line = Strings.LightTable.endOfShoot(kept: 14, of: 54)
        #expect(!line.contains(Strings.LightTable.continueToPresets))
        #expect(!line.contains("⌘]"))
    }
}
