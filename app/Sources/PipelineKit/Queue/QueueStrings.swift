import Foundation

/// Every sentence the list says for itself.
///
/// "Job" is ours, not his. The engine calls a piece of work a job because a
/// job is what a process is; on screen it is the thing he already calls it —
/// **Cull**, **Write the presets**, **Copy the RAWs to iCloud** — and the
/// list is a list of work, not a queue of jobs. DESIGN.md §2.13's table is
/// the source of every word in `what(_:)`, and where the app has no word for
/// a kind the engine's own title is printed rather than a guess.
///
/// The list has one name, **Up Next**, on every button that fills it, on its
/// heading and in the toolbar. It went by four - "the List", "Up Next",
/// "Activity" and "the Activity item" - so the same act read as four things.
/// The window it lives in is still Activity, because the history is there too.
///
/// The sentence that says why something was refused, or why something could
/// not run when its turn came, is the ENGINE's and is never written here.
extension Strings {

    private static func q(_ key: String, _ value: String, _ comment: String) -> String {
        Bundle.main.localizedString(forKey: key, value: value, table: nil)
    }

    public enum Queue {

        // MARK: - what the list is

        public static var title: String {
            q("queue.title", "Up Next", "The heading over the list in the Activity window.")
        }
        public static var emptyTitle: String {
            q("queue.emptyTitle", "Nothing waiting", "The list, with nothing on it.")
        }
        /// What the list is FOR, said where he finds it empty. The one place
        /// the whole idea is explained, so it is explained in his evening's
        /// own terms rather than in ours.
        public static var emptyBody: String {
            q("queue.emptyBody",
              "Stack up everything you want done — a copy, a cull, the presets, a reel, the RAWs to iCloud — and walk away. Hold ⌥ on any step's button to add it here instead of doing it now.",
              "The empty list. It says what the list is for.")
        }
        public static var runningNow: String {
            q("queue.runningNow", "Happening now", "The heading over the job that is running.")
        }

        // MARK: - his words for each kind of work

        /// His own word for a kind of work, or `nil` where the app has none
        /// and the engine's title should be printed instead.
        public static func what(_ kind: String) -> String? {
            switch kind {
            case "ingest": return q("queue.what.ingest", "Copy the Card", "A piece of work on the list.")
            case "cull": return q("queue.what.cull", "Cull", "A piece of work on the list.")
            case "presets": return q("queue.what.presets", "Write the presets", "A piece of work on the list.")
            case "gather": return q("queue.what.gather", "Build the PhotoLab folder", "A piece of work on the list.")
            case "spread": return q("queue.what.spread", "Write presets for the burst", "A piece of work on the list.")
            case "reel": return q("queue.what.reel", "Cut a reel", "A piece of work on the list.")
            case "instagram": return q("queue.what.instagram", "Make the Instagram copies", "A piece of work on the list.")
            case "stor-push": return q("queue.what.push", "Copy the RAWs to iCloud", "A piece of work on the list.")
            case "stor-pull": return q("queue.what.pull", "Bring the RAWs back", "A piece of work on the list.")
            case "stor-check": return q("queue.what.check", "Check every original", "A piece of work on the list.")
            // A plan is named for what it checks. All five were "Work out
            // what would go", which a copy to iCloud does not do, while the
            // notification that sent him to the row named the plan itself.
            case "plan-push": return q("queue.what.planPush", "Check what would be copied", "A storage plan on the list.")
            case "plan-pull": return q("queue.what.planPull", "Check what would come back", "A storage plan on the list.")
            case "plan-drop": return q("queue.what.planDrop", "Check what would be removed", "A storage plan on the list.")
            case "plan-expire": return q("queue.what.planExpire", "Check what would be let go", "A storage plan on the list.")
            case "plan-reclaim":
                return q("queue.what.planReclaim", "Check what cache would be taken back", "A storage plan on the list.")
            default: return nil
            }
        }

        // MARK: - the two things a step's button can be

