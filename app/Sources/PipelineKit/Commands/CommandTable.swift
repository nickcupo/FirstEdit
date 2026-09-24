import AppKit

// The whole menu bar, once, as data (DESIGN.md §2.12).
//
// Everything that reads a shortcut reads it from here: the menu bar AppKit
// builds, the Keyboard Shortcuts window, the help tag on a button, and the
// key table the light table's KeyMap is built from. They cannot drift,
// because there is only one of them.

/// What a command is called in code. Never shown to anyone.
public struct CommandID: Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ raw: String) { self.rawValue = raw }
    public init(stringLiteral value: String) { self.rawValue = value }
}

/// The modifier keys, as data. `NSEvent.ModifierFlags` is AppKit's and is not
/// what a table should be written in.
public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = Modifiers(rawValue: 1 << 0)
    public static let shift = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let control = Modifiers(rawValue: 1 << 3)

    public var appKit: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if contains(.command) { f.insert(.command) }
        if contains(.shift) { f.insert(.shift) }
        if contains(.option) { f.insert(.option) }
        if contains(.control) { f.insert(.control) }
        return f
    }

    /// In the order Apple prints them: ⌃⌥⇧⌘.
    public var display: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// One key equivalent: what AppKit is given and what a person is shown.
public struct Shortcut: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        case character(Character)
        case space
        case left, right, up, down
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public init(_ c: Character, _ modifiers: Modifiers = []) {
        self.init(.character(c), modifiers)
    }

    /// What `NSMenuItem.keyEquivalent` is set to.
    public var keyEquivalent: String {
        switch key {
        case .character(let c): return String(c).lowercased()
        case .space: return " "
        case .left: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case .right: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case .up: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case .down: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        }
    }

    /// What the Shortcuts window and a help tag print.
    public var display: String {
        let k: String
        switch key {
        case .character(let c):
            k = c == "-" ? "−" : String(c).uppercased()
        case .space: k = "Space"
        case .left: k = "←"
        case .right: k = "→"
        case .up: k = "↑"
        case .down: k = "↓"
        }
        return modifiers.display + k
    }

    /// A single letter or digit with no modifier at all. These are real menu
    /// key equivalents with an empty modifier mask, so they show in the menus,
    /// work with Full Keyboard Access and can be re-bound in System Settings —
    /// and they are the ones `validateMenuItem` turns off while a text field
    /// has the keyboard.
    public var isBareCharacter: Bool {
        guard modifiers.isEmpty, case .character(let c) = key else { return false }
        return c.isLetter || c.isNumber
    }

    /// Whether this is a bare key at all, letters, digits, Space or an arrow.
    public var isUnmodified: Bool { modifiers.isEmpty }
}

/// Which menu a row lives in.
public enum MenuID: String, CaseIterable, Sendable {
    case app, file, edit, frame, view, go, shoot, window, help
}

/// How the Keyboard Shortcuts window groups the same table.
public enum ShortcutGroup: String, CaseIterable, Sendable {
    /// The one scheme: the keys that mean the same on every page with
    /// photographs (§2.5.3). No menu row is in it; the window builds it.
    case everywhere
    case moving, deciding, looking, everything

    public var title: String {
        switch self {
        case .everywhere: return Words.Shortcuts.everywhere
        case .moving: return Words.Shortcuts.moving
        case .deciding: return Words.Shortcuts.deciding
        case .looking: return Words.Shortcuts.looking
        case .everything: return Words.Shortcuts.everything
        }
    }
}

/// One row of the menu bar.
public struct Command: Sendable, Identifiable {
    /// What AppKit does with the row.
    public enum Role: Sendable, Equatable {
        /// This app's own action, dispatched through `CommandCenter`.
        case ordinary
        /// Removes a copy or deletes photographs. Never in a toolbar, never
        /// beside a frequent action, and never given a key equivalent.
        case destructive
        /// A responder-chain selector AppKit or the system already owns.
        case system(String)
        /// A submenu AppKit fills in: Services, the window list.
        case systemSubmenu(SystemSubmenu)
    }

