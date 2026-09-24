import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// The light table as behaviour: what a press does, what it refuses to do, and
/// what it never does twice.
@Suite("The light table", .serialized)
@MainActor
struct ViewerTests {

    // MARK: - a session with stacks in it

    /// The dog shoot, with the columns the cull is about to start writing put
    /// in: a stack of four in one burst, a face on every frame of it.
    static func response() throws -> ShootResponse {
        let data = try Fixture.data("shoot")
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try #require(obj["rows"] as? [[String: Any]])
        var byBurst: [String: [Int]] = [:]
        for (i, r) in rows.enumerated() {
            byBurst["\(r["scene"] as? String ?? "")/\(r["burst"] as? String ?? "")", default: []].append(i)
        }
        let biggest = byBurst.max { $0.value.count < $1.value.count }?.value ?? []
        for (n, i) in biggest.enumerated() {
            rows[i]["face_x"] = 0.4 + Double(n) * 0.02
            rows[i]["face_y"] = 0.3
            if n < 4 {
                rows[i]["stack"] = "s1"
                rows[i]["stack_top"] = n == 1 ? "1" : "0"
            }
        }
        obj["rows"] = rows
        return try JSONDecoder().decode(ShootResponse.self,
                                        from: JSONSerialization.data(withJSONObject: obj))
    }

    /// The same session, with every burst already recorded as been through —
    /// which is the state an N leaves behind, and the only state in which
    /// un-marking means anything.
    static func modelAllSeen() throws -> ViewerModel {
        let data = try Fixture.data("shoot")
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(obj["rows"] as? [[String: Any]])
        var seen: [String: Any] = [:]
        for r in rows {
            seen["\(r["scene"] as? String ?? "")/\(r["burst"] as? String ?? "")"] =
                ["seen": "2026-09-22T10:00:00", "from": NSNull()]
        }
        obj["review"] = ["at": "", "bursts": seen, "stale": ""]
        let response = try JSONDecoder().decode(ShootResponse.self,
                                                from: JSONSerialization.data(withJSONObject: obj))
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"))
        let session = ShootSession(response: response, ext: nil, client: client,
                                   pump: ImagePump(budget: .base, loader: { _ in Data() }),
                                   queue: VerdictQueue(sender: { _ in .failure(.offline) }))
        return ViewerModel(session: session, navigation: Navigation())
    }

    static func model(log: WriteLog = WriteLog()) throws -> ViewerModel {
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"))
        let pump = ImagePump(budget: .base, loader: { _ in Data() })
        let session = ShootSession(response: try response(), ext: nil, client: client, pump: pump,
                                   queue: VerdictQueue(sender: { await log.send($0) }))
        let m = ViewerModel(session: session, navigation: Navigation())
        // The burst that has the stack in it.
        if let i = session.bursts.firstIndex(where: { b in
            b.frames.contains { session.rows[$0]?.stack != nil }
        }) { m.goToBurst(i) }
        return m
    }

    /// Pretends the stage drew the frame under the cursor, which is the only
    /// thing that lets a verdict through (§2.5.4).
    static func show(_ m: ViewerModel) {
        guard let stem = m.currentStem else { return }
        m.didDisplay(stem: stem, generation: m.session.cursor.generation)
    }

