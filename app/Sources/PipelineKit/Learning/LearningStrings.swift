import Foundation

/// §2.9 and §2.13, in plain words.
///
/// Three rules hold in this file. No word from the retired list is in a
/// label. Nothing here is ever put in front of a sentence the engine wrote —
/// where the engine has words, the engine's words are shown. And nothing
/// here states a number the engine did not send.
extension Strings {
    public enum Learning {
        private static func s(_ key: String, _ value: String, _ comment: String) -> String {
            Bundle.main.localizedString(forKey: key, value: value, table: nil)
        }

        public static var title: String {
            s("learning.title", "What the Cull Has Learned", "The screen's title and its sidebar row.")
        }
        public static var headline: String {
            s("learning.headline",
              "It learns only from shoots you have finished. Nothing new is used until it has been checked against every photograph you kept.",
              "The paragraph at the top of the learning screen.")
        }
        public static func checkedAgainst(_ keepers: Int, _ shoots: Int) -> String {
            String(localized: "learning.checkedAgainst",
                   defaultValue: "Checked against \(keepers) photographs you kept on \(shoots) shoots",
                   comment: "The screen's subtitle, and the sidebar row's.")
        }
        public static var nothingKeptYet: String {
            s("learning.nothingKeptYet", "Nothing to check against yet",
              "The subtitle before he has finished a shoot.")
        }
        public static var learnNow: String {
            s("learning.learnNow", "Learn Now", "The screen's one primary action.")
        }
        public static func lastChecked(_ when: String) -> String {
            String(localized: "learning.lastChecked", defaultValue: "Last checked \(when)",
                   comment: "The footer line.")
        }
        public static var neverChecked: String {
            s("learning.neverChecked", "Nothing has been checked yet", "The footer line, first run.")
        }
        public static func newShoots(_ n: Int) -> String {
            String(localized: "learning.newShoots",
                   defaultValue: n == 1 ? "1 new shoot to learn from" : "\(n) new shoots to learn from",
                   comment: "The footer line's second half.")
        }
        /// The shoots waiting to be learned from, named: one or two by name,
        /// more as the first and how many besides.
        public static func readyToLearnFrom(_ shoots: [String]) -> String {
            guard !shoots.isEmpty else { return nothingNew }
            let names = shootNames(shoots)
            return String(localized: "learning.readyToLearnFrom", defaultValue: "Ready to learn from \(names)",
                          comment: "The footer, naming the shoots waiting to be learned from, beside Learn Now.")
        }
        /// One or two shoots by name; more as the first and how many besides.
        static func shootNames(_ shoots: [String]) -> String {
            guard shoots.count > 2 else { return ListFormatter.localizedString(byJoining: shoots) }
            return String(localized: "learning.readyMore", defaultValue: "\(shoots[0]) and \(shoots.count - 1) more",
                          comment: "The first shoot named, and how many more.")
        }
        public static var nothingNew: String {
            s("learning.nothingNew", "Nothing new to learn from", "The footer line's second half.")
        }

        // MARK: the states

        public static var inUse: String { s("learning.inUse", "In use", "A learner's state.") }
        public static var notInUse: String { s("learning.notInUse", "Not in use", "A learner's state.") }
        public static var notEnough: String { s("learning.notEnough", "Not enough yet", "A learner's state.") }
        public static var couldNotCheck: String {
            s("learning.couldNotCheck", "Couldn't check", "A learner's state.")
        }
        public static var stoppedUsing: String {
            s("learning.stoppedUsing", "Turned off", "A learner he has turned off. What it learned is kept.")
        }
        public static var nothingLearnedYet: String {
            s("learning.nothingLearnedYet", "Nothing learned yet", "A learner with no data at all.")
        }
        public static var builtIn: String {
            s("learning.builtIn", "Built in", "Not trained on his photographs, and it says so.")
        }
        public static func inUseSince(_ date: String) -> String {
            String(localized: "learning.inUseSince", defaultValue: "In use since \(date).",
                   comment: "Composed only when the engine sent no sentence.")
        }
        public static func wouldHide(_ n: Int, _ shoot: String) -> String {
            String(localized: "learning.wouldHide",
                   defaultValue: "Not in use. The new version would stop putting forward \(n) of the photographs you kept on \(shoot).",
                   comment: "Composed only when the engine sent no sentence.")
        }

        // MARK: what it would cost him

