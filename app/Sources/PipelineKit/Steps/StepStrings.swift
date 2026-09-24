import Foundation

/// Every sentence the five workflow steps say for themselves.
///
/// Two rules hold here, the same two that hold in `Design/Strings.swift`. No
/// word from DESIGN.md §2.13's retired list is in a label a person reads —
/// which is why the cull's own word for a near-identical frame never reaches a
/// screen and comes out as "looks like the frame beside it" (the engine's word
/// itself is recognised in `CullReasons.swift`), and why a preset is a preset and
/// never the name of the file it is written into. And not one string the
/// extension contributes is here: its question, its words and its step labels
/// are read from `ExtConfig` at runtime.
///
/// Sentences the *engine* writes — a refusal, a stage word, the copy's own
/// note, the storage phrase — are not here either. Those are printed as the
/// engine wrote them.
extension Strings {

    /// `comment` is for the catalog's translators and is read by nothing at
    /// runtime; it stays at the call site so a sentence and its reason travel
    /// together.
    private static func t(_ key: String, _ value: String, _ comment: String) -> String {
        Bundle.main.localizedString(forKey: key, value: value, table: nil)
    }

    // MARK: - Copy the Card (§2.6)

    public enum Import {
        public static var title: String { t("import.title", "Copy the Card", "The step's heading.") }
        public static var blurb: String {
            t("import.blurb", "Nothing on the card is changed. Its frames are copied into your library.",
              "Under the heading. It promises no check: Check the Copy says what is read back, and Don't check reads back nothing.")
        }
        public static var card: String { t("import.card", "Memory card", "A form row.") }
        public static var noCard: String {
            t("import.noCard", "No memory card is in.", "No volume with photographs on it is mounted.")
        }
        public static var noCardWhy: String {
            t("import.noCardWhy", "Put one in and it appears here.", "Under 'No memory card is in.'")
        }
        public static var ejectAfter: String {
            t("import.ejectAfter", "Eject after copying", "A checkbox beside the card picker.")
        }
        public static var name: String { t("import.name", "Name", "The shoot's name field.") }
        public static var namePrompt: String {
            t("import.namePrompt", "2026-10-04-lake", "The name field's placeholder, showing the shape.")
        }
        public static var nameEmpty: String {
            t("import.nameEmpty", "Give the shoot a name.", "Under the name field.")
        }
        public static var nameCharacters: String {
            t("import.nameCharacters", "Letters, numbers, a dot, a dash or an underscore — nothing else.",
              "Under the name field. The engine holds the same rule.")
        }
        public static func nameTaken(_ name: String) -> String {
            String(localized: "import.nameTaken", defaultValue: "\(name) is already in your library.",
                   comment: "Under the name field.")
        }
        public static var check: String { t("import.check", "Check the copy", "A picker.") }
        public static var checkInFlight: String {
            t("import.checkInFlight", "While copying", "One pass over the card. The default.")
        }
        public static var checkEnd: String {
            t("import.checkEnd", "Again at the end", "Two passes, which catches a failing card.")
        }
        public static var checkNone: String {
            t("import.checkNone", "Don't check", "The fastest, and it proves the least.")
        }
        public static var checkInFlightNote: String {
            t("import.checkInFlightNote", "One pass over the card: every frame is read back as it lands.",
              "Under the picker.")
        }
        public static var checkEndNote: String {
            t("import.checkEndNote", "Two passes: every frame is read back again at the end, which catches a card that is failing.",
              "Under the picker.")
        }
        public static var checkNoneNote: String {
            t("import.checkNoneNote", "Fastest, and it proves the least: nothing is read back.",
              "Under the picker.")
        }
        public static var goesTo: String { t("import.goesTo", "It goes here", "A form row with the path.") }
        /// What the engine found of this card in the library, counted frame
        /// by frame. Nothing is said of a card none of whose photographs are
        /// in any shoot, whatever it is called.
        public static func alreadyCopied(_ c: CardContents) -> String? {
            guard !c.copiedAs.isEmpty, c.held > 0, c.photographs > 0 else { return nil }
            if c.held >= c.photographs {
                return String(localized: "import.alreadyCopiedAll",
                              defaultValue: "All \(c.photographs) frames on this card are already in \(c.copiedAs).",
                              comment: "The card was copied before, every frame of it.")
            }
            if c.copying {
                return String(localized: "import.copyingInto",
                              defaultValue: "This card is being copied into \(c.copiedAs) now.",
                              comment: "A copy of this card is running, or waiting on the list of work.")
            }
            if c.stopped {
                return String(localized: "import.copyStoppedAt",
                              defaultValue: "The copy of this card into \(c.copiedAs) stopped at \(c.held) of \(c.photographs).",
                              comment: "A copy of this card that did not finish.")
            }
            return String(localized: "import.alreadyCopiedSome",
                          defaultValue: "\(c.held) of the \(c.photographs) frames on this card are already in \(c.copiedAs).",
                          comment: "A card copied before and shot on since.")
        }
        /// With no engine to count it: the shoot that holds the card's newest
        /// photograph, by its name, size and time.
        public static func alreadyCopied(as shoot: String) -> String {
            String(localized: "import.alreadyCopied", defaultValue: "This memory card was already copied as \(shoot).",
                   comment: "The shoot holding the card's newest photograph, when the engine was not there to count.")
        }
        public static var copy: String { t("import.copy", "Copy the Card", "The primary, before the count is known.") }
        public static var copying: String { t("import.copying", "Copying…", "No log yet: the copy's own note has not started.") }
        public static var nothingChanged: String {
            t("import.nothingChanged", "Nothing on the card was changed.", "After a copy that finished.")
        }
        public static var ejected: String { t("import.ejected", "The card was ejected.", "After copying, when he asked for it.") }
        public static func ejectFailed(_ why: String) -> String {
            String(localized: "import.ejectFailed", defaultValue: "The card could not be ejected: \(why)",
                   comment: "Beside the primary. Eject it from Finder instead.")
        }
        public static var openTheShoot: String {
            t("import.openTheShoot", "Open the Shoot", "After a copy: goes to the new shoot's Cull step.")
        }

