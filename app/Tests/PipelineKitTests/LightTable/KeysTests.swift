import Foundation
import AppKit
import SwiftUI
import Testing
@testable import PipelineKit

/// An engine that answers every POST with `{"ok": true}` after a delay, and
/// writes down what it was asked. `/api/label` and `/api/review` go through
/// the client, not the verdict queue, so a test of what a reason or a burst
/// crossing sends needs an engine that is there.
final class KeysEngine: URLProtocol, @unchecked Sendable {
    struct Call: Equatable { let path: String; let body: [String: String] }
    nonisolated(unsafe) static var calls: [Call] = []
    nonisolated(unsafe) static var delay: TimeInterval = 0
    static let lock = NSLock()

    static func reset(delay: TimeInterval = 0) {
        lock.withLock { calls = []; self.delay = delay }
    }
    static var recorded: [Call] { lock.withLock { calls } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        var body: [String: String] = [:]
        if let data = request.httpBody ?? request.httpBodyStream.map(Self.read),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in obj { body[k] = "\(v)" }
        }
        let wait = Self.lock.withLock { () -> TimeInterval in
            Self.calls.append(Call(path: path, body: body))
            return Self.delay
        }
        let url = request.url!
        let answer: @Sendable () -> Void = { [self] in
            let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                    headerFields: ["content-type": "application/json"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"ok": true, "seen": 1, "at": ""}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if wait > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + wait, execute: answer)
        } else {
            answer()
        }
    }
    override func stopLoading() {}

    private static func read(_ s: InputStream) -> Data {
        s.open(); defer { s.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }

    static func client() -> StudioClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KeysEngine.self]
        return StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"),
                            session: URLSession(configuration: config))
    }
}

/// What his keys do, press by press, against an engine that is there.
@Suite("His keys land where he means them", .serialized)
@MainActor
struct KeysTests {

    /// The dog shoot of `ViewerTests` — a stack of four in its biggest burst —
    /// with the stack starting `stackAt` frames in, so a test can stand
    /// before it.
    static func response(stackAt offset: Int) throws -> ShootResponse {
        let data = try Fixture.data("shoot")
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try #require(obj["rows"] as? [[String: Any]])
        var byBurst: [String: [Int]] = [:]
        for (i, r) in rows.enumerated() {
            byBurst["\(r["scene"] as? String ?? "")/\(r["burst"] as? String ?? "")", default: []].append(i)
        }
        let biggest = byBurst.max { $0.value.count < $1.value.count }?.value ?? []
        for (n, i) in biggest.enumerated() where (offset..<(offset + 4)).contains(n) {
            rows[i]["stack"] = "s1"
            rows[i]["stack_top"] = n == offset + 1 ? "1" : "0"
        }
        obj["rows"] = rows
        return try JSONDecoder().decode(ShootResponse.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    /// The stacked dog shoot of `ViewerTests`, with a client that answers.
    static func model(log: WriteLog = WriteLog(), delay: TimeInterval = 0, stackAt: Int? = nil) throws -> ViewerModel {
        KeysEngine.reset(delay: delay)
        let pump = ImagePump(budget: .base, loader: { _ in Data() })
        let response = try stackAt.map { try Self.response(stackAt: $0) } ?? ViewerTests.response()
        let session = ShootSession(response: response, ext: nil,
                                   client: KeysEngine.client(), pump: pump,
                                   queue: VerdictQueue(sender: { await log.send($0) }))
        let m = ViewerModel(session: session, navigation: Navigation())
        if let i = session.bursts.firstIndex(where: { b in
            b.frames.contains { session.rows[$0]?.stack != nil }
        }) { m.goToBurst(i) }
        return m
    }

    static func settle(_ ms: Int = 120) async {
        for _ in 0..<(ms / 4) {
            try? await Task.sleep(for: .milliseconds(4))
            await Task.yield()
        }
    }

    // MARK: - the reason after D (§2.5.3)

    @Test("D then 4 labels the frame D put out, and leaves the next frame unmarked")
    func reasonGoesToTheDroppedFrame() async throws {
        let log = WriteLog()
        let m = try Self.model(log: log)
        ViewerTests.show(m)
        let dropped = try #require(m.currentStem)
        await ViewerTests.press(m, .drop)
        // Held up for the test: its three seconds are wall time, and a full
        // run on a busy machine can spend them between two presses.
        m.reasonStripUntil = Date().addingTimeInterval(60)
        let next = try #require(m.currentStem)
        #expect(next != dropped, "D moves on")
        #expect(m.reasonStripStem == dropped, "the strip asks about the frame D put out")
        ViewerTests.show(m)

        await ViewerTests.press(m, .reason(4))
        await Self.settle()
        #expect(m.session.rows[dropped]?.label == DropReason.blur.rawValue, "the frame he meant has no reason")
        #expect(m.session.rows[next]?.label == "", "the frame he has not judged was labelled")
        #expect(m.session.rows[next]?.override == nil, "the frame he has not judged was put out")
        #expect(m.currentStem == next, "a reason for the frame behind him moves nothing")
        #expect(await log.writes.count == 1, "the drop is written once, and nothing else is")
        let labels = KeysEngine.recorded.filter { $0.path == "/api/label" }
        #expect(labels.count == 1)
        #expect(labels.first?.body["file"] == m.session.rows[dropped]?.file)
        #expect(labels.first?.body["label"] == "blur")
        #expect(m.reasonStripUntil == nil, "the strip has had its answer")
    }

    @Test("undo takes back the reason on its own, and the drop is still his")
    func undoTakesBackTheReasonAlone() async throws {
        let m = try Self.model()
        ViewerTests.show(m)
        let dropped = try #require(m.currentStem)
        await ViewerTests.press(m, .drop)
        // This checks undo while the prompt is open, not its wall-clock lifetime.
        // A busy CI runner can spend the three seconds between these presses.
        m.reasonStripUntil = .distantFuture
        ViewerTests.show(m)
        await ViewerTests.press(m, .reason(1))
        await Self.settle()
        let names = m.session.undo.steps.map(\.name)
        #expect(names.last == Strings.Verdict.undoReason("shadow", ShootSession.shortStem(dropped)),
                "the undo step names the frame the reason went to")

        await ViewerTests.press(m, .undo)
        await Self.settle()
        #expect(m.session.rows[dropped]?.label == "")
        #expect(m.session.rows[dropped].map(VerdictValue.his) == .out, "the drop was a step of its own")
        #expect(m.session.undo.steps.count == 1)
    }

    @Test("the reason prompt targets the dropped frame before its deadline, but not at or after it")
    func reasonTargetHonoursItsDeadline() async throws {
        let m = try Self.model()
        ViewerTests.show(m)
        let dropped = try #require(m.currentStem)
        await ViewerTests.press(m, .drop)
        await m.allSettled()
        let deadline = try #require(m.reasonStripUntil)
        #expect(m.reasonTarget(pressedAt: deadline.addingTimeInterval(-0.001)) == dropped)
        #expect(m.reasonTarget(pressedAt: deadline) == nil)
        #expect(m.reasonTarget(pressedAt: deadline.addingTimeInterval(0.001)) == nil)
    }

    @Test("a D that was refused raises no strip")
    func refusedDropAsksNothing() async throws {
        let m = try Self.model()
        // Nothing drawn: the D is refused.
        await ViewerTests.press(m, .drop)
        #expect(m.session.refusals[.verdict] != nil)
        #expect(m.reasonStripUntil == nil)
        #expect(m.reasonStripStem == nil)
    }

    @Test("with no strip up, a digit puts the frame on screen out with that reason and moves on, as D does")
    func digitOutsideTheStrip() async throws {
        let log = WriteLog()
        let m = try Self.model(log: log)
        ViewerTests.show(m)
        let here = try #require(m.currentStem)
        await ViewerTests.press(m, .reason(2))
        await Self.settle()
        #expect(m.session.rows[here]?.label == DropReason.cutOff.rawValue)
        #expect(m.session.rows[here].map(VerdictValue.his) == .out)
        #expect(m.currentStem != here, "it did not move on the way D does")
        #expect(await log.writes.map(\.rating) == [VerdictValue.drop])
    }

    @Test("once the frame D put out has been kept, a digit is about the frame on screen again")
    func strippedTargetKeptSinceIsNotRelabelled() async throws {
        let m = try Self.model()
        ViewerTests.show(m)
        let dropped = try #require(m.currentStem)
        await ViewerTests.press(m, .drop)
        // Back to it, and kept after all, inside the three seconds.
        await ViewerTests.press(m, .previousFrame)
        ViewerTests.show(m)
        await ViewerTests.press(m, .keep)
        #expect(m.session.rows[dropped].map(VerdictValue.his) == .kept)
        #expect(m.reasonTarget() == nil, "a frame he kept is not the strip's to label")
    }

    @Test("a D the engine refuses late, and a digit pressed while its answer was on the way, put nothing out again and label nothing")
    func digitAfterALateRefusal() async throws {
        let log = WriteLog()
        let m = try Self.model(log: log)
        m.goToFrame(0)
        let a = try #require(m.currentRow)
        try #require(VerdictValue.his(a) == .unmarked)
        await log.setDelay(.milliseconds(120))
        await log.setRefuse([a.file])
        ViewerTests.show(m)
        m.perform(.drop)
        await Self.settle(20)
        #expect(m.reasonStripStem == a.stem, "the strip is up for the D, which has not been answered")
        m.perform(.reason(4))
        await Self.settle(400)
        await m.allSettled()
        #expect(m.session.rows[a.stem].map(VerdictValue.his) == .unmarked)
        #expect(m.session.rows[a.stem]?.label == "")
        #expect(await log.writes.filter { $0.file == a.file }.count == 1, "the refused frame was put out again")
        #expect(KeysEngine.recorded.filter { $0.path == "/api/label" }.isEmpty,
                "a reason was written for a frame that is not out")
        #expect(m.reasonStripUntil == nil, "the strip is still asking about a frame that is not out")
        #expect(m.reasonNeedingConfirmation == nil)
    }