        /// Says what it counts. "See the 48" sat under a sentence about 16,
        /// and he had to work out that 48 was every keeper the version would
        /// move — the 16 it hides, the others it moves lower, and the ones it
        /// brings forward.
        public static func seeThem(_ n: Int) -> String {
            String(localized: "learning.seeThem",
                   defaultValue: n == 1 ? "See the 1 It Would Change" : "See All \(n) It Would Change",
                   comment: "Opens every photograph the version would move, read only.")
        }
        public static var seeThemPlain: String {
            s("learning.seeThemPlain", "See Them", "Opens the affected photographs, read only.")
        }
        /// The button beside a needs line, naming the shoot it acts on.
        public static func needButton(_ need: LearnerNeed) -> String {
            switch need.act {
            case .pull:
                return String(localized: "learning.needPull", defaultValue: "Bring \(need.shoot) Back…",
                              comment: "Opens the list of that shoot's RAWs to bring back from iCloud.")
            case .finish:
                return String(localized: "learning.needFinish", defaultValue: "Open \(need.shoot)",
                              comment: "Goes to that shoot's Edit in PhotoLab step.")
            case .vectors:
                return String(localized: "learning.needVectors", defaultValue: "Measure \(need.shoot)",
                              comment: "Measures that shoot's picture vectors off its previews, so the check can reach it.")
            }
        }
        public static func needHelp(_ need: LearnerNeed) -> String {
            switch need.act {
            case .pull:
                return s("learning.needPullHelp",
                         "Shows what would be brought back from iCloud before anything is copied. Then press Learn Now.",
                         "Help on the bring-back button beside a needs line.")
            case .finish:
                return s("learning.needFinishHelp",
                         "Opens the shoot at Edit in PhotoLab, where its keepers are finished.",
                         "Help on the open button beside a needs line.")
            case .vectors:
                return s("learning.needVectorsHelp",
                         "Measures its frames off the previews it already has. Nothing in the shoot changes. Then press Learn Now to check it.",
                         "Help on the Measure button beside a check that could not reach a shoot.")
            }
        }
        public static var goBack: String {
            s("learning.goBack", "Go Back to the Version Before",
              "In the row's ⋯ menu. It runs the same check first.")
        }
        public static var stopUsing: String {
            s("learning.stopUsing", "Stop Using This", "In the row's ⋯ menu. The data is kept.")
        }
        public static var startUsing: String {
            s("learning.startUsing", "Start Using This Again", "Turns a stopped learner back on.")
        }
        public static var moreActions: String {
            s("learning.moreActions", "More", "The ⋯ menu's label, for VoiceOver and Voice Control.")
        }

        // MARK: the review screen