        // The six sentences of the copy's own log (DESIGN.md §2.6). They are
        // built only from that log, never from a listing of the folder.
        public static func done(_ files: Int, proof: String) -> String {
            proof.isEmpty
                ? String(localized: "import.doneNoProof", defaultValue: "\(files) frames copied.",
                         comment: "The copy's log said how many and nothing more.")
                : String(localized: "import.done", defaultValue: "\(files) frames copied, \(proof).",
                         comment: "The proof clause is the copy script's own words.")
        }
        public static func failed(_ detail: String) -> String {
            detail.isEmpty
                ? t("import.failedPlain", "Checking FAILED. Nothing here has been proved; look at the card before you go on.",
                    "Red. The copy was made and could not be proved.")
                : String(localized: "import.failed",
                         defaultValue: "Checking FAILED for \(detail). Nothing here has been proved; look at the card before you go on.",
                         comment: "Red. The copy was made and could not be proved.")
        }
        public static func stopped(_ files: Int, of: Int) -> String {
            String(localized: "import.stopped",
                   defaultValue: "The copy stopped after \(files) of \(of) frames. Nothing here has been checked.",
                   comment: "Red. A copy that did not finish.")
        }
        public static func unclear(_ log: String) -> String {
            String(localized: "import.unclear",
                   defaultValue: "The copy's own log does not say how it finished, so nothing here is proved. It is at \(log).",
                   comment: "Red. A copy killed mid-write.")
        }
        public static func beforeLogs(_ frames: Int, verify: String) -> String {
            verify.isEmpty
                ? String(localized: "import.beforeLogs",
                         defaultValue: "\(frames) frames are in this shoot. This copy was made before the copy kept its own log, so how it was checked is not recorded.",
                         comment: "A shoot copied before logging existed.")
                : String(localized: "import.beforeLogsVerify",
                         defaultValue: "\(frames) frames are in this shoot. This copy was made before the copy kept its own log, so how it was checked is not recorded beyond \"\(verify)\".",
                         comment: "A shoot copied before logging existed, with what was asked of it.")
        }
    }

    // MARK: - Cull (§2.6)

