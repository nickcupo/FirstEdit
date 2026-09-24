import Foundation

/// What the first launch under the name First Edit says (`FirstLaunch`):
/// the one alert when Photo Pipeline is still open, and the line Settings ▸
/// Advanced shows under the support folder when the folder could not be
/// brought across as planned. Each is said where he will look for it, once,
/// and none of them asks him to do anything but the one thing it names.
extension Strings {

    public enum FirstLaunch {
        private static func s(_ key: String, _ value: String, _ comment: String) -> String {
            Bundle.main.localizedString(forKey: key, value: value, table: nil)
        }

        public static var stillOpenTitle: String {
            s("firstLaunch.stillOpenTitle", "Photo Pipeline is still open.",
              "The alert at launch while the app's old version runs. Nothing has been moved.")
        }
        public static var stillOpenBody: String {
            s("firstLaunch.stillOpenBody", "Quit it, then open First Edit again. Nothing has been moved.",
              "Under stillOpenTitle.")
        }

        /// The folder could not be renamed, so it is used where it is.
        public static func couldNotMove(_ old: String) -> String {
            String(localized: "firstLaunch.couldNotMove",
                   defaultValue: "Photo Pipeline's folder could not be renamed, so First Edit is using it where it is, at \(old).",
                   comment: "Settings, Advanced, under Show the Support Folder. The argument is a folder.")
        }

        /// Two folders, and First Edit's own is the one in use.
        public static func otherFolder(_ old: String) -> String {
            String(localized: "firstLaunch.otherFolder",
                   defaultValue: "Photo Pipeline's folder is still at \(old). First Edit is not using it, and nothing in it was moved or deleted.",
                   comment: "Settings, Advanced, under Show the Support Folder. The argument is a folder.")
        }

        /// A thing the rename is checked against, as he knows it.
        public static func checked(_ path: String) -> String {
            switch path {
            case "models": return s("firstLaunch.checked.models", "the models", "What was not found after the rename.")
            case "learned":
                return s("firstLaunch.checked.learned", "what the cull has learned", "What was not found after the rename.")
            case "extension/studio_ext.py":
                return s("firstLaunch.checked.extension", "the extension", "What was not found after the rename.")
            default: return path
            }
        }

        /// Renamed, but the old name is not a link to it afterwards.
        public static var noLinkAfterMove: String {
            s("firstLaunch.noLinkAfterMove",
              "Photo Pipeline's folder is now First Edit's, but there is no link to it under the old name, so a tool that still names that folder will not find it. MIGRATED.json in the support folder says how to put it back.",
              "Settings, Advanced, under Show the Support Folder.")
        }

        // MARK: two folders, and the one in use has no work in it

        public static var twoFoldersTitle: String {
            s("firstLaunch.twoFoldersTitle", "Photo Pipeline's folder is still there.",
              "An alert once after launch, when both support folders exist and First Edit's lacks what the other has.")
        }

        /// - Parameters: the folder in use, what it is missing, the other folder.
        public static func twoFoldersBody(inUse: String, missing: String, other: String) -> String {
            String(localized: "firstLaunch.twoFoldersBody",
                   defaultValue: "First Edit is using its own folder, \(inUse), which is missing \(missing). Photo Pipeline's folder is still at \(other). Nothing in either was moved, merged or deleted. To use Photo Pipeline's, quit First Edit, rename the First Edit folder to anything else, and open First Edit again: it then moves Photo Pipeline's folder across.",
                   comment: "Under twoFoldersTitle. The first and last arguments are folders; the middle one names what is missing.")
        }

        public static var showBothFolders: String {
            s("firstLaunch.showBothFolders", "Show Both Folders", "Button: opens both folders in Finder.")
        }

        public static var carryOn: String {
            s("firstLaunch.carryOn", "Continue", "Button: closes the alert.")
        }

        // MARK: the old app opened while First Edit runs

        public static var oldOpenedTitle: String {
            s("firstLaunch.oldOpenedTitle", "Photo Pipeline was opened.",
              "An alert while First Edit runs, when the old app starts.")
        }
        public static var oldOpenedBody: String {
            s("firstLaunch.oldOpenedBody",
              "It uses the same folder as First Edit, and the two should not be open at once. Quit Photo Pipeline to go on.",
              "Under oldOpenedTitle.")
        }
        public static var quitOld: String {
            s("firstLaunch.quitOld", "Quit Photo Pipeline", "Button: asks the old app to quit, as its own Quit would.")
        }
        public static var leaveOldOpen: String {
            s("firstLaunch.leaveOldOpen", "Leave It Open", "Button: closes the alert and changes nothing.")
        }

        /// `FirstEdit --check` with the old app open: one line, and no engine.
        public static var checkRefused: String {
            s("firstLaunch.checkRefused",
              "FAIL Photo Pipeline is open and shares this folder; quit it, or set PIPELINE_SUPPORT to a folder of its own",
              "Printed by the headless check, never shown in a window.")
        }

        /// Renamed, but something that was there before is not found after.
        public static func notFoundAfterMove(_ names: String) -> String {
            String(localized: "firstLaunch.notFoundAfterMove",
                   defaultValue: "After renaming Photo Pipeline's folder, First Edit could not find \(names) in it. MIGRATED.json in the support folder says how to put it back.",
                   comment: "Settings, Advanced, under Show the Support Folder. The argument names folders.")
        }
    }
}
