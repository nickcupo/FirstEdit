import AppKit
import Observation

// Where a command in the table meets the thing that does it.
//
// A crew that owns a screen registers its actions here by id and forgets
// about the menu bar; the menu bar asks this object whether a row is
// available, what its state is, and then runs it. So the menu is honest about
// what can be done right now, and a screen never has to know it is in a menu.

/// One action behind a menu row.
@MainActor
public struct CommandAction {
    public let isEnabled: () -> Bool
    /// A checkmark, or nothing when the row is not a state.
    public let state: () -> Bool?
    /// The row's whole title right now, where it names what it will do —
    /// "Undo Keep 04330" — or nil for the table's own.
    public let title: () -> String?
    /// The row's help tag right now, where the page answering it does
    /// something else than the table's tag says — Next Burst on Reels
    /// records nothing — or nil for the table's own.
    public let help: () -> String?
    public let run: () -> Void

    public init(isEnabled: @escaping () -> Bool = { true },
                state: @escaping () -> Bool? = { nil },
                title: @escaping () -> String? = { nil },
                help: @escaping () -> String? = { nil },
                run: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.state = state
        self.title = title
        self.help = help
        self.run = run
    }
}

@MainActor @Observable
public final class CommandCenter {
    public static let shared = CommandCenter()

    private var actions: [CommandID: CommandAction] = [:]

    /// The open shoot's own steps, in the engine's order and with its own
    /// labels. The Go menu is rebuilt when this changes, so a step from the
    /// extension is an ordinary menu row with an ordinary number.
    public private(set) var steps: [StepState] = []

    /// One row per screen attached right now, for Window ▸ Put the Picture On.
    /// Set by whoever watches the screens; empty when there is nothing but the
    /// Mac's own, and the submenu is then left out rather than drawn empty.
    public private(set) var screenRows: [Command] = []

    /// Set by whatever holds the running job, so the Dock, the Activity
    /// window and Shoot ▸ Stop the Job all read one thing.
    public var job: Job?

    public init() {}

    // MARK: registering

    public func register(_ id: CommandID, isEnabled: @escaping () -> Bool = { true },
                         state: @escaping () -> Bool? = { nil },
                         title: @escaping () -> String? = { nil },
                         help: @escaping () -> String? = { nil },
                         run: @escaping () -> Void) {
        actions[id] = CommandAction(isEnabled: isEnabled, state: state, title: title, help: help, run: run)
        MenuBar.needsRefresh()
    }

    public func register(_ id: CommandID, _ action: CommandAction) {
        actions[id] = action
        MenuBar.needsRefresh()
    }

    public func unregister(_ id: CommandID) {
        actions.removeValue(forKey: id)
        MenuBar.needsRefresh()
    }

    public func isRegistered(_ id: CommandID) -> Bool { actions[id] != nil }

    /// What answers a row now, so a page that answers it while it is on
    /// screen can put the app's own back when it goes.
    public func action(_ id: CommandID) -> CommandAction? { actions[id] }

    // MARK: asking

    /// A row with nobody behind it is greyed out rather than silently doing
    /// nothing. A key with nobody behind it does nothing rather than beeping.
    public func canRun(_ id: CommandID) -> Bool {
        guard let a = actions[id] else { return false }
        return a.isEnabled()
    }

    public func state(_ id: CommandID) -> Bool? { actions[id]?.state() }

    public func title(_ id: CommandID) -> String? { actions[id]?.title() }
    public func help(_ id: CommandID) -> String? { actions[id]?.help() }

    @discardableResult
    public func run(_ id: CommandID) -> Bool {
        guard let a = actions[id], a.isEnabled() else { return false }
        a.run()
        return true
    }

    // MARK: the steps in the Go menu

    public func setSteps(_ steps: [StepState]) {
        guard steps.map(\.id) != self.steps.map(\.id) || steps.map(\.label) != self.steps.map(\.label)
        else { return }
        self.steps = steps
        MenuBar.rebuildSteps(center: self)
    }