    public enum Cull {
        public static var title: String { t("cull.title", "Cull", "The step's heading.") }
        public static var blurb: String {
            t("cull.blurb", "The cull looks at every frame and puts some forward. It decides nothing: you choose the keepers on the next step.",
              "Under the heading.")
        }
        public static var focus: String { t("cull.focus", "How fussy about focus", "The one slider.") }
        /// The slider's live word: one or two, short enough to read in the
        /// corner of an eye while dragging. What each means at length is the
        /// note under the slider, which does not change as it moves.
        public static func focusWord(_ f: Double) -> String {
            let f = (f * 10).rounded() / 10
            if f <= 1.5 { return t("cull.focusLenient", "lenient", "The slider's live word.") }
            if f <= 1.8 { return t("cull.focusABitLenient", "a little lenient", "The slider's live word.") }
            if f <= 2.0 { return t("cull.focusNormal", "normal", "The slider's live word.") }
            if f <= 2.4 { return t("cull.focusABitStrict", "a little strict", "The slider's live word.") }
            return t("cull.focusStrict", "strict", "The slider's live word.")
        }
        /// The two ends of the slider, in words rather than bare numbers.
        public static var focusLenientEnd: String { t("cull.focusLenientEnd", "Lenient", "The slider's left end.") }
        public static var focusStrictEnd: String { t("cull.focusStrictEnd", "Strict", "The slider's right end.") }
        public static var focusNote: String {
            t("cull.focusNote", "A face softer than this is marked soft and shown last. Nothing is removed. Lower for sport and dancing, higher for posed portraits.",
              "Under the slider. The same every time, so it is read once.")
        }
        public static var settingsForAgain: String {
            t("cull.settingsForAgain", "Settings for Cull Again", "A disclosure under the report, shut until he opens it.")
        }
        public static var settingsInUse: String {
            t("cull.settingsInUse", "The cull that is running is using these. Stop it to change them.",
              "Above the settings while a cull runs. They are held still.")
        }
        public static var settingsStarting: String {
            t("cull.settingsStarting", "The cull is starting with these.",
              "Above the settings from the press until the cull is running. They are held still.")
        }
        public static var settingsWaiting: String {
            t("cull.settingsWaiting", "The cull in Up Next will run with these. Remove it from Up Next to change them.",
              "Above the settings while a cull waits. They are held still.")
        }
        public static var moving: String {
            t("cull.moving", "People move between frames", "A switch for the engine's own flag.")
        }
        /// On a shoot no cull was asked of yet: where the two settings came
        /// from. They were 1.9 and off on every new shoot, and he set them
        /// back every evening.
        public static func asLastTime(_ shoot: String) -> String {
            String(localized: "cull.asLastTime", defaultValue: "Both start as you culled \(shoot).",
                   comment: "Above the focus slider and the People move switch, on a shoot not culled yet.")
        }
        public static var movingNote: String {
            t("cull.movingNote", "Turn it on for sport, dancing, anything that moves fast.", "Under the switch.")
        }
        public static func estimate(_ minutes: Int) -> String {
            minutes <= 1
                ? t("cull.estimateOne", "About a minute.", "The time estimate.")
                : String(localized: "cull.estimate", defaultValue: "About \(minutes) minutes.",
                         comment: "The time estimate, frames divided by 230 a minute.")
        }
        public static var noFrames: String {
            t("cull.noFrames", "There are no frames in this shoot yet. Copy a card first.",
              "The step with nothing to cull.")
        }
        public static var failed: String {
            t("cull.failed", "The cull stopped with an error. Nothing you have marked was changed.",
              "Red, beside the primary, after a cull that crashed. Show the Log is beside it.")
        }
        public static var run: String { t("cull.run", "Cull It", "The primary.") }
        public static var again: String { t("cull.again", "Cull Again…", "Runs it a second time. Ends in an ellipsis: it asks first.") }
        public static var againTitle: String { t("cull.againTitle", "Cull this shoot again?", "The sheet's title.") }
        /// The sheet's button: "Cull Again", or, when the press puts the
        /// re-cull in Up Next — ⌥ held, or his work running — what the step's
        /// own button says then. It read "Cull Again" and added.
        public static func againConfirm(adds: Bool) -> String {
            adds ? Strings.Queue.addInstead : again.replacingOccurrences(of: "…", with: "")
        }
        /// The sheet's body: what stays, what it will run with, and how long.
        /// The settings are the ones on the page now, which is what this run
        /// will use, and the time is `estimate`'s, so a small shoot reads
        /// "About a minute." rather than "About 1 minutes."
        public static func againBody(_ kept: Int, _ minutes: Int, focus: Double, moving: Bool) -> String {
            String(localized: "cull.againBody",
                   defaultValue: "Your \(kept) keepers and every frame you have marked stay exactly as they are. Only the cull's own suggestions are replaced, using \(settings(focus: focus, moving: moving)). \(estimate(minutes))",
                   comment: "The sheet's body. Nothing of his is at risk, so it is not red. The settings clause is 'focus 1.9 (normal), for people moving between frames'.")
        }
        /// "focus 1.9 (normal)", with ", for people moving between frames"
        /// when that is on. One phrase for the report and the sheet, so the two
        /// say what a run used in the same words.
        public static func settings(focus: Double, moving: Bool) -> String {
            let number = String(format: "%.1f", focus)
            let word = focusWord(focus)
            return moving
                ? String(localized: "cull.settingsMoving",
                         defaultValue: "focus \(number) (\(word)), for people moving between frames",
                         comment: "What a cull runs with.")
                : String(localized: "cull.settings", defaultValue: "focus \(number) (\(word))",
                         comment: "What a cull runs with.")
        }
        public static var cancel: String { t("cull.cancel", "Cancel", "The sheet's default button.") }

        // The report the step becomes afterwards. Every number here is the
        // machine's own work, read from its own column and never through his
        // corrections.
        public static func putForward(_ n: Int, of: Int) -> String {
            String(localized: "cull.putForward", defaultValue: "It put forward \(n) of \(of) frames.",
                   comment: "The report's headline. The cull's own count, never his.")
        }
        /// Rated two: nothing wrong with them, and not the best of their
        /// moment. Never counted with the faults — the filmstrip draws the two
        /// with different marks, and so does the report.
        public static func setAside(_ n: Int) -> String {
            String(localized: "cull.setAside", defaultValue: "\(n) fine, not the best of their moment",
                   comment: "A line of the report, beside the filmstrip's dotted circle.")
        }
        public static func stacked(_ frames: Int, into stacks: Int) -> String {
            stacks <= 0
                ? String(localized: "cull.stackedFrames", defaultValue: "\(frames) stacked behind a similar frame",
                         comment: "A line of the report.")
                : String(localized: "cull.stacked",
                         defaultValue: "\(frames) stacked behind a similar frame, in \(stacks) stacks",
                         comment: "A line of the report, when the engine says how many stacks.")
        }
        public static func faults(_ n: Int) -> String {
            String(localized: "cull.faults", defaultValue: "\(n) with a fault it can name",
                   comment: "A line of the report, beside the filmstrip's triangle.")
        }
        /// The faults past the ones the line names, so the line always adds
        /// up to the number in front of it.
        public static func otherFaults(_ n: Int) -> String {
            String(localized: "cull.otherFaults", defaultValue: "\(n) other", comment: "The end of the faults line.")
        }
        public static func culledAt(_ when: String) -> String {
            String(localized: "cull.culledAt", defaultValue: "Culled \(when) with what it had learned then.",
                   comment: "The last line of the report.")
        }
        /// What the cull whose results are on screen ran with, as it
        /// recorded them once they were written — not what the slider says
        /// now, and not what a cull he stopped since was started with.
        public static func culledWith(focus: Double, moving: Bool) -> String {
            String(localized: "cull.culledWith", defaultValue: "Culled with \(settings(focus: focus, moving: moving)).",
                   comment: "The report's last line: the settings the finished cull recorded.")
        }
        public static var learnedLink: String {
            t("cull.learnedLink", "What the Cull Has Learned ›", "A link under the report. Title case: it is a place, named as the sidebar names it.")
        }
        public static var continueToKeepers: String {
            t("cull.continueToKeepers", "Choose Keepers", "The primary once the shoot is culled: the next step, on Return.")
        }
        /// Names the whole it counts from. "316 of them", straight under
        /// "262 stacked behind a similar frame", read as 316 of the 262.
        public static func markedByHim(_ n: Int, of frames: Int) -> String {
            String(localized: "cull.markedByHim",
                   defaultValue: "You have marked \(n) of the \(frames) frames yourself.",
                   comment: "When he has marked frames: how many of the whole shoot. His marks count over the cull's.")
        }