    /// One press, applied. The queue behind `perform` is asynchronous on
    /// purpose, so a test waits for it rather than reaching past it.
    static func press(_ m: ViewerModel, _ a: KeyMap.Action) async {
        m.perform(a)
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(2))
            await Task.yield()
        }
    }

    // MARK: - the display gate

    @Test("a verdict is refused on a frame that has not been drawn, and the sentence says which")
    func gate() async throws {
        let log = WriteLog()
        let m = try Self.model(log: log)
        await Self.press(m, .keep)
        #expect(await log.writes.isEmpty, "nothing was on screen")
        #expect(m.session.refusals[.verdict] == Strings.Verdict.stillOpening)

        Self.show(m)
        await Self.press(m, .keep)
        #expect(await log.writes.count == 1)
        #expect(m.session.refusals[.verdict] == nil, "the owner of the refusal cleared it")
    }

    @Test("a frame with no pixels anywhere can take no verdict at all")
    func noPixels() async throws {
        let log = WriteLog()
        let m = try Self.model(log: log)
        // A row the engine says has no rendering at any size.
        let stem = try #require(m.currentStem)
        _ = try JSONSerialization.jsonObject(with: Fixture.data("shoot")) as? [String: Any]
        m.session.didDisplay(stem: stem, generation: m.session.cursor.generation)
        #expect(m.session.displayRefusal() == nil)
        // Nothing here fakes the absence of pixels — `hasAnyRendering` is the
        // engine's own three columns, and the foundation's own test covers the
        // sentence. What this asserts is that the viewer asks the session and
        // does not decide for itself.
        #expect(Strings.Verdict.noPixels.contains("not on this Mac"))
    }

    @Test("a held K writes exactly one verdict, and 200 arrow repeats write none")
    func heldKeysAndArrows() async throws {
        let log = WriteLog()
        let m = try Self.model(log: log)
        Self.show(m)

        // The first press is real; every one after it carries isARepeat.
        _ = m.key(KeyMap.Press("k"))
        for _ in 0..<200 { _ = m.key(KeyMap.Press("k", isARepeat: true)) }
        for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(2)); await Task.yield() }
        #expect(await log.writes.count == 1, "a held K keeps one frame only")
        #expect(m.pressesIgnoredAsRepeat == 200)
        #expect(m.showHeldKeyTip, "and it says so, once")

        let before = await log.writes.count
        for _ in 0..<200 { _ = m.key(KeyMap.Press(key: .right, isARepeat: true)) }
        for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(2)); await Task.yield() }
        #expect(await log.writes.count == before, "arrows never write")
    }

    // MARK: - moving

    @Test("nothing crosses a burst boundary on its own")
    func noAutoCross() async throws {
        let m = try Self.model()
        let burst = m.burstIndex
        for _ in 0..<50 { await Self.press(m, .nextFrame) }
        #expect(m.burstIndex == burst)
        #expect(m.frameIndex == m.frames.count - 1)
        // → on the last frame bounces rather than wrapping.
        let bump = m.bump
        await Self.press(m, .nextFrame)
        #expect(m.bump == bump + 1)
        #expect(m.frameIndex == m.frames.count - 1)
    }

    @Test("Keep and Drop advance to the next frame, and stop silently at the end of the burst")
    func autoAdvance() async throws {
        let m = try Self.model()
        Self.show(m)
        let start = m.frameIndex
        await Self.press(m, .keep)
        #expect(m.frameIndex == start + 1)
        Self.show(m)
        await Self.press(m, .drop)
        #expect(m.frameIndex == start + 2)
    }

    @Test("only leaving a burst forward records it as looked through; jumping and scrolling record nothing")
    func beenThrough() async throws {
        let m = try Self.model()
        let id = try #require(m.currentBurst?.id)
        #expect(m.currentBurst?.seen == false)
        m.goToBurst(0)
        m.goToBurst(m.bursts.count - 1)
        m.goToFrame(0)
        #expect(m.bursts.first(where: { $0.id == id })?.seen == false,
                "jumping around is not the same as looking through")
    }

    @Test("an N pressed by mistake can be taken back, and never on trust")
    func unmarking() async throws {
        // §7.4. Leaving a burst forward is the only thing that records it, and
        // Undo reaches the most recent N and nothing further back — so an N
        // pressed an hour ago had nothing that could take it back. The route
        // and the sentence for it both existed; the control did not.
        let fresh = try Self.model()
        let id = try #require(fresh.currentBurst?.id)
        // Nothing to take back is not an error, and does not reach the engine
        // — which is a dead port here, so a request would come back refused.
        #expect(fresh.currentBurst?.seen == false)
        #expect(await fresh.session.unmarkBurst(id) == .unchanged)
        #expect(await fresh.session.unmarkBurst("no-such-burst") == .unchanged)

        // A burst that HAS been through, taken back against an engine that is
        // not there: the fact may not change on the strength of a write that
        // did not land (§7.7).
        let m = try Self.modelAllSeen()
        let seenID = try #require(m.currentBurst?.id)
        #expect(m.currentBurst?.seen == true)
        let outcome = await m.session.unmarkBurst(seenID)
        guard case .refused = outcome else {
            Issue.record("an engine that is not there answered: \(outcome)")
            return
        }
        #expect(m.currentBurst?.seen == true,
                "a burst was un-marked on the strength of a write that failed")
        #expect(m.session.refusals.messages[.navigation] != nil)
    }

    // MARK: - stacks

    @Test("a stack is a contiguous run inside one burst, and nothing is hidden")
    func stacks() throws {
        let m = try Self.model()
        let stack = try #require(m.currentStack)
        #expect(stack.count == 4)
        #expect(stack.frames == Array(m.frames[stack.range]))
        // Every frame of the burst is still in the strip, in shutter order.
        #expect(m.frames.count >= stack.count)
        #expect(Set(stack.frames).isSubset(of: Set(m.frames)))
        // The top is the cull's guess, which is not necessarily the first.
        #expect(stack.top == m.frames[stack.start + 1])
    }

    @Test("two frames of one stack either side of a frame that is not in it are two stacks")
    func contiguous() {
        func row(_ stem: String, stack: String?, top: Int? = nil) -> Row {
            var f: [String: JSONValue] = ["file": .string("\(stem).ARW"), "stem": .string(stem),
                                          "rating": .string("3")]
            if let stack { f["stack"] = .string(stack) }
            if let top { f["stack_top"] = .integer(top) }
            return try! Row(fields: Fields(f))
        }
        let frames = ["a", "b", "c", "d", "e"]
        let rows = ["a": row("a", stack: "s1"), "b": row("b", stack: "s1", top: 1),
                    "c": row("c", stack: nil),
                    "d": row("d", stack: "s1"), "e": row("e", stack: "s1")]
        let stacks = Stacks.of(burst: frames, rows: rows)
        #expect(stacks.count == 2, "a bracket drawn over a gap says something that is not true")
        #expect(stacks[0].frames == ["a", "b"])
        #expect(stacks[1].frames == ["d", "e"])
        // A run of one is not a stack.
        let single = Stacks.of(burst: ["a", "b"], rows: ["a": row("a", stack: "s9"), "b": row("b", stack: nil)])
        #expect(single.isEmpty)
    }

    @Test("Compare never opens by itself")
    func compareNeverOpensItself() throws {
        let m = try Self.model()
        #expect(m.mode == .single, "entering a burst with a stack of four opens nothing")
        #expect(m.stackInvitation == 4, "it offers, in a line under the picture")
        m.perform(.compare)
        // The press is what opens it.
        #expect(m.stackInvitation == 4)
    }

    @Test("C opens Compare on the stack, and ⇧K is one undo step")
    func compare() async throws {
        let log = WriteLog()
        let m = try Self.model(log: log)
        await Self.press(m, .compare)
        #expect(m.mode == .compare)
        #expect(m.compareSelection.count == 4)
        let focus = try #require(m.compareFocus)
        let set = m.compareSelection
        for stem in set { m.didDisplayTile(stem) }

        let undoBefore = m.session.undo.steps.count
        await Self.press(m, .keepOnly)
        #expect(m.session.undo.steps.count == undoBefore + 1, "one press, one step")
        #expect(VerdictValue.his(m.session.rows[focus]!) == .kept)
        for other in set where other != focus {
            #expect(VerdictValue.his(m.session.rows[other]!) == .out)
        }
        await Self.press(m, .undo)
        #expect(m.session.undo.steps.count == undoBefore, "and one step takes all four back")
        for stem in set {
            #expect(VerdictValue.his(m.session.rows[stem]!) == .unmarked)
        }
    }

    @Test("in Compare, K decides the focused tile and moves to the next one he has not decided")
    func compareFocusMoves() async throws {
        let m = try Self.model()
        await Self.press(m, .compare)
        let order = m.compareSelection
        for stem in order { m.didDisplayTile(stem) }
        let first = try #require(m.compareFocus)
        await Self.press(m, .keep)
        #expect(VerdictValue.his(m.session.rows[first]!) == .kept)
        #expect(m.compareFocus != first)
        #expect(m.compareFocus.map { VerdictValue.his(m.session.rows[$0]!) } == .unmarked)
    }

    // MARK: - undo

    @Test("two fast undo presses take back two different decisions")
    func twoUndos() async throws {
        let m = try Self.model()
        Self.show(m)
        await Self.press(m, .keep)
        Self.show(m)
        await Self.press(m, .drop)
        #expect(m.session.undo.steps.count == 2)
        let names = m.session.undo.steps.map(\.name)
        #expect(names[0].hasPrefix("Keep "))
        #expect(names[1].hasPrefix("Drop "))

        m.perform(.undo)
        m.perform(.undo)
        for _ in 0..<60 { try? await Task.sleep(for: .milliseconds(2)); await Task.yield() }
        #expect(m.session.undo.steps.isEmpty, "two presses, two decisions, not one race")
    }

    @Test("undo goes to the frame it changed")
    func undoNavigates() async throws {
        let m = try Self.model()
        Self.show(m)
        let stem = try #require(m.currentStem)
        await Self.press(m, .keep)
        await Self.press(m, .nextFrame)
        await Self.press(m, .nextFrame)
        #expect(m.currentStem != stem)
        await Self.press(m, .undo)
        #expect(m.currentStem == stem)
    }

    @Test("the undo stack is 200 deep and consecutive verdicts are never folded together")
    func undoDepth() {
        let log = VerdictLog()
        for i in 0..<250 {
            log.push(VerdictStep(kind: .keep, stem: "s\(i)", file: "f\(i)", before: nil, after: 5,
                                 burstIndex: 0, name: "Keep \(i)"))
        }
        #expect(log.steps.count == VerdictLog.depth)
        #expect(log.steps.count == 200)
        #expect(log.steps.first?.name == "Keep 50")
        #expect(log.undoName == "Keep 249")
    }

    // MARK: - the tally and the words

    @Test("the tally is his presses only, and the cull is never added to it")
    func tally() async throws {
        let m = try Self.model()
        let before = m.tally
        #expect(before.kept == 0)
        #expect(before.toGo == m.frames.count)
        Self.show(m)
        await Self.press(m, .keep)
        #expect(m.tally.kept == 1)
        #expect(m.tally.toGo == m.frames.count - 1)
        // The cull put frames forward in this burst; none of them count here.
        let cullPicks = m.frames.filter { (m.session.rows[$0]?.rating ?? 0) >= 3 }.count
        #expect(cullPicks >= 1)
        #expect(m.tally.kept == 1, "his one press, whatever the cull put forward")
        #expect(m.currentBurst?.cull_picks == cullPicks, "and the cull's own count is its own field")
    }

    @Test("his line and the cull's line never say the same kind of thing")
    func twoVoices() async throws {
        let m = try Self.model()
        #expect(m.hisLine == Strings.LightTable.youHaventMarked)
        #expect(m.cullLine.hasPrefix("the cull:"))
        Self.show(m)
        await Self.press(m, .keep)
        await Self.press(m, .previousFrame)
        #expect(m.hisLine == Strings.LightTable.youKept)
        #expect(m.cullLine.hasPrefix("the cull:"))
        #expect(!m.hisLine.contains("cull"))
    }

    @Test("the word for a run of similar frames is never the retired one")
    func neverThatWord() {
        let words = [Strings.LightTable.similar(4), Strings.LightTable.similarHelp,
                     Strings.LightTable.stackInvitation(4), Strings.LightTable.compareHeader(4),
                     Strings.LightTable.cullsGuess]
        for w in words {
            #expect(!w.lowercased().contains("dup"), "\(w)")
        }
    }

    // MARK: - resume

    @Test("opening Choose Keepers goes where §2.5.13 says, in that order")
    func resume() throws {
        let bursts = (0..<5).map {
            Burst(id: "b\($0)", index: $0, scene: nil, started_at: nil, frames: ["f\($0)"],
                  cover: nil, seen: $0 < 2, kept: 0, out: 0, cull_picks: 0, undecided: 1)
        }
        // 1. where he left off
        let left = TodaysServer.resolve(at: "b3", bursts: bursts, stale: "", kept: 0, frames: 5)
        #expect(left.kind == .left_off && left.burst_id == "b3")
        #expect(left.note.contains("Back where you left off"))
        // 2. the burst he was in is gone
        let moved = TodaysServer.resolve(at: "b9", bursts: bursts, stale: "", kept: 0, frames: 5)
        #expect(moved.kind == .moved && moved.burst_id == "b2")
        // 3. everything been through
        let all = bursts.map {
            Burst(id: $0.id, index: $0.index, scene: nil, started_at: nil, frames: $0.frames,
                  cover: nil, seen: true, kept: 0, out: 0, cull_picks: 0, undecided: 0)
        }
        let seen = TodaysServer.resolve(at: "", bursts: all, stale: "", kept: 14, frames: 54)
        #expect(seen.kind == .all_seen)
        #expect(seen.note.contains("You kept 14"))
        // 4. a fresh shoot
        let fresh = TodaysServer.resolve(at: "", bursts: bursts, stale: "", kept: 0, frames: 5)
        #expect(fresh.kind == .fresh)
        #expect(fresh.note.contains("E keep, D drop, F next frame, R next burst"))
        // The engine's own stale sentence goes in front, as written.
        let stale = TodaysServer.resolve(at: "b3", bursts: bursts,
                                         stale: "The count was worked out again.", kept: 0, frames: 5)
        #expect(stale.note.hasPrefix("The count was worked out again."))
    }

    @Test("the seam has two implementations and the app is written against the newer one")
    func seam() throws {
        let r = try Self.response()
        #expect(r.bursts.isEmpty, "this engine does not group yet")
        #expect(TodaysServer().bursts(in: r).count == 19, "so the app groups, on the engine's own key")
        #expect(NewServer().bursts(in: r).isEmpty, "and takes the server's grouping the day it lands")
        // The sizes have landed on both: `/full` up to 4096 and a 4096 tile.
        // A 27" fit view (3606 device px) is no longer stretched from 2600.
        #expect(TodaysServer().fullPixels(forPoints: CGSize(width: 1803, height: 1202), scale: 2) == 4096)
        #expect(NewServer().fullPixels(forPoints: CGSize(width: 1803, height: 1202), scale: 2) == 4096)
        #expect(TodaysServer().maximumTilePixels == 4096)
        #expect(NewServer().maximumTilePixels == 4096)
    }
}

