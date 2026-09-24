import SwiftUI
import AppKit

/// A step's primary action, which is either "do it now" or "add it to the
/// list" — and always says which.
///
/// Two rules, and they are the whole of it.
///
/// 1. **It never queues silently.** While nothing of his is running the
///    button is the step's own verb — *Cull It*, *Write the Presets* — and it
///    does that. While something is running, or while the list is held, the
///    button reads *Add Cull It to the List* and does that instead. The label
///    is read from the same thing that decides, so they cannot disagree.
/// 2. **⌥ always means add.** Held down, the label changes under his finger
///    the way a Finder menu does, and pressing it puts the work on the list
///    whether or not anything is running. That is how he stacks an evening up
///    from the step pages without going to the Activity window at all.
///
/// The box is `StepMetric.primaryBox` and does not change size between the
/// two, so nothing on the page moves when the answer changes.
public struct StepPrimary: View {
    let action: String
    let doItNow: () -> Void
    let addToTheList: () -> Void
    let disabled: Bool
    /// Whether pressing it without ⌥ would add rather than start. Read from
    /// the list, which is the same thing that decides what actually happens.
    let wouldWait: Bool
    /// Whether Return presses it. A step with a field of its own that Return
    /// means something in turns this off while that field has the keyboard:
    /// AppKit hands the window's default button the key before the field
    /// sees it, so on Reels, 93 and Return in the burst field cut whichever
    /// burst was already chosen.
    let returnKey: Bool

    @State private var optionHeld = false
    @Environment(\.stepOptionKey) private var optionKey

    public init(_ action: String, wouldWait: Bool, disabled: Bool = false, returnKey: Bool = true,
                doItNow: @escaping () -> Void, addToTheList: @escaping () -> Void) {
        self.action = action
        self.wouldWait = wouldWait
        self.disabled = disabled
        self.returnKey = returnKey
        self.doItNow = doItNow
        self.addToTheList = addToTheList
    }

    /// What the button says right now, and what pressing it will do. One
    /// value, so a label that says "Add" can never start a job.
    var adds: Bool { StepPrimaryWords.adds(wouldWait: wouldWait, optionHeld: optionHeld || optionKey) }

    public var body: some View {
        Button(StepPrimaryWords.label(action, adds: adds)) {
            if adds { addToTheList() } else { doItNow() }
        }
        .primaryActionStyle()
        .disabled(disabled)
        .keyboardShortcut(returnKey ? KeyboardShortcut.defaultAction : nil)
        .help(adds ? StepPrimaryWords.spoken(action, adds: true) : Strings.Queue.addedHelp)
        .accessibilityLabel(StepPrimaryWords.spoken(action, adds: adds))
        .accessibilityIdentifier("step.primary")
        .onModifierKeysChanged(mask: .option) { _, new in
            optionHeld = new.contains(.option)
        }
    }
}

extension EnvironmentValues {
    /// Set by a test or the snapshot harness to photograph the ⌥ label
    /// without a keyboard. Production leaves it false and reads the real key.
    @Entry public var stepOptionKey: Bool = false
}

/// The toolbar's copy of a step's primary action, with the same two rules.
///
/// It read only `wouldWait` and had no modifier observer at all, so with ⌥
/// held the box at the bottom of the page said *Add Cull It to the List* and
/// added, while the button at the top still said *Cull It* and started the
/// job — the exact thing rule 2 above says cannot happen. Its help tag was
/// hard-wired to one of the two states as well.
///
/// `shortcut` is the step's own, and most steps have none. It used to be
/// hard-wired to ⌘R here, which is Cull's — `CommandTable` gives ⌘R to
/// Shoot ▸ Cull, and the Cull step's old button carried it, so Cull was
/// unchanged. The Presets step's old button had no key at all, and a focused
/// button inside the window beats a menu command: on Presets, ⌘R wrote the
/// presets while the menu it came from said it culled. A step's toolbar button
/// may only carry a key the command table has not already given to something
/// else, and `StepShortcutTests` is the gate.
public struct StepPrimaryToolbarButton: View {
    let action: String
    let wouldWait: Bool
    /// The step's own key, or none. Never one the command table already owns
    /// for a different action.
    let shortcut: KeyEquivalent?
    /// Never available, whatever the modifier says — nothing to cull, nothing
    /// to write.
    let disabled: Bool
    /// This step's own work is running, stopping or waiting. Nothing it could
    /// do then is wanted, ⌥ or not: with his cull running, the button read
    /// "Add It to the List" and ⌘R put a second cull of the same shoot behind
    /// it, which started the moment the first one ended.
    let busy: Bool
    let doItNow: () -> Void
    let addToTheList: () -> Void