        public static var looksAlike: String {
            t("cull.looksAlike", "looks like the frame beside it",
              "How the cull's own word for a near-identical frame is said on screen.")
        }

        /// The cull's own reason words, in words a person reads.
        ///
        /// An unknown reason is the engine's own, printed as it wrote it —
        /// except that the engine's word for a frame that resembles the one
        /// beside it never reaches a screen. It is a retired word (§2.13), and
        /// it would also be a lie about what happened: those frames were
        /// stacked, and nothing was hidden.
        public static func reasonWord(_ raw: String) -> String {
            switch CullReason.of(raw) {
            case .soft: return t("cull.reasonSoft", "too soft to read", "A reason.")
            case .looksAlike: return looksAlike
            case .blownHighlights: return t("cull.reasonBlown", "blown highlights", "A reason.")
            case .noFocus: return t("cull.reasonNoFocus", "nothing in focus", "A reason.")
            case .eyesClosed: return t("cull.reasonEyes", "eyes closed", "A reason.")
            case .cutOff: return t("cull.reasonCut", "cut off", "A reason.")
            case .midWord: return t("cull.reasonMidWord", "caught mid-word", "A reason.")
            case .faceInShadow: return t("cull.reasonFaceShadow", "face in shadow", "A reason.")
            case .tooDark: return t("cull.reasonTooDark", "too dark", "A reason.")
            case .unreadable: return t("cull.reasonUnreadable", "could not be read", "A reason.")
            case .unknown: return raw
            }
        }
    }

    // MARK: - Presets (§2.4, §2.6)

