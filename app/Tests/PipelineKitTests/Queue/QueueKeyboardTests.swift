import Testing
import AppKit
import SwiftUI
@testable import PipelineKit

// The list could only be reordered by a drag or a two-click menu, and a
// comment said every row could be moved from the keyboard. A row can be
// picked now, and ⌥⌘↑, ⌥⌘↓ and ⌥⌘Home move it. Checked the way AppKit
// delivers them: as key equivalents to a real window, never shown.

@Suite("Moving a row from the keyboard", .serialized)
@MainActor
struct QueueKeyboardTests {

    static let three = QueueState(
        waiting: [QueueItem(id: 11, kind: "ingest", shoot: "a", does: "Copy it."),
                  QueueItem(id: 12, kind: "cull", shoot: "a", does: "Cull it."),
                  QueueItem(id: 13, kind: "presets", shoot: "a", does: "Write them.")],
        listed: 3)

    /// Hosts the list in a window that is never ordered in, lets it lay out,
    /// and hands it the key.
    static func press(_ arrow: Int, _ flags: NSEvent.ModifierFlags, picked: Int?) -> [(IndexSet, Int)] {
        _ = NSApplication.shared
        var moves: [(IndexSet, Int)] = []
        let list = QueueList(state: three, move: { moves.append(($0, $1)) }, selected: picked)
        let w = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 640, height: 400),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        defer { w.close() }
        let h = NSHostingView(rootView: list.frame(width: 640, height: 400))
        w.contentView = h
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            h.layoutSubtreeIfNeeded()
        }
        let key = String(UnicodeScalar(arrow)!)
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                 windowNumber: w.windowNumber, context: nil, characters: key,
                                 charactersIgnoringModifiers: key, isARepeat: false,
                                 keyCode: arrow == NSUpArrowFunctionKey ? 126
                                    : arrow == NSDownArrowFunctionKey ? 125 : 115)!
        _ = w.performKeyEquivalent(with: e)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        return moves
    }

    @Test("⌥⌘↑ moves the picked row up one place")
    func up() {
        let m = Self.press(NSUpArrowFunctionKey, [.command, .option], picked: 12)
        #expect(m.count == 1)
        #expect(m.first?.0 == IndexSet(integer: 1) && m.first?.1 == 0)
    }

    @Test("⌥⌘↓ moves it down one place")
    func down() {
        let m = Self.press(NSDownArrowFunctionKey, [.command, .option], picked: 12)
        #expect(m.first?.0 == IndexSet(integer: 1) && m.first?.1 == 3)
    }

    @Test("⌥⌘Home sends it to the top: Do Next")
    func doNext() {
        let m = Self.press(NSHomeFunctionKey, [.command, .option], picked: 13)
        #expect(m.first?.0 == IndexSet(integer: 2) && m.first?.1 == 0, "\(m)")
    }

    @Test("nothing picked, nothing moves; the first row does not move up")
    func nothingToMove() {
        #expect(Self.press(NSUpArrowFunctionKey, [.command, .option], picked: nil).isEmpty)
        #expect(Self.press(NSUpArrowFunctionKey, [.command, .option], picked: 11).isEmpty)
    }
}
