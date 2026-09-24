import Foundation
import Testing
@testable import PipelineKit

/// The wait on PhotoLab (DESIGN.md §2.6): the reel it cuts is the one he had
/// when he pressed, whatever he browses meanwhile; it never moves the page;
/// the primary is Cut Now while it waits on the burst he is looking at; and
/// the page gives one count for the burst, not three.
@Suite("Reels waiting on PhotoLab", .serialized)
@MainActor
struct ReelsWaitTests {

    @Test("the reel is cut as he had it when he pressed, not as the page is when the exports settle")
    func cutsWhatHeChose() async throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.burst93(), burst: "93")
        m.choose(format: .loop)
        let stems = m.frames.map(\.stem)
        for s in stems.prefix(3) + stems.suffix(4) { m.toggle(s) }       // frames 4 to 9
        var sent: [[String: JSONValue]] = []
        m.sendReel = { _, body in sent.append(body) }
        m.countExports = { _, _ in 3 }
        m.startSpread = { _, _ in }
        m.fetchOptions = { _, _, _ in try ReelsScaffold.burst93() }
        await m.finishInPhotoLab()?.value
        let frozen = try #require(m.wait?.request)
        #expect(frozen["format"] == .string("loop"))
        #expect(frozen["frames"] == .array(stems.dropFirst(3).dropLast(4).map(JSONValue.string)))

        // While PhotoLab exports he looks at a timelapse, then at another burst.
        m.choose(format: .timelapse)
        m.burst = "94"
        m.speed = 12
        m.spreadEnded(Job(running: false, stopped: false, kind: "spread", shoot: m.session.name, log: "", code: 0))
        #expect(m.wait?.ready == true)
        m.stopWaiting()

        // Settled: what he froze goes, and the page stays where he is.
        m.startWaiting(burst: "93", baseline: 3, target: 13, request: frozen)
        m.pollInterval = .milliseconds(1)
        m.countExports = { _, _ in 13 }
        for _ in 0..<400 where sent.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(sent.count == 1)
        #expect(sent.first?["format"] == .string("loop"))
        #expect(sent.first?["burst"] == .string("93"))
        #expect(sent.first?["frames"] == frozen["frames"])
        #expect(m.burst == "94" && m.format == .timelapse)
        #expect(m.wait == nil)
    }

    @Test("a frame named when he pressed that is no longer there is dropped, and under three cut nothing")
    func dropsWhatHasGone() async throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.burst93(), burst: "93")
        var sent: [[String: JSONValue]] = []
        m.sendReel = { _, body in sent.append(body) }
        m.fetchOptions = { _, _, _ in try ReelsScaffold.options(about: "93", frames: 2) }
        m.startWaiting(burst: "93", baseline: 3, target: 13,
                       request: ["format": .string("cut"), "burst": .string("93"),
                                 "frames": .array(["B93F0", "B93F1", "GONE"].map(JSONValue.string))])
        m.cutNow()
        for _ in 0..<200 where m.waitNote == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(sent.isEmpty)
        #expect(m.waitNote == Strings.Reels.needThree)
    }

    @Test("while it waits on the burst he is looking at, the primary is Cut Now, and it cuts what he froze")
    func thePrimaryIsCutNow() async throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.burst93(), burst: "93")
        var sent: [[String: JSONValue]] = []
        m.sendReel = { _, body in sent.append(body) }
        #expect(m.primaryWord == Strings.Reels.cutIt && m.whyNot == nil)
        m.pollInterval = .seconds(60)
        m.startWaiting(burst: "93", baseline: 3, target: 13)
        #expect(m.waitingHere)
        #expect(m.primaryWord == Strings.Reels.cutNow)
        #expect(m.whyNot == Strings.Reels.cutNowNote)
        #expect(!m.frozenChanged)
        m.toggle("TSC06264")
        #expect(m.frozenChanged)                    // and the page says the reel will not have it
        m.primary()
        #expect(m.wait == nil)
        for _ in 0..<200 where sent.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        // One reel, not a draft now and a finished one later.
        #expect(sent.count == 1 && sent.first?["frames"] == nil)
        #expect(m.primaryWord == Strings.Reels.cutIt)
    }

    @Test("on another burst the primary is Cut It for that burst, and the wait goes on")
    func anotherBurstIsItsOwn() throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.burst93(), burst: "93")
        m.pollInterval = .seconds(60)
        m.startWaiting(burst: "231", baseline: 0, target: 13)
        #expect(!m.waitingHere && m.primaryWord == Strings.Reels.cutIt && !m.frozenChanged)
        #expect(m.canPressPrimary == m.canCut)
        m.stopWaiting()
    }

    @Test("while it waits, the burst's row counts what the wait counts, and the line says of how many")
    func oneCount() throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.burst93(), burst: "93")
        let b = try #require(m.chosenBurst)
        #expect(m.exported(b) == 3)
        var w = ReelWait(burst: "93", baseline: 3, target: 13)
        _ = w.saw(7)
        m.previewWait(w)
        #expect(m.exported(b) == 7)
        #expect(ReelsCentre.waitLine(w) == Strings.Reels.soFar("93", 7, of: 13))
        _ = w.saw(7)
        #expect(ReelsCentre.waitLine(w) == Strings.Reels.soFar("93", 7, of: 13) + " " + Strings.Reels.cutsIn(40))
        // The watch counts every folder; the row never says more than the burst has.
        var over = ReelWait(burst: "93", baseline: 3, target: 13)
        _ = over.saw(20)
        m.previewWait(over)
        #expect(m.exported(b) == 13)
        // Writing the presets is not yet a count of anything.
        m.previewWait(ReelWait(burst: "93", baseline: 3, target: 13, ready: false))
        #expect(m.exported(b) == 3)
        m.previewWait(nil)
    }

    @Test("a reel of some of the burst says that Cut Now is his once those are in, since the wait counts the whole burst")
    func someOfTheBurst() {
        let six: [String: JSONValue] = ["frames": .array((3...8).map { .string("TSC0\($0)") })]
        var w = ReelWait(burst: "93", baseline: 3, target: 13, request: six)
        #expect(w.reelFrames == 6)
        let tail = " " + Strings.Reels.someOfTheBurst(6, of: 13)
        #expect(ReelsCentre.waitLine(w) == Strings.Reels.waiting("93") + tail)
        _ = w.saw(9)
        _ = w.saw(9)
        #expect(ReelsCentre.waitLine(w) == Strings.Reels.soFar("93", 9, of: 13) + " " + Strings.Reels.cutsIn(40) + tail)
        // The whole burst, or nothing named: nothing more to say.
        #expect(ReelWait(burst: "93", baseline: 3, target: 13).reelFrames == nil)
        #expect(!ReelsCentre.waitLine(ReelWait(burst: "93", baseline: 3, target: 13)).contains(tail))
    }
}