    public enum Presets {
        public static var title: String { t("presets.title", "Presets", "The step's heading.") }
        public static var blurb: String {
            t("presets.blurb", "A preset per look in this shoot, written beside the frames it fits, so your editor opens them already started.",
              "Under the heading.")
        }
        /// The honest split of §2.4. The number that decides is labelled for
        /// what it decides; the two authors under it are each named.
        public static func willBeEdited(_ n: Int) -> String {
            String(localized: "presets.willBeEdited", defaultValue: "\(n) frames will get a preset.",
                   comment: "What the step will do. Not a count of anyone's opinion.")
        }
        public static func splitYours(_ n: Int) -> String {
            // "You marked Keep", not "you kept": the sidebar's "you kept"
            // also holds the picks he left standing, which are the next line
            // here, and the same two words over two numbers on one screen
            // read as a contradiction.
            String(localized: "presets.splitYours", defaultValue: "\(n) you marked Keep", comment: "His own presses.")
        }
        public static func splitAgreed(_ n: Int) -> String {
            String(localized: "presets.splitAgreed",
                   defaultValue: "\(n) the cull put forward in bursts you looked through and did not mark",
                   comment: "The machine's, in bursts he went through. Never counted as his.")
        }
        public static func splitNotLookedThrough(_ n: Int) -> String {
            String(localized: "presets.splitNotLookedThrough",
                   defaultValue: "\(n) the cull put forward in bursts you have not looked through yet",
                   comment: "The third group. A frame nobody has opened is the cull's guess and nothing else.")
        }
        public static func leaveThoseOut(_ n: Int) -> String {
            String(localized: "presets.leaveThoseOut", defaultValue: "Leave those \(n) out",
                   comment: "A checkbox beside the split.")
        }
        public static var noneYet: String {
            t("presets.noneYet", "Nothing has been chosen yet. Cull this shoot, or choose your keepers, and the count appears here.",
              "The step with nothing to write.")
        }
        /// What the picker sets: the editor these presets are written for,
        /// which is also the one Edit opens.
        public static var writtenFor: String { t("presets.writtenFor", "Written for", "A picker of editors.") }
        public static func estimate(_ minutes: Int) -> String {
            minutes <= 1
                ? t("presets.estimateOne", "About a minute.", "The time estimate, before the first write.")
                : String(localized: "presets.estimate", defaultValue: "About \(minutes) minutes.",
                         comment: "The time estimate, before the first write: keepers divided by 200 a minute.")
        }
        /// What each editor gets, in one line. The words are the engine's own
        /// from the step it replaces.
        public static func editorNote(_ id: String) -> String {
            switch id {
            case "lightroom":
                return t("presets.noteLightroom", "An .xmp beside each RAW, read by Lightroom Classic and Camera Raw.", "Under the picker.")
            case "rawtherapee":
                return t("presets.noteRawTherapee", "A .pp3 profile beside each RAW.", "Under the picker.")
            case "darktable":
                return t("presets.noteDarktable", "The star and the label only: darktable keeps its edits where they cannot be written safely from outside.", "Under the picker.")
            default:
                return t("presets.noteDxO", "The whole preset, written beside each RAW and picked up by PhotoLab.", "Under the picker.")
            }
        }
        public static func foundAt(_ path: String) -> String {
            String(localized: "presets.foundAt", defaultValue: "Found at \(path)", comment: "Under the editor picker.")
        }
        public static var notFound: String {
            t("presets.notFound", "Not found on this Mac. The presets are still written; open them wherever it is installed.",
              "Under the editor picker.")
        }
        public static var alsoDropped: String {
            t("presets.alsoDropped", "Also write the frames you put out", "A checkbox.")
        }
        public static func alsoDroppedCost(_ n: Int) -> String {
            String(localized: "presets.alsoDroppedCost",
                   defaultValue: "\(n) more files beside your RAWs. Useful if you change your mind in the editor; otherwise they are clutter.",
                   comment: "Under the checkbox.")
        }
        public static var destination: String { t("presets.destination", "Written beside the RAWs in", "A form row with the path.") }
        public static var write: String { t("presets.write", "Write the Presets", "The primary.") }
        public static var again: String { t("presets.again", "Write Them Again…", "Ends in an ellipsis: it asks first.") }
        public static var againTitle: String { t("presets.againTitle", "Write the presets again?", "The sheet's title.") }
        /// Writing them again gives every frame the new starting preset; on a
        /// frame he has changed in his editor, his changes stay on top of it.
        /// It said those frames "keep your edit" while "every other frame"
        /// was written again, as if his were not touched at all.
        public static func againBody(_ his: Int) -> String {
            his <= 0
                ? t("presets.againBodyNone", "Every frame gets its preset written again. Nothing you have changed in your editor has been found on these frames.",
                    "The sheet's body when the engine found no hand edits.")
                : String(localized: "presets.againBody",
                         defaultValue: "Every frame gets its preset written again. On the \(his) you have changed in your editor, your changes stay on top of the new one.",
                         comment: "The sheet's body. His changes are kept; only the starting preset under them is new.")
        }
        /// The sheet's one action, named for what it does. It was "Skip the
        /// Frames You Changed", which is not a choice here — his changes are
        /// always kept — and read against "Nothing you have changed has been
        /// found" when there were none.
        public static var againConfirm: String {
            t("presets.againConfirm", "Write Them Again", "The sheet's default button. His own changes are always kept on top.")
        }
        /// The same button when the press puts the work in Up Next, in the
        /// words the step's own button uses then. It read "Write Them Again"
        /// and added.
        public static func againConfirm(adds: Bool) -> String {
            adds ? Strings.Queue.addInstead : againConfirm
        }
        /// What is on the disk, from an engine that does not say what its last
        /// run did.
        public static func written(_ presets: Int, onto frames: Int) -> String {
            String(localized: "presets.written",
                   defaultValue: "\(presets) presets written for \(frames) frames.",
                   comment: "After writing, when the engine does not say what the run did.")
        }
        /// What the last run did, in the three counts the engine keeps.
        public static func ran(wrote: Int, changed: Int, already: Int, under: Int = 0) -> String {
            var parts = [String(localized: "presets.ranWrote", defaultValue: "Wrote a preset onto \(wrote) frames",
                                comment: "After a run: how many it wrote.")]
            if under > 0 {
                parts.append(String(localized: "presets.ranUnder",
                                    defaultValue: "on the \(under) you had changed, your changes stay on top",
                                    comment: "After Write Them Again: his edited frames, given the new preset under his changes."))
            }
            if changed > 0 {
                parts.append(String(localized: "presets.ranChanged",
                                    defaultValue: "\(changed) you had changed in your editor kept your edit",
                                    comment: "After a run: the frames it left alone because they are his."))
            }
            if already > 0 {
                parts.append(String(localized: "presets.ranAlready", defaultValue: "\(already) already had one",
                                    comment: "After a run: frames that already carried its preset."))
            }
            return parts.joined(separator: " · ") + "."
        }
        public static func leftAlone(_ n: Int) -> String {
            String(localized: "presets.leftAlone",
                   defaultValue: "\(n) frames you had already changed in your editor were left alone.",
                   comment: "A fact the engine reports, not a promise.")
        }
    }

    // MARK: - Edit (§2.6)