    /// The step rows as the Go menu draws them right now.
    public var stepCommands: [Command] {
        steps.isEmpty ? CommandTable.baseStepCommands : CommandTable.stepCommands(steps)
    }

    /// The screens, as Window ▸ Put the Picture On draws them right now.
    public func setScreens(_ rows: [Command]) {
        guard rows.map(\.id) != screenRows.map(\.id) || rows.map(\.title) != screenRows.map(\.title)
        else { return }
        screenRows = rows
        CommandTable.attachedScreens = rows
        MenuBar.rebuildWindowMenu(center: self)
    }
}

// MARK: - the menu bar itself

/// Builds `NSApp.mainMenu` out of `CommandTable`.
///
/// AppKit, not SwiftUI `Commands`: a single-letter key equivalent with an
/// empty modifier mask, a `validateMenuItem` that can turn those off while a
/// text field has the keyboard, `NSApp.helpMenu` so the system Help search
/// reads every item by name, and a title that changes between "Show" and
/// "Hide" are all things only a real `NSMenu` does.
@MainActor
public enum MenuBar {
    private static var target: MenuTarget?
    private static var installed = false

    /// Builds the whole bar and hands it to AppKit. Safe to call twice.
    public static func install(center: CommandCenter = .shared) {
        let t = MenuTarget(center: center)
        target = t

        let main = NSMenu()
        for definition in CommandTable.menus {
            let item = NSMenuItem()
            item.title = definition.title
            item.submenu = menu(for: definition, target: t)
            main.addItem(item)
        }
        NSApplication.shared.mainMenu = main

        // The three AppKit fills in for itself.
        NSApplication.shared.servicesMenu = servicesMenu
        if let w = main.item(withTitle: CommandTable.window.title)?.submenu {
            NSApplication.shared.windowsMenu = w
        }
        if let h = main.item(withTitle: CommandTable.help.title)?.submenu {
            // Setting this is what puts the Search field at the top and makes
            // the system's own Help search find every item by name.
            NSApplication.shared.helpMenu = h
        }
        installed = true
    }

    /// Re-asserts the bar after something else has replaced it, which SwiftUI
    /// does when its scenes change.
    public static func reinstallIfNeeded(center: CommandCenter = .shared) {
        guard installed else { return }
        let ours = NSApplication.shared.mainMenu?.item(withTitle: CommandTable.frame.title) != nil
        if !ours { install(center: center) }
    }

    static func needsRefresh() {
        // Nothing to do: `validateMenuItem` runs just before a menu is drawn
        // and reads the register then. This exists so a caller can say so.
    }

    /// The Window menu's screen rows, after a display came or went.
    public static func rebuildWindowMenu(center: CommandCenter = .shared) {
        guard installed, let t = target,
              let w = NSApplication.shared.mainMenu?
                  .item(withTitle: CommandTable.window.title)?.submenu
        else { return }
        w.removeAllItems()
        fill(w, with: CommandTable.window, target: t, center: center)
        NSApplication.shared.windowsMenu = w
    }

    /// The Go menu's step rows, after the open shoot changed.
    public static func rebuildSteps(center: CommandCenter = .shared) {
        guard installed, let t = target,
              let go = NSApplication.shared.mainMenu?
                  .item(withTitle: CommandTable.go.title)?.submenu
        else { return }
        go.removeAllItems()
        fill(go, with: CommandTable.go, target: t, center: center)
    }

    private static var servicesMenu: NSMenu {
        NSMenu(title: Words.App.services)
    }

    static func menu(for definition: MenuDefinition, target t: MenuTarget) -> NSMenu {
        let m = NSMenu(title: definition.title)
        // A menu that never auto-enables is a menu the app is answerable for:
        // every row's availability comes from `validateMenuItem`.
        m.autoenablesItems = true
        fill(m, with: definition, target: t, center: t.center)
        return m
    }

