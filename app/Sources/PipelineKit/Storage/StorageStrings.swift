import Foundation

/// §2.8 and §2.13.
///
/// Everything a *count* or a *size* appears in comes from the engine: the
/// panel's line, the states' words, the plan's label and its list are all
/// printed as the engine wrote them. What is here is only what the app says
/// for itself — the names of the actions, and the sentences around the two
/// rungs that cannot be undone.
extension Strings {
    public enum Storage {
        private static func s(_ key: String, _ value: String, _ comment: String) -> String {
            Bundle.main.localizedString(forKey: key, value: value, table: nil)
        }

        public static var title: String { s("storage.title", "Storage", "The panel's heading.") }
        public static var whereTheyAre: String {
            s("storage.whereTheyAre", "Where your photographs are", "The panel's first group.")
        }
        public static var missingNext: String {
            s("storage.missingNext",
              "Check Every Original, below, looks for each of them again and names the ones that are gone.",
              "Under a row of frames recorded as archived and found nowhere: what he can do next.")
        }
        public static var thisMac: String { s("storage.thisMac", "This Mac", "The first glyph cell.") }
        public static var iCloud: String { s("storage.iCloud", "iCloud", "The second glyph cell.") }

        // MARK: the frequent actions, first and together

        public static var push: String {
            s("storage.push", "Copy the RAWs to iCloud…",
              "A frequent action. The ellipsis is the plan sheet, as in Shoot ▸ Storage.")
        }
        public static var pull: String {
            s("storage.pull", "Bring the RAWs Back…",
              "A frequent action. The ellipsis is the plan sheet, as in Shoot ▸ Storage.")
        }
        /// An action's name with the engine's own figure for what it would
        /// carry: "Copy the RAWs to iCloud (36.3 GB)…".
        public static func sized(_ name: String, _ size: String) -> String {
            guard !size.isEmpty else { return name }
            let bare = name.hasSuffix("…") ? String(name.dropLast()) : name
            return String(localized: "storage.sized", defaultValue: "\(bare) (\(size))…",
                          comment: "A panel button with the engine's figure for what it would carry.")
        }

        // MARK: why a button is off
        //
        // Said beside the button and in its help, from the engine's own
        // counts, so a disabled button always carries its reason (§2.8).

        public static var dropNotFinished: String {
            s("storage.dropNotFinished", "This shoot is not finished yet, so its RAWs are still going to be read. Press Finish This Shoot first.",
              "Why Remove the Local RAWs is off on a shoot copied to iCloud before it was finished.")
        }
        public static var pushNothing: String {
            s("storage.pushNothing", "Nothing on this Mac is waiting to be copied to iCloud.",
              "Why Copy the RAWs to iCloud is off.")
        }
        public static var nothingInICloud: String {
            s("storage.nothingInICloud", "Nothing of this shoot is in iCloud.",
              "Why Bring the RAWs Back or Let Go is off.")
        }
        public static var pullNothing: String {
            s("storage.pullNothing", "Every RAW of this shoot in iCloud is already on this Mac.",
              "Why Bring the RAWs Back is off.")
        }
        public static var reclaimRefused: String {
            s("storage.reclaimRefused", "It will not run on this shoot, for the reasons listed above.",
              "Why the cache button is off when the engine refuses the shoot.")
        }
        public static var reclaimNothing: String {
            s("storage.reclaimNothing", "Nothing here can be taken back.", "Why the cache button is off.")
        }
        public static var dropNothingHere: String {
            s("storage.dropNothingHere", "None of its RAWs are on this Mac.", "Why Remove the Local RAWs is off.")
        }
        public static var dropNothingUp: String {
            s("storage.dropNothingUp", "Nothing here has a copy in iCloud yet.", "Why Remove the Local RAWs is off.")
        }
        public static var dropNothingChecked: String {
            s("storage.dropNothingChecked", "Nothing here has a checked copy in iCloud yet.",
              "Why Remove the Local RAWs is off.")
        }
        public static var expireNotFinished: String {
            s("storage.expireNotFinished", "This shoot is not finished, so nothing in it has started to age.",
              "Why Let Go is off.")
        }
        public static func expireNotDue(_ days: Int) -> String {
            String(localized: "storage.expireNotDue",
                   defaultValue: days == 1 ? "Not due for 1 more day, by the retention set above."
                                           : "Not due for \(days) more days, by the retention set above.",
                   comment: "Why Let Go is off: the retention lock has not run out.")
        }
        public static func why(_ name: String, _ reason: String) -> String {
            let bare = name.hasSuffix("…") ? String(name.dropLast()) : name
            return String(localized: "storage.why", defaultValue: "\(bare): \(reason)",
                          comment: "A footnote under the buttons naming one that is off and why.")
        }
        public static var check: String {
            s("storage.check", "Check Every Original", "A frequent action. It reads; it removes nothing.")
        }
        public static var reclaim: String {
            s("storage.reclaim", "Take Back the Cache…",
              "Removes renderings the app can make again. The ellipsis is the plan sheet.")
        }

        // MARK: the job the panel started

