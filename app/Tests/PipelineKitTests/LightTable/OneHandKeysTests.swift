import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// The cull under one hand (DESIGN.md §2.5.3): his right hand is on the
/// mouse, so E keep · D drop · S previous frame · F next frame · R next burst
/// · W previous burst · Q undo · X clear the mark, beside C, Z, G, Space and
/// 1–6. "I hate k and being so far i need 2 hands." K, N, P, U, 0 and the
/// arrows go on working.
///
/// Nested in `KeysTests`, whose engine records what it was asked in one
/// shared list: run beside that suite, each reset the other's record.
extension KeysTests {
    @Suite("The cull under the left hand", .serialized)
    @MainActor
    struct OneHandKeysTests {

        static func press(_ c: String, _ m: ViewerModel, held: Bool = false, shift: Bool = false) async {
            #expect(m.key(KeyMap.Press(c, shift: shift, isARepeat: held)), "\(c) was not the light table's")
            await KeysTests.settle(80)
        }

        // MARK: - the table

        @Test("every key of the left hand does what its old key does")
        func theLeftHand() {
            func a(_ c: String, _ mode: KeyMap.Mode = .single, shift: Bool = false) -> KeyMap.Action? {
                KeyMap.action(for: KeyMap.Press(c, shift: shift), mode: mode)
            }
            let pairs: [(String, String)] = [("e", "k"), ("x", "0"), ("r", "n"), ("w", "p"), ("q", "u")]
            for (new, old) in pairs {
                for mode in [KeyMap.Mode.single, .fullImage, .compare, .allBursts, .review] {
                    #expect(a(new, mode) != nil, "\(new) does nothing in \(mode)")
                    #expect(a(new, mode) == a(old, mode), "\(new) and \(old) differ in \(mode)")
                }
            }
            #expect(a("e") == .keep)
            #expect(a("d") == .drop)
            #expect(a("x") == .clearMark)
            #expect(a("r") == .nextBurst)
            #expect(a("w") == .previousBurst)
            #expect(a("q") == .undo)
            #expect(a("e", shift: true) == .keepOnly)
            #expect(a("k", shift: true) == .keepOnly)
            // F is → in every mode, the next cover in All Bursts; S is ←
            // wherever a frame is shown, and Single in All Bursts.
            for mode in [KeyMap.Mode.single, .fullImage, .compare, .allBursts, .review] {
                #expect(a("f", mode) == KeyMap.action(for: KeyMap.Press(key: .right), mode: mode), "f in \(mode)")
            }
            for mode in [KeyMap.Mode.single, .fullImage, .compare, .review] {
                #expect(a("s", mode) == KeyMap.action(for: KeyMap.Press(key: .left), mode: mode))
            }
            // The rest of the layout is where it was.
            #expect(a("c") == .compare)
            #expect(a("z") == .toggleOneToOne)
            #expect(a("g") == .allBursts)
            #expect(KeyMap.action(for: KeyMap.Press(key: .space), mode: .single) == .toggleFullImage)
            for n in 1...6 { #expect(a("\(n)") == .reason(n)) }
            // ⌘ on any of them is not the light table's: ⌘Q quits, ⌘W closes,
            // ⌘E ejects, ⌘R culls, ⌘F finds a burst.
            for c in ["e", "s", "f", "r", "w", "q", "x"] {
                #expect(KeyMap.action(for: KeyMap.Press(c, command: true), mode: .single) == nil, "⌘\(c)")
            }
        }

        @Test("S is the previous frame in every view, and the previous cover in All Bursts, as ← is")
        func sByMode() {
            #expect(KeyMap.action(for: KeyMap.Press("s"), mode: .allBursts) == .previousFrame)
            #expect(KeyMap.action(for: KeyMap.Press("s"), mode: .allBursts)
                    == KeyMap.action(for: KeyMap.Press(key: .left), mode: .allBursts))
            #expect(KeyMap.action(for: KeyMap.Press("s"), mode: .single) == .previousFrame)
            #expect(KeyMap.action(for: KeyMap.Press("s"), mode: .fullImage) == .previousFrame)
            #expect(KeyMap.action(for: KeyMap.Press("s"), mode: .compare) == .previousFrame)
        }

