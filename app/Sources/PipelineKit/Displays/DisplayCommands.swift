import SwiftUI

/// The rows this crew contributes to the menu bar (§3.10), as data.
///
/// Data first, so the "every key action has a menu item" and "no key equivalent
/// appears twice" tests can read them without building a menu — and so the
/// Commands crew splices them into its own `CommandTable` with no view code of
/// this crew's in it.
///
/// Fitted into `DESIGN.md` §2.12 with no collisions. Free before this design,
/// and now taken by it: ⌥⌘P, ⌃⌘P, ⌃⌘1 / ⌃⌘2 / ⌃⌘3, and the bare letter H.
public struct DisplayCommandRow: Sendable, Equatable, Identifiable {
    public enum Menu: String, Sendable, CaseIterable { case window, view, frame }

    public struct Shortcut: Sendable, Equatable, Hashable {
        public let key: String
        public let modifiers: Modifiers
        public init(_ key: String, _ modifiers: Modifiers = []) {
            self.key = key
            self.modifiers = modifiers
        }
    }

    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public var id: String { identifier }
    public let identifier: String
    public let menu: Menu
    public let title: String
    public let shortcut: Shortcut?
    /// A submenu's heading carries no action of its own.
    public let isGroup: Bool

    public init(_ identifier: String, _ menu: Menu, _ title: String,
                _ shortcut: Shortcut? = nil, isGroup: Bool = false) {
        self.identifier = identifier
        self.menu = menu
        self.title = title
        self.shortcut = shortcut
        self.isGroup = isGroup
    }
}

public enum DisplayCommands {

    /// Every row, in menu order.
    ///
    /// Two titles change with the state and are named here in their opening
    /// form: the Window item reads "Take the Picture Off the Other Screen"
    /// while the window is open, and drops "the Other Screen" entirely when
    /// there is only one display — because then it would be a lie.
    public static var rows: [DisplayCommandRow] {
        [
            DisplayCommandRow("displays.toggle", .window, DisplayStrings.Menu.showOnOtherScreen,
                              .init("p", [.command, .option])),
            DisplayCommandRow("displays.putOn", .window, DisplayStrings.Menu.putThePictureOn,
                              nil, isGroup: true),
            DisplayCommandRow("displays.fill", .window, DisplayStrings.Menu.fillThatScreen),
            // No keyboard shortcut: ⌃⌘F belongs to the main window and must
            // keep belonging to it. A shortcut that means "full screen" but
            // acts on a different window than the focused one is exactly the
            // two-screen confusion this design exists to avoid.
            DisplayCommandRow("displays.fullScreen", .window, DisplayStrings.Menu.fullScreenThere),
            DisplayCommandRow("displays.presentation", .window, DisplayStrings.Menu.presentation,
                              nil, isGroup: true),
            DisplayCommandRow("displays.presentation.kept", .window, DisplayStrings.Menu.whatIKept,
                              .init("p", [.command, .control])),
            DisplayCommandRow("displays.presentation.burst", .window,
                              DisplayStrings.Menu.thisBurstEveryFrame),
            DisplayCommandRow("displays.presentation.shoot", .window,
                              DisplayStrings.Menu.wholeShootEveryFrame),
            DisplayCommandRow("displays.theseScreens", .window, DisplayStrings.Menu.theseScreens),

            DisplayCommandRow("displays.modes", .view, DisplayStrings.Menu.onTheOtherScreen,
                              nil, isGroup: true),
            DisplayCommandRow("displays.mode.follow", .view, DisplayStrings.Menu.follow,
                              .init("1", [.command, .control])),
            DisplayCommandRow("displays.mode.frame", .view, DisplayStrings.Menu.alwaysTheFrame,
                              .init("2", [.command, .control])),
            DisplayCommandRow("displays.mode.wholeBurst", .view, DisplayStrings.Menu.theWholeBurst,
                              .init("3", [.command, .control])),

            // A real menu key equivalent with an empty modifier mask, so it
            // shows in the menu, works with Full Keyboard Access and is
            // rebindable in System Settings like every other item.
            DisplayCommandRow("displays.hold", .frame, DisplayStrings.Menu.hold, .init("h")),
        ]
    }

    /// Every shortcut this crew takes. The Commands crew's "no key equivalent
    /// appears twice" test unions this with its own.
    public static var shortcuts: [DisplayCommandRow.Shortcut] {
        rows.compactMap(\.shortcut)
    }
}

// The SwiftUI `DisplayMenus` that used to stand in here is gone. The Commands
// crew's table now carries these rows (CommandTable.displayCommands) and
// `DisplayRegistration` says what each one does: two menus contributing the
// same key equivalent is two rows, and the system picks one of them.