        public static var jobStarting: String {
            s("storage.jobStarting", "Starting…",
              "The panel's progress row before the engine has described the job it started.")
        }
        /// How a job the panel started ended. The title is the engine's own
        /// ("copying the RAWs of 2026-09-19 to iCloud"); only the outcome is
        /// said here, in the Activity window's words.
        public static func jobEnded(_ outcome: PipelineKit.Job.Outcome, _ title: String) -> String {
            guard !title.isEmpty else {
                switch outcome {
                case .done: return Strings.Job.done
                case .stopped: return Strings.Job.stopped
                case .failed: return Strings.Job.failed
                case .refused: return Strings.Job.refused
                case .idle, .running: return s("storage.jobEndedBare", "It has ended.",
                                               "A job whose own ending was not seen.")
                }
            }
            switch outcome {
            case .done:
                return String(localized: "storage.jobDone", defaultValue: "Finished \(title).",
                              comment: "The panel's line after a job it started ended well. The title is the engine's.")
            case .stopped:
                return String(localized: "storage.jobStopped", defaultValue: "Stopped \(title).",
                              comment: "After he stopped the job. The title is the engine's.")
            case .failed:
                return String(localized: "storage.jobFailed", defaultValue: "It failed while \(title).",
                              comment: "After the job crashed. The title is the engine's.")
            case .refused:
                return String(localized: "storage.jobRefused", defaultValue: "Refused: \(title). Its reason is below.",
                              comment: "A command that said no on purpose. Not a failure.")
            case .idle, .running:
                return String(localized: "storage.jobEnded", defaultValue: "Ended: \(title).",
                              comment: "Another job took the slot before this one's ending was seen.")
            }
        }
        public static var dismiss: String {
            s("storage.dismiss", "Dismiss", "Clears the line saying how the last job ended.")
        }
        public static var waitForTheJob: String {
            s("storage.waitForTheJob", "Waits for the job at the top of this panel to finish",
              "On every panel button while a job the panel started is running.")
        }

        // MARK: the group below the rule

        public static var destructiveGroup: String {
            s("storage.destructiveGroup", "Remove and delete",
              "The header of the group that is kept away from the frequent buttons.")
        }
        public static var drop: String {
            s("storage.drop", "Remove the Local RAWs…", "Removes a copy and keeps a checked one.")
        }
        public static var expire: String {
            // "Archived" was a third word for iCloud on a panel that says
            // iCloud everywhere else.
            s("storage.expire", "Let Go of the RAWs in iCloud…", "The one rung that deletes photographs.")
        }
        public static var neverDeletesFolder: String {
            s("storage.neverDeletesFolder",
              "FirstEdit never deletes a shoot's folder. Finder does that.",
              "Under the group, so the limit is stated rather than discovered.")
        }

        // MARK: the plan sheet

        /// The plan sheet's title, by what the list is of. "This is what
        /// would go" sat over a list of what would be copied up, which goes
        /// nowhere.
        public static func planTitle(for what: String) -> String {
            switch what {
            case "push":
                return s("storage.planTitle.push", "This is what would be copied to iCloud",
                         "The plan sheet's title for Copy the RAWs to iCloud.")
            case "pull":
                return s("storage.planTitle.pull", "This is what would be brought back",
                         "The plan sheet's title for Bring the RAWs Back.")
            default:
                return s("storage.planTitle", "This is what would go", "The plan sheet's title.")
            }
        }
        public static var drawing: String {
            s("storage.drawing", "Working out the list…", "While the engine draws the list.")
        }
        public static var cancel: String { s("storage.cancel", "Cancel", "The default button.") }
        public static var redrawn: String {
            s("storage.redrawn",
              "This shoot changed since that list was drawn. Here is the list again.",
              "Shown when the engine refuses a spent or stale confirmation.")
        }
        public static var nothingToDo: String {
            s("storage.nothingToDo", "There is nothing in this list to do.", "A plan with no work in it.")
        }
        /// Not the same thing as an empty list, and it must not say so: a job
        /// of his is in the way and the list has not been drawn at all yet.
        public static var nothingDrawnYet: String {
            s("storage.nothingDrawnYet", "Nothing to confirm yet",
              "On the confirm button while a job he asked for is in the way.")
        }
        public static var refusedHeading: String {
            s("storage.refusedHeading", "It would not do these", "Above the engine's refusal lines.")
        }

        // MARK: rung one — replaces the machine's own work

        public static var replacesTitle: String {
            s("storage.replacesTitle", "Run this again?",
              "The sheet for a rung that replaces the machine's own work.")
        }
        public static var keepsYourMarks: String {
            s("storage.keepsYourMarks",
              "Everything you have marked stays exactly as it is. Only the machine's own work is replaced.",
              "The body of a rung-one sheet.")
        }

        // MARK: rung three — the one that deletes photographs