    private static func fill(_ m: NSMenu, with definition: MenuDefinition,
                             target t: MenuTarget, center: CommandCenter) {
        var first = true
        for section in definition.sections {
            // A section is rebuilt from the table every time, so the Window
            // menu's screen rows and the Go menu's step rows are whatever is
            // true when the bar is built.
            let items = section.dynamic == .steps ? center.stepCommands : section.items
            if items.isEmpty { continue }
            if !first { m.addItem(.separator()) }
            first = false
            for c in items { m.addItem(item(for: c, target: t)) }
        }
    }

    static func item(for c: Command, target t: MenuTarget) -> NSMenuItem {
        let row = NSMenuItem()
        row.title = c.title
        row.representedObject = c.id.rawValue
        if let help = c.help { row.toolTip = help }

        if let s = c.shortcut {
            row.keyEquivalent = s.keyEquivalent
            // An empty modifier mask is the point: K is a real menu key
            // equivalent, which is what makes it discoverable, re-bindable and
            // reachable by Full Keyboard Access.
            row.keyEquivalentModifierMask = s.modifiers.appKit
        }

        switch c.role {
        case .systemSubmenu(.services):
            row.submenu = NSMenu(title: c.title)
        case .system(let selector):
            row.action = NSSelectorFromString(selector)
            row.target = nil          // up the responder chain, as AppKit likes
        case .ordinary, .destructive:
            if c.isSubmenu {
                let sub = NSMenu(title: c.title)
                sub.autoenablesItems = true
                var previousWasDestructive = false
                for (i, child) in c.children.enumerated() {
                    // Destructive rows live in their own section at the bottom,
                    // never in a submenu's first group.
                    if child.isDestructive && !previousWasDestructive && i > 0 {
                        sub.addItem(.separator())
                    }
                    previousWasDestructive = child.isDestructive
                    sub.addItem(item(for: child, target: t))
                }
                row.submenu = sub
                // Only so `validateMenuItem` is asked about the row itself: a
                // submenu whose rows are all grey is grey too, rather than an
                // arrow that opens onto nothing he can choose. Choosing a row
                // that has a submenu opens it; the action is never sent.
                row.action = #selector(MenuTarget.performCommand(_:))
                row.target = t
            } else {
                row.action = #selector(MenuTarget.performCommand(_:))
                row.target = t
            }
        }
        row.setAccessibilityLabel(c.title)
        return row
    }
}

extension MenuBar {
    /// The row AppKit is actually showing for a command, if the bar is up.
    ///
    /// macOS substitutes its own key for some system rows — on this release it
    /// hides the app's Enter Full Screen ⌃⌘F and shows a Globe-F of its own.
    /// The Keyboard Shortcuts window asks here first, so it prints the key the
    /// menu prints rather than the key the table wished for.
    public static func liveItem(_ id: CommandID) -> NSMenuItem? {
        func search(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if !item.isHidden, item.representedObject as? String == id.rawValue,
                   !item.keyEquivalent.isEmpty {
                    return item
                }
                if let sub = item.submenu, let hit = search(sub) { return hit }
            }
            return nil
        }
        guard let main = NSApplication.shared.mainMenu else { return nil }
        return search(main)
    }

    /// "⌃⌘F", or whatever the system put there instead.
    public static func liveShortcutDisplay(_ id: CommandID) -> String? {
        guard let item = liveItem(id) else { return nil }
        var out = ""
        let m = item.keyEquivalentModifierMask
        if m.contains(.function) { out += "🌐" }
        if m.contains(.control) { out += "⌃" }
        if m.contains(.option) { out += "⌥" }
        if m.contains(.shift) { out += "⇧" }
        if m.contains(.command) { out += "⌘" }
        guard let scalar = item.keyEquivalent.unicodeScalars.first else { return out }
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: out += "←"
        case NSRightArrowFunctionKey: out += "→"
        case NSUpArrowFunctionKey: out += "↑"
        case NSDownArrowFunctionKey: out += "↓"
        case 32: out += "Space"
        default: out += item.keyEquivalent == "-" ? "−" : item.keyEquivalent.uppercased()
        }
        return out
    }
}
