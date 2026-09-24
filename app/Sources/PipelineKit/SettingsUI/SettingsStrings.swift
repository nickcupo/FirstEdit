import Foundation

/// §2.11. Five tabs, each a grouped form.
extension Strings {
    public enum Settings {
        private static func s(_ key: String, _ value: String, _ comment: String) -> String {
            Bundle.main.localizedString(forKey: key, value: value, table: nil)
        }

        public static var general: String { s("settings.general", "General", "A tab.") }
        public static var choosing: String { s("settings.choosing", "Choosing", "A tab.") }
        public static var storage: String { s("settings.storage", "Storage", "A tab.") }
        public static var learning: String { s("settings.learning", "Learning", "A tab.") }
        public static var advanced: String { s("settings.advanced", "Advanced", "A tab.") }

        // General
        public static var libraryFolder: String {
            s("settings.libraryFolder", "Your photographs are in", "General.")
        }
        public static var choose: String { s("settings.choose", "Choose…", "A button.") }
        public static var nothingIsMoved: String {
            s("settings.nothingIsMoved", "Nothing is moved.", "Under the library folder.")
        }

        /// What is in the folder the control shows. The control above it is
        /// the folder the engine is given — the one he picked, resolved — so
        /// the line is the count alone; it used to spell the same path out a
        /// second time beside it.
        public static func resolvedLine(_ r: LibraryFolder.Resolution) -> String {
            r.shoots.count == 1
                ? s("settings.resolvedToOne", "1 shoot", "Under the library folder: what is there.")
                : String(format: s("settings.resolvedTo", "%lld shoots", "Under the library folder: what is there."),
                         r.shoots.count)
        }

        /// The refusal, naming what was looked for. A folder is turned down
        /// here rather than saved and left to fail silently in the engine.
        public static func noShootsHere(_ path: String) -> String {
            let f = s("settings.noShootsHere",
                      "There are no shoots in %@, and it holds other things. A shoot is a folder with a raw/, a cull/, or photographs in it: choose the folder that holds them, or an empty folder for new ones.",
                      "Shown when a chosen library folder has no shoot under it and is not empty.")
            return String(format: f, path)
        }
        /// The open panel's own line, the same from Settings, the first run
        /// and the empty sidebar.
        public static var pickerMessage: String {
            s("settings.pickerMessage", "Choose the folder that holds your shoots, or an empty folder for new ones.",
              "The line at the top of the folder panel.")
        }
        public static var editor: String { s("settings.editor", "Open keepers in", "General.") }
        public static var checkForUpdates: String {
            s("settings.checkForUpdates", "Check for updates automatically", "General.")
        }
        // The restart a new folder needs, asked only when a job of his is
        // running (`EngineRestart`).
        public static func restartStops(_ job: String) -> String {
            String(localized: "settings.restartStops", defaultValue: "Restarting the engine stops \(job).",
                   comment: "The question when a new library folder would stop a running job.")
        }
        public static var restartStopsBody: String {
            s("settings.restartStopsBody",
              "Or it can wait, and restart once that and anything waiting in Up Next are done. Nothing you decided is lost, and a stopped job can be started again.",
              "Under the question.")
        }
        public static var restartWhenItFinishes: String {
            s("settings.restartWhenItFinishes", "Restart When It Finishes", "The default answer.")
        }
        public static var stopItAndRestart: String {
            s("settings.stopItAndRestart", "Stop It and Restart", "The other answer.")
        }
        public static var restartCancel: String {
            s("settings.restartCancel", "Cancel", "Keeps the folder as it was.")
        }
        /// The restart waiting on the job, under the folder, with Don't Wait.
        public static func restartWaiting(_ job: String, _ folder: String) -> String {
            String(localized: "settings.restartWaiting",
                   defaultValue: "The engine restarts on \(folder) once \(job), and anything in Up Next after it, is done.",
                   comment: "Under the library folder while the restart waits for a job.")
        }
        /// The job and the list are done, and the restart is held while he is
        /// in Choose Keepers.
        public static func restartWhenYouLeave(_ folder: String) -> String {
            String(localized: "settings.restartWhenYouLeave",
                   defaultValue: "The engine restarts on \(folder) when you leave Choose Keepers.",
                   comment: "Under the library folder and at the foot of the sidebar, once the job it waited for is done.")
        }
        /// The window's line once a restart that waited has happened.
        public static func restartedAfter(_ job: String, _ folder: String) -> String {
            String(localized: "settings.restartedAfter",
                   defaultValue: "Now that \(job) is done, the engine reads \(folder).",
                   comment: "The window's quiet line after a restart that waited for a job.")
        }
        public static var dontWait: String {
            s("settings.dontWait", "Don't Wait", "Drops the waiting restart. Nothing is changed.")
        }
        /// The running job, as the question names it.
        public static func runningJob(kind: String, shoot: String, title: String) -> String {
            switch (kind, shoot.isEmpty) {
            case ("cull", false):
                return String(localized: "settings.job.cull", defaultValue: "the cull of \(shoot)",
                              comment: "Restarting the engine stops …")
            case ("ingest", false):
                return String(localized: "settings.job.ingest", defaultValue: "the copy of the card into \(shoot)",
                              comment: "Restarting the engine stops …")
            case ("presets", false):
                return String(localized: "settings.job.presets", defaultValue: "the presets being written for \(shoot)",
                              comment: "Restarting the engine stops …")
            case ("setup", _):
                // The engine's own title is "getting the picture model, once",
                // which made "Restarting the engine stops getting the picture
                // model, once."
                return s("settings.job.setup", "the picture model's download", "Restarting the engine stops …")
            default:
                if let what = Strings.Queue.what(kind) {
                    return shoot.isEmpty
                        ? String(localized: "settings.job.listed", defaultValue: "“\(what)”",
                                 comment: "Restarting the engine stops …: a piece of work by its name on the list.")
                        : String(localized: "settings.job.listedFor", defaultValue: "“\(what)” for \(shoot)",
                                 comment: "Restarting the engine stops …: a piece of work on the list, and its shoot.")
                }
                return title.isEmpty ? s("settings.job.something", "the job that is running", "Restarting the engine stops …")
                                     : title
            }
        }

