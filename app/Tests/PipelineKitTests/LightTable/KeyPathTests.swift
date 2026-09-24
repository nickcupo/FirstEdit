import Foundation
import AppKit
import SwiftUI
import Testing
@testable import PipelineKit

/// The one path a key takes to the light table (DESIGN.md §2.5.3), driven the
/// way AppKit drives it: through the window's key equivalents and
/// `NSApplication.sendEvent`, never by calling `ViewerModel.key` directly —
/// which is how the old tests passed while a held K kept a run of frames.
///
/// No window here is ever ordered onto a screen.
@Suite("Every key reaches the light table by one path", .serialized)
@MainActor
struct KeyPathTests {

    static func window() -> NSWindow {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: 780),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    static func key(_ c: String, keyCode: UInt16, in w: NSWindow, repeat: Bool = false,
                    up: Bool = false, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                         context: nil, characters: c, charactersIgnoringModifiers: c,
                         isARepeat: `repeat`, keyCode: keyCode)!
    }

    static let kCode: UInt16 = 40, nCode: UInt16 = 45, dCode: UInt16 = 2, cCode: UInt16 = 8

    static func settle() async {
        for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(2)); await Task.yield() }
    }

    @Test("no button in the control bar takes K, D, N or C for itself")
    func barHoldsNoKeys() throws {
        let m = try ViewerTests.model()
        let w = Self.window()
        defer { w.close() }
        let host = NSHostingView(rootView: ControlBar(model: m).frame(width: 1100, height: 56))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 56)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        // AppKit offers a key to the window's key equivalents before any view
        // sees it as a press. A bare shortcut on Keep took K here, repeats and
        // all, and the rule that a held key counts once never ran.
        let left: [(String, UInt16)] = [("e", 14), ("s", 1), ("f", 3), ("r", 15), ("w", 13), ("x", 7), ("q", 12)]
        for (c, code) in [("k", Self.kCode), ("d", Self.dCode), ("n", Self.nCode), ("c", Self.cCode)] + left {
            #expect(!w.performKeyEquivalent(with: Self.key(c, keyCode: code, in: w)),
                    "a button in the bar took \(c.uppercased())")
            #expect(!w.performKeyEquivalent(with: Self.key(c, keyCode: code, in: w, repeat: true)),
                    "a button in the bar took a held \(c.uppercased())")
        }
    }

    @Test("a held K keeps one frame, and a held N finishes one burst, through the event path")
    func heldKeysThroughEvents() async throws {
        let log = WriteLog()
        let m = try ViewerTests.model(log: log)
        ViewerTests.show(m)
        let w = Self.window()
        defer { w.close() }
        let sink = LightTableKeyView(model: m)
        w.contentView = sink
        #expect(sink.isListening)

        NSApp.sendEvent(Self.key("k", keyCode: Self.kCode, in: w))
        for _ in 0..<30 { NSApp.sendEvent(Self.key("k", keyCode: Self.kCode, in: w, repeat: true)) }
        // Read as the repeats land: the line stays up four seconds of wall
        // time, which a full run on a busy machine can spend in the settle.
        #expect(m.showHeldKeyTip, "and the line that says so came up")
        await Self.settle()
        #expect(await log.writes.count == 1, "a held K kept more than the frame he pressed it on")
        #expect(m.pressesIgnoredAsRepeat == 30)

        // N held: only the first press is a press. The engine here is a dead
        // port, so even that one is refused — what matters is that the
        // repeats never became presses at all.
        let ignored = m.pressesIgnoredAsRepeat
        NSApp.sendEvent(Self.key("n", keyCode: Self.nCode, in: w))
        for _ in 0..<5 { NSApp.sendEvent(Self.key("n", keyCode: Self.nCode, in: w, repeat: true)) }
        await Self.settle()
        #expect(m.pressesIgnoredAsRepeat == ignored + 5)
        #expect(!m.bursts.contains { $0.seen }, "a held N marked bursts he never looked at")
        sink.stopListening()
    }

    @Test("keys arrive whatever has the keyboard, and never while he is typing")
    func whateverHasTheKeyboard() async throws {
        let log = WriteLog()
        let m = try ViewerTests.model(log: log)
        let w = Self.window()
        defer { w.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 780))
        w.contentView = content
        let sink = LightTableKeyView(model: m)
        content.addSubview(sink)
        defer { sink.stopListening() }

        // Nothing has the keyboard — what coming back from Full Image, or a
        // click on the sidebar or a thumbnail, used to leave behind.
        w.makeFirstResponder(nil)
        let start = m.frameIndex
        NSApp.sendEvent(Self.key(String(UnicodeScalar(NSRightArrowFunctionKey)!), keyCode: 124, in: w))
        await Self.settle()
        #expect(m.frameIndex == start + 1, "→ was dead with nothing holding the keyboard")

        // A text field that is being typed into keeps its letters.
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        content.addSubview(field)
        w.makeFirstResponder(field)
        #expect(MenuValidation.isTextEditing(in: w))
        ViewerTests.show(m)
        NSApp.sendEvent(Self.key("k", keyCode: Self.kCode, in: w))
        await Self.settle()
        #expect(await log.writes.isEmpty, "a k typed into a field kept a photograph")
    }

    @Test("a key pressed in another window is not the light table's")
    func otherWindows() async throws {
        let log = WriteLog()
        let m = try ViewerTests.model(log: log)
        ViewerTests.show(m)
        let w = Self.window(), other = Self.window()
        defer { w.close(); other.close() }
        let sink = LightTableKeyView(model: m)
        w.contentView = sink
        defer { sink.stopListening() }
        NSApp.sendEvent(Self.key("k", keyCode: Self.kCode, in: other))
        await Self.settle()
        #expect(await log.writes.isEmpty)
    }

    @Test("Esc with nothing to leave is taken quietly, and ⇧⌘Z goes on only when there is something to redo")
    func quietWhenNothingToDo() throws {
        let m = try ViewerTests.model()
        #expect(m.mode == .single && !m.fullImage)
        // Nothing else in the window answers Esc: passed on, it beeped.
        #expect(m.key(KeyMap.Press(key: .escape)), "Esc with nothing to leave went on to the beep")
        m.setFullImage(true)
        #expect(m.key(KeyMap.Press(key: .escape)), "in Full Image Esc is his way out")
        m.setFullImage(false)

        let w = Self.window()
        defer { w.close() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        let owner = UndoOwner(undo)
        w.contentView = owner
        w.makeFirstResponder(owner)
        let redo = Self.key("z", keyCode: 6, in: w, flags: [.command, .shift])
        #expect(!m.key(KeyMap.Press(event: redo)), "the light table has no redo of its own")
        #expect(LightTableKeys.route(redo, to: m, in: w),
                "⇧⌘Z with nothing to redo went on to a greyed Redo and the beep")
        undo.beginUndoGrouping()
        // Undoing it registers the redo, as any real undo does.
        undo.registerUndo(withTarget: owner) { o in o.undo.registerUndo(withTarget: o) { _ in } }
        undo.endUndoGrouping()
        undo.undo()
        #expect(undo.canRedo)
        #expect(!LightTableKeys.route(redo, to: m, in: w), "a redo there is to do is the Edit menu's")
    }

    @Test("with Full Keyboard Access on, Space presses the button he tabbed to, and is Full Image otherwise")
    func fullKeyboardAccess() async throws {
        let m = try ViewerTests.model()
        let w = Self.window()
        defer { w.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 780))
        w.contentView = content
        let button = NSButton(title: "Keep", target: nil, action: nil)
        content.addSubview(button)
        let saved = LightTableKeys.fullKeyboardAccess
        defer { LightTableKeys.fullKeyboardAccess = saved }
        let space = Self.key(" ", keyCode: 49, in: w)

        LightTableKeys.fullKeyboardAccess = { true }
        w.makeFirstResponder(button)
        #expect(w.firstResponder === button)
        #expect(!LightTableKeys.route(space, to: m, in: w), "Space was taken from the focused button")

        // Nothing focused, or the setting off: Space is Full Image.
        w.makeFirstResponder(nil)
        #expect(LightTableKeys.route(space, to: m, in: w))
        await Self.settle()
        #expect(m.fullImage)
        m.setFullImage(false)
        LightTableKeys.fullKeyboardAccess = { false }
        w.makeFirstResponder(button)
        #expect(LightTableKeys.route(space, to: m, in: w))
    }

    @Test("every control in the bar names its key in its help tag, the left hand's first")
    func helpNamesTheKey() throws {
        #expect(LightTableKeys.key(CommandTable.ID.keep) == "E or K")
        #expect(LightTableKeys.key(CommandTable.ID.drop) == "D")
        #expect(LightTableKeys.key(CommandTable.ID.finishBurst) == "R or N")
        #expect(LightTableKeys.key(CommandTable.ID.nextFrame) == "F or →")
        #expect(LightTableKeys.key(CommandTable.ID.previousFrame) == "S or ←")
        #expect(LightTableKeys.key(CommandTable.ID.clearMark) == "X or 0")
        #expect(LightTableKeys.key("edit.undo") == "⌘Z, Q or U")
        #expect(LightTableKeys.keys(CommandTable.ID.nextFrame, CommandTable.ID.finishBurst) == "F, →, R or N")
        #expect(Strings.LightTable.withKey("Keep", "K") == "Keep (K)")
        #expect(Strings.LightTable.withKey("Keep", nil) == "Keep")

        // The chevrons, on a frame in the middle of a burst and on its last.
        let m = try ViewerTests.model()
        let i = try #require(m.bursts.indices.first { $0 > 0 && $0 + 1 < m.bursts.count && m.bursts[$0].frames.count >= 2 })
        m.goToBurst(i)
        m.goToFrame(0)
        #expect(ControlBar(model: m).nextHelp == "Next frame (F or →)")
        #expect(ControlBar(model: m).previousHelp == "Last frame of the burst before (S or ←)")
        m.goToFrame(1)
        #expect(ControlBar(model: m).previousHelp == "Previous frame (S or ←)")
        m.goToFrame(m.frames.count - 1)
        #expect(ControlBar(model: m).nextHelp == "Finish this burst and open the next (F, →, R or N)")
    }
}

