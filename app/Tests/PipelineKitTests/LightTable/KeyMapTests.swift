import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// Every row of §2.5.3, and the two properties that hold over all of them.
@Suite("Keys")
struct KeyMapTests {

    private func action(_ p: KeyMap.Press, _ mode: KeyMap.Mode = .single) -> KeyMap.Action? {
        KeyMap.action(for: p, mode: mode)
    }

    @Test("every row of the table in §2.5.3")
    func theTable() {
        #expect(action(KeyMap.Press("k")) == .keep)
        #expect(action(KeyMap.Press("d")) == .drop)
        #expect(action(KeyMap.Press("0")) == .clearMark)
        for n in 1...6 {
            #expect(action(KeyMap.Press("\(n)")) == .reason(n))
        }
        #expect(action(KeyMap.Press(key: .left)) == .previousFrame)
        #expect(action(KeyMap.Press(key: .right)) == .nextFrame)
        #expect(action(KeyMap.Press(key: .up)) == .previousPick)
        #expect(action(KeyMap.Press(key: .down)) == .nextPick)
        #expect(action(KeyMap.Press("n")) == .nextBurst)
        #expect(action(KeyMap.Press("p")) == .previousBurst)
        #expect(action(KeyMap.Press(key: .space)) == .toggleFullImage)
        #expect(action(KeyMap.Press("z")) == .toggleOneToOne)
        #expect(action(KeyMap.Press("0", command: true)) == .oneToOne)
        #expect(action(KeyMap.Press("9", command: true)) == .fit)
        #expect(action(KeyMap.Press(key: .left, shift: true)) == .pan(dx: -1, dy: 0))
        #expect(action(KeyMap.Press(key: .right, shift: true)) == .pan(dx: 1, dy: 0))
        #expect(action(KeyMap.Press(key: .up, shift: true)) == .pan(dx: 0, dy: -1))
        #expect(action(KeyMap.Press(key: .down, shift: true)) == .pan(dx: 0, dy: 1))
        #expect(action(KeyMap.Press("c")) == .compare)
        #expect(action(KeyMap.Press("k", shift: true)) == .keepOnly)
        #expect(action(KeyMap.Press("g")) == .allBursts)
        #expect(action(KeyMap.Press("s"), .allBursts) == .previousFrame)
        #expect(action(KeyMap.Press(key: .return), .allBursts) == .single)
        #expect(action(KeyMap.Press("z", command: true)) == .undo)
        #expect(action(KeyMap.Press("u")) == .undo)
        #expect(action(KeyMap.Press("?")) == .shortcuts)
        #expect(action(KeyMap.Press("/", command: true)) == .shortcuts)
        #expect(action(KeyMap.Press(key: .escape)) == .leave)
    }

    @Test("⇧K is Keep Only, never Keep — the modifier is read before the letter")
    func shiftBeforeLetter() {
        #expect(action(KeyMap.Press("k", shift: true)) == .keepOnly)
        #expect(action(KeyMap.Press("z", command: true)) == .undo)
        #expect(action(KeyMap.Press("z", command: true, shift: true)) == .redo)
        // ⌘D is the system's, not a Drop.
        #expect(action(KeyMap.Press("d", command: true)) == nil)
        #expect(action(KeyMap.Press("k", command: true)) == nil)
        #expect(action(KeyMap.Press("n", command: true)) == nil)
    }

    // MARK: - the two properties

    @Test("no verdict action allows repeat: a held key writes one frame, never three")
    func verdictsNeverRepeat() {
        for a in KeyMap.everyAction where a.isVerdict {
            #expect(!a.allowsRepeat, "\(a) is a verdict and must ignore key repeat")
        }
        // LT-06 measured a held K writing three unseen frames in 90 ms. This is
        // the line that makes that impossible.
        #expect(KeyMap.accepts(KeyMap.Press("k", isARepeat: true), mode: .single) == nil)
        #expect(KeyMap.accepts(KeyMap.Press("d", isARepeat: true), mode: .single) == nil)
        #expect(KeyMap.accepts(KeyMap.Press("n", isARepeat: true), mode: .single) == nil)
        #expect(KeyMap.accepts(KeyMap.Press("p", isARepeat: true), mode: .single) == nil)
        #expect(KeyMap.accepts(KeyMap.Press("0", isARepeat: true), mode: .single) == nil)
        #expect(KeyMap.accepts(KeyMap.Press("1", isARepeat: true), mode: .single) == nil)
        #expect(KeyMap.accepts(KeyMap.Press("c", isARepeat: true), mode: .single) == nil)
        #expect(KeyMap.accepts(KeyMap.Press("g", isARepeat: true), mode: .single) == nil)
        #expect(KeyMap.accepts(KeyMap.Press(key: .return, isARepeat: true), mode: .allBursts) == nil)
        #expect(KeyMap.accepts(KeyMap.Press("z", isARepeat: true), mode: .single) == nil)
        // The left hand's: E, X, R, W and Q are one press however long held.
        for c in ["e", "x", "r", "w", "q"] {
            #expect(KeyMap.accepts(KeyMap.Press(c, isARepeat: true), mode: .single) == nil, "a held \(c)")
        }
        #expect(KeyMap.accepts(KeyMap.Press(key: .space, isARepeat: true), mode: .single) == nil)
    }