    @Test("a D on a kept frame refused late, then a digit, asks nothing about the frame behind him and leaves it kept")
    func digitAfterALateRefusalOnAKeptFrame() async throws {
        let log = WriteLog()
        let m = try Self.model(log: log)
        m.goToFrame(0)
        let a = try #require(m.currentRow)
        ViewerTests.show(m)
        await ViewerTests.press(m, .keep)
        await m.allSettled()
        m.goToFrame(0)
        ViewerTests.show(m)
        try #require(m.session.rows[a.stem].map(VerdictValue.his) == .kept)
        await log.setDelay(.milliseconds(120))
        await log.setRefuse([a.file])
        m.perform(.drop)
        await Self.settle(20)
        m.perform(.reason(4))
        await Self.settle(400)
        await m.allSettled()
        #expect(m.session.rows[a.stem].map(VerdictValue.his) == .kept)
        #expect(m.reasonNeedingConfirmation == nil, "he was asked about the frame behind him")
        #expect(KeysEngine.recorded.filter { $0.path == "/api/label" }.isEmpty)
    }

    @Test("a digit pressed while the strip was up answers it even when it is applied after the strip has gone, behind a crossing")
    func digitIsTimedAtThePress() async throws {
        let (m, i) = try Self.atTheEndOfABurst(delay: 0.2)
        ViewerTests.show(m)
        let a = try #require(m.currentStem)
        m.perform(.drop)                 // the last frame: it stays, and asks why
        await Self.settle(20)
        try #require(m.reasonStripStem == a)
        // The last moment of its three seconds.
        m.reasonStripUntil = Date().addingTimeInterval(0.05)
        m.perform(.nextFrame)            // crossing, with the engine slow to answer
        m.perform(.reason(4))            // pressed while the strip is still up
        await Self.settle(600)
        await m.allSettled()
        #expect(m.burstIndex == i + 1)
        #expect(m.session.rows[a]?.label == DropReason.blur.rawValue, "the frame the strip named has no reason")
        let here = try #require(m.currentStem)
        #expect(m.session.rows[here]?.override == nil, "the first frame of the next burst was put out")
        #expect(m.session.rows[here]?.label == "")
    }

    @Test("in Compare, D then a digit labels the tile D put out, not the tile the focus moved to")
    func compareReason() async throws {
        let m = try Self.model()
        await ViewerTests.press(m, .compare)
        #expect(m.mode == .compare)
        for stem in m.compareSelection { m.didDisplayTile(stem) }
        let dropped = try #require(m.compareFocus)
        await ViewerTests.press(m, .drop)
        let focus = try #require(m.compareFocus)
        #expect(focus != dropped)
        await ViewerTests.press(m, .reason(4))
        await Self.settle()
        #expect(m.session.rows[dropped]?.label == DropReason.blur.rawValue)
        #expect(m.session.rows[focus]?.label == "")
        #expect(m.session.rows[focus].map(VerdictValue.his) == .unmarked)
    }

    // MARK: - → past the end of a burst (§2.5.3, §2.5.13)

    /// A burst that has another after it with at least two frames, and the
    /// model standing on its last frame.
    static func atTheEndOfABurst(log: WriteLog = WriteLog(), delay: TimeInterval = 0) throws -> (ViewerModel, Int) {
        let m = try model(log: log, delay: delay)
        let i = try #require(m.bursts.indices.first { $0 + 1 < m.bursts.count && m.bursts[$0 + 1].frames.count >= 2 })
        m.goToBurst(i)
        m.goToFrame(m.frames.count - 1)
        return (m, i)
    }

    static func reviews() -> [KeysEngine.Call] { KeysEngine.recorded.filter { $0.path == "/api/review" } }