        public static var reviewTitle: String {
            s("learning.reviewTitle", "What this would change", "The read-only review screen's title.")
        }
        public static func reviewSubtitle(_ n: Int, _ shoot: String) -> String {
            String(localized: "learning.reviewSubtitle",
                   defaultValue: n == 1 ? "1 photograph you kept on \(shoot)"
                                        : "\(n) photographs you kept on \(shoot)",
                   comment: "Under the review screen's title.")
        }
        public static func reviewSubtitleMany(_ n: Int) -> String {
            String(localized: "learning.reviewSubtitleMany",
                   defaultValue: n == 1 ? "1 photograph you kept" : "\(n) photographs you kept",
                   comment: "Under the review screen's title, across more than one shoot.")
        }
        /// A group's heading in the review: what happens to these frames,
        /// said once for all of them, in the engine's two words.
        public static func reviewGroup(_ now: String, _ new: String, _ n: Int) -> String {
            String(localized: "learning.reviewGroup",
                   defaultValue: "Now: \(now) · New version: \(new) — \(n)",
                   comment: "A heading over the frames one change applies to. Both words are the engine's.")
        }
        public static var reviewLargeHint: String {
            s("learning.reviewLargeHint", "Space to go back · ← → for the next",
              "Beside a frame opened large in the review.")
        }
        public static var done: String {
            s("learning.done", "Done", "Ends the review. Nothing is being cancelled.")
        }
        public static var readOnly: String {
            s("learning.readOnly", "Keep and Drop are off here. This is a look, not a decision.",
              "Why the verdict keys do nothing in review mode.")
        }
        public static func nowAndNew(_ now: String, _ candidate: String) -> String {
            String(localized: "learning.nowAndNew",
                   defaultValue: "Now: \(now) · New version: \(candidate)",
                   comment: "A frame's caption in review mode. Both halves are the engine's words.")
        }
        public static var useItAnyway: String {
            s("learning.useItAnyway", "Use It Anyway…",
              "Exists only on the review screen, with the frames in front of him.")
        }
        public static var useItAnywayConfirm: String {
            s("learning.useItAnywayConfirm", "Use It Anyway", "The sheet's other button. Not the default.")
        }
        public static func useItAnywayBody(_ n: Int, _ shoot: String) -> String {
            String(localized: "learning.useItAnywayBody",
                   defaultValue: "It would stop putting forward \(n) photographs you kept on \(shoot). Your keepers stay kept — the cull just shows them less. You can go back to the version before at any time.",
                   comment: "The Use It Anyway sheet's body.")
        }
        public static func useItAnywayBodyMany(_ n: Int) -> String {
            String(localized: "learning.useItAnywayBodyMany",
                   defaultValue: "It would stop putting forward \(n) photographs you kept. Your keepers stay kept — the cull just shows them less. You can go back to the version before at any time.",
                   comment: "The Use It Anyway sheet's body, across more than one shoot.")
        }
        /// After the engine's own sentence about what the version would do,
        /// and true of what that learner changes: a preset hides no keeper,
        /// and the burst order moves them rather than showing them less.
        public static func useItAnywayTail(for learner: Learner) -> String {
            if learner.isStartingEdit { return useItAnywayTailEdit }
            if learner.isBurstOrder { return useItAnywayTailOrder }
            return useItAnywayTail
        }
        public static var useItAnywayTail: String {
            s("learning.useItAnywayTail",
              "Your keepers stay kept — the cull just shows them less. You can go back to the version before at any time.",
              "The Use It Anyway sheet's body, after the engine's sentence, for a learner that ranks frames.")
        }
        public static var useItAnywayTailEdit: String {
            s("learning.useItAnywayTailEdit",
              "Only a new shoot starts from it, and nothing you have exported is rendered again. You can go back to the version before at any time.",
              "The Use It Anyway sheet's body for the starting edit, after the engine's sentence. A preset shows no keeper less.")
        }
        public static var useItAnywayTailOrder: String {
            s("learning.useItAnywayTailOrder",
              "Your keepers stay kept — only where they come in their burst changes. You can go back to the version before at any time.",
              "The Use It Anyway sheet's body for the burst order, after the engine's sentence. It hides none.")
        }
        /// Composed only when the engine sent no sentence and the version
        /// hides nothing: it moves keepers within their bursts.
        public static func useItAnywayMoves(_ later: Int, _ earlier: Int) -> String {
            String(localized: "learning.useItAnywayMoves",
                   defaultValue: "It would show \(later) of the photographs you kept later in their burst and \(earlier) earlier.",
                   comment: "The Use It Anyway sheet's first sentence for a version that hides none of his keepers.")
        }
        public static var useItAnywayTitle: String {
            s("learning.useItAnywayTitle", "Use this version anyway?", "The sheet's title.")
        }
        public static var cancel: String { s("learning.cancel", "Cancel", "The default button.") }

        // MARK: while it runs, and after

        public static func learningFrom(_ shoot: String, _ keepers: Int) -> String {
            String(localized: "learning.learningFrom",
                   defaultValue: "Learning from \(shoot)… checking against your \(keepers) keepers",
                   comment: "On the row, while the job runs. The rest of the app stays usable.")
        }
        public static var learningNow: String {
            s("learning.learningNow", "Learning…", "On the row, while the job runs and no shoot is named.")
        }
        public static var queued: String {
            s("learning.queued", "Something else is running. This starts when it is done.",
              "A second job was asked for while one runs.")
        }
        /// The row's Stop, while it runs. Not "cancel": nothing is being
        /// undone, and nothing he decided is at stake.
        public static var stopLearning: String {
            s("learning.stopLearning", "Stop",
              "Stops the learning run from the row it is reported on.")
        }
        public static var stopping: String {
            s("learning.stopping", "Stopping…", "After Stop was pressed on the learning row.")
        }
        /// Said where he can read it before he decides, because it is the
        /// whole reason this is a thing he is allowed to stop. The engine
        /// sends this sentence; this is what an engine that does not gets.
        public static var safeToStop: String {
            s("learning.safeToStop", "Stopping it loses only the time it has spent.",
              "Under the learning row, while it runs. The line above it already says nothing new is used until it is checked.")
        }
        /// After his own work pushed it aside. A note, not a refusal.
        public static var pausedForYou: String {
            s("learning.pausedForYou", "Paused while you were working. It picks up when the Mac is idle.",
              "On the learning row, after his work stood the run down.")
        }
        public static func elapsedFor(_ elapsed: String) -> String {
            String(localized: "learning.elapsedFor", defaultValue: "Going for \(elapsed)",
                   comment: "How long the learning run has been going, on the row.")
        }
        public static var whatChanged: String {
            s("learning.whatChanged", "What Changed", "The banner's button: brings the first changed row into view.")
        }
        public static var dismissBanner: String {
            s("learning.dismissBanner", "Dismiss", "Clears the banner after a run.")
        }
        // MARK: the banner after a run