    public enum SystemSubmenu: String, Sendable { case services }

    public let id: CommandID
    public let title: String
    /// The title while the thing it toggles is on: "Hide the Filmstrip".
    public let titleWhenOn: String?
    public let shortcut: Shortcut?
    /// A second way in, printed in the Shortcuts window but not a second menu
    /// item: `?` alongside ⌘/.
    public let alternateDisplay: String?
    public let group: ShortcutGroup
    public let role: Role
    /// Whether holding the key down repeats it. Every key that writes one of
    /// his verdicts says no: a held K wrote three unseen frames in 90 ms.
    public let allowsRepeat: Bool
    public let help: String?
    public let children: [Command]
    /// The responder-chain selector an ordinary row hands itself to while a
    /// text field has the keyboard or nothing of the app's can run it: Undo is
    /// the light table's verdicts, and still a text field's typing.
    public let fallback: String?

    public init(_ id: CommandID, _ title: String, key: Shortcut? = nil,
                titleWhenOn: String? = nil, alternateDisplay: String? = nil,
                group: ShortcutGroup = .everything, role: Role = .ordinary,
                allowsRepeat: Bool = true, help: String? = nil, children: [Command] = [],
                fallback: String? = nil) {
        self.id = id
        self.title = title
        self.titleWhenOn = titleWhenOn
        self.shortcut = key
        self.alternateDisplay = alternateDisplay
        self.group = group
        self.role = role
        self.allowsRepeat = allowsRepeat
        self.help = help
        self.children = children
        self.fallback = fallback
    }

    /// The keys `alternateDisplay` names, one by one: "Q, U" is Q and U.
    public var alternates: [String] {
        alternateDisplay.map { $0.components(separatedBy: ", ") } ?? []
    }

    public var isSubmenu: Bool { !children.isEmpty || isSystemSubmenu }
    public var isSystemSubmenu: Bool { if case .systemSubmenu = role { return true }; return false }
    public var isDestructive: Bool { role == .destructive }

    /// Itself and everything under it.
    public var flattened: [Command] { [self] + children.flatMap(\.flattened) }
}

/// A run of items with a separator after it.
public struct MenuSection: Sendable {
    public let items: [Command]
    /// Filled at build time rather than written down: the shoot's own steps.
    public let dynamic: Dynamic?

    public enum Dynamic: String, Sendable { case steps }

    public init(_ items: [Command], dynamic: Dynamic? = nil) {
        self.items = items
        self.dynamic = dynamic
    }
}

public struct MenuDefinition: Sendable, Identifiable {
    public let id: MenuID
    public let title: String
    public let sections: [MenuSection]

    public init(_ id: MenuID, _ title: String, _ sections: [MenuSection]) {
        self.id = id
        self.title = title
        self.sections = sections
    }

    public var commands: [Command] { sections.flatMap(\.items) }
}

// MARK: - the table

@MainActor
public enum CommandTable {

    // MARK: ids, so nothing is addressed by a string spelled twice

    public enum ID {
        public static let checkForUpdates: CommandID = "app.checkForUpdates"
        public static let settings: CommandID = "app.settings"

        public static let newShoot: CommandID = "file.newShoot"
        /// Not in the bar until the engine can copy from a folder (§2.12).
        public static let addFolder: CommandID = "file.addFolder"
        public static let eject: CommandID = "file.eject"
        public static let showShoot: CommandID = "file.showShoot"
        public static let showExports: CommandID = "file.showExports"

        public static let undo: CommandID = "edit.undo"
        public static let redo: CommandID = "edit.redo"
        public static let findBurst: CommandID = "edit.findBurst"

