import Foundation

/// Every sentence the app says for itself.
///
/// Two rules hold here and are checked by `tools/vocabulary-scan.sh`. No word
/// from DESIGN.md §2.13's retired list appears in a label. And not one string
/// the extension contributes is in this file — those are fetched from
/// `ExtConfig` at runtime and never compiled in.
///
/// Everything goes through `String(localized:defaultValue:)` against the
/// catalog in `app/Resources/Localizable.xcstrings`. Running from a checkout
/// there is no compiled catalog, so the default value is what shows — which is
/// the English text written here, so nothing reads as a missing key. In a
/// built app a key the catalog has wins over the text here, so changing a
/// sentence whose key is in the catalog means changing it there too, and
/// `StringCatalogTests` fails until both say the same (DESIGN.md §4.2, §5).
public enum Strings {

    /// `comment` is for the catalog's translators and is read by nothing at
    /// runtime; it is kept at the call site so the sentence and its reason
    /// travel together.
    private static func s(_ key: String, _ value: String, _ comment: String) -> String {
        Bundle.main.localizedString(forKey: key, value: value, table: nil)
    }

    public enum App {
        public static var name: String { s("app.name", "First Edit", "The app's name, as a window title.") }
        public static func updateAvailable(_ version: String) -> String {
            String(localized: "app.updateAvailable", defaultValue: "Update to \(version) available ›",
                   comment: "The sidebar footer, only when there is one.")
        }
    }

    public enum Engine {
        public static var stoppedTitle: String {
            s("engine.stoppedTitle", "First Edit's engine stopped", "The engine-down view's title.")
        }
        public static var nothingLost: String {
            s("engine.nothingLost", "Nothing you decided is lost.", "Under the engine-down title.")
        }
        public static var stopped: String {
            s("engine.stopped", "First Edit's engine stopped. Nothing you decided is lost.",
              "Shown in place of the window's content when the child process is not running.")
        }
        public static var restarted: String {
            s("engine.restarted", "The engine stopped and was restarted. Nothing you decided is lost.",
              "A quiet banner, not an alert.")
        }
        public static var restart: String { s("engine.restart", "Restart the Engine", "Button.") }
        public static var showLog: String { s("engine.showLog", "Show the Log", "Button.") }
        public static var starting: String { s("engine.starting", "Starting…", "While the engine comes up.") }
        public static var couldNotStart: String {
            s("engine.couldNotStart", "The bundled Python could not be started.",
              "Shown with the last line of the log under it.")
        }
        public static var noPort: String {
            s("engine.noPort", "The engine started but never said which port it was on.", "A failed start.")
        }
        public static func exited(_ code: Int32) -> String {
            String(localized: "engine.exited", defaultValue: "The engine stopped (exit \(code)).",
                   comment: "The child process ended on its own.")
        }
    }

    public enum API {
        public static var offline: String {
            s("api.offline", "First Edit could not reach its own engine.", "A request never left.")
        }
        public static var notUnderstood: String {
            s("api.notUnderstood", "The engine answered something this version does not understand.",
              "A decoding failure. The technical text goes behind Details.")
        }
        public static func httpFailure(_ status: Int) -> String {
            String(localized: "api.httpFailure", defaultValue: "The engine refused that (\(status)).",
                   comment: "A non-success status with no sentence in the body.")
        }
    }

