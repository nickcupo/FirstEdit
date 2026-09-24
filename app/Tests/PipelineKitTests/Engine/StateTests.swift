import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// Records every write the queue sends, and refuses the ones it is told to.
///
/// Held, it answers nothing until it is let go. A test that has to see a press
/// land while the engine has not answered yet holds it: a delay only made that
/// likely, and a busy run could spend the whole delay before the test looked.
actor WriteLog {
    private(set) var writes: [VerdictWrite] = []
    var refuse: Set<String> = []
    var delay: Duration = .zero
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func setRefuse(_ files: Set<String>) { refuse = files }
    func setDelay(_ d: Duration) { delay = d }
    func hold() { held = true }
    func letGo() {
        held = false
        let answering = waiting
        waiting = []
        for w in answering { w.resume() }
    }
    func send(_ w: VerdictWrite) async -> Result<RatingResult, StudioError> {
        writes.append(w)
        if held { await withCheckedContinuation { waiting.append($0) } }
        if delay > .zero { try? await Task.sleep(for: delay) }
        if refuse.contains(w.file) { return .failure(.refused("that file is not in this shoot")) }
        return .success(RatingResult(ok: true, key_note: ""))
    }
}

@Suite("The verdict queue, the undo log and the display gate", .serialized)
@MainActor
struct StateTests {

    @Test("a repeat of the value in flight or committed is dropped")
    func sameValueDropped() async {
        let log = WriteLog()
        let q = VerdictQueue(sender: { await log.send($0) })
        await q.seed(file: "a.ARW", value: nil)
        _ = await q.submit(.init(shoot: "s", file: "a.ARW", rating: 5))
        _ = await q.submit(.init(shoot: "s", file: "a.ARW", rating: 5))
        _ = await q.submit(.init(shoot: "s", file: "a.ARW", rating: nil))
        #expect(await log.writes.map(\.rating) == [5, nil])
        #expect(await q.dropped == 1)
    }

    @Test("different values for one frame land in press order; frames do not wait on each other")
    func pressOrder() async {
        let log = WriteLog()
        await log.setDelay(.milliseconds(20))
        let q = VerdictQueue(sender: { await log.send($0) })
        let presses: [(String, Int?)] = [("a", 5), ("b", 2), ("a", 2), ("c", 5), ("a", 3),
                                         ("b", 5), ("c", nil), ("a", 5), ("b", 2), ("c", 2)]
        await withTaskGroup(of: Void.self) { g in
            for (i, p) in presses.enumerated() {
                g.addTask { _ = await q.submit(.init(shoot: "s", file: p.0, rating: p.1)) }
                // A human does not press two keys in the same microsecond.
                try? await Task.sleep(for: .milliseconds(1))
                _ = i
            }
        }
        let writes = await log.writes
        for f in ["a", "b", "c"] {
            let mine = writes.filter { $0.file == f }.map(\.rating)
            let pressed = presses.filter { $0.0 == f }.map(\.1)
            #expect(mine == pressed, "\(f): \(mine) vs \(pressed)")
        }
    }

    // MARK: - the session

    static func session(log: WriteLog) throws -> ShootSession {
        let r = try Fixture.decode(ShootResponse.self, "shoot")
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"))
        let pump = ImagePump(budget: .base, loader: { _ in Data() })
        return ShootSession(response: r, ext: nil, client: client, pump: pump,
                            queue: VerdictQueue(sender: { await log.send($0) }))
    }

    @Test("the fixture's shoot groups into its 19 bursts and lists its steps without claiming any done")
    func fallbacks() throws {
        let s = try Self.session(log: WriteLog())
        #expect(s.bursts.count == 19)
        #expect(s.bursts.map(\.frames.count).reduce(0, +) == 54)
        #expect(s.steps.map(\.id) == ["ingest", "cull", "keepers", "presets", "edit", "instagram", "reels", "done"])
        #expect(s.steps.allSatisfy { !$0.done && $0.enabled })
    }

    @Test("no verdict is written for a frame that is not on screen, with the right one of three sentences")
    func displayGate() async throws {
        let log = WriteLog()
        let s = try Self.session(log: log)
        // Nothing drawn yet.
        #expect(await s.keep() == .refused(Strings.Verdict.stillOpening))
        // Drawn, then he moved on before the new frame drew.
        s.didDisplay(stem: s.currentStem!, generation: s.cursor.generation)
        let stale = s.cursor.generation
        s.nextFrame()
        s.didDisplay(stem: s.currentStem!, generation: stale)
        #expect(await s.keep() == .refused(Strings.Verdict.notOnScreen))
        #expect(await log.writes.isEmpty)
        #expect(s.refusals[.verdict] == Strings.Verdict.notOnScreen)
        #expect(s.undo.steps.isEmpty)
    }