/// A view that owns an undo manager, as a window's content does.
@MainActor
final class UndoOwner: NSView {
    let undo: UndoManager
    init(_ undo: UndoManager) {
        self.undo = undo
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    }
    required init?(coder: NSCoder) { fatalError("not used from a nib") }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { undo }
}

/// All Bursts (G), whose keys used to be dead and whose Keep reached a frame
/// hidden behind the grid (DESIGN.md §2.5.11).
@Suite("All Bursts answers its own keys", .serialized)
@MainActor
struct AllBurstsKeysTests {

    @Test("G opens it and G again goes back; so do Return and Esc")
    func gToggles() async throws {
        let m = try ViewerTests.model()
        for leave in [KeyMap.Press("g"), KeyMap.Press(key: .return), KeyMap.Press(key: .escape)] {
            _ = m.key(KeyMap.Press("g"))
            await ViewerTests.press(m, .fit)
            #expect(m.mode == .allBursts)
            #expect(m.key(leave), "All Bursts did not answer \(leave)")
            await ViewerTests.press(m, .fit)
            #expect(m.mode == .single, "\(leave) did not go back")
        }
    }

    @Test("Space and the zoom keys do nothing in All Bursts, as their greyed rows say")
    func nothingToLookAt() async throws {
        let m = try ViewerTests.model()
        await ViewerTests.press(m, .allBursts)
        #expect(m.key(KeyMap.Press(key: .space)))
        _ = m.key(KeyMap.Press("z"))
        await ViewerTests.press(m, .oneToOne)
        #expect(!m.fullImage, "Space put up Full Image of the frame behind the grid")
        #expect(m.zoom.isFit)
        #expect(m.mode == .allBursts)
        for a: KeyMap.Action in [.toggleFullImage, .toggleOneToOne, .oneToOne, .fit, .zoomIn, .zoomOut] {
            m.mode = .allBursts
            #expect(!LightTableCommands.enabled(a, m), "the key is refused but its row is not greyed")
        }
    }