    @State private var optionHeld = false
    @Environment(\.stepOptionKey) private var optionKey

    public init(_ action: String, wouldWait: Bool, shortcut: KeyEquivalent? = nil,
                disabled: Bool = false, busy: Bool = false,
                doItNow: @escaping () -> Void, addToTheList: @escaping () -> Void) {
        self.action = action
        self.wouldWait = wouldWait
        self.shortcut = shortcut
        self.disabled = disabled
        self.busy = busy
        self.doItNow = doItNow
        self.addToTheList = addToTheList
    }

    var adds: Bool { StepPrimaryWords.adds(wouldWait: wouldWait, optionHeld: optionHeld || optionKey) }

    public var body: some View {
        Button(StepPrimaryWords.label(action, adds: adds)) {
            if adds { addToTheList() } else { doItNow() }
        }
        .disabled(disabled || busy)
        // `nil` means none: the overload that takes an optional is the only
        // way to say "this button has no key" without a branch in the body.
        .keyboardShortcut(shortcut.map { KeyboardShortcut($0, modifiers: .command) })
        .help(adds ? StepPrimaryWords.spoken(action, adds: true) : Strings.Queue.addedHelp)
        .accessibilityLabel(StepPrimaryWords.spoken(action, adds: adds))
        .onModifierKeysChanged(mask: .option) { _, new in
            optionHeld = new.contains(.option)
        }
    }
}

/// The same two choices, for a step whose action is in a menu or a toolbar
/// rather than in the primary's box: the label, worked out once.
@MainActor
public enum StepPrimaryWords {
    /// Whether pressing a step's primary action **now** puts the work on the
    /// list rather than starting it. Every control on a step asks this one
    /// question, with its own reading of the modifier, so the box at the
    /// bottom of the page and the button in the toolbar cannot disagree about
    /// what pressing them will do.
    public static func adds(wouldWait: Bool, optionHeld: Bool) -> Bool {
        optionHeld || wouldWait
    }

    /// What a step's action should be called right now. `adds` is the one
    /// value every control on the step reads, so the box and the toolbar
    /// cannot say two different things about what pressing them will do.
    public static func label(_ action: String, adds: Bool) -> String {
        adds ? Strings.Queue.addInstead : action
    }

    /// The whole sentence, for a help tag, VoiceOver and the Shoot menu's
    /// row. An action that asks first keeps its ellipsis at the end of the
    /// sentence, because it still asks when it adds: "Add Cull Again to Up
    /// Next…", where it read "Add Cull Again… to Up Next".
    public static func spoken(_ action: String, adds: Bool) -> String {
        guard adds else { return action }
        guard action.hasSuffix("…") else { return Strings.Queue.addInsteadSpoken(action) }
        return Strings.Queue.addInsteadSpoken(String(action.dropLast())) + "…"
    }

    /// Whether pressing an action now would add it to the list. The one
    /// reading every control on a step asks, so the button in the box and the
    /// item in the toolbar cannot say two different things.
    public static var wouldWait: Bool { Queues.wouldWait }

    /// The key a step's toolbar button may carry: **the command table's own**,
    /// for the very action that button performs, and none at all where the
    /// table gives that action none.
    ///
    /// It is derived rather than written down because a key written down twice
    /// is a key that can come to mean two things. ⌘R was hard-wired into
    /// `StepPrimaryToolbarButton`; the table gives ⌘R to Shoot ▸ Cull, so Cull
    /// was right by accident and Presets — which the table gives no key at all
    /// — took it. A focused button inside the window beats a menu command, so
    /// on the Presets step ⌘R wrote the presets while the menu it came from
    /// said it culled.
    ///
    /// Only a plain ⌘ and a letter. A toolbar button is one press of one
    /// action; anything the table spells with ⌥, ⇧ or ⌃ belongs to a menu item
    /// with its own wording, and a button is not the place to shadow it.
    public static func toolbarKey(for id: CommandID) -> KeyEquivalent? {
        guard let shortcut = CommandTable.shortcut(id), shortcut.modifiers == .command,
              case .character(let c) = shortcut.key else { return nil }
        return KeyEquivalent(Character(String(c).lowercased()))
    }
}