        public static let keep: CommandID = "frame.keep"
        public static let drop: CommandID = "frame.drop"
        public static let clearMark: CommandID = "frame.clearMark"
        public static let whyItIsOut: CommandID = "frame.whyItIsOut"
        public static func reason(_ r: DropReason) -> CommandID { CommandID("frame.reason.\(r.rawValue)") }
        public static let compare: CommandID = "frame.compare"
        public static let keepOnly: CommandID = "frame.keepOnly"
        public static let nextFrame: CommandID = "frame.next"
        public static let previousFrame: CommandID = "frame.previous"
        public static let nextForward: CommandID = "frame.nextForward"
        public static let previousForward: CommandID = "frame.previousForward"
        public static let finishBurst: CommandID = "frame.finishBurst"
        public static let previousBurst: CommandID = "frame.previousBurst"
        public static let showFrameInFinder: CommandID = "frame.showInFinder"
        public static let copyFrameNumber: CommandID = "frame.copyNumber"

        public static let single: CommandID = "view.single"
        public static let allBursts: CommandID = "view.allBursts"
        public static let fullImage: CommandID = "view.fullImage"
        public static let actualSize: CommandID = "view.actualSize"
        public static let zoomToFit: CommandID = "view.zoomToFit"
        public static let zoomIn: CommandID = "view.zoomIn"
        public static let zoomOut: CommandID = "view.zoomOut"
        /// Not in the bar: the light table cannot hide its filmstrip or its
        /// scrubber yet, and a row that can never be pressed is a promise the
        /// Keyboard Shortcuts window repeats (§2.12). The ids stay for the day
        /// it can.
        public static let filmstrip: CommandID = "view.filmstrip"
        public static let burstMap: CommandID = "view.burstMap"
        public static let sidebar: CommandID = "view.sidebar"
        public static let inspector: CommandID = "view.inspector"
        public static let viewerBackground: CommandID = "view.viewerBackground"
        public static func background(_ b: ViewerBackground) -> CommandID {
            CommandID("view.viewerBackground.\(b.rawValue)")
        }
        public static let appearance: CommandID = "view.appearance"
        public static func appearance(_ a: AppAppearance) -> CommandID {
            CommandID("view.appearance.\(a.rawValue)")
        }

        public static let allShoots: CommandID = "go.allShoots"
        public static let learned: CommandID = "go.learned"
        /// The library's Storage page. Not `storage`, which is the Shoot
        /// menu's Storage submenu.
        public static let storagePage: CommandID = "go.storage"
        public static let nextStep: CommandID = "go.nextStep"
        public static let previousStep: CommandID = "go.previousStep"
        public static let resume: CommandID = "go.resume"
        /// One per position in the shoot's own step list, 1-based.
        public static func step(_ position: Int) -> CommandID { CommandID("go.step.\(position)") }

        public static let cull: CommandID = "shoot.cull"
        public static let cullAgain: CommandID = "shoot.cullAgain"
        public static let writePresets: CommandID = "shoot.writePresets"
        public static let openInEditor: CommandID = "shoot.openInEditor"
        public static let cutAReel: CommandID = "shoot.cutAReel"
        public static let finished: CommandID = "shoot.finished"
        public static let stopJob: CommandID = "shoot.stopJob"
        public static let storage: CommandID = "shoot.storage"
        public static let copyUp: CommandID = "shoot.storage.copyUp"
        public static let bringBack: CommandID = "shoot.storage.bringBack"
        public static let checkEvery: CommandID = "shoot.storage.checkEvery"
        public static let takeBackCache: CommandID = "shoot.storage.takeBackCache"
        public static let removeLocal: CommandID = "shoot.storage.removeLocal"
        public static let letGo: CommandID = "shoot.storage.letGo"

        public static let fill: CommandID = "window.fill"
        public static let centre: CommandID = "window.centre"
        public static let activity: CommandID = "window.activity"

