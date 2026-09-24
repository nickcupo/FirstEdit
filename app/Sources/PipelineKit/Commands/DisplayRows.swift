import Foundation

// DESIGN-displays.md §7.2 and §3.10: the two-display crew contributes rows and
// the command table takes them. Written here rather than in CommandTable.swift
// so the rows stay the other crew's to change, and translated once into the
// shape the menu bar already builds from.
//
// The keys were reserved in `CommandTable.reserved` before the rows existed.
// They are real rows now, so the reservation list is what proves nothing else
// took one while they were on their way.
extension CommandTable {

    /// One row per screen attached right now, under Window ▸ Put the Picture
    /// On. Set through `CommandCenter.setScreens(_:)` by whoever watches the
    /// displays; empty until then, and an empty group is left out of the menu
    /// rather than drawn as a submenu with nothing in it.
    @MainActor static var attachedScreens: [Command] = []

    /// The displays rows for one menu, in the order that crew listed them,
    /// as `Command` values the menu bar can build.
    @MainActor static func displayCommands(_ menu: DisplayCommandRow.Menu) -> [Command] {
        var out: [Command] = []
        var i = 0
        let rows = DisplayCommands.rows.filter { $0.menu == menu }
        while i < rows.count {
            let row = rows[i]
            i += 1
            guard row.isGroup else {
                out.append(command(from: row))
                continue
            }
            // A group takes the rows written under it. The ids are that
            // crew's own, and `displays.modes` holds `displays.mode.*` — the
            // plural is on the group and not on its rows — so the prefix is
            // named here rather than guessed from the group's id. Guessing it
            // put the three modes in the View menu as three loose rows with no
            // "On the Other Screen" above them.
            let prefix = childPrefix(of: row.identifier)
            var children: [Command] = []
            while i < rows.count, rows[i].identifier.hasPrefix(prefix) {
                children.append(command(from: rows[i]))
                i += 1
            }
            // "Put the Picture On ▸" has no rows written down: its children
            // are the screens attached right now.
            if children.isEmpty { children = attachedScreens }
            // A submenu with nothing in it is not a menu item; it is a dead
            // end with an arrow on it.
            guard !children.isEmpty else { continue }
            out.append(Command(CommandID(row.identifier), row.title, group: .looking,
                               children: children))
        }
        return out
    }

    private static func childPrefix(of group: String) -> String {
        switch group {
        case "displays.modes": return "displays.mode."
        default: return group + "."
        }
    }

    private static func command(from row: DisplayCommandRow) -> Command {
        Command(CommandID(row.identifier), row.title,
                key: row.shortcut.map(shortcut(from:)),
                group: .looking,
                // Bare H writes nothing, but it is a key held on a photograph
                // and a repeat of it is never wanted.
                allowsRepeat: row.shortcut?.modifiers.isEmpty != true)
    }

    private static func shortcut(from s: DisplayCommandRow.Shortcut) -> Shortcut {
        var m: Modifiers = []
        if s.modifiers.contains(.command) { m.insert(.command) }
        if s.modifiers.contains(.option) { m.insert(.option) }
        if s.modifiers.contains(.control) { m.insert(.control) }
        if s.modifiers.contains(.shift) { m.insert(.shift) }
        return Shortcut(Character(s.key), m)
    }
}