    public enum Edit {
        public static var title: String { t("edit.title", "Edit in PhotoLab", "The step's heading.") }
        public static func titleIn(_ editor: String) -> String {
            String(localized: "edit.titleIn", defaultValue: "Edit in \(editor)", comment: "The step's heading, named for his editor.")
        }
        public static func keepersWithPresets(_ n: Int) -> String {
            String(localized: "edit.keepersWithPresets",
                   defaultValue: "\(n) keepers, each with its preset beside it",
                   comment: "A row of the checklist.")
        }
        public static var folderOfThose: String {
            t("edit.folderOfThose", "A folder holding only those frames", "A row of the checklist.")
        }
        public static func exportedSoFar(_ n: Int, of: Int) -> String {
            String(localized: "edit.exportedSoFar", defaultValue: "\(n) of \(of) exported so far",
                   comment: "A row of the checklist, live from the export folder.")
        }
        public static var show: String { t("edit.show", "Show", "A button beside a path.") }
        public static var open: String { t("edit.open", "Open My Keepers in PhotoLab", "The primary.") }
        public static func openIn(_ editor: String) -> String {
            String(localized: "edit.openIn", defaultValue: "Open My Keepers in \(editor)", comment: "The primary, named for his editor.")
        }
        public static var building: String { t("edit.building", "Building the folder…", "While the primary is in flight.") }
        /// What Open does, before he presses it. The page said nothing, and
        /// nothing changed on it in the seconds the editor takes to appear.
        public static func blurb(_ n: Int, editor: String) -> String {
            String(localized: "edit.blurb",
                   defaultValue: "Builds a folder of only your \(n) keepers and opens it in \(editor). The RAWs in it are hard links: it takes no disk space, and deleting it deletes nothing.",
                   comment: "Under the heading.")
        }
        public static func noPresetsYet(_ n: Int) -> String {
            String(localized: "edit.noPresetsYet", defaultValue: "\(n) keepers, with no presets written for them yet",
                   comment: "A row of the checklist, when nothing has been written.")
        }
        public static func presetsBeingWritten(_ n: Int) -> String {
            String(localized: "edit.presetsBeingWritten", defaultValue: "The presets for these \(n) keepers are being written",
                   comment: "A row of the checklist, while the presets job runs.")
        }
        public static var writeThenOpen: String {
            t("edit.writeThenOpen", "Write the Presets, Then Open", "The primary when no presets are written.")
        }
        public static var openWhenWritten: String {
            t("edit.openWhenWritten", "Open When the Presets Are Written", "The primary while the presets are being written.")
        }
        public static var waitingToOpen: String {
            t("edit.waitingToOpen", "Opens When They Are Written", "The primary after he asked for it to open once the presets are written.")
        }
        public static func opensWhenWritten(_ editor: String) -> String {
            String(localized: "edit.opensWhenWritten", defaultValue: "\(editor) opens as soon as the presets are written, while this page is open.",
                   comment: "Beside the primary while it waits. Leaving the page drops the request: nothing opens at a screen he has left.")
        }
        public static var openWithoutPresets: String {
            t("edit.openWithoutPresets", "Open Without Presets", "A link beside the primary, for the deliberate case.")
        }
        public static func opened(_ editor: String, at: Date) -> String {
            let time = at.formatted(date: .omitted, time: .shortened)
            return String(localized: "edit.opened", defaultValue: "Opened in \(editor) at \(time).",
                          comment: "Beside the primary once the editor was asked to open the keepers.")
        }
        public static func presetsNotWritten(_ editor: String) -> String {
            String(localized: "edit.presetsNotWritten",
                   defaultValue: "The presets were not written, so \(editor) was not opened. The Presets step says why.",
                   comment: "When the presets job he was waiting on stopped or failed.")
        }
        public static var exportsGoTo: String {
            t("edit.exportsGoTo", "Exports are looked for in", "A form row with the path, before anything is exported.")
        }
        public static var noPreset: String {
            t("edit.noPreset", "No preset showing? Your editor knew this folder from before — in PhotoLab: File ▸ Sidecars ▸ Import.",
              "A footnote. The menu path is PhotoLab's own and is spelled as PhotoLab spells it.")
        }
        public static var nothingToOpen: String {
            t("edit.nothingToOpen", "Nothing has been chosen yet, so there is no folder to build.",
              "The step before any keepers exist.")
        }
        public static var continueToFinish: String { t("edit.continueToFinish", "Finish ›", "A link to the next step.") }
    }

    // MARK: - Finish (§2.6)