        public static let appHelp: CommandID = "help.app"
        public static let shortcuts: CommandID = "help.shortcuts"
        public static let showLog: CommandID = "help.showLog"
        public static let report: CommandID = "help.report"
    }

    // MARK: the eight menus

    /// The whole bar, in order. Everything else in this crew reads this.
    public static var menus: [MenuDefinition] {
        [app, file, edit, frame, view, go, shoot, window, help]
    }

    public static var app: MenuDefinition {
        MenuDefinition(.app, Strings.App.name, [
            MenuSection([
                Command("app.about", Words.App.about, role: .system("orderFrontStandardAboutPanel:")),
            ]),
            MenuSection([
                Command(ID.checkForUpdates, Words.App.checkForUpdates),
            ]),
            MenuSection([
                // Not a `.system` row: which selector opens the Settings
                // scene changed between macOS releases, so `CommandHost` tries
                // both rather than leaving a greyed Command-comma behind.
                Command(ID.settings, Words.App.settings, key: Shortcut(",", .command)),
            ]),
            MenuSection([
                Command("app.services", Words.App.services, role: .systemSubmenu(.services)),
            ]),
            MenuSection([
                Command("app.hide", Words.App.hide, key: Shortcut("h", .command), role: .system("hide:")),
                Command("app.hideOthers", Words.App.hideOthers, key: Shortcut("h", [.command, .option]),
                        role: .system("hideOtherApplications:")),
                Command("app.showAll", Words.App.showAll, role: .system("unhideAllApplications:")),
            ]),
            MenuSection([
                Command("app.quit", Words.App.quit, key: Shortcut("q", .command), role: .system("terminate:")),
            ]),
        ])
    }

    public static var file: MenuDefinition {
        MenuDefinition(.file, Words.Menus.file, [
            MenuSection([
                Command(ID.newShoot, Words.File.newShoot, key: Shortcut("n", .command)),
                // Add a Folder of Photographs (⇧⌘N) is left out until the
                // engine can copy from a folder: a row that is grey for ever
                // is a promise the Shortcuts window repeats (§2.12).
            ]),
            MenuSection([
                Command(ID.eject, Words.File.eject, key: Shortcut("e", .command)),
            ]),
            MenuSection([
                Command(ID.showShoot, Words.File.showShoot, key: Shortcut("r", [.command, .option])),
                Command(ID.showExports, Words.File.showExports, key: Shortcut("x", [.command, .option])),
            ]),
            MenuSection([
                Command("file.close", Words.File.closeWindow, key: Shortcut("w", .command),
                        role: .system("performClose:")),
            ]),
        ])
    }

    public static var edit: MenuDefinition {
        MenuDefinition(.edit, Words.Menus.edit, [
            MenuSection([
                // His verdicts on the light table, named — "Undo Keep 04330" —
                // and a text field's own typing while one has the keyboard.
                // It was the responder chain's alone, and nothing in the chain
                // knows about a verdict: greyed while ⌘Z and U undid them. U
                // undoes too, on the light table (§2.5.5), and so does Q under
                // the left hand: the Shortcuts window lists them here, among
                // the keys that decide.
                Command(ID.undo, Words.Edit.undo, key: Shortcut("z", .command), alternateDisplay: "Q, U",
                        group: .deciding, allowsRepeat: false, fallback: "undo:"),
                // What ⌘Z took back last on the light table, named — "Redo
                // Keep 04330" — and a text field's own typing while one has
                // the keyboard. It was the responder chain's alone, which
                // knows nothing of a verdict, so it sat grey while ⇧⌘Z put
                // one back.
                Command(ID.redo, Words.Edit.redo, key: Shortcut("z", [.command, .shift]),
                        group: .deciding, allowsRepeat: false, fallback: "redo:"),
            ]),
            MenuSection([
                Command("edit.cut", Words.Edit.cut, key: Shortcut("x", .command), role: .system("cut:")),
                Command("edit.copy", Words.Edit.copy, key: Shortcut("c", .command), role: .system("copy:")),
                Command("edit.paste", Words.Edit.paste, key: Shortcut("v", .command), role: .system("paste:")),
                Command("edit.selectAll", Words.Edit.selectAll, key: Shortcut("a", .command),
                        role: .system("selectAll:")),
            ]),
            MenuSection([
                Command(ID.findBurst, Words.Edit.findBurst, key: Shortcut("f", .command), group: .moving),
            ]),
            MenuSection([
                Command("edit.emoji", Words.Edit.emoji, key: Shortcut(.space, [.command, .control]),
                        role: .system("orderFrontCharacterPalette:")),
                Command("edit.dictation", Words.Edit.dictation, role: .system("startDictation:")),
            ]),
        ])
    }

