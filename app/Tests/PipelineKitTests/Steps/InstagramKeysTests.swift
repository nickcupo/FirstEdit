import AppKit
import Foundation
import Testing
@testable import PipelineKit

/// The parity test (DESIGN.md §2.17): every key means on the Instagram step
/// what it means in Choose Keepers. He asked for it in so many words — "make
/// sure there is control parity so same way you maneuver the other steps
/// carries over and i'm not doing different buttons for forward and backward".
///
/// The key table is pinned by construction — the step reads `KeyMap` and has
/// none of its own — so what is pinned here is the meaning table: which of
/// Keepers' actions the step takes, and what each one does to a wall of cuts.
@Suite("The Instagram step's keys are Choose Keepers' keys", .serialized)
@MainActor
struct InstagramKeysTests {

    /// Every press worth trying, and the bare keys besides.
    static var presses: [KeyMap.Press] {
        KeyMap.everyPress + [KeyMap.SpecialKey.left, .right, .up, .down, .space, .escape, .return].map {
            KeyMap.Press(key: $0)
        }
    }

    /// Keepers' action for a press, to meaning, for every one Keepers reads.
    static let pinned: [(KeyMap.Action, InstagramMeaning, InstagramMeaning)] = [
        // (Keepers' action, on the wall, in the editor)
        (.nextFrame, .next, .next),
        (.previousFrame, .previous, .previous),
        (.keep, .include, .include),
        (.drop, .leaveOut, .leaveOut),
        (.clearMark, .clear, .clear),
        (.toggleFullImage, .open(.fit), .close),
        (.toggleOneToOne, .open(.oneToOne), .toggleOneToOne),
        (.undo, .undo, .undo),
        (.redo, .redo, .redo),
        (.leave, .nothing, .close),
        (.shortcuts, .shortcuts, .shortcuts),
    ]

