import AppKit

// The key table, derived from the menu bar and from nothing else.
//
// The light table builds its `KeyMap` out of `KeyBindings.all`, so a key that
// works under his hand is a key that is written in a menu, spoken by
// VoiceOver and re-bindable in System Settings. Neither list can gain a row
// the other does not have, because there is only one list.

/// One key that does something, and whether holding it down repeats.
public struct KeyBinding: Sendable, Equatable {
    public let shortcut: Shortcut
    public let command: CommandID
    /// Key *repeat* never writes one of his verdicts (LT-06).
    public let allowsRepeat: Bool
    /// Where the key came from in the menu bar, for the Shortcuts window.
    public let menu: MenuID

    public init(shortcut: Shortcut, command: CommandID, allowsRepeat: Bool, menu: MenuID) {
        self.shortcut = shortcut
        self.command = command
        self.allowsRepeat = allowsRepeat
        self.menu = menu
    }
}

@MainActor
public enum KeyBindings {

    /// Every key that works without a modifier: the single letters, the
    /// digits, Space and the four arrows. These belong to the focused view,
    /// which is why they must never fire while a text field has the keyboard.
    public static var unmodified: [KeyBinding] { all.filter { $0.shortcut.isUnmodified } }

    /// Every key equivalent in the whole bar, modifiers and all.
    public static let all: [KeyBinding] = {
        var out: [KeyBinding] = []
        for menu in CommandTable.menus {
            for c in menu.commands.flatMap(\.flattened) {
                guard let s = c.shortcut else { continue }
                // One action may sit in two menus under two names — Compare is
                // in Frame and in View. It is one key and one binding.
                if out.contains(where: { $0.command == c.id }) { continue }
                out.append(KeyBinding(shortcut: s, command: c.id,
                                      allowsRepeat: c.allowsRepeat, menu: menu.id))
            }
        }
        return out
    }()

    /// `?` opens the Keyboard Shortcuts window from the light table, where his
    /// hand is, alongside the menu's ⌘/.
    public static let questionMark = KeyBinding(shortcut: Shortcut("?"),
                                                command: CommandTable.ID.shortcuts,
                                                allowsRepeat: false, menu: .help)

    /// What the key table answers for a real key press, or nothing.
    ///
    /// A press while a text field has the keyboard resolves to nothing at all,
    /// so typing "k" into a search box types a k. A repeat of a key that does
    /// not repeat resolves to nothing, so a held K keeps one frame.
    public static func binding(for event: NSEvent, textEditing: Bool) -> KeyBinding? {
        guard let hit = match(event) else { return nil }
        if textEditing && hit.shortcut.isUnmodified { return nil }
        if event.isARepeat && !hit.allowsRepeat { return nil }
        return hit
    }

    static func match(_ event: NSEvent) -> KeyBinding? {
        let mods = Modifiers(event.modifierFlags)
        let chars = event.charactersIgnoringModifiers ?? ""
        if mods.isEmpty, chars == "?" { return questionMark }
        return (all + [questionMark]).first { b in
            b.shortcut.modifiers == mods && b.shortcut.matches(chars)
        }
    }
}

extension Shortcut {
    /// Whether a press of these characters is this shortcut.
    public func matches(_ characters: String) -> Bool {
        guard let c = characters.unicodeScalars.first else { return false }
        switch key {
        case .character(let want):
            return String(Character(c)).lowercased() == String(want).lowercased()
        case .space: return c == " "
        case .left: return Int(c.value) == NSLeftArrowFunctionKey
        case .right: return Int(c.value) == NSRightArrowFunctionKey
        case .up: return Int(c.value) == NSUpArrowFunctionKey
        case .down: return Int(c.value) == NSDownArrowFunctionKey
        }
    }
}

extension Modifiers {
    /// Only the four that a menu key equivalent can carry. Caps Lock, Fn and
    /// the numeric-pad bit are not part of a shortcut.
    public init(_ flags: NSEvent.ModifierFlags) {
        var m: Modifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        self = m
    }
}