    /// The cull's keys sit under his left hand (§2.5.3): E keep · D drop ·
    /// S and F the previous and next frame · R and W the next and previous
    /// burst · X clear the mark, beside C, Z, G and 1–6. His right hand is on
    /// the mouse, and K was a hand's width from D. A menu row shows one key,
    /// so it shows the left hand's; the key he learned before it still works
    /// and is its `alternateDisplay`, "or K" in the Shortcuts window and
    /// "E or K" in a help tag.
    public static var frame: MenuDefinition {
        MenuDefinition(.frame, Words.Menus.frame, [
            MenuSection([
                Command(ID.keep, Words.Frame.keep, key: Shortcut("e"), alternateDisplay: "K", group: .deciding,
                        allowsRepeat: false, help: Strings.Verdict.heldKey),
                Command(ID.drop, Words.Frame.drop, key: Shortcut("d"), group: .deciding,
                        allowsRepeat: false, help: Strings.Verdict.dropHelp),
                Command(ID.clearMark, Words.Frame.clearMark, key: Shortcut("x"), alternateDisplay: "0",
                        group: .deciding, allowsRepeat: false),
            ]),
            MenuSection([
                Command(ID.whyItIsOut, Words.Frame.whyItIsOut, group: .deciding,
                        children: DropReason.allCases.map { r in
                            Command(ID.reason(r), titleCase(r.word),
                                    key: Shortcut(Character("\(r.key)")), group: .deciding,
                                    allowsRepeat: false)
                        }),
            ]),
            MenuSection([
                Command(ID.compare, Words.Frame.compare, key: Shortcut("c"), group: .looking,
                        allowsRepeat: false),
                Command(ID.keepOnly, Words.Frame.keepOnly, key: Shortcut("e", .shift), alternateDisplay: "⇧K",
                        group: .deciding, allowsRepeat: false),
            ]),
            MenuSection([
                Command(ID.nextFrame, Words.Frame.nextFrame, key: Shortcut("f"), alternateDisplay: "→",
                        group: .moving),
                Command(ID.previousFrame, Words.Frame.previousFrame, key: Shortcut("s"), alternateDisplay: "←",
                        group: .moving),
                Command(ID.nextForward, Words.Frame.nextForward, key: Shortcut(.down), group: .moving),
                Command(ID.previousForward, Words.Frame.previousForward, key: Shortcut(.up), group: .moving),
            ]),
            MenuSection([
                Command(ID.finishBurst, Words.Frame.finishBurst, key: Shortcut("r"), alternateDisplay: "N",
                        group: .moving, allowsRepeat: false, help: Words.Frame.finishBurstHelp),
                Command(ID.previousBurst, Words.Frame.previousBurst, key: Shortcut("w"), alternateDisplay: "P",
                        group: .moving, allowsRepeat: false),
            ]),
            MenuSection([
                // ⌥⌘R belongs to the shoot, in File. This one is the frame's
                // own file, so it takes the shifted form rather than sharing a
                // key equivalent with a different action.
                Command(ID.showFrameInFinder, Words.Frame.showInFinder,
                        key: Shortcut("r", [.command, .option, .shift])),
                Command(ID.copyFrameNumber, Words.Frame.copyNumber, key: Shortcut("c", [.command, .option])),
            ]),
            // Hold, on bare H (DESIGN-displays.md §3.10).
            MenuSection(displayCommands(.frame)),
        ])
    }