    @Test("every key means on the wall what it means in Choose Keepers")
    func wallParity() {
        for p in Self.presses {
            let keepers = KeyMap.action(for: p, mode: .single)
            let here = InstagramKeys.action(p, .wall)
            #expect(here == keepers.flatMap { InstagramKeys.meaning(of: $0, in: .wall) },
                    "the wall reads \(p) differently from Keepers")
            // And the meaning of every action that moves or marks is pinned.
            if let a = keepers, let row = Self.pinned.first(where: { $0.0 == a }) {
                #expect(here == row.1, "\(p) is \(a) in Keepers but \(String(describing: here)) on the wall")
            }
        }
        // ↑ ↓ are a row of the wall; ⇧-arrows and ⌘9 are not the wall's.
        #expect(InstagramKeys.action(.init(key: .down), .wall) == .rowDown)
        #expect(InstagramKeys.action(.init(key: .up), .wall) == .rowUp)
        #expect(InstagramKeys.action(.init(key: .left, shift: true), .wall) == nil)
        #expect(InstagramKeys.action(.init("9", command: true), .wall) == nil)
        #expect(InstagramKeys.action(.init("0", command: true), .wall) == .open(.oneToOne))
    }

    @Test("every key Keepers reads over a large picture means the same in the editor")
    func editorParity() {
        for p in Self.presses {
            let keepers = KeyMap.action(for: p, mode: .fullImage)
            let here = InstagramKeys.action(p, .editor)
            if let a = keepers {
                #expect(here == InstagramKeys.meaning(of: a, in: .editor),
                        "the editor reads \(p) differently from Keepers")
                if let row = Self.pinned.first(where: { $0.0 == a }) {
                    #expect(here == row.2, "\(p) is \(a) in Keepers but \(String(describing: here)) in the editor")
                }
            } else if let here {
                // A key Keepers has no action for can only be one of the
                // editor's own, or Return, which is Done.
                let own = InstagramKeys.editorKeys.values.contains(here) || (p.key == .return && here == .close)
                #expect(own, "\(p) means \(here) in the editor and nothing in Keepers")
            }
        }
        #expect(InstagramKeys.action(.init(key: .right, shift: true), .editor) == .nudge(dx: 1, dy: 0))
        #expect(InstagramKeys.action(.init("0", command: true), .editor) == .oneToOne)
        #expect(InstagramKeys.action(.init("9", command: true), .editor) == .fit)
    }

    @Test("the editor's own keys are ones Choose Keepers does not use")
    func editorKeysAreFree() {
        for c in ["a", "t", "v", "-", "=", "+"] {
            for mode in [KeyMap.Mode.single, .fullImage, .compare, .allBursts, .review] {
                #expect(KeyMap.action(for: .init(c), mode: mode) == nil, "Keepers reads \(c) in \(mode)")
                #expect(KeyMap.action(for: .init(c, shift: true), mode: mode) == nil)
            }
            #expect(InstagramKeys.action(.init(c), .editor) != nil)
            // Never on the wall, and never with ⌘: those are the menu's.
            #expect(InstagramKeys.action(.init(c), .wall) == nil)
            #expect(InstagramKeys.action(.init(c, command: true), .editor) == KeyMap.action(for: .init(c, command: true), mode: .fullImage).flatMap { InstagramKeys.meaning(of: $0, in: .editor) })
        }
    }

    @Test("forward, back, include, leave out, clear, undo, open and leave are the same presses as Keepers'")
    func theSamePresses() {
        // Whatever key Keepers gives an action, the step's meaning follows it.
        let cases: [(KeyMap.Action, InstagramMeaning)] = [
            (.nextFrame, .next), (.previousFrame, .previous), (.keep, .include), (.drop, .leaveOut),
            (.clearMark, .clear), (.undo, .undo), (.toggleFullImage, .open(.fit)), (.leave, .nothing),
        ]
        for (action, meaning) in cases {
            let presses = Self.presses.filter { KeyMap.action(for: $0, mode: .single) == action }
            #expect(!presses.isEmpty, "Keepers has no key for \(action)")
            for p in presses { #expect(InstagramKeys.action(p, .wall) == meaning) }
        }
    }

    /// His one-handed layout: the keys he named, pinned one by one, so a
    /// change to Keepers' table that moved one of them fails here too.
    @Test("the left hand's keys work here as they do in Keepers")
    func leftHand() {
        #expect(KeyMap.action(for: .init("f"), mode: .single) == .nextFrame)
        let wall: [(KeyMap.Press, InstagramMeaning)] = [
            (.init("s"), .previous), (.init("f"), .next), (.init(key: .left), .previous), (.init(key: .right), .next),
            (.init("e"), .include), (.init("k"), .include), (.init("d"), .leaveOut), (.init("x"), .clear),
            (.init("q"), .undo), (.init("z", command: true), .undo), (.init(key: .space), .open(.fit)),
            (.init("z"), .open(.oneToOne)), (.init(key: .escape), .nothing),
        ]
        for (p, m) in wall { #expect(InstagramKeys.action(p, .wall) == m, "\(p) on the wall") }
        let editor: [(KeyMap.Press, InstagramMeaning)] = [
            (.init("s"), .previous), (.init("f"), .next), (.init("e"), .include), (.init("d"), .leaveOut),
            (.init("x"), .clear), (.init("q"), .undo), (.init(key: .space), .close), (.init("z"), .toggleOneToOne),
            (.init(key: .escape), .close),
        ]
        for (p, m) in editor { #expect(InstagramKeys.action(p, .editor) == m, "\(p) in the editor") }
    }

    @Test("Space opens and closes the editor whatever Settings ▸ Choosing's Space says: there are no bursts here")
    func spaceWithTheBurstSetting() throws {
        let space = KeyMap.Press(key: .space)
        #expect(KeyMap.action(for: space, mode: .single, spaceShowsWholePicture: false) == .nextBurst)
        #expect(InstagramKeys.action(space, .wall) == .open(.fit))
        #expect(InstagramKeys.action(space, .editor) == .close)
        #expect(InstagramKeys.action(.init(key: .space, shift: true), .wall) == .open(.fit))
        let m = try InstagramScaffold.model()
        #expect(m.key(space))
        #expect(m.editor != nil)
        #expect(m.key(space))
        #expect(m.editor == nil)
    }

    @Test("a held include marks one photograph, and a held arrow moves on every repeat")
    func heldKeys() throws {
        let m = try InstagramScaffold.model()
        let first = try #require(m.order.first)
        #expect(m.key(.init("k")))
        #expect(m.mark(first) == .include)
        let ringAfterOne = m.ring
        // Its repeats are taken, and do nothing.
        for _ in 0..<5 { #expect(m.key(.init("k", isARepeat: true))) }
        #expect(m.marks.values.filter { $0 == .include }.count == 1)
        #expect(m.ring == ringAfterOne)
        #expect(m.key(.init("e")))
        for _ in 0..<5 { #expect(m.key(.init("e", isARepeat: true))) }
        #expect(m.marks.values.filter { $0 == .include }.count == 2)
        // A held → moves on every repeat.
        let before = try #require(m.ring.flatMap { m.order.firstIndex(of: $0) })
        for _ in 0..<3 { #expect(m.key(.init(key: .right, isARepeat: true))) }
        #expect(m.ring == m.order[before + 3])
    }

    @Test("Return is not the wall's, so it presses Make; in the editor it is Done")
    func returnKey() throws {
        #expect(InstagramKeys.action(.init(key: .return), .wall) == nil)
        #expect(InstagramKeys.action(.init(key: .return), .editor) == .close)
        let m = try InstagramScaffold.model()
        #expect(!m.key(.init(key: .return)))
        m.open(m.order[2])
        #expect(m.key(.init(key: .return)))
        #expect(m.editor == nil)
    }

    @Test("the keys move the ring, mark, open, and step through the editor in the wall's order")
    func walking() throws {
        let m = try InstagramScaffold.model()
        #expect(m.key(.init(key: .right)))
        #expect(m.ring == m.order[0] && m.ringShown)
        #expect(m.key(.init(key: .right)))
        #expect(m.ring == m.order[1])
        #expect(m.key(.init(key: .left)) && m.key(.init(key: .left)))
        #expect(m.ring == m.order[0])       // stops at the end
        m.columns = 4
        #expect(m.key(.init(key: .down)))
        #expect(m.ring == m.order[4])
        #expect(m.key(.init("d")))
        #expect(m.mark(m.order[4]) == .leaveOut && m.ring == m.order[5])
        #expect(m.key(.init(key: .left)) && m.key(.init("0")))
        #expect(m.mark(m.order[4]) == nil && m.ring == m.order[4])     // clear stays put
        #expect(m.key(.init(key: .space)))
        #expect(m.editor?.stem == m.order[4] && m.editor?.view == .fit)
        #expect(m.key(.init(key: .right)))
        #expect(m.editor?.stem == m.order[5])
        #expect(m.key(.init("z")))
        #expect(m.editor?.view == .oneToOne)
        #expect(m.key(.init("z")))
        #expect(m.editor?.view == .fit)
        #expect(m.key(.init(key: .escape)))
        #expect(m.editor == nil && m.ring == m.order[5])
        // Esc on the wall is taken and does nothing.
        #expect(m.key(.init(key: .escape)))
        #expect(m.editor == nil)
    }

    @Test("a scroll over the photograph steps photographs as a scroll over the frame steps frames in Keepers")
    func scrollParity() throws {
        // Keepers' own stepper: one wheel notch toward him is the next frame
        // there, and so the next photograph here; away, the previous.
        func notch(_ down: CGFloat, option: Bool = false, at t: TimeInterval) -> [ScrollInput.FrameScroll.Step] {
            var s = ScrollInput.FrameScroll()
            return s.steps(down: down, across: 0, precise: false, began: false, option: option, at: t)
        }
        let forward = notch(-ScrollInput.lineHeight, at: 0)
        #expect(forward.map(\.action) == [.nextFrame])
        #expect(forward.compactMap { InstagramKeys.meaning(of: $0.action, in: .editor) } == [.next])
        let m = try InstagramScaffold.model()
        // On the wall a scroll is the wall's own: it scrolls, and steps nothing.
        m.scrolled(forward)
        #expect(m.editor == nil && m.ring == nil)
        m.open(m.order[3])
        m.scrolled(forward)
        #expect(m.editor?.stem == m.order[4])
        m.scrolled(notch(ScrollInput.lineHeight, at: 1))
        #expect(m.editor?.stem == m.order[3])
        // ⌥ is Keepers' picks, which mean nothing in the editor.
        m.scrolled(notch(-ScrollInput.lineHeight, option: true, at: 2))
        #expect(m.editor?.stem == m.order[3])
        // Result is fitted too, and steps; at 1:1 the scroll pans instead.
        m.perform(.result)
        m.scrolled(forward)
        #expect(m.editor?.stem == m.order[4] && m.editor?.view == .result)
        m.perform(.oneToOne)
        m.scrolled(forward)
        #expect(m.editor?.stem == m.order[4])
    }

    @Test("the editor's own keys are in the Keyboard Shortcuts window, each the key the editor reads")
    func shortcutsWindow() {
        let rows = ShortcutsCatalog.rows.filter { $0.menu == Strings.Steps.instagram }
        #expect(rows.count == InstagramKeys.shortcutRows.count)
        let expected: [(String, InstagramMeaning)] = [
            (Strings.Instagram.automaticCut, .automatic), (Strings.Instagram.cutOrWhole, .cutOrWhole),
            (Strings.Instagram.result, .result), (Strings.Instagram.smallerCut, .smaller),
            (Strings.Instagram.largerCut, .larger),
        ]
        for (title, meaning) in expected {
            let row = rows.first { $0.title == title }
            #expect(row?.keys == InstagramKeys.editorKey(meaning), "\(title) is listed with its key")
            // The key the window names is the one the editor reads.
            let typed = (row?.keys ?? "").replacingOccurrences(of: "−", with: "-").lowercased()
            #expect(InstagramKeys.action(.init(typed), .editor) == meaning, "\(title)'s key does it")
        }
        let move = rows.first { $0.title == Strings.Instagram.moveTheCut }
        #expect(move?.keys == "⇧←→↑↓")
        #expect(InstagramKeys.action(.init(key: .up, shift: true), .editor) == .nudge(dx: 0, dy: -1))
        // One letter asks what it does, as for Keepers' keys.
        #expect(ShortcutsCatalog.grouped(matching: "t").flatMap(\.1).map(\.title) == [Strings.Instagram.cutOrWhole])
        #expect(ShortcutsCatalog.grouped(matching: "-").flatMap(\.1).map(\.title) == [Strings.Instagram.smallerCut])
        // And none of them is a key Keepers lists for itself.
        let keepers = Set(ShortcutsCatalog.rows.filter { $0.menu != Strings.Steps.instagram }.compactMap(\.keys))
        for r in rows where r.keys != "⇧←→↑↓" { #expect(!keepers.contains(r.keys ?? ""), "\(r.title)") }
    }
}
