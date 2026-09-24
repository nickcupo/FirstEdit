import Foundation
import Testing
@testable import PipelineKit

/// The player beside the burst (DESIGN.md §2.6): paused when he arrives, but a
/// reel he has just cut from the page plays as it comes out.
@Suite("The Reels player", .serialized)
@MainActor
struct ReelsPlayerTests {

    @Test("only a reel he cut from the page, and that came out, counts as just cut")
    func countsHisCuts() throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.burst93(), burst: "93")
        nonisolated(unsafe) var sent = 0
        m.sendReel = { _, _ in sent += 1 }
        let done = try Fixture.decodeJob(running: false, fraction: 1, kind: "reel", code: 0)
        let failed = try Fixture.decodeJob(running: false, fraction: 1, kind: "reel", code: 1)

        // A reel from the list, or from before he was here, ending: not his
        // press on this page, so nothing starts playing at him.
        m.ended(done)
        #expect(m.reelsCut == 0)

        m.cut()
        #expect(sent == 1)
        // The presets for PhotoLab ending is not the reel.
        m.ended(try Fixture.decodeJob(running: false, fraction: 1, kind: "spread", code: 0))
        #expect(m.reelsCut == 0)
        m.ended(done)
        #expect(m.reelsCut == 1)
        // Said once: the same ending read again is not a second reel.
        m.ended(done)
        #expect(m.reelsCut == 1)

        // One that failed plays nothing, and leaves nothing waiting to.
        m.cut()
        m.ended(failed)
        m.ended(done)
        #expect(m.reelsCut == 1)
    }

    @Test("the player plays the reel it loads only when one has been cut since it last looked, and not under Reduce Motion")
    func playsOnlyWhatIsNew() {
        #expect(ReelPlayer.playsOnLoad(cuts: 1, seen: 0, playsNew: true))
        #expect(!ReelPlayer.playsOnLoad(cuts: 1, seen: 1, playsNew: true))
        #expect(!ReelPlayer.playsOnLoad(cuts: 2, seen: 1, playsNew: false))
    }
}