        /// The primary of a step, when pressing it would add to the list
        /// rather than start now.
        ///
        /// Not "Add Cull It to the List": a button that swallows another
        /// button's sentence reads like a machine wrote it, and the step's
        /// own page is right above it saying which step this is. What it has
        /// to carry is where pressing it goes, and it says that. The step's
        /// verb is still in the help tag and in what VoiceOver reads, where
        /// there is room for a whole sentence.
        public static var addInstead: String {
            q("queue.addInstead", "Add to Up Next",
              "A step's primary while something else is running, or with ⌥ held.")
        }
        public static func addInsteadSpoken(_ action: String) -> String {
            String(localized: "queue.addInsteadSpoken", defaultValue: "Add \(action) to Up Next",
                   comment: "What VoiceOver reads for that button. The action is the step's own.")
        }
        public static var addedHelp: String {
            q("queue.addedHelp", "Hold ⌥ to add this to Up Next instead of doing it now.",
              "The help tag on every step's primary.")
        }
        /// Why a step's button says "Add to Up Next" when he did not hold ⌥,
        /// said once beside it: the button changed under him and nothing said
        /// why, or that the time under it was the step's own and not the wait.
        /// `running` is the job in the way, named as the list names it -
        /// "Happening now: Build the PhotoLab folder · 2026-09-19." - and not
        /// by the engine's title, which brought back words the list had
        /// retired ("Gathering the keepers of …"). The title only for work
        /// the app has no word for. Nil when there is nothing to say.
        /// A job named as Up Next names it, with its shoot: "Write the
        /// presets · 2026‑09‑13‑dog". Empty when the app has no word for it
        /// and the engine gave no title. Never the engine's own title where
        /// the app has a word, which brought back "Gathering the keepers of".
        public static func named(_ job: PipelineKit.Job) -> String {
            let what = what(job.kind) ?? job.title.capitalizedFirst
            if what.isEmpty { return "" }
            // The shoot's hyphens do not break: "2026-09-13-" at the end
            // of one line and "dog" at the start of the next is no name.
            let shoot = job.shoot.replacingOccurrences(of: "-", with: "\u{2011}")
            return shoot.isEmpty ? what : "\(what) · \(shoot)"
        }

        public static func whyItAdds(running: PipelineKit.Job?, held: Bool) -> String? {
            if let running {
                let named = named(running)
                if named.isEmpty {
                    return q("queue.whyItAddsPlain", "Something else is running; this goes after it in Up Next.",
                             "Beside a step's button while another job runs.")
                }
                return String(localized: "queue.whyItAdds",
                              defaultValue: "Happening now: \(named). This goes after it in Up Next.",
                              comment: "Beside a step's button while another job runs. The work is named as Up Next names it, with its shoot.")
            }
            return held
                ? q("queue.whyItAddsHeld", "Up Next is held; this waits there until you continue.",
                    "Beside a step's button while the list is held.")
                : nil
        }
        public static func added(_ what: String) -> String {
            String(localized: "queue.added", defaultValue: "\(what) is in Up Next.",
                   comment: "After a piece of work was added. The what is the app's own word for it.")
        }

        // MARK: - the controls on the list