    public enum Library {
        public static var library: String { s("library.library", "Library", "Sidebar section.") }
        public static func kept(_ n: Int) -> String {
            String(localized: "library.kept", defaultValue: "\(n) keepers",
                   comment: "Keepers include explicit keeps and accepted cull picks in reviewed bursts.")
        }
        public static var allShoots: String { s("library.allShoots", "All Shoots", "Sidebar row.") }
        public static var learned: String {
            s("library.learned", "What the Cull Has Learned", "Sidebar row.")
        }
        public static var storage: String { s("library.storage", "Storage", "Sidebar row.") }
        public static var inProgress: String { s("library.inProgress", "In Progress", "Sidebar section.") }
        public static var finished: String { s("library.finished", "Finished", "Sidebar section.") }
        public static var memoryCard: String { s("library.memoryCard", "Memory Card", "Sidebar section.") }
        public static var empty: String { s("library.empty", "No shoots yet", "Nothing in the library.") }
        public static var emptyWhy: String {
            // It named File ▸ Add a Folder of Photographs…, which is greyed:
            // the engine copies only from a card (DESIGN.md §2.12).
            s("library.emptyWhy", "Put a memory card in to copy your first shoot.",
              "Under the empty-library title.")
        }
        /// Where it looked. An empty sidebar with nothing written on it is
        /// the same picture whether the library is new, the folder is wrong,
        /// or the disk it is on is not plugged in — and the folder being
        /// wrong is the one he actually hit.
        public static func emptyWhere(_ path: String) -> String {
            String(localized: "library.emptyWhere",
                   defaultValue: "Nothing was found in \(path).",
                   comment: "Under the empty-library title: the folder the engine looked in.")
        }
        public static var emptyLookedFor: String {
            s("library.emptyLookedFor",
              "It looks for folders with a raw/, a cull/, or photographs in them.",
              "Under the empty-library folder line.")
        }
        /// An empty folder he chose to start a library in, said the same way
        /// in Settings, on the first run and in the sidebar.
        public static func newLibrary(_ shelf: String) -> String {
            String(localized: "library.newLibrary",
                   defaultValue: "No shoots here yet. New shoots will be made in \(shelf).",
                   comment: "Under a chosen library folder that is empty.")
        }
        public static var chooseAnotherFolder: String {
            s("library.chooseAnotherFolder", "Choose Another Folder…",
              "The button on the empty sidebar.")
        }
        public static var loading: String { s("library.loading", "Looking for your shoots…", "First load.") }
        public static var lookAgain: String {
            s("library.lookAgain", "Look Again", "Button under the sentence saying the shoots could not be read.")
        }
        public static func frames(_ n: Int) -> String {
            String(localized: "library.frames", defaultValue: "\(n) frames", comment: "A shoot row's subtitle.")
        }
        public static var copying: String {
            s("library.copying", "Copying the card…",
              "A shoot row's subtitle while its card copy is running or waiting on the list.")
        }
        public static func copyStopped(_ files: Int, _ of: Int) -> String {
            String(localized: "library.copyStopped", defaultValue: "Copy stopped at \(files) of \(of)",
                   comment: "A shoot row's subtitle when its card copy stopped part way, by the copy's own log.")
        }
        public static func framesAndKept(_ n: Int, _ kept: Int) -> String {
            String(localized: "library.framesAndKept", defaultValue: "\(n) frames · \(kept) keepers",
                   comment: "A shoot row's subtitle. Keepers include explicit keeps and accepted cull picks.")
        }
        public static var showTheFile: String { s("library.showTheFile", "Show the File", "On a broken shoot's row.") }
    }

    public enum Overview {
        public static var shoot: String { s("overview.shoot", "Shoot", "A column.") }
        public static var frames: String { s("overview.frames", "Frames", "A column and a row label.") }
        public static var youKept: String { s("overview.youKept", "Keepers", "Explicit keeps and accepted cull picks.") }
        public static var youPutOut: String { s("overview.youPutOut", "Not kept", "Reviewed frames not kept, including cull decisions left unchanged.") }
        public static var cullPutForward: String {
            s("overview.cullPutForward", "The cull put forward", "The machine's shortlist, never his.")
        }
        public static var bursts: String { s("overview.bursts", "Bursts", "A row label.") }
        public static var folder: String { s("overview.folder", "Folder", "A row label.") }
        public static var where_: String { s("overview.where", "Where it is", "The engine's storage phrase.") }
        public static func beenThrough(_ seen: Int, _ total: Int) -> String {
            String(localized: "overview.beenThrough", defaultValue: "\(seen) of \(total) looked through",
                   comment: "Only leaving a burst forward records it as looked through. The one phrase for it, everywhere.")
        }
        public static func burstsOf(_ seen: Int, _ total: Int) -> String {
            String(localized: "overview.burstsOf", defaultValue: "\(seen) of \(total) bursts",
                   comment: "The window subtitle on Choose Keepers.")
        }
    }

