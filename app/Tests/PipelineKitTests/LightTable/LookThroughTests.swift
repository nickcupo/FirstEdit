import Foundation
import Testing
@testable import PipelineKit

/// Decision 4: clicking "eyes closed 131" in the cull's report shows those
/// frames on the light table (DESIGN.md §2.6), K and D working as usual and
/// nothing recorded as been through.
@Suite("Looking through the frames one fault covers", .serialized)
@MainActor
struct LookThroughTests {

    static func settings(goesOn: Bool) -> SettingsStore {
        let name = "LookThroughTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let s = SettingsStore(defaults: d)
        s.afterLastFrameGoesOn = goesOn
        return s
    }

    /// A list across bursts: a middle frame of one, the first and last of a
    /// later one, and the last of a later one still.
    static func setUp(goesOn: Bool = true, log: WriteLog = WriteLog()) throws -> (ViewerModel, ViewerModel.FrameList) {
        let m = try BurstCrossingTests.model(log: log)
        m.settings = settings(goesOn: goesOn)
        let bursts = m.bursts.indices.filter { m.bursts[$0].frames.count >= 2 }
        try #require(bursts.count >= 3, "the fixture has three bursts of two frames or more")
        let (a, b, c) = (m.bursts[bursts[0]].frames, m.bursts[bursts[1]].frames, m.bursts[bursts[2]].frames)
        let list = ViewerModel.FrameList(name: "eyes closed",
                                         stems: [a[1], b[0], b[b.count - 1], c[c.count - 1]])
        return (m, list)
    }

    static func finishes(_ m: ViewerModel) -> Int { BurstCrossingTests.finishes(m) }

    @Test("the click opens the first of them; → and ← go through them alone, across bursts, recording nothing")
    func walk() async throws {
        let (m, list) = try Self.setUp()
        let seenBefore = m.bursts.map(\.seen)
        m.lookThrough(list)
        #expect(m.currentStem == list.stems[0])
        #expect(m.lookingThroughPosition == 1)
        #expect(m.lookingThroughLine?.contains("1 of 4") == true)
        #expect(m.lookingThroughLine?.contains("eyes closed") == true)

        for (i, stem) in list.stems.enumerated().dropFirst() {
            await ViewerTests.press(m, .nextFrame)
            #expect(m.currentStem == stem, "→ did not go to the next of them (\(i + 1) of 4)")
        }
        let bumps = m.bump
        await ViewerTests.press(m, .nextFrame)
        #expect(m.currentStem == list.stems[3] && m.bump == bumps + 1, "past the last of them it bumps")
        await ViewerTests.press(m, .previousFrame)
        #expect(m.currentStem == list.stems[2])

        #expect(m.bursts.map(\.seen) == seenBefore, "looking through them recorded a burst as been through")
        #expect(Self.finishes(m) == 0)
    }

    @Test("K keeps the frame on screen and goes on to the next of them, never on out of its burst")
    func keepGoesToTheNextOfThem() async throws {
        let (m, list) = try Self.setUp(goesOn: true)
        m.lookThrough(list)
        await ViewerTests.press(m, .nextFrame)
        await ViewerTests.press(m, .nextFrame)
        // The last frame of its burst, with Settings saying K goes on there.
        let last = list.stems[2]
        #expect(m.currentStem == last && m.isLastFrameOfBurst)
        let burst = m.burstIndex
        ViewerTests.show(m)
        await ViewerTests.press(m, .keep)
        await m.allSettled()
        #expect(m.session.rows[last].map(VerdictValue.his) == .kept)
        #expect(m.currentStem == list.stems[3], "K did not go on to the next of them")
        #expect(!m.bursts[burst].seen, "K on the last frame of a burst recorded it while looking through")
        #expect(Self.finishes(m) == 0)

        // D the same way, and the question after it is about the frame it put out.
        await ViewerTests.press(m, .previousFrame)
        ViewerTests.show(m)
        let dropped = try #require(m.currentStem)
        await ViewerTests.press(m, .drop)
        await m.allSettled()
        #expect(m.session.rows[dropped].map(VerdictValue.his) == .out)
        #expect(m.currentStem == list.stems[3])
        #expect(m.reasonStripStem == dropped)
    }