    public enum Finish {
        public static var title: String { t("finish.title", "Finish", "The step's heading.") }
        public static func exports(_ n: Int) -> String {
            String(localized: "finish.exports", defaultValue: "\(n) exported frames", comment: "A row.")
        }
        public static var noExports: String {
            t("finish.noExports", "Nothing exported yet.", "A row.")
        }
        public static func noExportsWhere(_ path: String) -> String {
            String(localized: "finish.noExportsWhere",
                   defaultValue: "When you export, \(path) is where this looks first, and it finds them in your editing folder or iCloud too.",
                   comment: "Under 'Nothing exported yet.'")
        }
        public static var whereTheyAre: String { t("finish.whereTheyAre", "Where they are", "A row label.") }
        public static func whereTheyAreIn(_ folder: String) -> String {
            String(localized: "finish.whereTheyAreIn", defaultValue: "In \(folder)",
                   comment: "A row label when exports are in more than one folder: the folder inside the shoot, like edit › edited.")
        }
        /// The step is Finish everywhere: the sidebar, the Go menu, this page's
        /// name and its button. It was Done in three of those and "This Shoot
        /// Is Finished" on the fourth.
        public static var markFinished: String {
            t("finish.markFinished", "Finish This Shoot", "The primary.")
        }
        public static var recording: String { t("finish.recording", "Recording your keepers…", "While the primary is in flight.") }
        /// `from` is the engine's own phrase for where they came from. What
        /// happens about learning is a line of its own (`learningNow`, or the
        /// engine's note), written from what the engine did with Settings ▸
        /// Learning: it promised learning "the next time the Mac is idle"
        /// with automatic learning switched off, and said it again above the
        /// engine's own note that said the same.
        public static func finished(_ keepers: Int, from: String) -> String {
            let from = from.isEmpty ? recordedFromExports : from
            return String(localized: "finish.finished",
                          defaultValue: "Finished. Your \(keepers) keepers are recorded — \(from).",
                          comment: "Printed in place of the primary once it is done.")
        }
        /// What the cull learns from, once the shoot is finished: the frames
        /// he exported ("i tend to cull further during editing"). The keepers
        /// every change is checked against are the row above it. `taught` nil
        /// is an engine that does not say, and the sentence is the one above.
        /// What it learns from, never when: that is the line under it
        /// (`learningNow`, or the engine's note), written from what the
        /// engine did with Settings ▸ Learning.
        public static func finished(_ keepers: Int, from: String, taught: Int?, taughtFrom: String) -> String {
            guard let taught else { return finished(keepers, from: from) }
            switch taughtFrom {
            case "exported":
                return String(localized: "finish.finishedTaught",
                              defaultValue: "Finished. The cull learns from the \(taught) you exported.",
                              comment: "Printed in place of the primary once it is done.")
            case "recorded":
                return String(localized: "finish.finishedTaughtRecorded",
                              defaultValue: "Finished. Its exports cannot be found now, so the cull learns from the \(keepers) keepers recorded.",
                              comment: "A shoot finished before its exports were written down, whose exports have moved since.")
            default:
                return String(localized: "finish.finishedTaughtNothing",
                              defaultValue: "Finished. Nothing you exported was found, so the cull has nothing to learn from this shoot yet.",
                              comment: "Finished with no exports found: it teaches nothing.")
            }
        }
        /// A row under the recorded keepers: what the cull learns from, which
        /// is not what it is checked against.
        public static func learnsFrom(_ n: Int, recorded: Bool) -> String {
            recorded
                ? String(localized: "finish.learnsFromRecorded",
                         defaultValue: "The cull learns from the \(n) keepers recorded: its exports cannot be found now",
                         comment: "A row, on a shoot finished before its exports were written down.")
                : String(localized: "finish.learnsFrom", defaultValue: "The cull learns only from the \(n) you exported",
                         comment: "A row under the recorded keepers. Every keeper is checked against; only exports teach.")
        }
        /// Under the finished sentence when Finish started the learning run
        /// at once (Settings ▸ Learning, not only when idle).
        public static var learningNow: String {
            t("finish.learningNow", "The cull is learning from this shoot now.",
              "Under the finished sentence, when learning from it started at once.")
        }
        public static var recordedFromExports: String {
            t("finish.recordedFromExports", "the frames you exported", "Where recorded keepers came from, when the engine does not say.")
        }
        public static var finishedNoCount: String {
            t("finish.finishedNoCount", "Finished.",
              "When the engine recorded nothing to count.")
        }
        public static var learnedLink: String {
            t("finish.learnedLink", "What the Cull Has Learned ›", "A link under the finished sentence, named as the sidebar names the page.")
        }
        public static var keepRawsNote: String {
            t("finish.keepRawsNote", "Finish This Shoot records your keepers, and every later change to the cull is checked against all of them. The cull learns only from the frames you exported.",
              "A footnote above the primary. Removing the local RAWs waits for it on its own, so it no longer says to press it first.")
        }
        public static var alreadyFinished: String {
            t("finish.alreadyFinished", "Finished.", "Instead of the primary, when the day is not known.")
        }
        /// "Finished on 22 Sep." — the day, in the Mac's own short form.
        public static func finishedOn(_ day: String) -> String {
            let parse = DateFormatter()
            parse.calendar = Calendar(identifier: .gregorian)
            parse.locale = Locale(identifier: "en_US_POSIX")
            parse.dateFormat = "yyyy-MM-dd"
            guard let date = parse.date(from: day) else { return alreadyFinished }
            let said = date.formatted(.dateTime.day().month(.abbreviated))
            return String(localized: "finish.finishedOn", defaultValue: "Finished on \(said).",
                          comment: "Instead of the primary, once the shoot is finished.")
        }
        public static func recordedKeepers(_ n: Int, from: String) -> String {
            from.isEmpty
                ? String(localized: "finish.recordedKeepers", defaultValue: "\(n) keepers recorded", comment: "A row.")
                : String(localized: "finish.recordedKeepersFrom", defaultValue: "\(n) keepers recorded: \(from)",
                         comment: "A row. Says why it can differ from the export count above it.")
        }