    public enum Steps {
        public static var ingest: String { s("step.ingest", "Copy the Card", "Step name.") }
        public static var cull: String { s("step.cull", "Cull", "Step name.") }
        public static var keepers: String { s("step.keepers", "Choose Keepers", "Step name.") }
        public static var presets: String { s("step.presets", "Presets", "Step name.") }
        public static var edit: String { s("step.edit", "Edit in PhotoLab", "Step name.") }
        public static var instagram: String { s("step.instagram", "Instagram", "Step name.") }
        public static var reels: String { s("step.reels", "Reels", "Step name.") }
        public static var done: String { s("step.done", "Finish", "Step name.") }
        public static var notYet: String {
            s("step.notYet", "This step is not ready yet.", "A step whose prerequisite is unmet.")
        }
        public static var pickAShoot: String {
            s("step.pickAShoot", "Choose a shoot on the left.", "Nothing selected.")
        }
        public static var notBuiltYet: String {
            s("step.notBuiltYet", "This step is not built yet.",
              "The foundation shell before a feature crew registers its step view.")
        }
    }

    public enum Verdict {
        public static var keep: String { s("verdict.keep", "Keep", "The right-hand button. Never abbreviated.") }
        public static var drop: String { s("verdict.drop", "Drop", "The left-hand button.") }
        public static var dropHelp: String {
            s("verdict.dropHelp", "Drop doesn't delete anything. It records that this frame is out.",
              "Help tag on the Drop button.")
        }
        public static var notOnScreen: String {
            s("verdict.notOnScreen", "That frame isn't the one on screen.",
              "A verdict is only ever taken on a frame that is actually displayed.")
        }
        public static var noPixels: String {
            s("verdict.noPixels",
              "This frame's pixels are not on this Mac — its RAW is archived, or its rendering was taken back. Nothing can be decided here.",
              "A frame with no picture at any size can take no verdict.")
        }
        public static var stillOpening: String {
            s("verdict.stillOpening", "Still opening this frame.", "Shown with a soft bump and a haptic.")
        }
        public static var heldKey: String {
            s("verdict.heldKey", "Holding a key marks one frame only. Press it again for the next.",
              "Shown once when a key repeat is ignored.")
        }
        public static func undoKeep(_ frame: String) -> String {
            String(localized: "verdict.undoKeep", defaultValue: "Keep \(frame)",
                   comment: "Names the step in the Edit menu, after the word Undo.")
        }
        public static func undoDrop(_ frame: String) -> String {
            String(localized: "verdict.undoDrop", defaultValue: "Drop \(frame)", comment: "An undo step's name.")
        }
        public static func undoClear(_ frame: String) -> String {
            String(localized: "verdict.undoClear", defaultValue: "Clear the Mark on \(frame)",
                   comment: "An undo step's name.")
        }
        public static func undoKeepOnly(_ frame: String) -> String {
            String(localized: "verdict.undoKeepOnly", defaultValue: "Keep Only \(frame)",
                   comment: "An undo step's name.")
        }
        public static func undoReason(_ reason: String, _ frame: String) -> String {
            String(localized: "verdict.undoReason", defaultValue: "Reason '\(reason)' on \(frame)",
                   comment: "An undo step's name.")
        }
        public static func undoFinishBurst(_ n: Int) -> String {
            String(localized: "verdict.undoFinishBurst", defaultValue: "Leaving Burst \(n)",
                   comment: "An undo step's name: N, or an arrow past the burst's last frame.")
        }
    }

    public enum Job {
        public static var what: String { s("job.what", "Job", "A column in the Activity window.") }
        public static var shoot: String { s("job.shoot", "Shoot", "A column in the Activity window.") }
        public static var started: String { s("job.started", "Started", "A column in the Activity window.") }
        public static var elapsed: String { s("job.elapsed", "Elapsed", "A column in the Activity window.") }
        public static var outcome: String { s("job.outcome", "Outcome", "A column in the Activity window.") }
        public static var running: String { s("job.running", "Running", "An outcome.") }
        public static var stop: String { s("job.stop", "Stop", "Stops the running job.") }
        public static var waiting: String {
            s("job.waiting", "Waiting for what is running to finish", "A second job was asked for while one runs.")
        }
        public static var refused: String {
            s("job.refused", "Refused", "A first-class outcome, in the ordinary text colour.")
        }
        public static var failed: String { s("job.failed", "Failed", "An outcome.") }
        public static var stopped: String { s("job.stopped", "Stopped", "An outcome.") }
        public static var done: String { s("job.done", "Done", "An outcome.") }
        public static var activity: String { s("job.activity", "Activity", "The window's title.") }
        public static var noJobs: String {
            s("job.noJobs", "Nothing has run yet in this session.", "The Activity window, empty.")
        }
        public static var copyLog: String { s("job.copyLog", "Copy the Log", "Button in the Activity window.") }
        public static var showLogFile: String {
            s("job.showLogFile", "Show the Log File in Finder", "Button in the Activity window.")
        }