    @Test("K and D in All Bursts decide nothing")
    func noVerdicts() async throws {
        let log = WriteLog()
        let m = try ViewerTests.model(log: log)
        ViewerTests.show(m)
        await ViewerTests.press(m, .allBursts)
        await ViewerTests.press(m, .keep)
        await ViewerTests.press(m, .drop)
        #expect(await log.writes.isEmpty, "a verdict landed on a frame hidden behind the grid")
    }

    @Test("a cover counts his keepers as the tally does, and keeps up as he keeps")
    func coverCountsLikeTheTally() async throws {
        let m = try BurstCrossingTests.model()
        ViewerTests.show(m)
        let burst = try #require(m.currentBurst)
        let before = m.tally.kept
        #expect(m.keptByHim(in: burst) == before)
        await ViewerTests.press(m, .keep)
        #expect(m.tally.kept == before + 1)
        #expect(m.keptByHim(in: burst) == before + 1, "the cover's count stayed where the shoot opened")
    }

    @Test("← → move a burst and ↑ ↓ move a row")
    func arrows() async throws {
        let m = try ViewerTests.model()
        m.goToBurst(0)
        await ViewerTests.press(m, .allBursts)
        m.allBurstsColumns = 4
        await ViewerTests.press(m, .nextFrame)
        #expect(m.burstIndex == 1)
        await ViewerTests.press(m, .nextPick)
        #expect(m.burstIndex == min(5, m.bursts.count - 1))
        await ViewerTests.press(m, .previousPick)
        #expect(m.burstIndex == 1)
        #expect(m.mode == .allBursts)
    }
}