    @Test("K writes the cull's own number when it had the frame in, 3 when it did not; D writes 2")
    func keepValues() async throws {
        let log = WriteLog()
        let s = try Self.session(log: log)
        let row = s.currentRow!
        s.didDisplay(stem: row.stem, generation: s.cursor.generation)
        #expect(await s.keep() == .applied)
        #expect(await log.writes.last?.rating == VerdictValue.keep(row))
        #expect(s.rows[row.stem]?.override == max(row.rating, 3))
        // It advanced to the next frame in shutter order.
        #expect(s.cursor.frame == 1)
        #expect(s.refusals[.verdict] == nil)
        let next = s.currentRow!
        s.didDisplay(stem: next.stem, generation: s.cursor.generation)
        #expect(await s.drop() == .applied)
        #expect(await log.writes.last?.rating == 2)
        // The cull's own field was never touched.
        #expect(s.rows[row.stem]?.rating == row.rating)
    }

    @Test("a refused write rolls back exactly its own step and says so")
    func refusedRollsBack() async throws {
        let log = WriteLog()
        let s = try Self.session(log: log)
        let row = s.currentRow!
        await log.setRefuse([row.file])
        s.didDisplay(stem: row.stem, generation: s.cursor.generation)
        #expect(await s.keep() == .refused("that file is not in this shoot"))
        #expect(s.rows[row.stem]?.override == nil)
        #expect(s.undo.steps.isEmpty)
        #expect(s.refusals[.verdict] == "that file is not in this shoot")
    }

    @Test("N presses are N named undo steps; two fast undos take back two different decisions")
    func undo() async throws {
        let log = WriteLog()
        let s = try Self.session(log: log)
        var stems: [String] = []
        for _ in 0..<2 {
            let stem = s.currentStem!
            stems.append(stem)
            s.didDisplay(stem: stem, generation: s.cursor.generation)
            _ = await s.keep()
        }
        #expect(s.undo.steps.count == 2)
        #expect(s.undo.undoName == Strings.Verdict.undoKeep(ShootSession.shortStem(stems[1])))
        async let first = s.undoLast()
        async let second = s.undoLast()
        _ = await (first, second)
        #expect(s.undo.steps.isEmpty)
        #expect(stems.allSatisfy { s.rows[$0]?.override == nil })
        // The last write for each frame puts it back to unmarked.
        let writes = await log.writes
        for stem in stems {
            let file = s.rows[stem]!.file
            #expect(writes.last { $0.file == file }?.rating == nil)
        }
    }

    @Test("the log is 200 deep and never coalesces")
    func depth() {
        let l = VerdictLog()
        for i in 0..<250 {
            l.push(VerdictStep(kind: .keep, stem: "f\(i)", file: "f\(i)", before: nil, after: 3,
                               burstIndex: 0, name: "Keep \(i)"))
        }
        #expect(l.steps.count == 200)
        #expect(l.steps.first?.stem == "f50")
    }

    @Test("the frame number he reads off the camera")
    func shortStem() {
        #expect(ShootSession.shortStem("TSC04330") == "04330")
        #expect(ShootSession.shortStem("IMG") == "IMG")
    }

    @Test("a refusal is cleared only by its owner")
    func refusalOwners() {
        let b = RefusalBoard()
        b.set(.verdict, "That frame isn't the one on screen.")
        b.set(.storage, "that list was drawn for something else.")
        b.clear(.storage)
        #expect(b[.verdict] != nil)
        #expect(b[.storage] == nil)
    }

    @Test("the stage has the keyboard when the window becomes key (NAT-01)")
    func firstResponder() {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let stage = FocusableView(frame: NSRect(x: 0, y: 40, width: 100, height: 100))
        w.contentView?.addSubview(other)
        w.contentView?.addSubview(stage)
        KeyFocus.preferred = stage
        // At launch.
        KeyFocus.restore(in: w)
        #expect(w.firstResponder === stage)
        // Something else took it; the window becoming key again gives it back.
        w.makeFirstResponder(nil)
        #expect(w.firstResponder !== stage)
        WindowChrome.configure(w, autosaveName: "test-\(UUID().uuidString)")
        KeyFocus.restore(in: w)
        #expect(w.firstResponder === stage)
        #expect(w.minSize == Tokens.Metric.minimumWindow)
        #expect(w.collectionBehavior.contains(.fullScreenPrimary))
        #expect(w.tabbingMode == .disallowed)
        KeyFocus.preferred = nil
    }
}

final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