        public static var clear: String {
            q("queue.clear", "Clear", "Takes everything waiting off the list. What is running is untouched.")
        }
        public static var hold: String {
            q("queue.hold", "Hold", "Stops the next one starting.")
        }
        public static var letGo: String {
            q("queue.letGo", "Continue", "Lets a held list go again.")
        }
        public static var heldNote: String {
            q("queue.heldNote", "Held. Nothing new starts until you continue — what is running now carries on.",
              "Under a held list.")
        }
        /// Under a list his Stop held. `named` is the stopped work as Up
        /// Next names it: "Cull · 2026-09-19".
        public static func heldAfterStop(_ named: String) -> String {
            String(localized: "queue.heldAfterStop",
                   defaultValue: "Held because you stopped \(named). Nothing new starts until you continue.",
                   comment: "Under a list that Stop held. The work is named as Up Next names it.")
        }
        /// Under a list held because the engine stopped while a job ran; the
        /// job is back at the top.
        public static func heldAfterCrash(_ named: String) -> String {
            String(localized: "queue.heldAfterCrash",
                   defaultValue: "Held because the engine stopped while \(named) ran. It is back at the top; continue to run it again.",
                   comment: "Under a list held after the engine stopped mid-job. The work is named as Up Next names it.")
        }
        /// Under a list held because the engine stopped during a card copy,
        /// which is back at the top to finish into the same shoot: how far
        /// it got, and what continuing does.
        public static func heldAfterCopyBack(_ named: String, files: Int, of: Int) -> String {
            of > 0
                ? String(localized: "queue.heldAfterCopyBack",
                         defaultValue: "Held because the engine stopped while \(named) ran, at \(files) of \(of) frames. It is back at the top; continue, with the card in, to finish the copy.",
                         comment: "Under a list held after the engine stopped mid-copy. The work is named as Up Next names it; the numbers are frames copied and frames on the card.")
                : String(localized: "queue.heldAfterCopyBackNoCount",
                         defaultValue: "Held because the engine stopped while \(named) ran. It is back at the top; continue, with the card in, to finish the copy.",
                         comment: "The same, when the copy's log did not say how far it got.")
        }
        /// Under a list an earlier engine held after it stopped during a card
        /// copy it did not put back: it says how far the copy got.
        public static func heldAfterCopyCut(_ named: String, files: Int, of: Int) -> String {
            of > 0
                ? String(localized: "queue.heldAfterCopyCut",
                         defaultValue: "Held because the engine stopped while \(named) ran, at \(files) of \(of) frames. Nothing new starts until you continue.",
                         comment: "Under a list held after the engine stopped mid-copy. The work is named as Up Next names it; the numbers are frames copied and frames on the card.")
                : String(localized: "queue.heldAfterCopyCutNoCount",
                         defaultValue: "Held because the engine stopped while \(named) ran. Nothing new starts until you continue.",
                         comment: "The same, when the copy's log did not say how far it got.")
        }
        /// On a waiting row the engine put back after it stopped under it.
        public static var interruptedNote: String {
            q("queue.interruptedNote", "The engine stopped while this ran; it runs again when you continue.",
              "On a row put back at the top of the list after the engine stopped mid-way.")
        }
        /// The line over the window after the engine restarted, when it
        /// stopped under a piece of work and put it back.
        public static func restartedWhile(_ named: String) -> String {
            String(localized: "queue.restartedWhile",
                   defaultValue: "The engine stopped while \(named) ran, and was restarted. It is back at the top of Up Next, held. Nothing you decided is lost.",
                   comment: "The line after an engine restart that cut off work. The work is named as Up Next names it.")
        }
        /// The line over the window after the engine restarted, when it
        /// stopped during a card copy: back at the top of Up Next, to finish
        /// into the same shoot. The frames it copied are in the shoot.
        public static func restartedDuringCopyBack(_ named: String, files: Int, of: Int) -> String {
            of > 0
                ? String(localized: "queue.restartedDuringCopyBack",
                         defaultValue: "The engine stopped while \(named) ran, at \(files) of \(of) frames, and was restarted. It is back at the top of Up Next, held, and finishes the copy when you continue with the card in. Nothing you decided is lost.",
                         comment: "The line after an engine restart that cut off a card copy. The numbers are frames copied and frames on the card.")
                : String(localized: "queue.restartedDuringCopyBackNoCount",
                         defaultValue: "The engine stopped while \(named) ran, and was restarted. It is back at the top of Up Next, held, and finishes the copy when you continue with the card in. Nothing you decided is lost.",
                         comment: "The same, when the copy's log did not say how far it got.")
        }
        /// The same line from an earlier engine, which did not put a card
        /// copy back: the frames it copied are in the shoot, and its page
        /// says how far it got.
        public static func restartedDuringCopy(_ named: String, files: Int, of: Int) -> String {
            of > 0
                ? String(localized: "queue.restartedDuringCopy",
                         defaultValue: "The engine stopped while \(named) ran, at \(files) of \(of) frames, and was restarted. The frames it copied are in the shoot. Nothing you decided is lost.",
                         comment: "The line after an engine restart that cut off a card copy. The numbers are frames copied and frames on the card.")
                : String(localized: "queue.restartedDuringCopyNoCount",
                         defaultValue: "The engine stopped while \(named) ran, and was restarted. The frames it copied are in the shoot. Nothing you decided is lost.",
                         comment: "The same, when the copy's log did not say how far it got.")
        }
        /// The line under the list, for whatever held it.
        public static func heldLine(_ after: HeldAfter?) -> String {
            switch after?.why {
            case .stopped?: return heldAfterStop(after?.named ?? "")
            case .crashed? where after?.putBack == false:
                return heldAfterCopyCut(after?.named ?? "", files: after?.files ?? 0, of: after?.of ?? 0)
            case .crashed? where after?.kind == "ingest":
                return heldAfterCopyBack(after?.named ?? "", files: after?.files ?? 0, of: after?.of ?? 0)
            case .crashed?: return heldAfterCrash(after?.named ?? "")
            case nil: return heldNote
            }
        }
        public static var remove: String {
            q("queue.remove", "Remove from Up Next", "Removes one piece of work from the list.")
        }
        public static var reorderHint: String {
            q("queue.reorderHint", "Drag to change the order, or pick one and press ⌥⌘↑ or ⌥⌘↓.",
              "Under the list.")
        }
        /// Sends a piece of work to the top of the list: it runs next.
        public static var doNext: String {
            q("queue.doNext", "Do Next", "A row's menu item, hover button and ⌥⌘Home: move it to the top.")
        }
        public static func clearQuestion(_ n: Int) -> String {
            String(localized: "queue.clearQuestion", defaultValue: "Remove all \(n) from Up Next?",
                   comment: "Asked before Clear takes more than one piece of work off the list.")
        }
        public static var clearNote: String {
            q("queue.clearNote", "What is running now carries on. The rest would have to be added again.",
              "Under that question.")
        }
        public static var clearConfirm: String {
            q("queue.clearConfirm", "Remove All", "The destructive button that clears the list.")
        }
        public static var keepThem: String {
            q("queue.keepThem", "Keep Them", "The button that leaves the list as it is.")
        }
        public static func position(_ i: Int, of n: Int) -> String {
            String(localized: "queue.position", defaultValue: "\(i) of \(n)",
                   comment: "A row's place in the list, for VoiceOver.")
        }
        public static var moveUp: String {
            q("queue.moveUp", "Move Up", "A VoiceOver action and a menu item on a row.")
        }
        public static var moveDown: String {
            q("queue.moveDown", "Move Down", "A VoiceOver action and a menu item on a row.")
        }
        public static var waitingCount: String {
            q("queue.waitingCount", "waiting", "Beside the number on the toolbar's Activity item.")
        }
        public static func waitingSpoken(_ n: Int) -> String {
            String(localized: "queue.waitingSpoken",
                   defaultValue: "\(n) waiting in Up Next",
                   comment: "The toolbar's Activity item, for VoiceOver.")
        }