        @Test("E and D, like K, never repeat; F and S repeat as the arrows do")
        func repeatRule() {
            for c in ["e", "d", "k", "x", "r", "w", "q"] {
                #expect(KeyMap.accepts(KeyMap.Press(c, isARepeat: true), mode: .single) == nil, "a held \(c) repeated")
            }
            #expect(KeyMap.accepts(KeyMap.Press("e", shift: true, isARepeat: true), mode: .compare) == nil)
            #expect(KeyMap.accepts(KeyMap.Press("f", isARepeat: true), mode: .single) == .nextFrame)
            #expect(KeyMap.accepts(KeyMap.Press("s", isARepeat: true), mode: .single) == .previousFrame)
            #expect(KeyMap.accepts(KeyMap.Press("s", isARepeat: true), mode: .allBursts) == .previousFrame)
            #expect(KeyMap.Action.keep.explainsHeldKey && KeyMap.Action.drop.explainsHeldKey)
        }

        // MARK: - through the event path

        static let eCode: UInt16 = 14, dCode: UInt16 = 2

        @Test("a held E keeps one frame and a held D drops one, through the event path, and the line says so")
        func heldEAndD() async throws {
            let log = WriteLog()
            let m = try ViewerTests.model(log: log)
            ViewerTests.show(m)
            let w = KeyPathTests.window()
            defer { w.close() }
            let sink = LightTableKeyView(model: m)
            w.contentView = sink
            defer { sink.stopListening() }

            NSApp.sendEvent(KeyPathTests.key("e", keyCode: Self.eCode, in: w))
            for _ in 0..<20 { NSApp.sendEvent(KeyPathTests.key("e", keyCode: Self.eCode, in: w, repeat: true)) }
            #expect(m.showHeldKeyTip, "the line that says a held key marks one frame did not come up")
            await KeyPathTests.settle()
            #expect(await log.writes.count == 1, "a held E kept more than the frame he pressed it on")
            #expect(m.pressesIgnoredAsRepeat == 20)

            ViewerTests.show(m)
            NSApp.sendEvent(KeyPathTests.key("d", keyCode: Self.dCode, in: w))
            for _ in 0..<20 { NSApp.sendEvent(KeyPathTests.key("d", keyCode: Self.dCode, in: w, repeat: true)) }
            await KeyPathTests.settle()
            #expect(await log.writes.count == 2, "a held D put out more than the frame he pressed it on")
            #expect(m.pressesIgnoredAsRepeat == 40)
        }

