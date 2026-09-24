import Foundation

/// The shell's own sentences, beside the pages that say them. The same rules
/// as `Strings`: his words, through the catalog, English as the default.
extension Strings.Shell {
    /// The close button on the line that says the engine was restarted.
    public static var closeBanner: String {
        String(localized: "shell.closeBanner", defaultValue: "Close",
               comment: "Closes the line saying the engine was restarted.")
    }
}

extension Strings.FirstRun {
    /// Beside Continue on page two while the folder he chose is opened.
    public static var takingFolder: String {
        String(localized: "firstRun.takingFolder", defaultValue: "Opening the library in this folder…",
               comment: "Beside Continue on page two while the app switches to the folder he chose.")
    }
}

extension Strings.Library {
    /// A step the engine says is done: the sidebar row's help and what
    /// VoiceOver says of it, beside its check.
    public static var stepDone: String {
        String(localized: "library.stepDone", defaultValue: "Done",
               comment: "A step in the sidebar that is done, in its help tag and VoiceOver value.")
    }
    /// Label the unit so reviewed bursts cannot be mistaken for kept frames.
    public static func reviewedBursts(_ seen: Int, _ total: Int) -> String {
        String(localized: "library.reviewedBursts", defaultValue: "\(seen)/\(total) bursts",
               comment: "Compact reviewed-burst count beside Choose Keepers, not a photo count.")
    }
    /// All Shoots' column saying which step each shoot is up to.
    public static var upTo: String {
        String(localized: "library.upTo", defaultValue: "Up to",
               comment: "All Shoots: a column, the step each shoot is up to next.")
    }
    /// The same, on Choose Keepers, in its help and to VoiceOver: its name
    /// and the bursts looked through.
    public static func upToBursts(_ step: String, _ seen: Int, _ of: Int) -> String {
        String(localized: "library.upToBursts", defaultValue: "\(step) · \(seen) of \(of) bursts",
               comment: "All Shoots' Up to column on Choose Keepers, spoken and in its help: the step's name, then bursts looked through of all.")
    }
    /// All Shoots' title when the engine could not say what is in the library.
    public static var couldNotRead: String {
        String(localized: "library.couldNotRead", defaultValue: "Your shoots could not be read",
               comment: "All Shoots' title when the list of shoots could not be read; the engine's sentence is under it.")
    }
}

extension Strings.Job {
    /// An Activity row's menu, and its double-click: the step that does it.
    public static var showTheStep: String {
        String(localized: "job.showTheStep", defaultValue: "Show the Step",
               comment: "An Activity row's menu: goes to the step whose button starts this work.")
    }
    /// The same, for work no one step owns.
    public static var showTheShoot: String {
        String(localized: "job.showTheShoot", defaultValue: "Show the Shoot",
               comment: "An Activity row's menu: goes to the shoot's own page.")
    }
}

extension Strings {

    /// The page shown when the engine is not running.
    public enum EngineDown {
        public static var whatToDo: String {
            String(localized: "engineDown.whatToDo",
                   defaultValue: "Restart it. If it stops again, choose Help ▸ Report a Problem… and attach the log.",
                   comment: "Under the engine-down title: what to do next.")
        }
    }

    /// A shoot row's context menu.
    public enum ShootMenu {
        public static var showInFinder: String {
            String(localized: "shootMenu.showInFinder", defaultValue: "Show in Finder",
                   comment: "A shoot row's context menu.")
        }
        public static var copyPath: String {
            String(localized: "shootMenu.copyPath", defaultValue: "Copy Path",
                   comment: "A shoot row's context menu: the folder's path, to paste.")
        }
    }

    /// All Shoots with nothing in it and a card in the Mac.
    public enum EmptyLibrary {
        public static func cardIsIn(_ volume: String) -> String {
            String(localized: "emptyLibrary.cardIsIn", defaultValue: "\(volume) is in",
                   comment: "The empty library's title while a memory card is mounted.")
        }
        public static var copyIt: String {
            String(localized: "emptyLibrary.copyIt", defaultValue: "Copy it to make your first shoot.",
                   comment: "Under the empty library's title while a memory card is mounted.")
        }
    }

    /// The toolbar's status item, when it is about something other than a
    /// job running.
    public enum StatusItem {
        public static func ended(_ what: String, _ outcome: String) -> String {
            String(localized: "statusItem.ended", defaultValue: "\(what) · \(outcome)",
                   comment: "The toolbar's status item after a job ends: the work, and how it ended.")
        }
        public static var clickToSee: String {
            String(localized: "statusItem.clickToSee", defaultValue: "Click to see what it said in Activity",
                   comment: "Help tag on the toolbar's status item after a job ends.")
        }
        public static func held(_ n: Int) -> String {
            String(localized: "statusItem.held", defaultValue: "\(n) held",
                   comment: "The toolbar's status item when the list is held with work on it.")
        }
        public static func andMore(_ n: Int) -> String {
            String(localized: "statusItem.andMore", defaultValue: "and \(n) more",
                   comment: "Under the first three items on the list, in the toolbar's popover.")
        }
        public static var showTheList: String {
            String(localized: "statusItem.showTheList", defaultValue: "Show Up Next",
                   comment: "Opens the Activity window, where Up Next is. The list has one name everywhere.")
        }
        public static var showActivity: String {
            String(localized: "statusItem.showActivity", defaultValue: "Show Activity",
                   comment: "Opens the Activity window, where the log is.")
        }
    }
}
