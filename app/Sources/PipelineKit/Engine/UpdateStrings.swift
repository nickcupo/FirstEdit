import Foundation

/// The update sheet's words (`UpdateSheet`, DESIGN.md §7.9). A reason the
/// check or the download could not go ahead is the engine's sentence and is
/// never written here.
extension Strings {

    private static func u(_ key: String, _ value: String, _ comment: String) -> String {
        Bundle.main.localizedString(forKey: key, value: value, table: nil)
    }

    public enum Update {
        public static var title: String { u("update.title", "Software Update", "The update sheet's heading.") }
        public static var checking: String {
            u("update.checking", "Checking for a newer version…", "While the check he asked for runs.")
        }
        /// The answer when nothing newer exists. A version the engine did
        /// not send is left out rather than printed as "()".
        public static func upToDate(_ v: String) -> String {
            v.isEmpty
                ? u("update.upToDatePlain", "You have the latest version.", "The answer when nothing newer exists.")
                : String(localized: "update.upToDate", defaultValue: "You have the latest version, \(v).",
                         comment: "The answer when nothing newer exists.")
        }
        public static func available(_ v: String, current: String) -> String {
            current.isEmpty
                ? String(localized: "update.availablePlain", defaultValue: "Version \(v) is ready to download.",
                         comment: "The answer when a newer version exists.")
                : String(localized: "update.available",
                         defaultValue: "Version \(v) is ready to download. You have \(current).",
                         comment: "The answer when a newer version exists, and the one he has.")
        }
        public static func downloading(_ v: String) -> String {
            String(localized: "update.downloading",
                   defaultValue: "Downloading version \(v). You can close this; it carries on in the toolbar, and Install is offered here when it has arrived.",
                   comment: "While the download runs.")
        }
        public static func staged(_ v: String) -> String {
            String(localized: "update.staged",
                   defaultValue: "Version \(v) is downloaded and checked. Installing it quits First Edit and opens the new version.",
                   comment: "When the download has finished.")
        }
        /// Over the engine's reason - no connection, GitHub answering 404 -
        /// which is printed under it as it was written.
        public static var couldNotCheck: String {
            u("update.couldNotCheck", "First Edit could not find out whether there is a newer version.",
              "When the check he asked for did not get an answer.")
        }
        public static var waitForTheJob: String {
            u("update.waitForTheJob", "Something is running. Install it when that has finished, so nothing is cut short.",
              "Under the staged sentence while a job of his runs; Install is greyed.")
        }
        public static var downloadFailed: String {
            u("update.downloadFailed",
              "The download did not finish. What it said is in the Activity window (⌥⌘L).",
              "Under the sentence when the download job failed without a sentence of its own.")
        }
        public static var download: String { u("update.download", "Download", "Button.") }
        public static var install: String { u("update.install", "Install and Relaunch", "Button.") }
        public static var later: String { u("update.later", "Later", "Button.") }
        public static var ok: String { u("update.ok", "OK", "Button.") }
        public static var close: String { u("update.close", "Close", "Button.") }
    }
}