    @Test("K and D go on to the next of them at once, without waiting for the engine to save")
    func verdictsDoNotWait() async throws {
        let log = WriteLog()
        // Held until both have gone on, rather than delayed 800 ms: a busy run
        // could spend the delay before the test looked (`WriteLog`).
        await log.hold()
        let (m, list) = try Self.setUp(log: log)
        m.lookThrough(list)
        ViewerTests.show(m)
        m.perform(.keep)
        try? await waitUntil(.seconds(30)) { m.currentStem == list.stems[1] }
        #expect(m.currentStem == list.stems[1], "K waited for the engine before going on")
        #expect(m.verdictsWritten == 0, "the engine has not answered yet")
        ViewerTests.show(m)
        m.perform(.drop)
        try? await waitUntil(.seconds(30)) { m.currentStem == list.stems[2] }
        #expect(m.currentStem == list.stems[2], "D waited for the engine before going on")
        #expect(m.verdictsWritten == 0, "the engine has not answered yet")
        await log.letGo()
        await m.allSettled()
        #expect(m.verdictsWritten == 2)
        #expect(m.session.rows[list.stems[0]].map(VerdictValue.his) == .kept)
        #expect(m.session.rows[list.stems[1]].map(VerdictValue.his) == .out)
        #expect(await log.writes.count == 2)

        // 0 clears the mark and stays, as anywhere.
        await ViewerTests.press(m, .previousFrame)
        ViewerTests.show(m)
        await ViewerTests.press(m, .clearMark)
        await m.allSettled()
        #expect(m.currentStem == list.stems[1])
        #expect(m.session.rows[list.stems[1]].map(VerdictValue.his) == .unmarked)
        #expect(Self.finishes(m) == 0)
    }

    @Test("N and P go to the next and the last burst that has any of them, recording nothing")
    func burstsWithThem() async throws {
        let (m, list) = try Self.setUp()
        m.lookThrough(list)
        await ViewerTests.press(m, .nextBurst)
        #expect(m.currentStem == list.stems[1])
        await ViewerTests.press(m, .nextBurst)
        #expect(m.currentStem == list.stems[3])
        await ViewerTests.press(m, .previousBurst)
        #expect(m.currentStem == list.stems[1], "P goes to the first of them in the burst before")
        #expect(Self.finishes(m) == 0)
    }

    @Test("Esc stops it where he is, and the arrows are the arrows again")
    func escStops() async throws {
        let (m, list) = try Self.setUp()
        m.lookThrough(list)
        let at = m.frameIndex
        #expect(m.key(KeyMap.Press(key: .escape)))
        await ViewerTests.press(m, .fit)
        #expect(m.lookingThrough == nil && m.lookingThroughLine == nil)
        #expect(m.currentStem == list.stems[0])
        await ViewerTests.press(m, .nextFrame)
        #expect(m.frameIndex == at + 1, "→ after Esc did not go to the next frame of the burst")
    }

    @Test("a frame clicked to that is not one of them says how many there are, and → finds the next")
    func offTheList() async throws {
        let (m, list) = try Self.setUp()
        m.lookThrough(list)
        m.goToFrame(0)
        #expect(m.lookingThroughPosition == nil)
        #expect(m.lookingThroughLine?.contains("4 frames") == true)
        await ViewerTests.press(m, .nextFrame)
        #expect(m.currentStem == list.stems[0])
    }

    // MARK: - nothing else records a burst either

