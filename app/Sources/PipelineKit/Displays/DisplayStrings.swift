import Foundation

/// Every sentence the second screen says, under `displays.` in the catalog.
///
/// Two rules, the same two that hold in `Design/Strings.swift`. No word from
/// `DESIGN.md` §2.13's retired list appears in anything a person reads — note
/// in particular that the word for an image size is retired: say "size", or say
/// the number. And not one string the extension contributes is in here.
public enum DisplayStrings {

    private static func s(_ key: String, _ value: String, _ comment: String) -> String {
        Bundle.main.localizedString(forKey: key, value: value, table: nil)
    }

    // MARK: - the Window menu (§3.10)

    public enum Menu {
        public static var showOnOtherScreen: String {
            s("displays.menu.show", "Show the Picture on the Other Screen",
              "Window menu. Opens the picture window on his external display.")
        }
        public static var takeOffOtherScreen: String {
            s("displays.menu.hide", "Take the Picture Off the Other Screen",
              "The same item while the window is open.")
        }
        /// With one display "the other screen" would be a lie.
        public static var showInOwnWindow: String {
            s("displays.menu.showAlone", "Show the Picture in Its Own Window",
              "The same item with only the built-in screen attached.")
        }
        public static var closeOwnWindow: String {
            s("displays.menu.hideAlone", "Close the Picture Window",
              "The same item with one display, while it is open.")
        }
        public static var putThePictureOn: String {
            s("displays.menu.putOn", "Put the Picture On",
              "A submenu with one item per attached screen. Hidden with one display.")
        }
        public static var fillThatScreen: String {
            s("displays.menu.fill", "Fill That Screen", "A checkmark item.")
        }
        public static var fullScreenThere: String {
            s("displays.menu.fullScreen", "Enter Full Screen on That Screen",
              "No keyboard shortcut: the key window is always the main window.")
        }
        public static var theseScreens: String {
            s("displays.menu.theseScreens", "These Screens…", "Opens the panel that names both panels.")
        }
        public static var onTheOtherScreen: String {
            s("displays.menu.modes", "On the Other Screen", "The View submenu holding the three modes.")
        }
        public static var follow: String {
            s("displays.menu.follow", "Follow the Light Table", "Mode. The default.")
        }
        public static var alwaysTheFrame: String {
            s("displays.menu.frame", "Always the Frame", "Mode.")
        }
        public static var theWholeBurst: String {
            s("displays.menu.wholeBurst", "The Whole Burst", "Mode.")
        }
        public static var hold: String {
            s("displays.menu.hold", "Hold This One on the Other Screen", "The H key.")
        }
        public static var releaseHold: String {
            s("displays.menu.release", "Release the Hold", "The same item while a frame is held.")
        }
        public static var presentation: String {
            s("displays.menu.presentation", "Presentation", "A submenu.")
        }
        public static var whatIKept: String {
            s("displays.menu.whatIKept", "What I Kept", "The default deck: his keepers, across the shoot.")
        }
        public static var thisBurstEveryFrame: String {
            s("displays.menu.thisBurst", "This Burst, Every Frame", "A deck.")
        }
        public static var wholeShootEveryFrame: String {
            s("displays.menu.wholeShoot", "The Whole Shoot, Every Frame", "A deck.")
        }
    }

    // MARK: - what the main window says (one line, never an alert)

    public enum Note {
        public static var screenWentAway: String {
            s("displays.note.gone", "The other screen went away. Everything you decided is here.",
              "On the control bar's second line when a display is unplugged mid-burst.")
        }
        public static var screenIsBack: String {
            s("displays.note.back", "The other screen is back.", "The window has reopened on it.")
        }
        public static var oneScreenNow: String {
            s("displays.note.clamshell", "One screen now. The picture is in a window on it.",
              "The lid closed with the external attached, so both windows are on one screen.")
        }
        public static var presentationScreenWentAway: String {
            s("displays.note.presentationGone",
              "The screen showing the pictures went away. Presentation is off.",
              "Verdicts become possible again.")
        }
        public static var presentationIsOn: String {
            s("displays.note.presenting", "Presentation is on — Esc ends it.",
              "Under the two disabled verdict buttons while a deck is being shown.")
        }
        public static var nothingKeptYet: String {
            s("displays.note.nothingKept",
              "You haven't kept anything yet. Showing every frame in this burst.",
              "Presentation ▸ What I Kept with no keepers falls back to this burst.")
        }
    }

    // MARK: - refusals

    public enum Refusal {
        public static var nothingDecidedWhilePresenting: String {
            s("displays.refusal.presenting", "Presentation is on. Nothing can be decided while it is.",
              "E, D, X, 1–6, ⇧E, Q, ⌘Z, R and W (and K, 0, ⇧K, U, N, P) are refused while a deck is shown.")
        }
        /// Shown in the picture window's own HUD for four seconds, never as an
        /// alert: entering full screen on one display while "Displays have
        /// separate Spaces" is off blanks every other display — the laptop,
        /// with his control bar on it, goes dark.
        public static var fullScreenWouldDarkenTheOther: String {
            s("displays.refusal.fullScreen",
              "Full screen would darken the other screen while “Displays have separate Spaces” is off "
              + "in System Settings. Filling this screen instead.",
              "A plain sentence in the picture window's HUD, then it does what he wanted.")
        }
    }

