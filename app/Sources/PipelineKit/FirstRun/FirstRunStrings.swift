import Foundation

/// §2.10. Four pages, and not one of them asks for a permission: those are
/// asked in context, the first time they are actually needed.
extension Strings {
    public enum FirstRun {
        private static func s(_ key: String, _ value: String, _ comment: String) -> String {
            Bundle.main.localizedString(forKey: key, value: value, table: nil)
        }

        public static var continueOn: String { s("firstRun.continue", "Continue", "The button on every page.") }
        public static var start: String { s("firstRun.start", "Start", "The button on the last page.") }
        public static var skip: String { s("firstRun.skip", "Skip", "The sheet is dismissible.") }
        public static var back: String { s("firstRun.back", "Back", "To the page before.") }

        // 1 — welcome
        public static var welcome: String {
            s("firstRun.welcome", "Welcome to FirstEdit", "Page one's title.")
        }
        public static var cardTitle: String { s("firstRun.cardTitle", "Copy the card, checked.", "Page one.") }
        public static var cardLine: String {
            s("firstRun.cardLine", "Every frame is read back and compared before the card is yours again.",
              "Page one.")
        }
        public static var cullTitle: String {
            s("firstRun.cullTitle", "The cull suggests. You decide.", "Page one.")
        }
        public static var cullLine: String {
            s("firstRun.cullLine", "It puts frames forward and sets frames aside. Nothing is deleted and nothing is decided for you.",
              "Page one.")
        }
        public static var filesTitle: String {
            s("firstRun.filesTitle", "Your photographs stay where you can see them.", "Page one.")
        }
        public static var filesLine: String {
            s("firstRun.filesLine", "Folders on your disk, with their own names. Nothing is moved into a database.",
              "Page one.")
        }

        // 2 — where they live
        public static var whereTitle: String {
            s("firstRun.whereTitle", "Where your photographs live", "Page two's title.")
        }
        public static var chooseFolder: String { s("firstRun.chooseFolder", "Choose…", "Page two.") }
        public static var nothingIsMoved: String {
            s("firstRun.nothingIsMoved", "FirstEdit never moves anything.", "Page two.")
        }
        public static func foundShoots(_ n: Int, _ where_: String) -> String {
            String(localized: "firstRun.foundShoots",
                   defaultValue: n == 1 ? "We found 1 shoot in \(where_). Use this library."
                                        : "We found \(n) shoots in \(where_). Use this library.",
                   comment: "Page two, when a library is already there.")
        }
        public static var noLibraryYet: String {
            s("firstRun.noLibraryYet", "Choose a folder and shoots will be made inside it.", "Page two.")
        }
        /// Where Continue puts them when nothing is chosen and nothing found.
        public static func willGoIn(_ shelf: String) -> String {
            String(localized: "firstRun.willGoIn",
                   defaultValue: "Shoots will go in \(shelf). Choose… to use another folder.",
                   comment: "Page two, with no library found and none chosen.")
        }

        // 3 — the picture model
        public static var modelTitle: String { s("firstRun.modelTitle", "The picture model", "Page three's title.") }
        public static var modelLine: String {
            s("firstRun.modelLine",
              "The cull uses a picture model, 1.7 GB, fetched once. Everything else is already here. You can copy a card while it downloads; the cull waits for it.",
              "Page three.")
        }
        public static var downloadNow: String {
            s("firstRun.downloadNow", "Download Now", "Page three. The page's Return.")
        }
        /// There was a Later beside Download Now, doing what Continue does.
        /// Continue is the one way on.
        public static var downloading: String {
            s("firstRun.downloading", "Downloading. The toolbar shows how far it has got, and you can carry on.",
              "After Download Now or Download It, while the engine fetches the model.")
        }
        /// The way back after Continue or Skip passed the model by: on the Cull
        /// step and in Settings, for as long as the engine says it is missing.
        public static var modelMissing: String {
            s("firstRun.modelMissing",
              "The picture model the cull uses is not on this Mac yet: 1.7 GB, fetched once. Without it, the first cull fetches it before it starts, and takes that much longer.",
              "Beside Download It, wherever the model is offered after the welcome pages.")
        }
        public static var downloadIt: String {
            s("firstRun.downloadIt", "Download It", "The button that fetches the picture model.")
        }
        public static var modelAlreadyHere: String {
            s("firstRun.modelAlreadyHere", "The picture model is already on this Mac.", "Page three.")
        }

        // 4 — the editor
        public static var editorTitle: String { s("firstRun.editorTitle", "Your editor", "Page four's title.") }
        public static var editorLine: String {
            s("firstRun.editorLine", "You can change this later in Settings.", "Page four.")
        }
        public static var noEditorFound: String {
            s("firstRun.noEditorFound", "None of these was found on this Mac. Choose the one you will use.",
              "Page four, with nothing installed, above the choices.")
        }
        /// One editor found, and it is PhotoLab: said rather than asked.
        public static func keepersOpenIn(_ name: String) -> String {
            String(localized: "firstRun.keepersOpenIn", defaultValue: "Keepers open in \(name).",
                   comment: "Page four, when PhotoLab is the only editor on this Mac.")
        }
        public static var change: String { s("firstRun.change", "Change…", "Page four. Shows the choices.") }
        public static var onThisMac: String {
            s("firstRun.onThisMac", "on this Mac", "Page four, beside an editor that is installed.")
        }

        // then
        public static func page(_ n: Int, of total: Int) -> String {
            String(localized: "firstRun.page", defaultValue: "Page \(n) of \(total)",
                   comment: "For VoiceOver. The dots are drawn without it.")
        }
    }
}