    public static var view: MenuDefinition {
        MenuDefinition(.view, Words.Menus.view, [
            MenuSection([
                // No key in the menu: the way back to one frame is Esc, or
                // Return on the ringed cover in All Bursts, and neither is a
                // row's key. S is Previous Frame in every view, All Bursts'
                // covers included (§2.5.3).
                Command(ID.single, Words.View.single, group: .looking,
                        allowsRepeat: false),
                // The same action as Frame ▸ Compare Similar Frames, under the
                // name the mode picker uses. One id, so C can only ever mean
                // one thing.
                Command(ID.compare, Words.View.compare, key: Shortcut("c"), group: .looking,
                        allowsRepeat: false),
                Command(ID.allBursts, Words.View.allBursts, key: Shortcut("g"), group: .looking,
                        allowsRepeat: false),
            ]),
            MenuSection([
                Command(ID.fullImage, Words.View.fullImage, key: Shortcut(.space), group: .looking,
                        allowsRepeat: false),
                Command("view.fullScreen", Words.View.enterFullScreen,
                        key: Shortcut("f", [.command, .control]), group: .looking,
                        role: .system("toggleFullScreen:")),
            ]),
            MenuSection([
                Command(ID.actualSize, Words.View.actualSize, key: Shortcut("0", .command),
                        alternateDisplay: "Z", group: .looking),
                // ⌘9 is Zoom to Fit, as it is in Preview. DESIGN-displays.md
                // §3.10 found Go's eighth and ninth steps landing on it; the
                // steps give way, because this is the convention a Mac
                // photographer already has in his hands.
                Command(ID.zoomToFit, Words.View.zoomToFit, key: Shortcut("9", .command), group: .looking),
                Command(ID.zoomIn, Words.View.zoomIn, key: Shortcut("+", .command), group: .looking),
                Command(ID.zoomOut, Words.View.zoomOut, key: Shortcut("-", .command), group: .looking),
            ]),
            MenuSection([
                Command(ID.sidebar, Words.View.showSidebar, key: Shortcut("s", [.command, .control]),
                        titleWhenOn: Words.View.hideSidebar, group: .looking),
                Command(ID.inspector, Words.View.showInspector, key: Shortcut("i", [.command, .option]),
                        titleWhenOn: Words.View.hideInspector, group: .looking),
            ]),
            MenuSection([
                Command(ID.viewerBackground, Words.View.viewerBackground, group: .looking, children: [
                    Command(ID.background(.neutralGrey), Words.View.neutralGrey, group: .looking),
                    Command(ID.background(.matchSystem), Words.View.matchTheSystem, group: .looking),
                    Command(ID.background(.black), Words.View.black, group: .looking),
                ]),
                // Light or dark for the whole app, the same three choices as
                // Settings ▸ General and the same object behind them. No key
                // equivalent: there is no free one worth spending on a setting
                // he changes twice a year.
                Command(ID.appearance, Strings.Appearance.menuTitle, group: .looking,
                        children: AppAppearance.allCases.map { choice in
                    Command(ID.appearance(choice), choice.label, group: .looking)
                }),
            ]),
            // What the other screen shows (DESIGN-displays.md §3.10).
            MenuSection(displayCommands(.view)),
        ])
    }

