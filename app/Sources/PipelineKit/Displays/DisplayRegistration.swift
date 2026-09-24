import AppKit
import Foundation

/// Where the picture on the other screen meets the menu bar.
///
/// `DisplayCommands.rows` says what the rows are and `CommandTable` draws
/// them; this says what each one does. One call at launch, and Window ▸ Show
/// the Picture on the Other Screen (⌥⌘P), the three modes, Presentation, Hold
/// and These Screens… are live.
///
/// `DisplayMenus` — this crew's SwiftUI stand-in — is gone: two menus with the
/// same key equivalent is two rows, and the system picks one of them.
@MainActor
public enum DisplayRegistration {

    public static func register(director: DisplayDirector, center: CommandCenter = .shared) {
        center.register(CommandID("displays.toggle"),
                        state: { director.isOpen }) { director.toggleWindow() }

        center.register(CommandID("displays.fill"),
                        isEnabled: { director.isOpen },
                        state: { director.fills }) { director.fillScreen(!director.fills) }

        center.register(CommandID("displays.fullScreen"),
                        isEnabled: { director.isOpen }) { director.enterFullScreen() }

        center.register(CommandID("displays.presentation.kept"),
                        isEnabled: { director.isOpen }) { director.beginPresentation(.whatIKept) }
        center.register(CommandID("displays.presentation.burst"),
                        isEnabled: { director.isOpen }) { director.beginPresentation(.thisBurst) }
        center.register(CommandID("displays.presentation.shoot"),
                        isEnabled: { director.isOpen }) { director.beginPresentation(.wholeShoot) }

        center.register(CommandID("displays.theseScreens")) { director.showScreensPanel() }

        for mode in DisplayDirector.Mode.allCases {
            center.register(CommandID("displays.mode.\(mode.rawValue)"),
                            isEnabled: { director.isOpen },
                            state: { director.mode == mode }) { director.setMode(mode) }
        }

        center.register(CommandID("displays.hold"),
                        isEnabled: { director.isOpen },
                        state: { director.heldStem != nil }) { director.toggleHold() }

        // A presentation's arrows and Esc are its own even while the light
        // table's window is in front, and the light table's key monitor is
        // usually installed before the presentation's, so it is told to stand
        // aside (DESIGN.md §2.5.3).
        LightTableKeys.yields = { [weak director] e in
            director?.isPresenting == true && PresentationKey.from(e) != nil
        }

        // The screens are a list that changes under him, so the rows are
        // rebuilt whenever the watcher says the set changed — and once now, so
        // the menu is right before anything is plugged in or taken out.
        screensChanged(director: director, center: center)
    }

    /// One row per attached screen under Window ▸ Put the Picture On, with a
    /// checkmark on the one the picture is on. With only the Mac's own screen
    /// there is no choice to offer and the submenu is left out.
    public static func screensChanged(director: DisplayDirector, center: CommandCenter = .shared) {
        let set = director.screens.screens
        guard !set.externals.isEmpty else {
            center.setScreens([])
            return
        }
        var rows: [Command] = []
        for info in set.screens {
            let id = CommandID("displays.putOn.\(info.key.raw)")
            center.register(id, state: { director.presence.key == info.key }) {
                director.open(on: info.key)
            }
            rows.append(Command(id, info.name, group: .looking))
        }
        center.setScreens(rows)
    }
}