        public static func learnedFrom(_ shoots: [String]) -> String {
            let names = shootNames(shoots)
            return String(localized: "learning.bannerFrom", defaultValue: "The cull learned from \(names).",
                          comment: "The banner's first sentence after a run lands.")
        }
        public static var learnedBare: String {
            s("learning.bannerBare", "The cull finished learning.", "The banner's first sentence, no shoot named.")
        }
        public static func bannerInUse(_ title: String) -> String {
            String(localized: "learning.bannerInUse",
                   defaultValue: "\(title): a new version is in use, and none of your keepers is hidden by it.",
                   comment: "Only a version that hid none of his keepers goes into use from a run.")
        }
        /// The starting edit hides nothing and shows nothing less: it is the
        /// first preset of the next shoot.
        public static func bannerInUseEdit(_ title: String) -> String {
            String(localized: "learning.bannerInUseEdit",
                   defaultValue: "\(title): a new version is in use, and new shoots start from it.",
                   comment: "The banner, when the starting edit changed. It never touches the cull.")
        }
        public static func bannerInUseMany(_ n: Int) -> String {
            String(localized: "learning.bannerInUseMany",
                   defaultValue: "\(n) new versions are in use, and none of your keepers is hidden by them.",
                   comment: "The banner, when more than one learner changed.")
        }
        public static func bannerInUseManyWithEdit(_ n: Int) -> String {
            String(localized: "learning.bannerInUseManyWithEdit",
                   defaultValue: "\(n) new versions are in use: none of them hides one of your keepers, and new shoots start from the new edit.",
                   comment: "The banner, when more than one learner changed and one of them is the starting edit.")
        }
        public static func bannerHeld(_ title: String) -> String {
            String(localized: "learning.bannerHeld", defaultValue: "\(title): a new version was held back.",
                   comment: "A version the run learned and the check held.")
        }
        public static func bannerHeldMany(_ n: Int) -> String {
            String(localized: "learning.bannerHeldMany", defaultValue: "\(n) new versions were held back.",
                   comment: "More than one version the run learned and the check held.")
        }
        public static var bannerNothing: String {
            s("learning.bannerNothing", "Nothing new went into use.", "The banner when the run changed nothing.")
        }
        public static var stoppedBanner: String {
            s("learning.stoppedBanner",
              "Stopped. Nothing it had learned is used, and it is asked for again when the Mac is idle.",
              "The banner after he stopped the run.")
        }
        public static func queuedBehind(_ title: String) -> String {
            String(localized: "learning.queuedBehind",
                   defaultValue: "Waiting for \(title) to finish. Then it learns.",
                   comment: "A run asked for while another job runs. The title is the engine's.")
        }
        public static var nothingCanBeRead: String {
            s("learning.nothingCanBeRead", "The record of what the cull has learned cannot be read.",
              "Shown instead of the rows when the whole record is unreadable.")
        }
        public static var nothingFinishedYet: String {
            s("learning.nothingFinishedYet", "Nothing has been finished yet",
              "The empty state: no shoot has been marked finished.")
        }
        public static var nothingFinishedYetWhy: String {
            s("learning.nothingFinishedYetWhy",
              "Mark a shoot finished and the cull can start learning from it. Until then it works the way it came.",
              "Under the empty state's title.")
        }
        public static var whatItWillLearn: String {
            s("learning.whatItWillLearn", "What it will learn",
              "Above one line per learner on the first run, before anything has been learned.")
        }
        public static var fixedHeader: String {
            s("learning.fixedHeader", "Things that do not learn",
              "The section under the learners.")
        }
        public static var folder: String {
            s("learning.folder", "What it has learned is kept in", "A label in the footer.")
        }
        public static var recordIs: String {
            s("learning.recordIs", "The record is", "Beside the path of a record that will not read.")
        }
        public static var showInFinder: String {
            s("learning.showInFinder", "Show in Finder", "Beside the path of a record that will not read.")
        }
        public static var learnNowWaitsForRecord: String {
            s("learning.learnNowWaitsForRecord", "Learn Now waits until the record of what it has learned reads again",
              "The help of Learn Now while it is off because the record will not read.")
        }
        /// The shoots the check could not measure against, named once. The
        /// reason is in the sentence above them and is the same for all.
        public static func notCheckedOn(_ shoots: [String]) -> String {
            let names = ListFormatter.localizedString(byJoining: shoots)
            return String(localized: "learning.notCheckedOn",
                          defaultValue: "Not checked on: \(names)",
                          comment: "The shoots a check could not be measured against, named once.")
        }
        public static func checkedNoneLost(_ checked: Int, _ down: Int, _ up: Int) -> String {
            String(localized: "learning.checkedNoneLost",
                   defaultValue: "Checked on \(checked) photographs you kept: none stopped, \(down) shown less, \(up) shown more.",
                   comment: "A learner that passed its check.")
        }
    }
}