    public static var go: MenuDefinition {
        MenuDefinition(.go, Words.Menus.go, [
            MenuSection([
                Command(ID.allShoots, Words.Go.allShoots, key: Shortcut("0", [.command, .shift]),
                        group: .moving),
                Command(ID.learned, Words.Go.learned, key: Shortcut("l", [.command, .shift]),
                        group: .moving),
                // The third library row, which only the mouse reached.
                Command(ID.storagePage, Words.Go.storage, key: Shortcut("s", [.command, .shift]),
                        group: .moving),
            ]),
            // One item per step of the shoot that is open, in the engine's own
            // order and with its own labels, filled in at build time.
            MenuSection(baseStepCommands, dynamic: .steps),
            MenuSection([
                Command(ID.nextStep, Words.Go.nextStep, key: Shortcut("]", .command), group: .moving),
                Command(ID.previousStep, Words.Go.previousStep, key: Shortcut("[", .command), group: .moving),
                Command(ID.resume, Words.Go.resume, key: Shortcut("j", .command), group: .moving),
            ]),
        ])
    }

    public static var shoot: MenuDefinition {
        MenuDefinition(.shoot, Words.Menus.shoot, [
            MenuSection([
                Command(ID.cull, Words.Shoot.cull, key: Shortcut("r", .command)),
                Command(ID.cullAgain, Words.Shoot.cullAgain),
            ]),
            MenuSection([
                Command(ID.writePresets, Words.Shoot.writePresets),
                Command(ID.openInEditor, Words.Shoot.openInEditor, key: Shortcut("e", [.command, .shift])),
                Command(ID.cutAReel, Words.Shoot.cutAReel),
            ]),
            MenuSection([
                Command(ID.finished, Words.Shoot.finished),
            ]),
            MenuSection([
                Command(ID.stopJob, Words.Shoot.stopJob, key: Shortcut(".", .command)),
            ]),
            MenuSection([
                Command(ID.storage, Words.Shoot.storage, children: [
                    Command(ID.copyUp, Words.Shoot.copyUp),
                    Command(ID.bringBack, Words.Shoot.bringBack),
                    Command(ID.checkEvery, Words.Shoot.checkEvery),
                    // Frequent, and it takes back nothing a photograph needs:
                    // it sits with the other four, above the rule.
                    Command(ID.takeBackCache, Words.Shoot.takeBackCache),
                    // A section of its own, at the bottom, with no key
                    // equivalent anywhere in the app.
                    Command(ID.removeLocal, Words.Shoot.removeLocal, role: .destructive,
                            help: Words.Shortcuts.noShortcut),
                    Command(ID.letGo, Words.Shoot.letGo, role: .destructive,
                            help: Words.Shortcuts.noShortcut),
                ]),
            ]),
        ])
    }

    public static var window: MenuDefinition {
        MenuDefinition(.window, Words.Menus.window, [
            MenuSection([
                Command("window.minimize", Words.Window.minimize, key: Shortcut("m", .command),
                        role: .system("performMiniaturize:")),
                Command("window.zoom", Words.Window.zoom, role: .system("performZoom:")),
                Command(ID.fill, Words.Window.fill),
                Command(ID.centre, Words.Window.centre),
            ]),
            MenuSection([
                Command(ID.activity, Words.Window.activity, key: Shortcut("l", [.command, .option])),
            ]),
            // The picture on the other screen (DESIGN-displays.md §3.10).
            MenuSection(displayCommands(.window)),
            // AppKit adds the open windows under this one, because the Window
            // menu is handed to `NSApp.windowsMenu`.
            MenuSection([
                Command("window.bringAllToFront", Words.Window.bringAllToFront,
                        role: .system("arrangeInFront:")),
            ]),
        ])
    }

    public static var help: MenuDefinition {
        MenuDefinition(.help, Words.Menus.help, [
            MenuSection((HelpBook.hasHelpBook ? [Command(ID.appHelp, Words.Help.appHelp)] : []) + [
                // ⌘/ is the item's key equivalent; `?` reaches the same window
                // from the light table, where his hand already is. Photo
                // Pipeline Help sits above it only when a help book ships:
                // without one it opened this same window, one row higher.
                Command(ID.shortcuts, Words.Help.shortcuts, key: Shortcut("/", .command),
                        alternateDisplay: "?"),
            ]),
            MenuSection([
                Command(ID.showLog, Words.Help.showLog),
                Command(ID.report, Words.Help.report),
            ]),
        ])
    }

