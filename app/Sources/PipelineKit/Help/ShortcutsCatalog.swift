import Foundation

// What the Keyboard Shortcuts window lists — read out of `CommandTable` and
// nowhere else, so the window and the menus cannot disagree about a key.
//
// The always-visible one-line legend in the light table is retired: it was
// truncated at every window size below 1728 px (LT-08). This window, and the
// help tag on each button, replace it.

public struct ShortcutRow: Identifiable, Sendable, Equatable {
    public let id: CommandID
    public let title: String
    /// Which menu it is in, so he can find it again with the mouse.
    public let menu: String
    /// "⌘K", "K", "→", or nothing at all.
    public let keys: String?
    /// "or ?".
    public let alternate: String?
    /// Why a row has no key.
    public let note: String?
    public let group: ShortcutGroup
    /// Every other key that is this row, one by one, for a one-letter
    /// search: K for Keep, Q and U for Undo, S for Single Frame in All
    /// Bursts.
    public let otherKeys: [String]

    public init(id: CommandID, title: String, menu: String, keys: String?, alternate: String?,
                note: String?, group: ShortcutGroup, otherKeys: [String] = []) {
        self.id = id
        self.title = title
        self.menu = menu
        self.keys = keys
        self.alternate = alternate
        self.note = note
        self.group = group
        self.otherKeys = otherKeys
    }
}

@MainActor
public enum ShortcutsCatalog {

    /// The one scheme first, E and D at its top — what he opens this window
    /// for, which were below the fold under twenty rows of moving around —
    /// then Deciding.
    public static let order: [ShortcutGroup] = [.everywhere, .deciding, .moving, .looking, .everything]

    /// Every action a person can take, in menu order.
    ///
    /// A row is listed when it is one of this app's own actions — with a key
    /// or without — or a Mac row the table has put in a group of its own
    /// (Undo, Enter Full Screen). The Mac's standard rows it contributes
    /// untouched (Cut, Copy, Paste, Emoji & Symbols, Hide, Quit, Minimize)
    /// are left out: they diluted his keys, and they work as they do in every
    /// app. Cull Again… and Let Go of the Archived RAWs… are here with no key
    /// beside them, which is the point: nothing that deletes photographs has
    /// one.
    ///
    /// A submenu's rows carry its name — "Why It Is Out: Shadow", "Viewer
    /// Background: Black" — because out of their menu "Black" and "Shadow"
    /// say nothing. The Go menu's steps are the open shoot's own, with its
    /// own labels and numbers, as the Go menu has them right now.
    public static var rows: [ShortcutRow] { rows(steps: CommandCenter.shared.stepCommands) }

    /// The same, with the Go menu's steps given: the tests' way in.
    static func rows(steps: [Command]) -> [ShortcutRow] {
        var out: [ShortcutRow] = []
        // The Mac rows the table kept come after the app's own in each group,
        // and so does Undo, whichever kind of row the table makes it: the
        // Edit menu comes before Frame, and Undo stood above Keep and Drop.
        var macRows: [ShortcutRow] = []
        var seen = Set<CommandID>()
        for menu in CommandTable.menus {
            let items = menu.id == .go
                ? menu.sections.flatMap { $0.dynamic == .steps ? steps : $0.items }
                : menu.commands
            for (c, parent) in items.flatMap({ Self.flatten($0, under: nil) }) {
                guard seen.insert(c.id).inserted, isListed(c) else { continue }
                let row = ShortcutRow(
                    id: c.id,
                    title: parent.map { Strings.Help.inSubmenu($0, c.title) } ?? c.title,
                    menu: menu.title,
                    // What the bar is really showing, when it is up: macOS
                    // substitutes its own key for some system rows.
                    keys: c.shortcut.map { MenuBar.liveShortcutDisplay(c.id) ?? $0.display },
                    alternate: c.alternateDisplay.map(Words.Shortcuts.orPlain),
                    // A blank key column says "no key" by itself; only the
                    // rows that never have one, on purpose, say why — and
                    // Single Frame, reached by Esc and by Return on a cover.
                    note: c.shortcut == nil && c.isDestructive ? Strings.Help.noneOnPurpose
                        : c.id == CommandTable.ID.single ? Strings.Help.singleInAllBursts : nil,
                    group: c.group,
                    otherKeys: c.id == CommandTable.ID.single ? ["⎋", "↩"] : c.alternates)
                if Self.goesLast(c) { macRows.append(row) } else { out.append(row) }
            }
        }
        return schemeRows + out + macRows + extraKeys
    }