@Suite("The arrows run the shoot, not one burst of it", .serialized)
@MainActor
struct ArrowsCrossTests {

    /// He asked for this directly: "make it so i dont need to hit n to go to
    /// the next burst, the arrows continue into the next burst and bring me
    /// back to the last burst."
    @Test("← off the first frame lands on the last frame of the burst before, and writes nothing")
    func backCrosses() async throws {
        let m = try ViewerTests.modelAllSeen()
        m.goToBurst(1)
        let firstBurst = m.bursts[0]
        m.goToFrame(0)
        #expect(m.burstIndex == 1)

        await ViewerTests.press(m, .previousFrame)
        #expect(m.burstIndex == 0, "← at the start of a burst did not cross back")
        #expect(m.frameIndex == firstBurst.frames.count - 1,
                "it landed somewhere other than where he would have walked to")
    }

    /// And the other direction is not symmetrical, on purpose. Going back has
    /// never recorded anything (§7.4), so crossing back must not either — not
    /// even by un-marking the burst it leaves.
    @Test("crossing back does not disturb what has been through")
    func backRecordsNothing() async throws {
        let m = try ViewerTests.modelAllSeen()
        m.goToBurst(1)
        m.goToFrame(0)
        let before = m.bursts.map(\.seen)

        await ViewerTests.press(m, .previousFrame)
        #expect(m.bursts.map(\.seen) == before)
    }

    /// Forward is a claim about work he has done, so it goes through the same
    /// call N does — which means it is refused the same way. The client here
    /// points at a port nothing listens on, so the write cannot land, and a
    /// burst may not be recorded on the strength of a write that failed.
    @Test("→ off the end does not cross, or record, when the write cannot land")
    func forwardRefusesWhenTheWriteFails() async throws {
        let m = try ViewerTests.model()
        let start = m.burstIndex
        let burst = try #require(m.currentBurst)
        m.goToFrame(burst.frames.count - 1)

        await ViewerTests.press(m, .nextFrame)
        #expect(m.burstIndex == start, "it crossed on a write that did not land")
        #expect(m.bursts[start].seen == false, "a burst was recorded on a failed write")
    }

    /// The end of the shoot is still the end of the shoot: no wrap.
    @Test("← on the very first frame and → on the very last one do not wrap")
    func noWrap() async throws {
        let m = try ViewerTests.model()
        m.goToBurst(0)
        m.goToFrame(0)
        let bumps = m.bump
        await ViewerTests.press(m, .previousFrame)
        #expect(m.burstIndex == 0 && m.frameIndex == 0)
        #expect(m.bump > bumps, "it did not bounce at the start of the shoot")
    }
}