        // MARK: when what he pressed cannot start yet
        //
        // §2.13's rule holds in every one of these: they are his words. The
        // sentence that says WHY is always the engine's and is never written
        // here — what is here is the two choices, because a choice is a
        // button and the engine has no buttons.

        /// Queue it behind the job that is running. The engine already has
        /// the queue; this is the word for taking it.
        public static var waitItsTurn: String {
            s("job.waitItsTurn", "Add to Up Next",
              "The first of the two choices when another job is in the way: queue it.")
        }
        public static var stopTheOther: String {
            s("job.stopTheOther", "Stop What Is Running",
              "The second of the two choices: stop the job in the way.")
        }
        public static func waitingBehind(_ title: String) -> String {
            String(localized: "job.waitingBehind",
                   defaultValue: "Waiting. This starts when \(title) finishes.",
                   comment: "After he chose to wait. The title is the engine's.")
        }
        public static var dontWait: String {
            s("job.dontWait", "Don't Wait", "Takes a waiting request back out of the line.")
        }

        // MARK: the machine's own homework, standing down

        /// Shown after his work pushed the learning run aside. A note, in the
        /// ordinary text colour — nothing went wrong and nothing was lost.
        /// From the Activity popover to the one screen that explains the
        /// whole business. Not the screen's own name: a button labelled the
        /// same as the heading above it says nothing about what pressing it
        /// does.
        public static var showWhatItHasLearned: String {
            s("job.showWhatItHasLearned", "Show What It Has Learned",
              "Opens the learning screen from the Activity popover.")
        }
        public static var learningPaused: String {
            s("job.learningPaused", "Learning paused; it will pick up when you are finished.",
              "The fallback line. The engine sends this sentence itself; this is for an engine that does not.")
        }
    }

    public enum Appearance {
        public static let menuTitle = String(localized: "Appearance", comment: "View menu submenu")
        public static let settingsLabel = String(localized: "Appearance", comment: "Settings, General tab")
        public static let system = String(localized: "Match the Mac", comment: "Appearance choice: follow the system setting")
        public static let light = String(localized: "Light", comment: "Appearance choice")
        public static let dark = String(localized: "Dark", comment: "Appearance choice")
    }

    public enum Quit {
        public static func title(kind: String) -> String {
            kind == "cull"
                ? s("quit.titleCull", "A cull is running. Quit anyway?", "⌘Q while the cull runs.")
                : s("quit.title", "Something is still running. Quit anyway?", "⌘Q while a job runs.")
        }
        public static func body(kind: String) -> String {
            kind == "cull"
                ? s("quit.bodyCull", "The cull stops where it is. Nothing you decided is lost, and it can be started again.",
                    "Under the title.")
                : s("quit.body", "It stops where it is. Nothing you decided is lost, and it can be started again.",
                    "Under the title.")
        }
        public static var keepWorking: String { s("quit.keepWorking", "Keep Working", "The default button.") }
        public static var quit: String { s("quit.quit", "Quit", "The other button.") }
    }

    public enum Shell {
        public static var details: String {
            s("shell.details", "Details", "The disclosure that holds the technical text of a refusal.")
        }
        public static var inspector: String { s("shell.inspector", "Inspector", "Toolbar toggle.") }
        public static var sidebar: String { s("shell.sidebar", "Sidebar", "Toolbar toggle.") }
        public static var nothingToShow: String {
            s("shell.nothingToShow", "Nothing to show here yet.", "An empty inspector.")
        }
    }
}
