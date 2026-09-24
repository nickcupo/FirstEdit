import Foundation

/// The Keyboard Shortcuts window's own words, beside the menu bar's
/// (`Words.Shortcuts`), and the Help menu's.
extension Strings {
    public enum Help {
        private static func s(_ key: String, _ value: String, _ comment: String) -> String {
            Bundle.main.localizedString(forKey: key, value: value, table: nil)
        }

        /// Beside the rows that remove or delete, in the key column. The menu
        /// item's help tag still gives the whole reason; here it has one line.
        public static var noneOnPurpose: String {
            s("help.noneOnPurpose", "None, on purpose", "In the key column of an action that deletes.")
        }
        /// A submenu's row out of its menu: "Why It Is Out: Shadow".
        public static func inSubmenu(_ parent: String, _ title: String) -> String {
            String(localized: "help.inSubmenu", defaultValue: "\(parent): \(title)",
                   comment: "A submenu item in the Shortcuts window, with the submenu it is in.")
        }
        public static var pan: String { s("help.pan", "Pan at 1:1", "A key with no menu item.") }
        public static var leave: String {
            s("help.leave", "Leave Full Image, Compare or All Bursts", "A key with no menu item.")
        }
        // The one scheme's rows (§2.5.3): each names what the key does on
        // every page with photographs, in Choose Keepers' word and the other
        // pages' where they differ.
        public static var everyPage: String {
            s("help.every.where", "Everywhere", "Where the first group's keys work: every page with photographs.")
        }
        public static var keepOrInclude: String { s("help.every.include", "Keep, or Include", "E on every page.") }
        public static var dropOrLeaveOut: String { s("help.every.leaveOut", "Drop, or Leave Out", "D on every page.") }
        public static var previousAndNext: String {
            s("help.every.move", "Previous and Next Photograph", "S and F, ← and →, on every page.")
        }
        public static var burstBeforeAndAfter: String {
            s("help.every.bursts", "Previous and Next Burst", "W and R on every page with bursts.")
        }
        public static var largeAndBack: String {
            s("help.every.large", "The Photograph Large, and Back", "Space on every page.")
        }
        public static var goBack: String { s("help.every.back", "Go Back", "Esc on every page.") }
        public static var mainButton: String {
            s("help.every.primary", "The Page's Main Button", "Return on every page.")
        }
        public static var openBurst: String {
            s("help.openBurst", "Open the Burst, in All Bursts", "A key with no menu item.")
        }
        /// View ▸ Single Frame's key column: no row's key, but Esc from
        /// Compare or All Bursts, and Return on a cover in All Bursts. S is
        /// the previous frame, or cover, in every view.
        public static var singleInAllBursts: String {
            s("help.singleInAllBursts", "Esc, or Return on a cover", "The key column of Single Frame in the Shortcuts window.")
        }
    }
}