        @Test("an e or a d typed into a text field is a letter, and marks nothing")
        func typedIntoAField() async throws {
            let log = WriteLog()
            let m = try ViewerTests.model(log: log)
            ViewerTests.show(m)
            let w = KeyPathTests.window()
            defer { w.close() }
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 780))
            w.contentView = content
            let sink = LightTableKeyView(model: m)
            content.addSubview(sink)
            defer { sink.stopListening() }
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
            content.addSubview(field)
            w.makeFirstResponder(field)
            #expect(MenuValidation.isTextEditing(in: w))
            let start = (m.burstIndex, m.frameIndex)
            for (c, code) in [("e", Self.eCode), ("d", Self.dCode), ("f", UInt16(3)), ("r", UInt16(15)),
                              ("x", UInt16(7)), ("q", UInt16(12))] {
                NSApp.sendEvent(KeyPathTests.key(c, keyCode: code, in: w))
            }
            await KeyPathTests.settle()
            #expect(await log.writes.isEmpty, "a letter typed into a field marked a photograph")
            #expect(m.burstIndex == start.0 && m.frameIndex == start.1, "a letter typed into a field moved him")
            for c in ["e", "d", "s", "f", "r", "w", "q", "x"] {
                #expect(KeyMap.action(for: KeyMap.Press(c), mode: .textEditing) == nil)
            }
        }

        // MARK: - what each one does

        @Test("S is the one before in the grid as in the single view: the previous cover, as F is the next")
        func sInTheGridAndOut() async throws {
            let m = try KeysTests.model()
            m.goToFrame(1)
            await Self.press("s", m)
            #expect(m.mode == .single)
            #expect(m.frameIndex == 0, "S in the single view is the previous frame")

            await Self.press("g", m)
            #expect(m.mode == .allBursts)
            let burst = m.burstIndex
            await Self.press("f", m)
            #expect(m.mode == .allBursts && m.burstIndex == burst + 1, "F in All Bursts is the next cover")
            await Self.press("s", m)
            #expect(m.mode == .allBursts, "S in All Bursts stays in All Bursts")
            #expect(m.burstIndex == burst, "S in All Bursts is the previous cover, where F went forward")
        }

        @Test("F on a burst's last frame goes on into the next and records it, as → does; a held F stops at the end")
        func fCrosses() async throws {
            let (m, i) = try KeysTests.atTheEndOfABurst()
            await Self.press("f", m)
            #expect(m.burstIndex == i + 1)
            #expect(m.frameIndex == 0)
            #expect(m.bursts[i].seen, "F off the last frame left the burst unrecorded")
            #expect(KeysTests.reviews().count == 1)

            // S off the first frame goes back to the last frame of the burst
            // before and records nothing, as ← does.
            await Self.press("s", m)
            #expect(m.burstIndex == i)
            #expect(m.isLastFrameOfBurst)
            #expect(KeysTests.reviews().count == 1)

            // Held, F runs through a burst and stops at its end.
            let j = try #require(m.bursts.indices.first { $0 + 1 < m.bursts.count && m.bursts[$0].frames.count >= 3
                                                            && !m.bursts[$0].seen })
            m.goToBurst(j)
            await Self.press("f", m)
            for _ in 0..<(m.frames.count + 3) { await Self.press("f", m, held: true) }
            #expect(m.burstIndex == j, "a held F crossed a burst")
            #expect(m.isLastFrameOfBurst)
            #expect(!m.bursts[j].seen)
            #expect(KeysTests.reviews().count == 1)
        }

        @Test("R finishes the burst as N does and records it; W goes back and records nothing")
        func rAndW() async throws {
            let m = try KeysTests.model()
            let i = try #require(m.bursts.indices.first { $0 + 1 < m.bursts.count && !m.bursts[$0].seen })
            m.goToBurst(i)
            await Self.press("r", m)
            #expect(m.burstIndex == i + 1)
            #expect(m.bursts[i].seen, "R left the burst unrecorded")
            #expect(KeysTests.reviews().count == 1)
            #expect(m.session.undo.steps.last.map { if case .finishBurst = $0.kind { true } else { false } } == true,
                    "the same undo step N leaves")

            await Self.press("w", m)
            #expect(m.burstIndex == i)
            #expect(KeysTests.reviews().count == 1, "W recorded something")

            // A held R is one press.
            await Self.press("r", m)
            for _ in 0..<4 { await Self.press("r", m, held: true) }
            #expect(m.burstIndex == i + 1, "a held R ran on out of the burst")
        }

        @Test("E keeps and moves on, Q takes it back, and X clears a mark")
        func eQAndX() async throws {
            let m = try KeysTests.model()
            m.goToFrame(0)
            let stem = try #require(m.currentStem)
            ViewerTests.show(m)
            await Self.press("e", m)
            await m.allSettled()
            #expect(m.session.rows[stem].map(VerdictValue.his) == .kept)
            #expect(m.frameIndex == 1, "E did not move on as K does")

            await Self.press("q", m)
            await m.allSettled()
            #expect(m.currentStem == stem, "Q did not go back to the frame it took back")
            #expect(m.session.rows[stem].map(VerdictValue.his) != .kept, "Q took nothing back")

            ViewerTests.show(m)
            await Self.press("d", m)
            await m.allSettled()
            #expect(m.session.rows[stem].map(VerdictValue.his) == .out)
            await Self.press("s", m)
            ViewerTests.show(m)
            await Self.press("x", m)
            await m.allSettled()
            #expect(m.session.rows[stem].map(VerdictValue.his) == .unmarked, "X left the mark on")
        }

        @Test("in Compare, F and S move the ring and E keeps the frame in it")
        func inCompare() async throws {
            let m = try KeysTests.model(stackAt: 0)
            let stack = try #require(m.stacks.first { $0.count >= 3 })
            m.openCompare(on: stack.frames)
            try #require(m.mode == .compare)
            let first = try #require(m.compareFocus)
            await Self.press("f", m)
            let second = try #require(m.compareFocus)
            #expect(second != first, "F did not move the ring")
            await Self.press("s", m)
            #expect(m.compareFocus == first, "S did not move the ring back")
            #expect(m.mode == .compare, "S left Compare")

            for s in m.compareSelection { m.didDisplayTile(s) }
            await Self.press("e", m)
            await m.allSettled()
            #expect(m.session.rows[first].map(VerdictValue.his) == .kept)
        }
    }
}