        // MARK: - a row that can no longer be done

        /// The heading on a row whose work has gone stale. The reason itself
        /// is the engine's sentence and is printed under this, unchanged. Not
        /// "This will be skipped": that states a guess as a fact, and the
        /// engine's reason often ends "put it back and this starts on its own".
        public static var cannotRun: String {
            q("queue.cannotRun", "Can't run yet",
              "On a row whose work can no longer be done. The reason under it is the engine's.")
        }
        public static var wontBeKept: String {
            q("queue.wontBeKept", "This one is not kept if the app is quit.",
              "On a row the engine cannot write down — an extension's own work.")
        }

        // MARK: - when it all finishes

        /// What a pass came to, counted by outcome and worst first: "1
        /// failed, 3 done". Every piece used to be counted as "finished", so
        /// a list whose cull failed said "4 finished" in the banner and in
        /// the window.
        public static func summary(_ t: QueueState.Tally) -> String {
            summaryParts(t).map(\.text).joined(separator: ", ")
        }
        /// The same count a part at a time, each saying whether it is the
        /// failures, so the window can put those - and only those - in the
        /// alarm colour. A refusal is in the ordinary colour, as it is in
        /// the history (§2.7).
        public static func summaryParts(_ t: QueueState.Tally) -> [(text: String, failed: Bool)] {
            var parts: [(text: String, failed: Bool)] = []
            if t.failed > 0 {
                parts.append((String(localized: "queue.summary.failed", defaultValue: "\(t.failed) failed",
                                     comment: "Part of what a finished list came to."), true))
            }
            if t.refused > 0 {
                parts.append((String(localized: "queue.summary.refused", defaultValue: "\(t.refused) refused",
                                     comment: "Part of what a finished list came to: work that said no on purpose, with its reason in the window. The history's own word."), false))
            }
            if t.skipped > 0 {
                parts.append((String(localized: "queue.summary.skipped", defaultValue: "\(t.skipped) skipped",
                                     comment: "Part of what a finished list came to."), false))
            }
            if t.stopped > 0 {
                parts.append((String(localized: "queue.summary.stopped", defaultValue: "\(t.stopped) stopped",
                                     comment: "Part of what a finished list came to."), false))
            }
            if t.done > 0 || parts.isEmpty {
                parts.append((String(localized: "queue.summary.done", defaultValue: "\(t.done) done",
                                     comment: "Part of what a finished list came to."), false))
            }
            return parts
        }
        /// The body of that notification, one line a piece, what went wrong
        /// first, in the summary's order: a banner shows three or four lines,
        /// and those are the ones he has to read.
        public static func whatHappened(_ lines: [(line: String, ended: PipelineKit.Job.Outcome)],
                                         skipped: [String] = []) -> String {
            let bad = lines.filter { $0.ended == .failed }.map { failedLine($0.line) }
                + lines.filter { $0.ended == .refused }.map { refusedLine($0.line) }
                + skipped.map { skippedLine($0) }
                + lines.filter { $0.ended == .stopped }.map { stoppedLine($0.line) }
            let good = lines.filter { ![.failed, .refused, .stopped].contains($0.ended) }.map(\.line)
            return (bad + good).joined(separator: "\n")
        }
        public static func refusedLine(_ what: String) -> String {
            String(localized: "queue.refusedLine", defaultValue: "\(what) — refused",
                   comment: "One line of the finished notification: work that said no on purpose.")
        }
        public static func skippedLine(_ what: String) -> String {
            String(localized: "queue.skippedLine", defaultValue: "\(what) — skipped",
                   comment: "One line of the finished notification.")
        }
        public static func failedLine(_ what: String) -> String {
            String(localized: "queue.failedLine", defaultValue: "\(what) — failed",
                   comment: "One line of the finished notification.")
        }
        public static func stoppedLine(_ what: String) -> String {
            String(localized: "queue.stoppedLine", defaultValue: "\(what) — stopped",
                   comment: "One line of the finished notification.")
        }
        public static var skippedHeading: String {
            q("queue.skippedHeading", "Skipped", "The heading over what the list could not do.")
        }
        public static var doneHeading: String {
            q("queue.doneHeading", "Done", "The heading over what the list finished.")
        }
        /// The Activity window's first column, over the history under the
        /// list. It said "Job" - ours, not his - directly under a list that
        /// carefully never uses the word.
        public static var workColumn: String {
            q("queue.workColumn", "Work", "The first column of the Activity window's history.")
        }
    }
}