    @Test("in Compare, N and P close it and go to the next and the last burst that has any of them, recording nothing")
    func burstsFromCompare() async throws {
        let (m, list) = try Self.setUp(goesOn: false)
        m.lookThrough(list)
        await ViewerTests.press(m, .nextFrame)
        #expect(m.currentStem == list.stems[1])
        let burst = m.burstIndex
        m.compareSelection = [m.frames[0], m.frames[m.frames.count - 1]]
        await ViewerTests.press(m, .compare)
        #expect(m.mode == .compare)
        await ViewerTests.press(m, .nextBurst)
        await BurstCrossingTests.settle()
        #expect(m.mode == .single)
        #expect(m.currentStem == list.stems[3], "N in Compare did not go to the next burst that has any of them")
        #expect(!m.bursts[burst].seen, "N in Compare recorded the burst while looking through")
        #expect(Self.finishes(m) == 0)

        m.compareSelection = [m.frames[0], m.frames[1]]
        await ViewerTests.press(m, .compare)
        #expect(m.mode == .compare)
        await ViewerTests.press(m, .previousBurst)
        #expect(m.mode == .single)
        #expect(m.currentStem == list.stems[1], "P in Compare did not go to the first of them in the burst before")
        #expect(m.lookingThrough != nil)
        #expect(Self.finishes(m) == 0)
    }

    @Test("⇧K in Compare on a set that ends a burst goes on to the next of them, recording nothing, whatever Settings says")
    func keepOnlyGoesToTheNextOfThem() async throws {
        let (m, list) = try Self.setUp(goesOn: true)
        m.lookThrough(list)
        await ViewerTests.press(m, .nextFrame)
        await ViewerTests.press(m, .nextFrame)
        #expect(m.currentStem == list.stems[2] && m.isLastFrameOfBurst)
        let burst = m.burstIndex
        let n = m.frames.count
        let set = [m.frames[n - 2], m.frames[n - 1]]
        m.compareSelection = set
        await ViewerTests.press(m, .compare)
        #expect(m.mode == .compare)
        for s in m.compareSelection { m.didDisplayTile(s) }
        await ViewerTests.press(m, .keepOnly)
        await BurstCrossingTests.settle()
        #expect(set.allSatisfy { m.session.rows[$0].map(VerdictValue.his) != .unmarked }, "⇧K decided the set")
        #expect(m.mode == .single)
        #expect(m.currentStem == list.stems[3], "⇧K did not go on to the next of them")
        #expect(!m.bursts[burst].seen, "⇧K on a set ending the burst recorded it while looking through")
        #expect(Self.finishes(m) == 0)
    }

    @Test("the end of a burst says nothing of N, and on the shoot's last frame ⌘] and Continue record nothing")
    func endOfBurstAndShoot() async throws {
        let (m, list) = try Self.setUp()
        m.lookThrough(list)
        await ViewerTests.press(m, .nextFrame)
        await ViewerTests.press(m, .nextFrame)
        #expect(m.isLastFrameOfBurst)
        #expect(m.endOfBurstLine == nil, "the end line offered → or N, which go to the next of them")
        #expect(m.lookingThroughLine != nil)

        let last = try #require(m.bursts.last)
        try #require(!last.seen, "the fixture's last burst is not yet been through")
        let stem = try #require(last.frames.last)
        m.lookThrough(ViewerModel.FrameList(name: "eyes closed", stems: [stem]))
        #expect(m.isLastBurst && m.isLastFrameOfBurst)
        #expect(!m.nextStepFinishesTheShoot, "⌘] would record the last burst while looking through")
        #expect(await m.finishBeforeContinuing())
        #expect(m.bursts.last?.seen == false)
        #expect(Self.finishes(m) == 0)

        // Stopped, the end of the shoot is the end of the shoot again.
        m.stopLookingThrough()
        #expect(m.endOfBurstLine != nil)
        #expect(m.nextStepFinishesTheShoot)
    }

    // MARK: - the left hand's keys (§2.5.3)