    // MARK: the steps

    /// ⌘1…⌘8 by **position in the shoot's own step list**, so the number in
    /// the menu is the number of the row he can see in the sidebar. There is
    /// no ⌘9: `View ▸ Zoom to Fit` has it, and a ninth step is reached with
    /// ⌘] or by clicking it.
    public static let stepNumberLimit = 8

    public static func stepShortcut(position: Int) -> Shortcut? {
        guard position >= 1, position <= stepNumberLimit,
              let c = Character("\(position)").unicodeScalars.first.map({ Character($0) })
        else { return nil }
        return Shortcut(c, .command)
    }

    public static func stepCommands(_ steps: [StepState]) -> [Command] {
        steps.enumerated().map { i, s in
            // The engine writes its step labels in sentence case ("Choose
            // keepers"); a menu row is in title case, like every other row.
            Command(ID.step(i + 1), titleCase(s.label), key: stepShortcut(position: i + 1), group: .moving,
                    help: s.enabled ? nil : s.why_disabled)
        }
    }

    /// A title that arrives in sentence case — from the engine, from a
    /// reason's own word — in the title case of a Mac menu row: "cut off" is
    /// "Cut Off", "Copy the card" is "Copy the Card". The short joining words
    /// stay small between the first word and the last, and a word that already
    /// carries a capital (PhotoLab, iCloud) is left exactly as it was written.
    public static func titleCase(_ s: String) -> String {
        let small: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "from", "in",
                                  "into", "of", "on", "or", "the", "to", "with"]
        let words = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return words.enumerated().map { i, w in
            if w.contains(where: \.isUppercase) { return w }
            if i > 0, i < words.count - 1, small.contains(w) { return w }
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }

    /// The seven the engine always has, for the Shortcuts window and for a
    /// menu bar drawn before a shoot is open.
    public static var baseStepCommands: [Command] {
        stepCommands(Fallbacks.baseStepIDs.map {
            StepState(id: $0, label: Fallbacks.baseLabel($0), done: false, enabled: true,
                      why_disabled: nil, source: .base)
        })
    }

    // MARK: what the rest of the app asks this table

    /// Every command in the bar, submenus included.
    public static var allCommands: [Command] { menus.flatMap { $0.commands.flatMap(\.flattened) } }

    public static func command(_ id: CommandID) -> Command? {
        allCommands.first { $0.id == id }
    }

    /// The shortcut for an action, for a help tag on the button that does the
    /// same thing. The control bar's buttons carry their key this way, which
    /// is why the always-visible legend in the light table is retired.
    public static func shortcut(_ id: CommandID) -> Shortcut? {
        command(id)?.shortcut
    }

    /// Shortcuts promised to DESIGN-displays.md §3.10 and handed out to
    /// nothing else. The rows that use them are in the table now
    /// (`displayCommands`), so the check is no longer "nobody has this" but
    /// "only the crew it was promised to has this".
    public static let reserved: [(Shortcut, String)] = [
        (Shortcut("p", [.command, .option]), "displays.toggle"),
        (Shortcut("p", [.command, .control]), "displays.presentation.kept"),
        (Shortcut("1", [.command, .control]), "displays.mode.follow"),
        (Shortcut("2", [.command, .control]), "displays.mode.frame"),
        (Shortcut("3", [.command, .control]), "displays.mode.wholeBurst"),
        (Shortcut("h"), "displays.hold"),
    ]
}

// `capitalizedFirst` is defined once, in Learning/LearnerRow.swift: two crews
// wrote the same helper, and the one kept leaves a name the engine wrote alone
// instead of re-casing it.