        // Choosing
        public static var viewerBackground: String {
            s("settings.viewerBackground", "Viewer background", "Choosing. View ▸ Viewer Background, as a label.")
        }
        public static var neutralGrey: String { s("settings.neutralGrey", "Neutral Gray", "A choice.") }
        /// The same words as Appearance's: one phrase for one thing.
        public static var matchSystem: String { s("settings.matchSystem", "Match the Mac", "A choice.") }
        public static var black: String { s("settings.black", "Black", "A choice.") }
        public static var backgroundWhy: String {
            s("settings.backgroundWhy",
              "With Neutral Gray behind the photograph, exposure reads the same in light and dark.",
              "Under the viewer background. Said here only, not again under Appearance.")
        }
        public static var spaceKey: String { s("settings.spaceKey", "Space key", "Choosing.") }
        public static var spaceWhole: String {
            s("settings.spaceWhole", "Shows the whole picture", "A choice for the Space key.")
        }
        public static var spaceNextBurst: String {
            s("settings.spaceNextBurst", "Finishes the burst and opens the next", "A choice for the Space key.")
        }
        public static var afterLastFrame: String {
            s("settings.afterLastFrame", "After the last frame of a burst", "Choosing.")
        }
        public static var stayHere: String { s("settings.stayHere", "Stay here", "A choice.") }
        public static var goOn: String { s("settings.goOn", "Go to the next burst", "A choice.") }
        public static var reasonsStrip: String {
            s("settings.reasonsStrip", "Show the reasons after a Drop", "Choosing.")
        }
        public static var openStacksInCompare: String {
            s("settings.openStacksInCompare", "Open stacks of 4 or more side by side", "Choosing.")
        }
        public static var showCullMarks: String {
            s("settings.showCullMarks", "Show the cull's own marks in the filmstrip", "Choosing.")
        }

        // Storage
        public static var retentionDays: String {
            s("settings.retentionDays", "Let go of archived RAWs after", "Storage.")
        }
        /// Word for word what the storage panel says under its own lock:
        /// one setting, one sentence, wherever it is read.
        public static var retentionIsALock: String {
            s("settings.retentionIsALock",
              "Nothing is scheduled by this. It only decides when Let Go of the Archived RAWs… stops refusing.",
              "Under the retention setting, because that is the whole of what it does. The same as storage.retentionIsALock.")
        }

        // Learning
        public static var learnAutomatically: String {
            s("settings.learnAutomatically", "Learn from finished shoots automatically", "Learning.")
        }
        public static var learnOnlyWhenIdle: String {
            s("settings.learnOnlyWhenIdle", "Only when the Mac is idle", "Learning.")
        }
        public static var openLearning: String {
            s("settings.openLearning", "Open What the Cull Has Learned", "Learning.")
        }
        public static var learningIsChecked: String {
            s("settings.learningIsChecked",
              "Nothing it learns is used until it has been checked against every photograph you kept.",
              "Under the learning settings.")
        }

        // Advanced
        public static var showLog: String { s("settings.showLog", "Show the Log", "Advanced.") }
        public static var showSupportFolder: String {
            s("settings.showSupportFolder", "Show the Support Folder", "Advanced.")
        }
        public static var extensionLabel: String { s("settings.extension", "Extension", "Advanced.") }
        public static var extensionFound: String { s("settings.extensionFound", "Found", "Advanced.") }
        public static var extensionNotFound: String {
            s("settings.extensionNotFound", "Not found. First Edit is complete without one.", "Advanced.")
        }
        public static var pictureModel: String {
            s("settings.pictureModel", "The cull's picture model", "Advanced.")
        }
        public static var pictureModelHere: String {
            s("settings.pictureModelHere", "On this Mac", "Advanced, the picture model.")
        }
        public static var pictureModelMissing: String {
            s("settings.pictureModelMissing", "Not on this Mac yet · 1.7 GB",
              "Advanced, the picture model, above Download It.")
        }
        public static var webInspector: String {
            s("settings.webInspector", "Allow Web Inspector on the built-in pages", "Advanced.")
        }
        public static var runFirstRunAgain: String {
            s("settings.runFirstRunAgain", "Show the welcome pages again", "Advanced.")
        }
    }
}