    /// The one-handed layout reaches the list the way the keys it stands
    /// beside do: F and S as → and ←, R and W as N and P, E as K. And on the
    /// last burst, where R is otherwise On to Presets, it stays the list's.
    @Test("F, S, R, W and E go through them as →, ←, N, P and K do, and R is never On to Presets meanwhile")
    func leftHand() async throws {
        let (m, list) = try Self.setUp(goesOn: true)
        m.lookThrough(list)
        func press(_ c: String) async {
            #expect(m.key(KeyMap.Press(c)), "\(c) was not the light table's")
            await BurstCrossingTests.settle()
        }
        await press("f")
        #expect(m.currentStem == list.stems[1], "F did not go to the next of them")
        await press("s")
        #expect(m.currentStem == list.stems[0], "S did not go to the one before")
        await press("r")
        #expect(m.currentStem == list.stems[1], "R did not go to the first of them in the next burst")
        await press("r")
        #expect(m.currentStem == list.stems[3])
        await press("w")
        #expect(m.currentStem == list.stems[1], "W did not go to the first of them in the burst before")
        await press("f")
        #expect(m.currentStem == list.stems[2] && m.isLastFrameOfBurst)
        let burst = m.burstIndex
        ViewerTests.show(m)
        await press("e")
        await m.allSettled()
        #expect(m.session.rows[list.stems[2]].map(VerdictValue.his) == .kept)
        #expect(m.currentStem == list.stems[3], "E did not go on to the next of them")
        #expect(!m.bursts[burst].seen, "E on the last frame of a burst recorded it while looking through")
        #expect(Self.finishes(m) == 0)

        let last = try #require(m.bursts.last)
        try #require(!last.seen, "the fixture's last burst is not yet been through")
        let stem = try #require(last.frames.last)
        m.lookThrough(ViewerModel.FrameList(name: "eyes closed", stems: [stem]))
        #expect(m.isLastBurst)
        #expect(!m.nextBurstLeavesForPresets, "R would go on to Presets while looking through")
        #expect(ControlBar(model: m).nextBurstTitle == Strings.LightTable.nextBurst)
        await press("r")
        #expect(m.currentStem == stem, "R on the last burst left while looking through")
        #expect(m.bursts.last?.seen == false)
        #expect(Self.finishes(m) == 0)
        m.stopLookingThrough()
        #expect(m.nextBurstLeavesForPresets)
        #expect(ControlBar(model: m).nextBurstTitle == Strings.LightTable.onToPresets)
    }

    // MARK: - the report's side

    static func row(_ stem: String, _ rating: Int, _ reason: String) -> Row {
        try! Row(fields: Fields(["file": .string("\(stem).ARW"), "stem": .string(stem),
                                 "rating": .string("\(rating)"), "reason": .string(reason)]))
    }

    @Test("each fault in the report links to exactly the frames it counts, in the order he shot them")
    func reportLinks() throws {
        var rows: [Row] = []
        let reasons = ["blink", "clear win", "blink", "blown highlights", "below the cut", "soft", "blink",
                       "face in the dark", "blown face", "mid-word", "soft", ""]
        for (i, r) in reasons.enumerated() {
            let rating = r == "clear win" ? 5 : r == "below the cut" ? 2 : 0
            rows.append(Self.row("f\(i)", rating, r))
        }
        let report = CullReport(rows: rows)
        let eyes = try #require(report.reasons.firstIndex { $0.count == 3 })
        let word = report.reasons[eyes].word
        #expect(report.framesByReason[word] == ["f0", "f2", "f6"])
        for r in report.reasons {
            #expect(report.framesByReason[r.word]?.count == r.count, "\(r.word)")
        }
        #expect(report.otherFrames.count == report.otherFaults)
        #expect(report.reasons.reduce(0) { $0 + $1.count } + report.otherFrames.count == report.faults)

        // The line reads as it did; its parts carry links, and the words
        // around them do not.
        let linked = report.faultsLinked
        #expect(String(linked.characters) == report.faultsLine)
        let links = linked.runs.compactMap(\.link)
        #expect(links.count == report.reasons.count + (report.otherFaults > 0 ? 1 : 0))
        let list = try #require(report.frames(for: links[eyes]))
        #expect(list.name == word && list.stems == ["f0", "f2", "f6"])
        if report.otherFaults > 0, let other = links.last {
            #expect(report.frames(for: other)?.stems == report.otherFrames)
        }
        #expect(report.frames(for: URL(string: "https://example.com")!) == nil)
    }
}