        // The sheet that fires when the recorded count would shrink. The app
        // writes it from the two numbers; the engine's own sentence is only
        // shown when they cannot be read out of it.
        public static var shrinkTitle: String {
            t("finish.shrinkTitle", "Record fewer keepers for this shoot?", "The sheet's title, when the two numbers are not known.")
        }
        public static func shrinkTitleCounts(_ had: Int, _ now: Int) -> String {
            String(localized: "finish.shrinkTitleCounts",
                   defaultValue: "Record \(now) keepers instead of \(had)?",
                   comment: "The sheet's title when the engine's sentence named both numbers. Short enough not to be cut.")
        }
        /// The cause only where the engine knows it: a finished shoot whose
        /// exports cannot be found. The other refusal — fewer than half the
        /// recorded keepers — can as well be his own changed marks, and was
        /// told it was missing files.
        public static func shrinkBody(_ had: Int, _ now: Int, exportsGone: Bool) -> String {
            exportsGone
                ? String(localized: "finish.shrinkBody",
                         defaultValue: "This shoot's recorded keepers are \(had). Most of the frames they came from cannot be found now, so recording what is on the disk would keep only \(now). Nothing changes until you choose.",
                         comment: "The sheet's body when a finished shoot's exports cannot be found.")
                : String(localized: "finish.shrinkBodyFewer",
                         defaultValue: "This shoot's recorded keepers are \(had). Recording your keepers as they stand now would record only \(now) in their place. Nothing changes until you choose.",
                         comment: "The sheet's body when the new list is less than half the recorded one, for no cause the engine knows.")
        }
        public static var shrinkKeep: String {
            t("finish.shrinkKeep", "Keep What Is Recorded", "The sheet's default button.")
        }
        public static func shrinkKeepCount(_ n: Int) -> String {
            String(localized: "finish.shrinkKeepCount", defaultValue: "Keep \(n)", comment: "The sheet's default button.")
        }
        public static var shrinkUse: String {
            t("finish.shrinkUse", "Record What Is on the Disk Now", "The sheet's other button.")
        }
        public static func shrinkUseCount(_ n: Int) -> String {
            String(localized: "finish.shrinkUseCount", defaultValue: "Record \(n)", comment: "The sheet's other button.")
        }
    }

    // MARK: - a step's own furniture

    public enum Step {
        public static var stop: String { t("step.stop", "Stop", "Stops the running job, in the primary's own box.") }
        public static var dontWait: String {
            t("step.dontWait", "Don't Wait", "Takes back a request that is queued behind a running job.")
        }
        /// `what` is the running work as Up Next names it (`Strings.Queue.named`),
        /// never the engine's title, which brought back words the list had
        /// stopped using. `ahead` is how many more in Up Next go before this
        /// step's work,
        /// after the one running. Past the first place the running job is not
        /// the whole of what it waits for, and a line that named only it said
        /// the cull would start when the presets ended, with a gather between.
        public static func waitingFor(_ title: String, ahead: Int = 0) -> String {
            if ahead > 0 {
                return title.isEmpty
                    ? String(localized: "step.waitingPlainAhead",
                             defaultValue: "Waiting for what is running and \(ahead) more ahead of this in Up Next.",
                             comment: "Beside the box that says its place in Up Next.")
                    : String(localized: "step.waitingForAhead",
                             defaultValue: "Waiting for \(title) and \(ahead) more ahead of this in Up Next.",
                             comment: "Beside the box that says its place in Up Next. The work is named as Up Next names it.")
            }
            return title.isEmpty
                ? t("step.waitingPlain", "Waiting for what is running to finish.", "A second request while one runs.")
                : String(localized: "step.waitingFor", defaultValue: "Waiting for \(title) to finish.",
                         comment: "A second request while one runs. The work is named as Up Next names it.")
        }
        public static var waiting: String { t("step.waiting", "Waiting…", "In the primary's own box, while queued.") }
        /// In the primary's own box while this step's work waits in Up Next.
        public static func onTheList(_ place: Int) -> String {
            if place <= 1 { return t("step.nextOnTheList", "First in Up Next", "In the primary's own box.") }
            let ordinal = NumberFormatter.localizedString(from: NSNumber(value: place), number: .ordinal)
            return String(localized: "step.onTheList", defaultValue: "\(ordinal) in Up Next",
                          comment: "In the primary's own box. The ordinal is its place in the line: 2nd, 3rd.")
        }
        public static func alreadyOnTheList(_ shoot: String) -> String {
            String(localized: "step.alreadyOnTheList",
                   defaultValue: "This is already in Up Next for \(shoot), so nothing more was added.",
                   comment: "Beside the primary, after a second press would have added the same work twice.")
        }
        public static func alreadyRunning(_ shoot: String) -> String {
            String(localized: "step.alreadyRunning",
                   defaultValue: "This is already running on \(shoot), so nothing was added to Up Next.",
                   comment: "Beside the primary, after a press would have queued the work that is running.")
        }
        public static var starting: String {
            t("step.starting", "Starting…", "In the primary's own box, from the press until the engine has started the job.")
        }
        public static var stopping: String { t("step.stopping", "Stopping…", "After Stop was pressed.") }
        public static var stoppedNote: String {
            t("step.stoppedNote", "Stopped. What it had already written stays, and nothing was deleted.",
              "After a job was stopped.")
        }
        public static var refusedNote: String {
            t("step.refusedNote", "Refused", "A job that declined on purpose. Not a failure, and not red.")
        }
        public static var showTheLog: String { t("step.showTheLog", "Show the Log", "Opens the Activity window.") }
        public static var showTheLogHelp: String {
            t("step.showTheLogHelp", "Opens the Activity window on this job's log (⌥⌘L).",
              "The help tag on Show the Log beside a job that failed.")
        }
        public static var failedNote: String {
            t("step.failedNote", "The last run failed with an error. The log says why.",
              "Beside a step's button after its job crashed, in the alarm colour. Not a refusal.")
        }
        public static var notCulledYet: String {
            t("step.notCulledYet", "This shoot has not been culled yet.", "A step whose prerequisite is unmet.")
        }
    }
}
