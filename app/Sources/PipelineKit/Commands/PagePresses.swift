import SwiftUI
import AppKit
import Observation

// A Shoot menu row is a step page's own button, pressed from wherever he is
// (DESIGN.md §2.12).
//
// The row goes to the page, and the page presses its own button: the same
// closure the button runs, so the again-question, the ⌥-means-add rule and
// "Add It to the List" are one decision whether he clicked, pressed Return or
// chose the row. The menu never starts the work itself. Work started behind a
// page he cannot see has no progress box, no Stop and nowhere to say it was
// refused, and "the page's action" written twice is two actions that drift.
//
// These rows were registered by nothing, so Cull It, Write the Presets, Open
// My Keepers in PhotoLab, Cut a Reel, This Shoot Is Finished and the whole
// Storage submenu were greyed on every page while the Keyboard Shortcuts
// window promised ⌘R and ⇧⌘E.

/// The one press waiting for its page.
@MainActor @Observable
public final class PagePresses {
    public static let shared = PagePresses()

    public struct Press: Equatable, Sendable {
        public let command: CommandID
        public let shoot: String
        /// ⌥ was down when he chose the row: the work goes on the list,
        /// exactly as ⌥ on the page's own button does.
        public let optionHeld: Bool
        /// Two presses of the same row are two presses.
        let serial: Int
    }

    public private(set) var pending: Press?
    private var serial = 0

    public init() {}

    /// The page a row belongs to. Every Storage row is on Finish, where the
    /// storage panel is (§2.8).
    public static func step(for command: CommandID) -> String? {
        typealias ID = CommandTable.ID
        switch command {
        case ID.cull, ID.cullAgain: return "cull"
        case ID.writePresets: return "presets"
        case ID.openInEditor: return "edit"
        case ID.cutAReel: return "reels"
        case ID.finished: return "done"
        case ID.copyUp, ID.bringBack, ID.checkEvery, ID.takeBackCache, ID.removeLocal, ID.letGo:
            return "done"
        default: return nil
        }
    }

    public func ask(_ command: CommandID, shoot: String, optionHeld: Bool) {
        serial += 1
        pending = Press(command: command, shoot: shoot, optionHeld: optionHeld, serial: serial)
    }

    /// The page for this row and this shoot takes its press, once.
    public func take(_ commands: [CommandID], shoot: String) -> Press? {
        guard let p = pending, commands.contains(p.command), p.shoot == shoot else { return nil }
        pending = nil
        return p
    }

    /// He went somewhere else before the page came up. The press is dropped
    /// rather than kept for his next visit, where it would start work he
    /// chose minutes ago on a page he had not seen yet.
    public func forget(unlessOn selection: SidebarSelection?) {
        guard let p = pending else { return }
        if case .step(let shoot, let step) = selection, shoot == p.shoot, step == Self.step(for: p.command) {
            return
        }
        pending = nil
    }

    /// For tests.
    public func reset() { pending = nil }

    /// The kinds of work this shoot already has in hand: running now, or
    /// waiting on the list. Pressing Cull It or Write the Presets again while
    /// that shoot's own cull or presets is one of them would be a second copy
    /// of the same work, and the engine takes duplicates — a second ⌘R from
    /// the overview queued a second cull of the shoot being culled. So the
    /// row is grey, and a page that gets the press anyway ignores it.
    public static func inHand(shoot: String, job: Job?, list: QueueState) -> Set<String> {
        var kinds = Set<String>()
        if let j = job, j.running, j.shoot == shoot { kinds.insert(j.kind) }
        if list.running, list.shoot == shoot { kinds.insert(list.kind) }
        for w in list.waiting where w.shoot == shoot { kinds.insert(w.kind) }
        return kinds
    }
}

extension View {
    /// The page's answer to its rows in the menu bar: `press` is the closure
    /// its own button runs, handed the row he chose and whether ⌥ was held.
    /// A page that cannot do it right now ignores the press, the way its
    /// greyed button would.
    public func answersMenu(_ commands: [CommandID], shoot: String,
                            press: @escaping @MainActor (CommandID, _ optionHeld: Bool) -> Void) -> some View {
        modifier(AnswersMenu(commands: commands, shoot: shoot, press: press))
    }
}

private struct AnswersMenu: ViewModifier {
    let commands: [CommandID]
    let shoot: String
    let press: @MainActor (CommandID, Bool) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: PagePresses.shared.pending, initial: true) { _, p in
            guard p != nil, let taken = PagePresses.shared.take(commands, shoot: shoot) else { return }
            // After this update rather than inside it: a question the press
            // asks (Cull Again…) is a presentation, and one started in the
            // same update as the page appearing can be dropped.
            Task { @MainActor in press(taken.command, taken.optionHeld) }
        }
    }
}