        public static func letGoTitle(_ n: Int) -> String {
            String(localized: "storage.letGoTitle",
                   defaultValue: n == 1 ? "Let go of 1 photograph?" : "Let go of \(n) photographs?",
                   comment: "The title of the only sheet that deletes photographs.")
        }
        public static var letGoBody: String {
            s("storage.letGoBody",
              "They are in iCloud and nothing on this Mac will hold them afterwards. This cannot be undone.",
              "The body of the let-go sheet.")
        }
        public static var includeOnlyCopies: String {
            s("storage.includeOnlyCopies", "Including the frames with no other copy",
              "A separate, unticked checkbox. Ticking it redraws the list.")
        }
        public static func typeToConfirm(_ n: Int) -> String {
            String(localized: "storage.typeToConfirm",
                   defaultValue: "Type the number of photographs to let go: \(n)",
                   comment: "The label of the field that has to match before the button works.")
        }
        public static func protectedKeepers(_ n: Int) -> String {
            String(localized: "storage.protectedKeepers",
                   defaultValue: n == 1 ? "1 photograph you kept is protected and stays."
                                        : "\(n) photographs you kept are protected and stay.",
                   comment: "Frozen at the value the list was drawn against, never recomputed.")
        }
        public static var theseWillGo: String {
            s("storage.theseWillGo", "These will cease to exist",
              "Above the names, listed as the engine printed them.")
        }
        public static var optionChanged: String {
            s("storage.optionChanged", "The list is being drawn again for that option.",
              "Ticking the checkbox invalidates the list, and the button waits for the new one.")
        }

        // MARK: the fold, and the retention lock

        public static var frameByFrame: String {
            s("storage.frameByFrame", "Every original, one by one",
              "A fold, fetched only when it is opened.")
        }
        public static var frame: String { s("storage.frame", "Original", "A column.") }
        public static var size: String { s("storage.size", "Size", "A column.") }
        public static var whereItIs: String { s("storage.whereItIs", "Where it is", "A column.") }
        public static var retention: String {
            s("storage.retention", "Let go of the RAWs in iCloud after", "The retention lock's label.")
        }
        /// The unit beside the retention field, for the number in it: "1 days"
        /// was what a retention of one said.
        public static func daysWord(_ n: Int) -> String {
            n == 1 ? s("storage.dayWord", "day", "Beside the retention field when it holds 1.")
                   : s("storage.daysWord", "days", "Beside the retention field.")
        }
        public static func days(_ n: Int) -> String {
            String(localized: "storage.days", defaultValue: n == 1 ? "1 day" : "\(n) days",
                   comment: "The retention lock's value.")
        }
        public static var retentionIsALock: String {
            s("storage.retentionIsALock",
              "Nothing is scheduled by this. It only decides when Let Go of the RAWs in iCloud… stops refusing.",
              "Under the retention lock, because a timer that deletes photographs is not in this app.")
        }
        public static var useAsDefault: String {
            s("storage.useAsDefault", "Use this for new shoots too", "Beside the retention lock.")
        }
        /// One noun for these bytes on the panel, its button, the menu, the
        /// library page and the sheet: the cache. Renderings, derived and
        /// "can be taken back" were three more names for it.
        public static var cacheHeading: String {
            s("storage.cacheHeading", "The cache", "The group that holds the cache figures.")
        }
        public static var derived: String {
            s("storage.derived", "Made from the originals", "A label beside the engine's own figure.")
        }
        /// Beside the figure Take Back the Cache… would take: the engine's
        /// own, the same one on the button and its sheet.
        public static var canTakeBackNow: String {
            s("storage.canTakeBackNow", "Can be taken back now", "A label beside the engine's own figure.")
        }
        public static var cacheRefusedHeading: String {
            s("storage.cacheRefusedHeading", "Take Back the Cache won't run on this shoot:",
              "Above the engine's reasons the cache cannot be taken back.")
        }
        public static func lastCopyWarning(_ count: Int, _ bytes: String) -> String {
            String(localized: "storage.lastCopyWarning",
                   defaultValue: "\(count) renderings (\(bytes)) are the last copy of frames this shoot has no original for. They are counted as originals and are never in a removal list.",
                   comment: "Why the cache figure is smaller than it looks.")
        }

        // MARK: the library-wide row

        public static var libraryTitle: String {
            s("storage.libraryTitle", "Storage", "The library-wide page's title.")
        }
        public static var free: String { s("storage.free", "Free on this disk", "A label.") }
        public static var reclaimable: String {
            s("storage.reclaimable", "Cache that can be taken back", "A label beside the engine's own figure.")
        }
        public static var strays: String {
            s("storage.strays", "Not in any shoot", "Files under the library root that belong to nothing.")
        }
        public static var libraryFolder: String {
            s("storage.libraryFolder", "Your photographs are in", "A label above the path.")
        }
        public static var perShoot: String {
            s("storage.perShoot", "Shoot by shoot", "The table under the library figures.")
        }
        public static var openShoot: String {
            s("storage.openShoot", "Shows this shoot's storage, on its Finish page",
              "The table row's action: it goes to the shoot's storage panel.")
        }
        public static var noShoots: String {
            s("storage.noShoots", "No shoots yet", "The library-wide page with nothing in it.")
        }
    }
}