/// Z, and the right-click menu on the photograph (DESIGN.md §2.5.3, §2.5.8).
@Suite("Z comes back, and the right-click menu matches the Frame menu", .serialized)
@MainActor
struct StageMenuTests {

    @Test("Z goes to 1:1 and Z again goes back to Fit; ⌘0 stays at 1:1")
    func zToggles() async throws {
        let m = try ViewerTests.model()
        #expect(m.zoom.isFit)
        _ = m.key(KeyMap.Press("z"))
        await ViewerTests.press(m, .single)          // lets the Z through the queue
        #expect(!m.zoom.isFit)
        _ = m.key(KeyMap.Press("z"))
        await ViewerTests.press(m, .single)
        #expect(m.zoom.isFit, "Z did not come back out")
        await ViewerTests.press(m, .oneToOne)
        await ViewerTests.press(m, .oneToOne)
        #expect(!m.zoom.isFit)
        // From a pinched in-between zoom, Z is 1:1, not Fit.
        for between in [0.6, 1.5] {
            m.zoom.state = .factor(between)
            _ = m.key(KeyMap.Press("z"))
            await ViewerTests.press(m, .single)
            #expect(m.zoom.state == .factor(1), "Z from \(Int(between * 100)) % went to Fit")
        }
    }

    @Test("the reasons carry their bare digit, under the Frame menu's title and words")
    func reasons() throws {
        let m = try ViewerTests.model()
        let menu = StageMenu.menu(for: m)
        let why = try #require(menu.items.first { $0.submenu != nil })
        #expect(why.title == Words.Frame.whyItIsOut)
        for (item, r) in zip(why.submenu!.items, DropReason.allCases) {
            #expect(item.keyEquivalent == "\(r.key)")
            #expect(item.keyEquivalentModifierMask.intersection([.command, .option, .control]).isEmpty,
                    "\(item.title) showed ⌘\(r.key), which is a step of the Go menu")
            #expect(item.title == r.word.capitalizedFirst)
        }
        #expect(menu.items.contains { $0.title == Words.Frame.showInFinder })
        #expect(menu.items.contains { $0.title == Words.Frame.copyNumber })
    }
}