    /// The keys that mean the same on every page with photographs — Choose
    /// Keepers, Instagram, Reels, the viewer, the review and a presentation
    /// (§2.5.3, `KeyParity`) — each once, with the left hand's key in the
    /// cap and the others beside it. Read from the menu rows that carry
    /// them, so they cannot drift from the menus either.
    static var schemeRows: [ShortcutRow] {
        typealias ID = CommandTable.ID
        func keys(_ id: CommandID) -> [String] {
            guard let c = CommandTable.command(id) else { return [] }
            return (c.shortcut.map { [$0.display] } ?? []) + c.alternates
        }
        func row(_ id: String, _ title: String, cap: String, others: [String],
                 search: [String]? = nil) -> ShortcutRow {
            ShortcutRow(id: CommandID("help.every.\(id)"), title: title, menu: Strings.Help.everyPage,
                        keys: cap, alternate: others.isEmpty ? nil : Words.Shortcuts.orPlain(others.joined(separator: ", ")),
                        note: nil, group: .everywhere, otherKeys: search ?? others)
        }
        // Back and on is one row, "S F", the other pair beside it: the same
        // two fingers. A one-letter search finds it by either key.
        func pair(_ id: String, _ title: String, _ back: CommandID, _ on: CommandID) -> ShortcutRow {
            let (b, o) = (keys(back), keys(on))
            return row(id, title, cap: [b.first, o.first].compactMap { $0 }.joined(separator: " "),
                       others: zip(b.dropFirst(), o.dropFirst()).map { "\($0) \($1)" }, search: b + o)
        }
        func one(_ id: String, _ title: String, _ command: CommandID, leftHand: String? = nil) -> ShortcutRow {
            var k = keys(command)
            // Undo's row shows ⌘Z, the Mac's; here the left hand's Q leads.
            if let l = leftHand, let i = k.firstIndex(of: l) { k.remove(at: i); k.insert(l, at: 0) }
            return row(id, title, cap: k.first ?? "", others: Array(k.dropFirst()))
        }
        return [
            one("include", Strings.Help.keepOrInclude, ID.keep),
            one("leaveOut", Strings.Help.dropOrLeaveOut, ID.drop),
            one("clear", Words.Frame.clearMark, ID.clearMark),
            one("undo", Words.Edit.undo, ID.undo, leftHand: "Q"),
            pair("move", Strings.Help.previousAndNext, ID.previousFrame, ID.nextFrame),
            pair("bursts", Strings.Help.burstBeforeAndAfter, ID.previousBurst, ID.finishBurst),
            one("large", Strings.Help.largeAndBack, ID.fullImage),
            one("oneToOne", Words.View.actualSize, ID.actualSize, leftHand: "Z"),
            row("back", Strings.Help.goBack, cap: "⎋", others: []),
            row("primary", Strings.Help.mainButton, cap: "↩", others: []),
        ]
    }

    /// Window ▸ Fill and Centre are the Mac's own window rows, drawn by this
    /// app only so they work on its windows: keyless, and no more his than
    /// Minimize, which is left out with the rest.
    static let macWindowRows: Set<CommandID> = [CommandTable.ID.fill, CommandTable.ID.centre]

    /// A Mac row, or Undo: after the app's own rows in their group.
    static func goesLast(_ c: Command) -> Bool {
        if case .system = c.role { return true }
        // Undo and Redo, once they take back and put back verdicts by name.
        return c.id == "edit.undo" || c.id == "edit.redo"
    }

    /// Whether a row of the table belongs in the window.
    static func isListed(_ c: Command) -> Bool {
        if macWindowRows.contains(c.id) { return false }
        switch c.role {
        case .ordinary, .destructive: return true
        case .system: return c.group != .everything
        case .systemSubmenu: return false
        }
    }

    /// A command and everything under it, each with the submenu it is in.
    static func flatten(_ c: Command, under parent: String?) -> [(Command, String?)] {
        guard c.isSubmenu else { return [(c, parent)] }
        return c.children.flatMap { flatten($0, under: c.title) }
    }

    /// Keys the light table reads that belong to no menu row of their own:
    /// panning at 1:1, leaving a view, opening a burst from All Bursts. They
    /// all worked and none of them was written anywhere (§2.5.3). The
    /// Instagram editor's own keys follow them, by where they work (§2.17).
    static var extraKeys: [ShortcutRow] {
        let whereTheyWork = Strings.Steps.keepers
        return [
            ShortcutRow(id: CommandID("help.pan"), title: Strings.Help.pan, menu: whereTheyWork,
                        keys: "⇧←→↑↓", alternate: nil, note: nil, group: .looking),
            ShortcutRow(id: CommandID("help.leave"), title: Strings.Help.leave, menu: whereTheyWork,
                        keys: "⎋", alternate: nil, note: nil, group: .looking),
            ShortcutRow(id: CommandID("help.openBurst"), title: Strings.Help.openBurst, menu: whereTheyWork,
                        keys: "↩", alternate: nil, note: nil, group: .looking),
        ] + InstagramKeys.shortcutRows    // the Instagram editor's own keys (§2.17)
          + ReelsKeys.shortcutRows        // Reels' I and O (§2.6)
    }

    /// The groups the window is built from, Deciding first, each in menu
    /// order.
    public static func grouped(matching text: String = "",
                               from rows: [ShortcutRow] = rows) -> [(ShortcutGroup, [ShortcutRow])] {
        let all = filtered(rows, text)
        return order.compactMap { g in
            let rows = all.filter { $0.group == g }
            return rows.isEmpty ? nil : (g, rows)
        }
    }

    /// One character is a question about a key — "what does K do?" — so it
    /// is answered with the rows that key is, not the dozen titles with a k
    /// in them. When no row has that key, it is searched like any text.
    static func filtered(_ rows: [ShortcutRow], _ text: String) -> [ShortcutRow] {
        let q = text.trimmingCharacters(in: .whitespaces)
        if q.count == 1 {
            let exact = rows.filter { isKey($0, q) }
            if !exact.isEmpty { return exact }
        }
        return rows.filter { matches($0, text) }
    }

    static func isKey(_ row: ShortcutRow, _ key: String) -> Bool {
        let k = key.lowercased()
        if row.keys?.lowercased() == k { return true }
        return row.otherKeys.contains { $0.lowercased() == k }
    }

    /// By the name of the action, by the menu it is in, or by the key itself —
    /// typing "keep" finds Keep and typing "⌘R" finds Cull It.
    static func matches(_ row: ShortcutRow, _ text: String) -> Bool {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let needle = q.lowercased()
        if row.title.lowercased().contains(needle) { return true }
        if row.menu.lowercased().contains(needle) { return true }
        if let k = row.keys, k.lowercased().contains(needle) { return true }
        if let a = row.alternate, a.lowercased().contains(needle) { return true }
        return false
    }
}
