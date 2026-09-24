import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// Crossing from one burst to the next, against an engine that says yes, so
/// the crossing actually happens (DESIGN.md §2.5.2, §2.5.13).
@Suite("Crossing into the next burst", .serialized)
@MainActor
struct BurstCrossingTests {

    /// The stack burst, on an engine that accepts every write.
    static func model(log: WriteLog = WriteLog()) throws -> ViewerModel {
        let session = ShootSession(response: try ViewerTests.response(), ext: nil,
                                   client: LiveCountsTests.client(),
                                   pump: ImagePump(budget: .base, loader: { _ in Data() }),
                                   queue: VerdictQueue(sender: { await log.send($0) }))
        let m = ViewerModel(session: session, navigation: Navigation())
        if let i = session.bursts.firstIndex(where: { b in
            b.frames.contains { session.rows[$0]?.stack != nil }
        }), session.bursts.indices.contains(i + 1) { m.goToBurst(i) } else { m.goToBurst(0) }
        return m
    }

    static func finishes(_ m: ViewerModel) -> Int {
        m.session.undo.steps.filter { if case .finishBurst = $0.kind { return true }; return false }.count
    }

    static func settle() async {
        for _ in 0..<60 { try? await Task.sleep(for: .milliseconds(2)); await Task.yield() }
    }

    @Test("a K pressed straight after → off the end of a burst never lands on the frame he left")
    func keyAfterCrossing() async throws {
        let log = WriteLog()
        let m = try Self.model(log: log)
        let start = m.burstIndex
        m.goToFrame(m.frames.count - 1)
        let last = try #require(m.currentRow?.file)
        ViewerTests.show(m)

        m.perform(.nextFrame)
        m.perform(.keep)
        await Self.settle()
        #expect(m.burstIndex == start + 1)
        #expect(await !log.writes.contains { $0.file == last },
                "the K meant for the next burst kept the last frame of the one he left")
    }

    @Test("two quick → presses at the end of a burst finish it once, and the second goes on")
    func twoArrows() async throws {
        let m = try Self.model()
        let start = m.burstIndex
        m.goToFrame(m.frames.count - 1)
        let before = Self.finishes(m)

        m.perform(.nextFrame)
        m.perform(.nextFrame)
        await Self.settle()
        #expect(Self.finishes(m) == before + 1, "one burst was finished twice")
        #expect(m.burstIndex == start + 1)
        #expect(m.frameIndex == min(1, m.frames.count - 1))
    }

    @Test("a held → stops at the end of a burst and records nothing, a held ← goes back across, and the next press goes on")
    func heldArrowStops() async throws {
        let m = try Self.model()
        let start = m.burstIndex
        m.goToFrame(m.frames.count - 1)
        let bumps = m.bump

        m.performHeld(.nextFrame)
        await Self.settle()
        #expect(m.burstIndex == start, "a held → ran into the next burst")
        #expect(m.bump == bumps + 1)
        #expect(Self.finishes(m) == 0)
        #expect(m.bursts[start].seen == false, "a held key recorded a burst as been through")

        // A held ← goes on back into the burst before: going back records
        // nothing, so there is nothing for a held key to claim.
        m.goToFrame(0)
        m.performHeld(.previousFrame)
        await Self.settle()
        #expect(start == 0 ? m.burstIndex == 0 : m.burstIndex == start - 1)
        #expect(m.bursts.allSatisfy { !$0.seen } || Self.finishes(m) == 0)

        // Letting go and pressing again is how he goes on.
        if m.burstIndex != start { m.goToBurst(start) }
        m.goToFrame(m.frames.count - 1)
        m.perform(.nextFrame)
        await Self.settle()
        #expect(m.burstIndex == start + 1)
    }

    @Test("a held arrow at an edge bumps once however long it is held, and drops what the stage has pending")
    func heldBumpsOnce() async throws {
        let m = try Self.model()
        let stage = CountingStage()
        m.heldMoves = stage
        m.goToFrame(m.frames.count - 1)
        let bumps = m.bump

        for _ in 0..<12 { m.performHeld(.nextFrame) }
        await Self.settle()
        #expect(m.bump == bumps + 1, "each repeat shoved the picture again")
        #expect(stage.letGoes >= 1)

        // A press of its own may bump again — and here, crosses.
        m.perform(.nextFrame)
        await Self.settle()
        #expect(m.burstIndex > 0)

        // ↓ at the end: the press bumps, and its repeats do not bump again.
        m.heldMoves = nil
        m.goToFrame(m.frames.count - 1)
        let before = m.bump
        _ = m.key(KeyMap.Press(key: .down))
        for _ in 0..<10 { _ = m.key(KeyMap.Press(key: .down, isARepeat: true)) }
        await Self.settle()
        #expect(m.bump == before + 1)
        _ = stage
    }

    @Test("Continue to Presets records the last burst as been through before it changes step")
    func continueRecords() async throws {
        let m = try Self.model()
        m.goToBurst(m.bursts.count - 1)
        #expect(m.currentBurst?.seen == false)
        await m.continueToPresets()
        #expect(m.bursts.last?.seen == true, "the last burst of the shoot stayed not been through")
        #expect(m.navigation.selection == .step(shoot: m.session.name, step: "presets"))
    }
}

/// A stage that only counts what the model asks of it.
@MainActor
final class CountingStage: HeldMoves {
    var holds = 0, letGoes = 0
    func hold(_ delta: Int) { holds += 1 }
    func letGo() { letGoes += 1 }
}
