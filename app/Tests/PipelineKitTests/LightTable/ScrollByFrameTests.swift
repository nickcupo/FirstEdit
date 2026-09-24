import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// §2.5.8: a scroll over the fitted photograph steps frame by frame, as the
/// arrows do, on into the next burst; with ⌥ it is the cull's picks. A notch
/// used to jump to the next pick and stop at the end of the burst, so on his
/// four-frame bursts most notches only shook the picture.
///
/// Nested in `KeysTests`, whose engine records what it was asked in one
/// shared list: run beside that suite, each reset the other's record.
extension KeysTests {
    @Suite("A scroll over the photograph goes frame by frame", .serialized)
    @MainActor
    struct ScrollByFrameTests {

        typealias Step = ScrollInput.FrameScroll.Step
        static let notch = ScrollInput.lineHeight

        // MARK: - what a scroll asks for

        @Test("a notch toward him is the next frame and away the previous; with ⌥ the cull's picks")
        func directions() {
            var s = ScrollInput.FrameScroll()
            #expect(s.steps(down: -Self.notch, across: 0, precise: false, began: false, option: false, at: 10)
                    == [Step(action: .nextFrame, held: false)])
            #expect(s.steps(down: Self.notch, across: 0, precise: false, began: false, option: false, at: 20)
                    == [Step(action: .previousFrame, held: false)])
            #expect(s.steps(down: -Self.notch, across: 0, precise: false, began: false, option: true, at: 30)
                    == [Step(action: .nextPick, held: false)])
            #expect(s.steps(down: Self.notch, across: 0, precise: false, began: false, option: true, at: 40)
                    == [Step(action: .previousPick, held: false)])
        }

        @Test("the first step of a spin is a press, the rest of it a key held down, and a pause starts a new one")
        func aSpinIsAHold() {
            var s = ScrollInput.FrameScroll()
            var t = 100.0
            func notch() -> [Step] {
                t += 0.05
                return s.steps(down: -Self.notch, across: 0, precise: false, began: false, option: false, at: t)
            }
            #expect(notch() == [Step(action: .nextFrame, held: false)])
            #expect(notch() == [Step(action: .nextFrame, held: true)])
            #expect(notch() == [Step(action: .nextFrame, held: true)])
            t += 1
            #expect(notch() == [Step(action: .nextFrame, held: false)], "a notch after a pause is a press of its own")
            // One big event: the first a press, the others held.
            t += 1
            #expect(s.steps(down: -Self.notch * 3, across: 0, precise: false, began: false, option: false, at: t)
                    == [Step(action: .nextFrame, held: false), Step(action: .nextFrame, held: true),
                        Step(action: .nextFrame, held: true)])
            // A trackpad saying a new gesture began is one, however soon.
            let pad = ScrollInput.Stepper.trackpadThreshold
            #expect(s.steps(down: -pad, across: 0, precise: true, began: true, option: false, at: t + 0.01)
                    == [Step(action: .nextFrame, held: false)])
            #expect(s.steps(down: -pad, across: 0, precise: true, began: false, option: false, at: t + 0.02)
                    == [Step(action: .nextFrame, held: true)])
            #expect(s.steps(down: -pad, across: 0, precise: true, began: true, option: false, at: t + 0.03)
                    == [Step(action: .nextFrame, held: false)])
        }

        @Test("sideways, one firm swipe is one frame, pushed left the next; a tilt wheel is one a notch")
        func sideways() {
            var s = ScrollInput.FrameScroll()
            let pad = ScrollInput.Stepper.trackpadThreshold
            #expect(s.steps(down: 0, across: -pad * 3, precise: true, began: true, option: false, at: 10)
                    == [Step(action: .nextFrame, held: false)], "a long swipe ran through the burst")
            #expect(s.steps(down: 0, across: -pad * 3, precise: true, began: false, option: false, at: 10.05) == [],
                    "the rest of the same swipe is not another frame")
            #expect(s.steps(down: 0, across: pad, precise: true, began: true, option: false, at: 11)
                    == [Step(action: .previousFrame, held: false)])
            #expect(s.steps(down: 0, across: -Self.notch, precise: false, began: false, option: false, at: 20)
                    == [Step(action: .nextFrame, held: false)])
            #expect(s.steps(down: 0, across: -Self.notch, precise: false, began: false, option: false, at: 20.05)
                    == [Step(action: .nextFrame, held: true)])
        }

        @Test("a quick swipe back the other way is the previous frame, a press of its own; the first swipe's leftover is not carried into it")
        func aSwipeBack() {
            var s = ScrollInput.FrameScroll()
            // A long swipe left, its events 30 pt apiece, then within 0.2 s a
            // firm one right. The rest of the first swipe used to be saved,
            // so the second stepped forward, as a press that could record a
            // burst.
            var t = 50.0
            var steps: [Step] = []
            for n in 0..<12 {
                t += 0.01
                steps += s.steps(down: 0, across: -30, precise: true, began: n == 0, option: false, at: t)
            }
            #expect(steps == [Step(action: .nextFrame, held: false)], "one frame for one swipe")
            var back: [Step] = []
            for n in 0..<5 {
                t += 0.02
                back += s.steps(down: 0, across: 26, precise: true, began: n == 0, option: false, at: t)
            }
            #expect(back == [Step(action: .previousFrame, held: false)])
        }

        @Test("a notch away straight after a fast spin toward him is one frame back, not three more forward")
        func aNotchBack() {
            var s = ScrollInput.FrameScroll()
            let spin = s.steps(down: -Self.notch * 10, across: 0, precise: false, began: false, option: false, at: 70)
            #expect(spin.count == 3 && spin.allSatisfy { $0.action == .nextFrame })
            #expect(s.steps(down: Self.notch, across: 0, precise: false, began: false, option: false, at: 70.08)
                    == [Step(action: .previousFrame, held: false)],
                    "the spin's leftover was spent the wrong way")
            // And nothing of the spin is left to come out after it.
            #expect(s.steps(down: -Self.notch, across: 0, precise: false, began: false, option: false, at: 70.16)
                    == [Step(action: .nextFrame, held: false)])
        }

        @Test("fingers turning back without lifting are the same gesture: a step back, held, with nothing carried")
        func fingersTurnBack() {
            var s = ScrollInput.FrameScroll()
            let pad = ScrollInput.Stepper.trackpadThreshold
            #expect(s.steps(down: -pad * 1.9, across: 0, precise: true, began: true, option: false, at: 80)
                    == [Step(action: .nextFrame, held: false)])
            // 0.9 of a step was left over toward him; turned back, it is not
            // paid off first, and the step back is the same gesture still going.
            #expect(s.steps(down: pad, across: 0, precise: true, began: false, option: false, at: 80.05)
                    == [Step(action: .previousFrame, held: true)])
        }

        // MARK: - on the stage

        /// A wheel notch as AppKit hands one over: lines, no phase, no momentum.
        /// `lines` is negative toward him.
        static func wheel(_ lines: Int32, at seconds: Double, option: Bool = false) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                          wheel1: lines, wheel2: 0, wheel3: 0))
            cg.timestamp = CGEventTimestamp(seconds * 1_000_000_000)
            if option { cg.flags = .maskAlternate }
            return try #require(NSEvent(cgEvent: cg))
        }

        static func settle() async { await KeysTests.settle(160) }

        /// On the first frame of a burst of three or more with another after it,
        /// so a spin has frames to run through before it meets the end.
        static func atTheStartOfALongBurst() throws -> (ViewerModel, Int) {
            let m = try KeysTests.model()
            let i = try #require(m.bursts.indices.first { $0 + 1 < m.bursts.count && m.bursts[$0].frames.count >= 3 })
            m.goToBurst(i)
            m.goToFrame(0)
            return (m, i)
        }

        @Test("on the stage a notch on the last frame crosses into the next burst and records it, as → does")
        func aNotchCrosses() async throws {
            let (m, i) = try KeysTests.atTheEndOfABurst()
            let stage = StageLayerView(model: m)
            let e = try Self.wheel(-1, at: 1000)
            let down = ScrollInput.points(e).dy
            try #require(down != 0)
            // Toward him, in whichever sign this Mac's scrolling direction gives.
            let toward: Int32 = down < 0 ? -1 : 1
            stage.scrollWheel(with: try Self.wheel(toward, at: 1000))
            await Self.settle()
            #expect(m.burstIndex == i + 1, "a notch on the last frame shook the picture and stayed")
            #expect(m.frameIndex == 0)
            #expect(m.bursts[i].seen, "leaving forward records the burst, exactly as → does")
            #expect(KeysTests.reviews().count == 1)

            // Away from him: back across the start, recording nothing.
            stage.scrollWheel(with: try Self.wheel(-toward, at: 1010))
            await Self.settle()
            #expect(m.burstIndex == i)
            #expect(m.isLastFrameOfBurst)
            #expect(KeysTests.reviews().count == 1)
        }

        @Test("a spin runs through a burst and stops at its end with one bounce; a notch after a pause goes on")
        func aSpinStopsAtTheEnd() async throws {
            let (m, i) = try Self.atTheStartOfALongBurst()
            let stage = StageLayerView(model: m)
            let toward: Int32 = ScrollInput.points(try Self.wheel(-1, at: 0)).dy < 0 ? -1 : 1
            let bumps = m.bump
            var t = 2000.0
            for _ in 0..<(m.frames.count + 4) {
                t += 0.04
                stage.scrollWheel(with: try Self.wheel(toward, at: t))
            }
            await Self.settle()
            #expect(m.burstIndex == i, "a wheel still turning recorded a burst")
            #expect(m.isLastFrameOfBurst)
            #expect(m.bump == bumps + 1, "one bounce for the spin, not one a notch")
            #expect(KeysTests.reviews().isEmpty)

            stage.scrollWheel(with: try Self.wheel(toward, at: t + 1))
            await Self.settle()
            #expect(m.burstIndex == i + 1)
            #expect(KeysTests.reviews().count == 1)
        }

        @Test("with ⌥ a notch goes to the next frame the cull put forward, as ↓ does, and never crosses")
        func optionIsThePicks() async throws {
            let m = try KeysTests.model()
            // A burst whose next pick from its first frame is not simply the
            // frame after it, so a pick and a frame cannot be mistaken.
            let found = m.bursts.indices.lazy.compactMap { i -> (Int, Int)? in
                m.goToBurst(i)
                guard let p = Stacks.nextPick(from: 0, frames: m.frames, rows: m.session.rows,
                                              stacks: m.stacks, forward: true), p > 1 else { return nil }
                return (i, p)
            }.first
            let (i, pick) = try #require(found)
            m.goToBurst(i)
            m.goToFrame(0)
            let stage = StageLayerView(model: m)
            let toward: Int32 = ScrollInput.points(try Self.wheel(-1, at: 0)).dy < 0 ? -1 : 1
            stage.scrollWheel(with: try Self.wheel(toward, at: 3000, option: true))
            await Self.settle()
            #expect(m.burstIndex == i)
            #expect(m.frameIndex == pick, "⌥ stepped a frame rather than to the cull's next pick")
            stage.scrollWheel(with: try Self.wheel(toward, at: 3010))
            await Self.settle()
            #expect(m.frameIndex == pick + 1 || m.burstIndex == i + 1, "a plain notch after it is one frame")
            #expect(KeysTests.reviews().count <= 1)
        }
    }
}
