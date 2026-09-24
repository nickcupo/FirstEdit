import Foundation

/// The Activity window's own sentences, beside the columns and outcomes in
/// `Strings.Job`: what the history says about a piece of work it lost sight
/// of, and what it says before anything has run.
extension Strings {

    private static func a(_ key: String, _ value: String, _ comment: String) -> String {
        Bundle.main.localizedString(forKey: key, value: value, table: nil)
    }

    public enum Activity {
        /// Written under a job's log when the engine went away while it ran.
        /// The job went with it, and the history says so rather than showing
        /// "Running" for the rest of the evening.
        public static var engineStoppedWhileRunning: String {
            a("activity.engineStoppedWhileRunning", "The engine stopped while this ran.",
              "Added to a job's log in the Activity window when the engine went away under it.")
        }
        /// The outcome of a job the engine finished and replaced between two
        /// looks, when nothing says how it ended. Not "Done": that would be a
        /// guess, and a failure dressed as one.
        public static var ended: String {
            a("activity.ended", "Ended", "An outcome, when the app did not see how a job ended.")
        }
        /// Under the list, where the history will be. One line: the list
        /// above it is what this window is for until something has run.
        public static var noHistory: String {
            a("activity.noHistory", "What runs shows here afterwards, with its log.",
              "The Activity window's history, before anything has run in this session.")
        }
        public static var historyComing: String {
            a("activity.historyComing", "What is running shows here with its log once it is under way.",
              "The Activity window's history, when work is running but the app has no record of it yet.")
        }
    }
}