    // MARK: - on the second screen

    public enum Picture {
        /// Once per launch, the first time the HUD is revealed: the one macOS
        /// reflex this design breaks is "click a window to type in it".
        public static var keysStayOnTheOtherScreen: String {
            s("displays.picture.keysElsewhere", "The keys stay on the other screen.",
              "One extra HUD line for three seconds, once per launch.")
        }
        public static var youKeptThis: String {
            s("displays.picture.kept", "you kept this", "The HUD's verdict phrase. His, never the cull's.")
        }
        public static var youPutThisOut: String {
            s("displays.picture.out", "you put this out", "The HUD's verdict phrase.")
        }
        public static func positionInBurst(_ n: Int, _ of: Int, _ burst: Int) -> String {
            String(localized: "displays.picture.position",
                   defaultValue: "\(n) of \(of) in burst \(burst)",
                   comment: "The HUD's first line, after the frame number.")
        }
        public static var noShootOpen: String {
            s("displays.picture.noShoot", "No shoot open.", "Centred, at 40 %, then it fades to nothing.")
        }
        public static func shootAndStep(_ shoot: String, _ step: String) -> String {
            String(localized: "displays.picture.elsewhere", defaultValue: "\(shoot) · \(step)",
                   comment: "A shoot is open but he is not on Choose Keepers.")
        }
        public static var buttonsAreOnTheOtherScreen: String {
            s("displays.picture.noButtons", "The buttons are on the other screen.",
              "Under the engine's own sentence. This window takes no clicks that do anything.")
        }
        public static var escToComeBack: String {
            s("displays.picture.esc", "Esc to come back", "The Presentation exit hint.")
        }
        public static func held(_ frame: String) -> String {
            String(localized: "displays.picture.held", defaultValue: "holding \(frame)",
                   comment: "The HUD says which frame is frozen on this screen.")
        }
        /// Over the frame number in the hold badge, which stays in the
        /// surround for as long as the hold does.
        public static var holding: String {
            s("displays.picture.holding", "holding",
              "The word in the hold badge on the other screen, over the held frame's number.")
        }
        /// VoiceOver, after the same sentence §2.15 specifies for a frame.
        public static var controlsAreInTheMainWindow: String {
            s("displays.picture.voiceOver", "Controls are in the main window.",
              "Appended to the picture window's accessibility label.")
        }
        public static func announceHold(_ frame: String) -> String {
            String(localized: "displays.picture.announceHold",
                   defaultValue: "The other screen is holding frame \(frame).",
                   comment: "A polite VoiceOver announcement, once.")
        }
        public static func announceMode(_ mode: String) -> String {
            String(localized: "displays.picture.announceMode",
                   defaultValue: "The other screen is showing \(mode).",
                   comment: "A polite VoiceOver announcement, once.")
        }
    }

    // MARK: - These Screens… (§5.7)

    public enum Screens {
        public static var title: String {
            s("displays.screens.title", "These Screens", "The panel's title.")
        }
        /// Never the retired word for an image size.
        public static func line(points: String, scale: String, real: String, profile: String) -> String {
            String(localized: "displays.screens.line",
                   defaultValue: "\(points) · \(scale) · \(real) real · \(profile)",
                   comment: "One row: point size, scale, the panel's own pixels, and its colour profile.")
        }
        public static var thePicture: String {
            s("displays.screens.here", "the picture", "Marks the screen the picture window is on.")
        }
        public static var noProfile: String {
            s("displays.screens.noProfile", "No profile",
              "A conversion board that presents none, so macOS has fallen back to a generic one.")
        }
        public static var explain: String {
            s("displays.screens.explain",
              "“Real” is what the panel is actually being driven at. If it is half what you expect, "
              + "that is the cable or the board, not this app.",
              "One line under the rows. Nothing on this panel changes anything.")
        }
    }

    // MARK: - Settings ▸ Choosing (§7.2)

    public enum Setting {
        public static var bringItBack: String {
            s("displays.setting.reopen", "Bring the picture back when a screen I've used comes back",
              "On. A screen it has never been opened on never gets a window thrown at it.")
        }
        public static var compareOverThere: String {
            s("displays.setting.compare", "Compare on the other screen when it's open", "On.")
        }
        public static var cullsLineOverThere: String {
            s("displays.setting.cullLine", "Show the cull's line on the other screen",
              "Off. The machine's words live where his controls are.")
        }
        public static var hidePointer: String {
            s("displays.setting.pointer", "Hide the pointer on the other screen when it sits still", "On.")
        }
    }
}