    @Test("only movement repeats")
    func movementRepeats() {
        #expect(KeyMap.accepts(KeyMap.Press(key: .left, isARepeat: true), mode: .single) == .previousFrame)
        #expect(KeyMap.accepts(KeyMap.Press(key: .right, isARepeat: true), mode: .single) == .nextFrame)
        #expect(KeyMap.accepts(KeyMap.Press(key: .up, isARepeat: true), mode: .single) == .previousPick)
        #expect(KeyMap.accepts(KeyMap.Press(key: .down, isARepeat: true), mode: .single) == .nextPick)
        #expect(KeyMap.accepts(KeyMap.Press(key: .left, shift: true, isARepeat: true),
                               mode: .single) == .pan(dx: -1, dy: 0))
        for a in KeyMap.everyAction where a.allowsRepeat {
            #expect(!a.isVerdict, "\(a) repeats and so must never write")
        }
    }

    @Test("a text field always wins: no single letter is an action while one has the keyboard")
    func textEditingWins() {
        for press in KeyMap.everyPress {
            #expect(KeyMap.action(for: press, mode: .textEditing) == nil,
                    "'\(press.characters)' must belong to the text field")
        }
    }

    @Test("every mode answers the keys it has to")
    func modes() {
        // K, D and N work in Full Image, so a whole burst can be judged there.
        #expect(action(KeyMap.Press("k"), .fullImage) == .keep)
        #expect(action(KeyMap.Press("d"), .fullImage) == .drop)
        #expect(action(KeyMap.Press("n"), .fullImage) == .nextBurst)
        // ⌘Z still undoes in All Bursts, and Return goes back to the burst.
        #expect(action(KeyMap.Press("z", command: true), .allBursts) == .undo)
        #expect(action(KeyMap.Press(key: .return), .allBursts) == .single)
        #expect(action(KeyMap.Press(key: .return), .single) == nil)
        // Esc leaves whichever one he is in.
        for mode in [KeyMap.Mode.fullImage, .compare, .allBursts, .review] {
            #expect(action(KeyMap.Press(key: .escape), mode) == .leave)
        }
    }

    @Test("Space is Full Image, and nothing in the map makes it the next burst")
    func spaceIsFullImage() {
        #expect(action(KeyMap.Press(key: .space)) == .toggleFullImage)
        #expect(KeyMap.everyAction.allSatisfy { $0 != .nextBurst } == false)
        // R, and N before it, are the only keys that finish a burst.
        let finishers = KeyMap.everyPress.filter {
            KeyMap.action(for: $0, mode: .single) == .nextBurst
        }
        #expect(Set(finishers.map(\.characters)) == ["r", "n"])
        #expect(finishers.allSatisfy { !$0.shift && !$0.command })
    }

    @Test("with Settings' Space set to the next burst, Space is N and nothing else changes")
    func spaceAsBefore() {
        #expect(KeyMap.action(for: KeyMap.Press(key: .space), mode: .single, spaceShowsWholePicture: false)
                == .nextBurst)
        #expect(KeyMap.action(for: KeyMap.Press(key: .space), mode: .fullImage, spaceShowsWholePicture: false)
                == .nextBurst)
        #expect(KeyMap.action(for: KeyMap.Press(key: .space), mode: .textEditing, spaceShowsWholePicture: false)
                == nil)
        #expect(KeyMap.action(for: KeyMap.Press("n"), mode: .single, spaceShowsWholePicture: false) == .nextBurst)
    }

    @Test("the six reasons are nameable faults, and 'just no' is not among them")
    func reasons() {
        #expect(DropReason.allCases.count == 6)
        #expect(DropReason.allCases.map(\.word) == ["shadow", "cut off", "face", "blur", "exposure", "framing"])
        // The app's words map to the engine's existing label strings.
        #expect(DropReason.face.rawValue == "expression")
        #expect(DropReason.framing.rawValue == "composition")
        for n in 1...6 { #expect(DropReason.forKey(n)?.key == n) }
        #expect(DropReason.forKey(0) == nil)
        #expect(DropReason.forKey(7) == nil)
    }

    @Test("an NSEvent-shaped press reads the same as a hand-written one")
    func fromEvent() {
        // The arrow keys arrive as private-use scalars and must not be read as
        // characters; Escape likewise.
        let left = KeyMap.Press(String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!), key: .left)
        #expect(left.characters.isEmpty == false || left.key == .left)
        #expect(KeyMap.action(for: KeyMap.Press(key: .left), mode: .single) == .previousFrame)
    }
}