    @Test("→ twice at the end of a burst, with the engine slow to answer, finishes it once and the second → moves on in the next")
    func crossingIsAwaited() async throws {
        let (m, i) = try Self.atTheEndOfABurst(delay: 0.06)
        m.perform(.nextFrame)
        m.perform(.nextFrame)
        await Self.settle(400)
        #expect(Self.reviews().count == 1, "the burst was recorded as been through \(Self.reviews().count) times")
        let finishes = m.session.undo.steps.filter { if case .finishBurst = $0.kind { true } else { false } }
        #expect(finishes.map(\.name) == [Strings.Verdict.undoFinishBurst(i + 1)],
                "one undo step, named for the burst he left")
        #expect(m.burstIndex == i + 1)
        #expect(m.frameIndex == 1, "the second press went nowhere")
    }

    @Test("a K pressed straight after → at the end of a burst is never taken on the frame he is leaving")
    func keepAfterCrossing() async throws {
        let log = WriteLog()
        let (m, i) = try Self.atTheEndOfABurst(log: log, delay: 0.06)
        let leaving = try #require(m.currentRow)
        ViewerTests.show(m)
        m.perform(.nextFrame)
        m.perform(.keep)
        await Self.settle(400)
        #expect(m.burstIndex == i + 1)
        #expect(await log.writes.allSatisfy { $0.file != leaving.file },
                "the K was written on the last frame of the burst he had just left")
        #expect(m.session.rows[leaving.stem]?.override == nil)
    }

    @Test("⌘Z after → crossed a burst takes him back to the frame he crossed from, and takes the burst back off")
    func undoACrossing() async throws {
        let (m, i) = try Self.atTheEndOfABurst()
        let from = try #require(m.currentStem)
        await ViewerTests.press(m, .nextFrame)
        await Self.settle()
        #expect(m.burstIndex == i + 1)
        #expect(m.bursts[i].seen)
        await ViewerTests.press(m, .undo)
        await Self.settle()
        #expect(m.burstIndex == i)
        #expect(m.currentStem == from, "⌘Z went to the burst's first frame, not the one he left from")
        #expect(!m.bursts[i].seen)
    }

    @Test("a held → runs to the end of the burst and stops there with one bounce, and records nothing")
    func heldArrowStaysInTheBurst() async throws {
        let (m, i) = try Self.atTheEndOfABurst()
        m.goToFrame(0)
        let bumps = m.bump
        for _ in 0..<(m.frames.count + 6) { m.performHeldMove(forward: true) }
        await Self.settle(200)
        #expect(m.burstIndex == i, "a key that was only still down crossed the burst")
        #expect(m.frameIndex == m.frames.count - 1)
        #expect(m.bump == bumps + 1, "one bounce for the hold, not one per refresh")
        #expect(Self.reviews().isEmpty)
        // A fresh press crosses.
        await ViewerTests.press(m, .nextFrame)
        await Self.settle()
        #expect(m.burstIndex == i + 1)
    }

    @Test("a held ← goes on back into the burst before, recording nothing, and bounces once at the start of the shoot")
    func heldBackArrowCrosses() async throws {
        let (m, i) = try Self.atTheEndOfABurst()
        m.goToBurst(i + 1)
        m.goToFrame(0)
        m.performHeldMove(forward: false)
        await Self.settle(60)
        #expect(m.burstIndex == i, "a held ← stopped at the start of the burst")
        #expect(m.frameIndex == m.frames.count - 1, "it lands where walking back would have")
        #expect(Self.reviews().isEmpty)
        m.goToBurst(0)
        m.goToFrame(0)
        let bumps = m.bump
        for _ in 0..<6 { m.performHeldMove(forward: false) }
        await Self.settle(60)
        #expect(m.burstIndex == 0 && m.frameIndex == 0)
        #expect(m.bump == bumps + 1, "one bounce for the hold, not one per refresh")
    }

    // MARK: - Compare (§2.5.12)

    @Test("C with frames he ⌘-clicked opens Compare on exactly those, and calls them frames, not similar")
    func comparePickedFrames() async throws {
        let m = try Self.model(stackAt: 2)
        m.goToFrame(0)
        let picked = [m.frames[0], m.frames[m.frames.count - 1]]
        m.compareSelection = picked
        #expect(m.canCompare, "the menu row, the button and the segment are live for his set")
        #expect(m.pickedLine == Strings.LightTable.pickedForCompare(2))
        await ViewerTests.press(m, .compare)
        #expect(m.mode == .compare)
        #expect(m.compareSelection == picked, "his set was thrown away for the stack")
        #expect(m.compareHeader == Strings.LightTable.comparePicked(2))
        await ViewerTests.press(m, .leave)
        #expect(m.mode == .single)
        #expect(m.compareSelection.isEmpty)
    }

    @Test("Esc clears the frames he was picking")
    func escClearsThePickedSet() async throws {
        let m = try Self.model(stackAt: 2)
        m.compareSelection = [m.frames[0]]
        await ViewerTests.press(m, .leave)
        #expect(m.compareSelection.isEmpty)
        #expect(m.pickedLine == nil)
    }

    @Test("⌘-click on a picked frame takes it out of the set, and a plain click goes to a frame and puts the set down")
    func pickingFollowsTheFilmstrip() throws {
        let m = try Self.model()
        try #require(m.frames.count >= 6)
        let strip = FilmstripView(model: m)
        strip.refresh()
        m.goToFrame(0)
        // The frame he is on starts the set, so one ⌘-click is a pair.
        strip.press(2, clicks: 1, modifiers: .command)
        strip.press(4, clicks: 1, modifiers: .command)
        #expect(m.compareSelection == [m.frames[0], m.frames[2], m.frames[4]])
        strip.press(2, clicks: 1, modifiers: .command)
        #expect(m.compareSelection == [m.frames[0], m.frames[4]], "the frame he took out is still in the set C compares")

        strip.press(1, clicks: 1, modifiers: [])
        #expect(m.frameIndex == 1, "a plain click goes to the frame")
        #expect(m.compareSelection.isEmpty, "a plain click left a set waiting unseen for C")
        strip.press(5, clicks: 1, modifiers: .command)
        #expect(m.compareSelection == [m.frames[1], m.frames[5]],
                "the next ⌘-click built its set out of the one he had put down")
    }

    @Test("C before the stack the invitation names goes to its top frame and opens it; past it, the invitation is gone")
    func invitationOpensItsStack() async throws {
        let m = try Self.model(stackAt: 1)
        m.goToFrame(0)
        let stack = try #require(m.invitedStack)
        try #require(stack.range.upperBound < m.frames.count, "a frame past the stack to stand on")
        #expect(m.currentStack == nil, "frame 1 is not in the stack")
        #expect(m.stackInvitation == 4, "it offers from before the stack")
        #expect(m.canCompare)
        await ViewerTests.press(m, .compare)
        #expect(m.mode == .compare, "C bounced")
        #expect(m.compareSelection == stack.frames)
        #expect(m.compareFocus == stack.top, "it opens on the cull's guess")
        #expect(m.compareHeader == Strings.LightTable.compareHeader(4))

        await ViewerTests.press(m, .single)
        m.goToFrame(stack.range.upperBound)
        #expect(m.stackInvitation == nil, "past the stack there is nothing for it to open")
        #expect(!m.canCompare)
    }

    @Test("the invitation, clicked, opens the stack it names from anywhere before it")
    func invitationClicked() async throws {
        let m = try Self.model(stackAt: 2)
        m.goToFrame(1)
        m.compareInvitedStack()
        #expect(m.mode == .compare)
        #expect(m.compareSelection == m.invitedStack?.frames)
    }

    @Test("N, P or a burst chosen on the scrubber while comparing closes Compare, and the next K is in the burst he went to")
    func compareClosesOnAnotherBurst() async throws {
        let log = WriteLog()
        let m = try Self.model(log: log)
        let burst = m.burstIndex
        await ViewerTests.press(m, .compare)
        #expect(m.mode == .compare)
        m.goToBurst(burst == 0 ? 1 : 0)
        #expect(m.mode == .single, "Compare stayed open on the burst he had left")
        #expect(m.compareSelection.isEmpty)
        ViewerTests.show(m)
        let here = try #require(m.currentStem)
        await ViewerTests.press(m, .keep)
        #expect(m.session.rows[here].map(VerdictValue.his) == .kept)
        #expect(m.burstIndex == (burst == 0 ? 1 : 0), "the K pulled him back to the burst he had left")
    }

    // MARK: - Z (§2.5.7)

    @Test("Z goes to 1:1 and Z again back to Fit, while ⌘0 stays at 1:1")
    func zToggles() async throws {
        let m = try Self.model()
        m.viewport = CGSize(width: 1084, height: 542)
        #expect(m.zoom.isFit)
        _ = m.key(KeyMap.Press("z"))
        await Self.settle(40)
        #expect(!m.zoom.isFit, "Z did not zoom in")
        _ = m.key(KeyMap.Press("z"))
        await Self.settle(40)
        #expect(m.zoom.isFit, "Z at 1:1 stayed at 1:1")
        _ = m.key(KeyMap.Press("0", command: true))
        _ = m.key(KeyMap.Press("0", command: true))
        await Self.settle(40)
        #expect(!m.zoom.isFit, "⌘0 is 1:1 however often it is pressed")
    }

    // MARK: - the burst scrubber (§2.5.10)

    @Test("a move inside a burst leaves every scrubber segment as it was, and a change of burst changes two")
    func scrubberRedrawsOnlyWhatChanged() async throws {
        let m = try Self.model()
        let before = BurstScrubber.segments(m.bursts, current: m.burstIndex)
        await ViewerTests.press(m, .nextFrame)
        #expect(BurstScrubber.segments(m.bursts, current: m.burstIndex) == before,
                "a frame move redraws the whole strip")
        let from = m.burstIndex
        m.goToBurst(from == 0 ? 1 : from - 1)
        let after = BurstScrubber.segments(m.bursts, current: m.burstIndex)
        #expect(zip(before, after).filter { $0 != $1 }.count == 2, "only the burst he left and the one he is in")
    }

    // MARK: - his reason and the cull's (§2.13)

    @Test("the reason he gives is said in his line, and the cull is never credited with it")
    func hisReasonIsHis() async throws {
        let m = try Self.model()
        ViewerTests.show(m)
        let dropped = try #require(m.currentStem)
        await ViewerTests.press(m, .drop)
        ViewerTests.show(m)
        await ViewerTests.press(m, .reason(1))
        await Self.settle()
        let row = try #require(m.session.rows[dropped])
        #expect(m.hisLine(for: row) == Strings.LightTable.youPutOutBecause("shadow"))
        #expect(!m.cullLine(for: row).contains("shadow"), "his reason was printed as the cull's")
        #expect(ViewerModel.cullFault(row) == nil || row.rating == 0)
    }

    @Test("a frame the cull put aside for a fault it named says so, in the report's words")
    func cullsOwnFault() throws {
        let m = try Self.model()
        let row = try #require(m.session.rows.values.first { $0.rating == 0 && ($0.reason ?? "") == "blown highlights" })
        #expect(m.cullLine(for: row) == Strings.LightTable.cullFault(Strings.Cull.reasonWord("blown highlights")))
        let aside = try #require(m.session.rows.values.first { $0.rating == 1 })
        #expect(m.cullLine(for: aside) == Strings.LightTable.cullAside, "only a 0 is a fault it named")
    }

    /// How wide a line is set in one of the bar's two text styles, in points.
    static func width(_ s: String, _ style: NSFont.TextStyle, digits: Bool = false) -> CGFloat {
        let base = NSFont.preferredFont(forTextStyle: style)
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: base.pointSize, weight: .regular) : base
        return (s as NSString).size(withAttributes: [.font: font]).width
    }

    @Test("at the default window the tally and the cull's named fault fit beside the cluster, shrunk no further than they may be")
    func captionsFitAtTheDefaultWindow() throws {
        let bar = ControlBarLayout(contentWidth: 1100)
        try #require(bar.showsSideCaptions)
        // The tally's two-figure worst plausible burst, in both of its forms.
        for tally in [Strings.LightTable.tallyAgreed(kept: 32, out: 12, agreed: 16),
                      Strings.LightTable.tally(kept: 32, out: 12, toGo: 16)] {
            #expect(Self.width(tally, .callout, digits: true) * 0.84 <= bar.trailingTally.width,
                    "\"\(tally)\" is cut even at its smallest")
        }
        // Every fault the cull names, in the words the light table uses.
        for raw in ["blown highlights", "nothing in focus", "eyes closed", "cut off", "mid-word",
                    "face in the dark", "blown face", "too dark"] {
            let line = Strings.LightTable.cullFault(Strings.Cull.reasonWord(raw))
            #expect(Self.width(line, .footnote) * 0.8 <= bar.leadingCaption.width,
                    "\"\(line)\" is cut at the default window")
        }
    }

    // MARK: - the end of a burst, and of the shoot (§2.5.2, §2.5.13)

    @Test("↓ on the last frame goes to the frame he hasn't marked, as the end line says")
    func downGoesToTheUnmarked() async throws {
        let m = try Self.model()          // the biggest burst, nothing marked
        try #require(m.frames.count > 2 && !m.isLastBurst)
        m.goToFrame(m.frames.count - 1)
        let unmarked = try #require(m.unmarkedInBurst)
        try #require(unmarked != m.frameIndex)
        #expect(m.endOfBurstLine?.contains("Next burst: F or R (→, N)") == true)
        let bumps = m.bump
        await ViewerTests.press(m, .nextPick)
        #expect(m.frameIndex == unmarked)
        #expect(m.bump == bumps, "↓ bounced")
    }

    @Test("the end line offers the frames he hasn't marked only in a burst he hasn't been through, and counts them")
    func unmarkedLinkOnlyWhenTheyAreWork() async throws {
        let (m, i) = try Self.atTheEndOfABurst()
        let toGo = m.tally.toGo
        try #require(toGo > 0)
        #expect(m.unmarkedLink != nil)
        #expect(Strings.LightTable.goToUnmarked(toGo).contains(toGo == 1 ? "the one" : "the first"))
        await ViewerTests.press(m, .nextFrame)
        await Self.settle()
        m.goToBurst(i)
        m.goToFrame(m.frames.count - 1)
        #expect(m.currentBurst?.seen == true)
        #expect(m.unmarkedLink == nil, "a link called agreed frames unmarked")
        #expect(m.endOfBurstLine?.contains("agreed") == true)
    }

    @Test("on the last burst, → off the last frame and Continue record it once, and → then only bounces")
    func theLastBurst() async throws {
        let m = try Self.model()
        m.goToBurst(m.bursts.count - 1)
        m.goToFrame(m.frames.count - 1)
        #expect(m.canFinishBurst, "the last burst is his to finish")
        await ViewerTests.press(m, .nextFrame)
        await Self.settle()
        #expect(m.currentBurst?.seen == true)
        #expect(Self.reviews().count == 1)
        #expect(!m.canFinishBurst)
        let bumps = m.bump
        await ViewerTests.press(m, .nextFrame)
        await ViewerTests.press(m, .nextFrame)
        #expect(Self.reviews().count == 1, "the last burst was recorded again")
        #expect(m.bump == bumps + 2)
        #expect(await m.finishBeforeContinuing(), "Continue goes on")
        #expect(Self.reviews().count == 1)
    }

    @Test("Continue on the last burst records it before going on")
    func continueRecords() async throws {
        let m = try Self.model()
        m.goToBurst(m.bursts.count - 1)
        #expect(m.currentBurst?.seen == false)
        #expect(await m.finishBeforeContinuing())
        #expect(m.currentBurst?.seen == true)
        #expect(Self.reviews().count == 1)
    }

    @Test("⌘] on the last frame of a last burst he has not finished records it, then goes on as Continue does; anywhere else it only goes on")
    func nextStepRecordsTheLastBurst() async throws {
        let m = try Self.model()
        let (host, app) = try GoMenuTests.host(selection: .step(shoot: m.session.name, step: "keepers"))
        LightTableCommands.attach(m, center: host.center)
        defer { LightTableCommands.detach(m, center: host.center) }

        // The end of a burst that is not the last: leaving from there is not
        // going through it, and records nothing.
        m.goToFrame(m.frames.count - 1)
        try #require(!m.isLastBurst && m.currentBurst?.seen == false)
        #expect(!m.nextStepFinishesTheShoot)
        #expect(host.center.run(CommandTable.ID.nextStep))
        #expect(app.navigation.step == "presets", "⌘] goes on at once")
        await Self.settle()
        #expect(Self.reviews().isEmpty, "a burst he left was recorded as been through")

        // The last frame of the last burst, where the line offers ⌘]:
        // recorded, then on.
        app.navigation.selection = .step(shoot: m.session.name, step: "keepers")
        m.goToBurst(m.bursts.count - 1)
        m.goToFrame(m.frames.count - 1)
        #expect(m.nextStepFinishesTheShoot)
        #expect(host.center.run(CommandTable.ID.nextStep))
        await Self.settle()
        #expect(m.currentBurst?.seen == true, "the key the line offers left the last burst unrecorded")
        #expect(Self.reviews().count == 1)
        #expect(app.navigation.step == "presets")

        // Once it has been through, ⌘] only goes on.
        app.navigation.selection = .step(shoot: m.session.name, step: "keepers")
        #expect(!m.nextStepFinishesTheShoot)
        #expect(host.center.run(CommandTable.ID.nextStep))
        await Self.settle()
        #expect(Self.reviews().count == 1)
        #expect(app.navigation.step == "presets")
    }

    @Test("in a burst he has been through the tally says agreed, not to go")
    func tallyAgreed() async throws {
        let m = try ViewerTests.modelAllSeen()
        let t = m.tally
        #expect(m.tallyText == Strings.LightTable.tallyAgreed(kept: t.kept, out: t.out, agreed: t.toGo))
        let fresh = try Self.model()
        #expect(fresh.tallyText.hasSuffix("left"))
    }

    // MARK: - the toolbar's modes (§2.3)

    static func segments(in view: NSView) -> NSSegmentedControl? {
        if let s = view as? NSSegmentedControl { return s }
        for v in view.subviews { if let s = segments(in: v) { return s } }
        return nil
    }

    @Test("each mode's segment names itself and its key, and Compare with nothing to open goes back to Single")
    func modePicker() async throws {
        let m = try Self.model()
        let session = m.session
        let plain = try #require(m.bursts.firstIndex { b in !b.frames.contains { session.rows[$0]?.stack != nil } })
        m.goToBurst(plain)
        #expect(!m.canCompare)
        let host = NSHostingView(rootView: ModePicker(model: m))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 60), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await Self.settle(40)
        let control = try #require(Self.segments(in: host))
        // S is the previous frame from here; Esc is the way back to Single.
        #expect(control.toolTip(forSegment: 0) == "Single (⎋)")
        #expect(control.toolTip(forSegment: 1) == Strings.LightTable.compareNothingHere)
        #expect(control.toolTip(forSegment: 2) == "All Bursts (G)")

        let bumps = m.bump
        control.selectedSegment = 1
        _ = control.sendAction(control.action, to: control.target)
        await Self.settle(80)
        host.layoutSubtreeIfNeeded()
        #expect(m.mode == .single)
        #expect(m.bump != bumps, "it bounces, as C does")
        #expect(control.selectedSegment == 0, "the segment stayed lit on Compare with one frame on the table")

        // In All Bursts too Esc is the way back, and S the previous cover:
        // the tag names the same key in every view.
        m.mode = .allBursts
        await Self.settle(40)
        host.layoutSubtreeIfNeeded()
        #expect(control.toolTip(forSegment: 0) == "Single (⎋)")
    }

    // MARK: - ? (§2.5.3)

    @Test("? opens what Help ▸ Keyboard Shortcuts opens")
    func questionMarkOpensTheShortcuts() async throws {
        let m = try Self.model()
        let center = CommandCenter.shared
        let wasThere = center.isRegistered(CommandTable.ID.shortcuts)
        final class Opened: @unchecked Sendable { var count = 0 }
        let opened = Opened()
        center.register(CommandTable.ID.shortcuts) { opened.count += 1 }
        defer { if !wasThere { center.unregister(CommandTable.ID.shortcuts) } }
        _ = m.key(KeyMap.Press("?", shift: true))
        await Self.settle(40)
        #expect(opened.count == 1, "? did nothing")
    }

    // MARK: - where he left off (§2.5.13)

    /// The dog shoot with the given frames of its first unfinished burst
    /// marked, opened afresh.
    static func reopened(marking picks: (Burst) -> [String]) throws -> (ViewerModel, Burst) {
        let plain = try Self.model()
        let first = try #require(plain.bursts.first { !$0.seen && $0.frames.count >= 6 })
        let marked = picks(first)
        let data = try Fixture.data("shoot")
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Where he was, as the engine records it: that burst.
        obj["review"] = ["at": first.id, "bursts": [String: Any](), "stale": ""]
        var rows = try #require(obj["rows"] as? [[String: Any]])
        for i in rows.indices where first.frames.contains(rows[i]["stem"] as? String ?? "") {
            rows[i]["override"] = marked.contains(rows[i]["stem"] as? String ?? "") ? 3 : NSNull()
        }
        obj["rows"] = rows
        let response = try JSONDecoder().decode(ShootResponse.self, from: JSONSerialization.data(withJSONObject: obj))
        let session = ShootSession(response: response, ext: nil, client: KeysEngine.client(),
                                   pump: ImagePump(budget: .base, loader: { _ in Data() }),
                                   queue: VerdictQueue(sender: { _ in .success(RatingResult(ok: true, key_note: "")) }))
        return (ViewerModel(session: session, navigation: Navigation()), first)
    }

    @Test("reopening a burst he had not finished lands after the furthest frame he marked, not on frame 1 and not back at the first he left alone")
    func resumeWhereHeGotTo() throws {
        // Everything decided up to frame 2.
        let (m, first) = try Self.reopened { Array($0.frames.prefix(2)) }
        #expect(m.currentBurst?.id == first.id)
        #expect(m.frameIndex == 2, "it reopened on frame \(m.frameIndex + 1), not where he had got to")
        // His way: K on the keepers and walk past the rest. Frames 2 and 5
        // kept; 1, 3 and 4 were looked at and left.
        let (k, _) = try Self.reopened { [$0.frames[1], $0.frames[4]] }
        #expect(k.frameIndex == 5, "it reopened on frame \(k.frameIndex + 1), behind where he had got to")
        // Marked to the end: the last frame, where the line says what is left.
        let (end, burst) = try Self.reopened { [$0.frames[1], $0.frames.last!] }
        #expect(end.frameIndex == burst.frames.count - 1)
        // Nothing marked: its first frame.
        let (none, _) = try Self.reopened { _ in [] }
        #expect(none.frameIndex == 0)
    }

    // MARK: - a refusal that has gone stale (§2.5.4)

    @Test("\"Still opening this frame.\" goes when he moves off the frame it was about; a refused write stays")
    func staleRefusalGoes() async throws {
        let log = WriteLog()
        let m = try Self.model(log: log)
        await ViewerTests.press(m, .keep)
        #expect(m.session.refusals[.verdict] == Strings.Verdict.stillOpening)
        await ViewerTests.press(m, .nextFrame)
        #expect(m.session.refusals[.verdict] == nil, "it stayed up, untrue, over a frame that was open")

        // The engine refusing a write is about the frame, not about where he is.
        let here = try #require(m.currentRow)
        await log.setRefuse([here.file])
        ViewerTests.show(m)
        await ViewerTests.press(m, .keep)
        await Self.settle()
        let refusal = try #require(m.session.refusals[.verdict])
        await ViewerTests.press(m, .nextFrame)
        #expect(m.session.refusals[.verdict] == refusal)
    }

    // MARK: - Settings ▸ Choosing (§2.11)

    /// A store of its own, thrown away after, so no test reads or writes the
    /// defaults of anything real.
    static func settings() -> (SettingsStore, () -> Void) {
        let name = "keys-settings-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (SettingsStore(defaults: d), { d.removePersistentDomain(forName: name) })
    }

    @Test("with Space set to go to the next burst, Space finishes the burst as N does and opens nothing")
    func spaceGoesOn() async throws {
        let (store, done) = Self.settings(); defer { done() }
        let (m, i) = try Self.atTheEndOfABurst()
        m.settings = store
        _ = m.key(KeyMap.Press(key: .space))
        await Self.settle()
        #expect(m.fullImage, "on, the default, Space is Full Image")
        _ = m.key(KeyMap.Press(key: .space))
        await Self.settle()
        #expect(!m.fullImage)
        store.spaceShowsWholePicture = false
        _ = m.key(KeyMap.Press(key: .space))
        await Self.settle()
        #expect(!m.fullImage)
        #expect(m.burstIndex == i + 1)
        #expect(m.bursts[i].seen)
        #expect(Self.reviews().count == 1)
    }

    @Test("with the reasons strip turned off, D raises no strip")
    func stripOff() async throws {
        let (store, done) = Self.settings(); defer { done() }
        let m = try Self.model()
        m.settings = store
        store.reasonsStripAfterDrop = false
        ViewerTests.show(m)
        await ViewerTests.press(m, .drop)
        #expect(m.reasonStripStem == nil)
        #expect(m.reasonStripUntil == nil)
    }

    @Test("by default K or D on the last frame finishes the burst and opens the next, as → does; Stay here stays")
    func goOnAfterTheLastFrame() async throws {
        let (store, done) = Self.settings(); defer { done() }
        let (m, i) = try Self.atTheEndOfABurst()
        m.settings = store
        #expect(store.afterLastFrameGoesOn, "going on is the default")
        ViewerTests.show(m)
        await ViewerTests.press(m, .drop)
        await Self.settle()
        #expect(m.burstIndex == i + 1, "D on the last frame stopped dead, and he had to press N")
        #expect(m.frameIndex == 0)
        #expect(m.bursts[i].seen, "the burst is recorded as looked through, exactly as N records it")
        #expect(Self.reviews().count == 1)
        #expect(m.reasonStripStem != nil, "the strip still asks about the frame D put out")

        // One press, one undo: Q takes back the mark and the burst's record
        // together, and puts him back on the frame. It used to take two, the
        // first only going back to the frame with it still out.
        let dropped = try #require(m.bursts[i].frames.last)
        #expect(m.session.undo.undoName == Strings.Verdict.undoDrop(ShootSession.shortStem(dropped)),
                "the menu names what he pressed")
        #expect(m.key(KeyMap.Press("q")))
        await Self.settle()
        #expect(m.burstIndex == i)
        #expect(m.currentStem == dropped)
        #expect(m.session.rows[dropped].map(VerdictValue.his) == .unmarked, "the drop is still on the frame")
        #expect(!m.bursts[i].seen, "the burst is still recorded as looked through")
        #expect(!m.session.undo.canUndo)
        // And one ⇧⌘Z puts both back, in the next burst again.
        _ = m.key(KeyMap.Press("z", command: true, shift: true))
        await Self.settle()
        #expect(m.session.rows[dropped].map(VerdictValue.his) == .out)
        #expect(m.bursts[i].seen)
        #expect(m.burstIndex == i + 1)
        #expect(!m.session.undo.canRedo)
        #expect(m.session.undo.steps.count == 2)
        #expect(Self.reviews().count == 3)
        // K on the last frame, going on: one Q again.
        #expect(m.key(KeyMap.Press("q")))
        await Self.settle()
        m.goToFrame(m.frames.count - 1)
        ViewerTests.show(m)
        await ViewerTests.press(m, .keep)
        await Self.settle()
        #expect(m.burstIndex == i + 1)
        #expect(m.key(KeyMap.Press("q")))
        await Self.settle()
        #expect(m.burstIndex == i)
        #expect(m.session.rows[dropped].map(VerdictValue.his) == .unmarked)
        #expect(!m.bursts[i].seen)
        #expect(!m.session.undo.canUndo)

        store.afterLastFrameGoesOn = false
        let reviews = Self.reviews().count
        m.goToFrame(m.frames.count - 1)
        ViewerTests.show(m)
        await ViewerTests.press(m, .keep)
        await Self.settle()
        #expect(m.burstIndex == i, "Stay here went on")
        #expect(m.isLastFrameOfBurst)
        #expect(Self.reviews().count == reviews)
    }

    @Test("a verdict the engine refuses after it went on leaves the crossing an undo of its own; Q never reaches past it")
    func refusedVerdictThatWentOn() async throws {
        let (store, done) = Self.settings(); defer { done() }
        let log = WriteLog()
        let m = try Self.model(log: log)
        m.settings = store
        let i = try #require(m.bursts.indices.first { $0 + 1 < m.bursts.count && m.bursts[$0].frames.count >= 2 })
        m.goToBurst(i)
        // A keep of his on the frame before, which no undo of this press may take.
        m.goToFrame(m.frames.count - 2)
        let before = try #require(m.currentStem)
        ViewerTests.show(m)
        await ViewerTests.press(m, .keep)
        await Self.settle()
        let last = try #require(m.currentRow)
        await log.setRefuse([last.file])
        ViewerTests.show(m)
        await ViewerTests.press(m, .keep)
        await Self.settle()
        #expect(m.burstIndex == i + 1)
        #expect(m.session.rows[last.stem].map(VerdictValue.his) == .unmarked, "the refused keep was left on")
        #expect(m.key(KeyMap.Press("q")))
        await Self.settle()
        #expect(!m.bursts[i].seen)
        #expect(m.session.rows[before].map(VerdictValue.his) == .kept, "one Q took back a keep it had nothing to do with")
        #expect(m.session.undo.steps.count == 1)
    }

    @Test("K on the last frame of the last burst records it and stays, where the line offers Presets")
    func keepOnTheVeryLastFrame() async throws {
        let (store, done) = Self.settings(); defer { done() }
        let m = try Self.model()
        m.settings = store
        m.goToBurst(m.bursts.count - 1)
        m.goToFrame(m.frames.count - 1)
        ViewerTests.show(m)
        await ViewerTests.press(m, .keep)
        await Self.settle()
        #expect(m.currentBurst?.seen == true)
        #expect(Self.reviews().count == 1)
        #expect(m.navigation.step == nil || m.navigation.step == "keepers", "a verdict took him off the page")
        #expect(m.endOfBurstLine != nil)
    }

    @Test("N on the last burst finishes it and goes on to Presets; finished already, it only goes on")
    func nextBurstOnTheLastGoesToPresets() async throws {
        let m = try Self.model()
        m.navigation.selection = .step(shoot: m.session.name, step: "keepers")
        m.goToBurst(m.bursts.count - 1)
        #expect(m.nextBurstLeavesForPresets)
        #expect(m.canGoToNextBurst)
        await ViewerTests.press(m, .nextBurst)
        await Self.settle()
        #expect(m.currentBurst?.seen == true, "the last burst was left unrecorded")
        #expect(Self.reviews().count == 1)
        #expect(m.navigation.step == "presets")

        m.navigation.selection = .step(shoot: m.session.name, step: "keepers")
        #expect(!m.canFinishBurst)
        #expect(m.canGoToNextBurst, "N there still goes somewhere")
        await ViewerTests.press(m, .nextBurst)
        await Self.settle()
        #expect(Self.reviews().count == 1, "the last burst was recorded a second time")
        #expect(m.navigation.step == "presets")

        // From Full Image it goes on too, and puts Full Image down, so
        // coming back is coming back to the table.
        m.navigation.selection = .step(shoot: m.session.name, step: "keepers")
        m.setFullImage(true)
        await ViewerTests.press(m, .nextBurst)
        await Self.settle()
        #expect(m.navigation.step == "presets")
        #expect(!m.fullImage, "Full Image was left up behind Presets")

        // In All Bursts N goes to a burst not looked through, and never
        // leaves the page.
        m.navigation.selection = .step(shoot: m.session.name, step: "keepers")
        m.mode = .allBursts
        #expect(!m.nextBurstLeavesForPresets)
        // Live on the last cover, looked through, while another burst is
        // still to do: N goes to it. It was greyed there.
        #expect(m.bursts.contains { !$0.seen })
        #expect(m.canGoToNextBurst, "Next Burst was grey with bursts still to look through")
        await ViewerTests.press(m, .nextBurst)
        await Self.settle()
        #expect(m.navigation.step == "keepers")

        // With every burst looked through there is nowhere for it to go, from
        // any cover, as the control bar's table says.
        for b in m.bursts.indices where !m.bursts[b].seen {
            m.session.go(burst: b)
            #expect(await m.session.finishBurst() == .applied)
        }
        for b in m.bursts.indices {
            m.goToBurst(b)
            #expect(!m.canGoToNextBurst, "Next Burst live on cover \(b) with nothing left to go to")
        }
    }

    @Test("with large stacks opening in Compare, arriving in one opens it once; Esc out of it stays out")
    func largeStackOpensItself() async throws {
        let (store, done) = Self.settings(); defer { done() }
        let m = try Self.model(stackAt: 1)
        m.settings = store
        m.goToFrame(0)
        try #require(m.currentStack == nil)
        await ViewerTests.press(m, .nextFrame)
        #expect(m.mode == .single, "it opened by itself with the setting off")
        await ViewerTests.press(m, .previousFrame)

        store.openLargeStacksInCompare = true
        await ViewerTests.press(m, .nextFrame)
        #expect(m.mode == .compare)
        #expect(m.compareSelection.count == 4)
        await ViewerTests.press(m, .leave)
        #expect(m.mode == .single)
        await ViewerTests.press(m, .nextFrame)
        #expect(m.mode == .single, "Esc out of it was undone by the next arrow")
    }

    /// A key as AppKit hands it over, held down or not.
    static func keyDown(_ c: String, code: UInt16, repeat held: Bool) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: c, charactersIgnoringModifiers: c,
                         isARepeat: held, keyCode: code)
    }

    @Test("K and N held down through the bar's own shortcuts are one press each, as on the photograph, even with Go to the next burst chosen")
    func heldKeysThroughTheBar() async throws {
        let (store, done) = Self.settings()
        defer { done() }
        store.afterLastFrameGoesOn = true
        let (m, i) = try Self.atTheEndOfABurst()
        m.settings = store
        ViewerTests.show(m)
        // The first K is a press; AppKit's repeats of it are not.
        m.currentEvent = { Self.keyDown("k", code: 40, repeat: false) }
        m.perform(.keep)
        await Self.settle()
        #expect(m.burstIndex == i + 1, "Go to the next burst: the K on the last frame goes on")
        ViewerTests.show(m)
        let here = m.frameIndex
        m.currentEvent = { Self.keyDown("k", code: 40, repeat: true) }
        for _ in 0..<5 { m.perform(.keep) }
        m.currentEvent = { Self.keyDown("n", code: 45, repeat: true) }
        for _ in 0..<5 { m.perform(.nextBurst) }
        await Self.settle()
        await m.allSettled()
        #expect(m.burstIndex == i + 1, "a held key ran on out of the burst")
        #expect(m.frameIndex == here, "a held K kept frame after frame")
        #expect(Self.reviews().count == 1, "a held key recorded bursts as been through")
        #expect(m.pressesIgnoredAsRepeat == 10)
        #expect(m.showHeldKeyTip, "the held key is not said once")
        m.currentEvent = { nil }
    }

    // MARK: - a verdict does not hold up the next press (§2.5.6)

    @Test("with the engine slow to save, an arrow pressed straight after K moves at once")
    func arrowDoesNotWaitForTheSave() async throws {
        let log = WriteLog()
        // The save is held, not delayed: it is not answered until the test
        // lets it go, so the → is seen to land with the K still on its way
        // however slowly the run goes. A 400 ms delay raced a 60 ms settle,
        // and a busy runner stretched the settle past it.
        await log.hold()
        let m = try Self.model(log: log)
        m.goToFrame(0)
        ViewerTests.show(m)
        m.perform(.keep)
        m.perform(.nextFrame)
        // A → that waited for the save would never move while it is held.
        try? await waitUntil(.seconds(30)) { m.frameIndex == 2 }
        #expect(m.frameIndex == 2, "the → waited for the engine to save the K")
        #expect(m.verdictsWritten == 0, "the engine has not answered yet")
        await log.letGo()
        await m.allSettled()
        #expect(m.verdictsWritten == 1)
        #expect(await log.writes.count == 1)
    }

    @Test("a write refused after he has moved on still takes back its own step and says why")
    func lateRefusal() async throws {
        let log = WriteLog()
        await log.setDelay(.milliseconds(100))
        let m = try Self.model(log: log)
        m.goToFrame(0)
        let first = try #require(m.currentRow)
        await log.setRefuse([first.file])
        ViewerTests.show(m)
        m.perform(.keep)
        m.perform(.nextFrame)
        await Self.settle(40)
        #expect(m.frameIndex == 2)
        await m.allSettled()
        #expect(m.session.rows[first.stem]?.override == first.override, "the refused Keep is still shown")
        #expect(m.session.undo.steps.isEmpty)
        #expect(m.session.refusals[.verdict] != nil)
        #expect(m.frameIndex == 2, "a refusal does not move him")
    }

    @Test("a second verdict on the same frame, and an undo, wait for the answer before them, so the engine ends with his last press")
    func sameFrameWaits() async throws {
        let log = WriteLog()
        await log.setDelay(.milliseconds(80))
        let m = try Self.model(log: log)
        m.goToFrame(0)
        let a = try #require(m.currentRow)
        ViewerTests.show(m)
        m.perform(.keep)
        m.perform(.previousFrame)
        await Self.settle(20)
        ViewerTests.show(m)
        m.perform(.drop)
        m.perform(.undo)
        await Self.settle(400)
        await m.allSettled()
        let onA = await log.writes.filter { $0.file == a.file }.map(\.rating)
        #expect(onA == [VerdictValue.keep(a), VerdictValue.drop, VerdictValue.keep(a)],
                "the writes for one frame reached the engine as \(onA)")
        #expect(m.session.rows[a.stem].map(VerdictValue.his) == .kept)
    }

    @Test("⌘Z straight after K, with the engine slow, takes the Keep back at the engine too")
    func undoRightAfterKeep() async throws {
        let log = WriteLog()
        await log.setDelay(.milliseconds(80))
        let m = try Self.model(log: log)
        m.goToFrame(0)
        let a = try #require(m.currentRow)
        try #require(a.override == nil)
        ViewerTests.show(m)
        m.perform(.keep)
        m.perform(.undo)
        await Self.settle(300)
        await m.allSettled()
        let onA = await log.writes.filter { $0.file == a.file }.map(\.rating)
        #expect(onA == [VerdictValue.keep(a), nil], "the engine was sent \(onA)")
        #expect(m.session.rows[a.stem]?.override == nil)
        #expect(m.session.undo.steps.isEmpty)
    }

    /// An engine that is slow, and refuses one value of one frame.
    actor SlowRefusing {
        let refused: VerdictWrite
        private(set) var writes: [VerdictWrite] = []
        init(refusing w: VerdictWrite) { refused = w }
        func send(_ w: VerdictWrite) async -> Result<RatingResult, StudioError> {
            writes.append(w)
            try? await Task.sleep(for: .milliseconds(80))
            return w == refused ? .failure(.refused("that file is not in this shoot"))
                                : .success(RatingResult(ok: true, key_note: ""))
        }
    }

    @Test("a Drop on a frame whose refused Keep is still on its way is not undone when the refusal arrives")
    func refusalBeforeTheNextVerdictOnTheFrame() async throws {
        let plain = try Self.model()
        plain.goToFrame(0)
        let a = try #require(plain.currentRow)
        let engine = SlowRefusing(refusing: VerdictWrite(shoot: plain.session.name, file: a.file,
                                                         rating: VerdictValue.keep(a)))
        let session = ShootSession(response: try ViewerTests.response(), ext: nil, client: KeysEngine.client(),
                                   pump: ImagePump(budget: .base, loader: { _ in Data() }),
                                   queue: VerdictQueue(sender: { await engine.send($0) }))
        let m = ViewerModel(session: session, navigation: Navigation())
        m.goToBurst(plain.burstIndex)
        m.goToFrame(0)
        ViewerTests.show(m)
        m.perform(.keep)
        m.perform(.previousFrame)
        await Self.settle(20)
        ViewerTests.show(m)
        m.perform(.drop)
        await Self.settle(300)
        await m.allSettled()
        #expect(await engine.writes.last { $0.file == a.file }?.rating == VerdictValue.drop)
        #expect(m.session.rows[a.stem].map(VerdictValue.his) == .out,
                "the engine holds his Drop and the screen says unmarked")
        #expect(m.session.undo.steps.map(\.kind) == [.drop])
    }

    @Test("a late success of one Keep does not take down why the Keep after it was refused; a later press's success does")
    func lateSuccessLeavesALaterRefusal() async throws {
        let plain = try Self.model()
        plain.goToFrame(0)
        let a = try #require(plain.currentRow)
        let b = try #require(plain.session.rows[plain.frames[1]])
        // A is slow to be saved; B is refused at once.
        let session = ShootSession(response: try ViewerTests.response(), ext: nil, client: KeysEngine.client(),
                                   pump: ImagePump(budget: .base, loader: { _ in Data() }),
                                   queue: VerdictQueue(sender: { w in
                                       if w.file == a.file { try? await Task.sleep(for: .milliseconds(150)) }
                                       return w.file == b.file ? .failure(.refused("that file is not in this shoot"))
                                                               : .success(RatingResult(ok: true, key_note: ""))
                                   }))
        let m = ViewerModel(session: session, navigation: Navigation())
        m.goToBurst(plain.burstIndex)
        m.goToFrame(0)
        ViewerTests.show(m)
        m.perform(.keep)                 // A, slow
        await Self.settle(20)
        ViewerTests.show(m)
        m.perform(.keep)                 // B, refused
        await Self.settle(40)
        let refusal = try #require(m.session.refusals[.verdict])
        await m.allSettled()
        #expect(m.session.refusals[.verdict] == refusal, "A's late answer took down why B was refused")
        ViewerTests.show(m)
        m.perform(.keep)                 // a press after B's
        await Self.settle(40)
        await m.allSettled()
        #expect(m.session.refusals[.verdict] == nil, "a press after the refused one went through")
    }

    @Test("a late answer to one Keep does not take down \"Still opening\" about the frame he is on now")
    func lateSuccessLeavesTheGate() async throws {
        let log = WriteLog()
        await log.setDelay(.milliseconds(100))
        let m = try Self.model(log: log)
        m.goToFrame(0)
        ViewerTests.show(m)
        m.perform(.keep)          // on, to a frame not drawn yet
        m.perform(.keep)          // too early
        await Self.settle(40)
        #expect(m.session.refusals[.verdict] == Strings.Verdict.stillOpening)
        await m.allSettled()
        #expect(m.session.refusals[.verdict] == Strings.Verdict.stillOpening)
    }

    // MARK: - ⇧⌘Z (§2.5.5)

    @Test("⇧⌘Z puts back the Keep ⌘Z took back, on its frame, and writes it again")
    func redoAKeep() async throws {
        let log = WriteLog()
        let m = try Self.model(log: log)
        m.goToFrame(0)
        let a = try #require(m.currentRow)
        ViewerTests.show(m)
        await ViewerTests.press(m, .keep)
        await ViewerTests.press(m, .undo)
        #expect(m.session.undo.redoName == Strings.Verdict.undoKeep(ShootSession.shortStem(a.stem)))
        await ViewerTests.press(m, .nextFrame)
        _ = m.key(KeyMap.Press("z", command: true, shift: true))
        await Self.settle()
        #expect(m.currentStem == a.stem, "redo goes to the frame it changes")
        #expect(m.session.rows[a.stem].map(VerdictValue.his) == .kept)
        #expect(await log.writes.filter { $0.file == a.file }.map(\.rating)
                == [VerdictValue.keep(a), a.override, VerdictValue.keep(a)])
        #expect(m.session.undo.steps.count == 1)
        #expect(!m.session.undo.canRedo)
    }

    @Test("a new verdict after ⌘Z clears what ⇧⌘Z could put back")
    func newVerdictClearsRedo() async throws {
        let log = WriteLog()
        let m = try Self.model(log: log)
        m.goToFrame(0)
        ViewerTests.show(m)
        await ViewerTests.press(m, .keep)
        await ViewerTests.press(m, .undo)
        #expect(m.session.undo.canRedo)
        ViewerTests.show(m)
        await ViewerTests.press(m, .drop)
        #expect(!m.session.undo.canRedo)
        let writes = await log.writes.count
        await ViewerTests.press(m, .redo)
        #expect(await log.writes.count == writes, "redo replayed a Keep over his Drop")
    }

    @Test("⇧⌘Z after taking back a finished burst records it again and goes on into the next")
    func redoAFinish() async throws {
        let (m, i) = try Self.atTheEndOfABurst()
        await ViewerTests.press(m, .nextFrame)
        await Self.settle()
        #expect(m.burstIndex == i + 1)
        await ViewerTests.press(m, .undo)
        await Self.settle()
        #expect(m.burstIndex == i)
        #expect(!m.bursts[i].seen)
        await ViewerTests.press(m, .redo)
        await Self.settle()
        #expect(m.bursts[i].seen)
        #expect(m.burstIndex == i + 1)
        #expect(Self.reviews().count == 3)
        #expect(m.session.undo.undoName == Strings.Verdict.undoFinishBurst(i + 1))
    }

    @Test("a redo the engine refuses stays ready to try again, and the frame keeps its undone mark")
    func refusedRedo() async throws {
        let log = WriteLog()
        let m = try Self.model(log: log)
        m.goToFrame(0)
        let a = try #require(m.currentRow)
        ViewerTests.show(m)
        await ViewerTests.press(m, .keep)
        await ViewerTests.press(m, .undo)
        await log.setRefuse([a.file])
        await ViewerTests.press(m, .redo)
        #expect(m.session.rows[a.stem]?.override == a.override)
        #expect(m.session.undo.canRedo)
        #expect(m.session.refusals[.verdict] != nil)
    }
}
