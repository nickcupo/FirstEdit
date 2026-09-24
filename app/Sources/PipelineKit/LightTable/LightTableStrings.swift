import Foundation

/// Everything the light table says, in his words (DESIGN.md §2.13).
///
/// Three rules hold over this file and `tools/vocabulary-scan.sh` checks them:
/// no word from the retired list, not one string the private extension
/// contributes, and — the one that matters most here — **the machine and he
/// never share a sentence**. The cull speaks in grey and the words "the cull".
/// His verdicts say "you kept" and "you put out". Agreement is its own third
/// thing and never renders as a press he did not make.
extension Strings {
    public enum LightTable {

        // MARK: - modes (§2.3)

        public static var single: String {
            String(localized: "lt.single", defaultValue: "Single",
                   comment: "The toolbar's first mode: one frame at a time.")
        }
        public static var compare: String {
            String(localized: "lt.compare", defaultValue: "Compare",
                   comment: "The toolbar's second mode: the frames of a stack side by side.")
        }
        public static var allBursts: String {
            String(localized: "lt.allBursts", defaultValue: "All Bursts",
                   comment: "The toolbar's third mode: a grid of burst covers.")
        }
        public static var fullImage: String {
            String(localized: "lt.fullImage", defaultValue: "Full Image",
                   comment: "Space. The picture fills the window and everything else goes.")
        }
        public static var viewer: String {
            String(localized: "lt.viewer", defaultValue: "The photograph",
                   comment: "The viewer's accessibility label.")
        }
        /// The strip is a list of 100–300 frames, not a photograph. Tabbing
        /// between the two has to say which one you have landed on.
        public static var filmstrip: String {
            String(localized: "lt.filmstrip", defaultValue: "Every frame of this burst",
                   comment: "The filmstrip's accessibility label.")
        }
        /// One tile of the Compare grid, before its own frame's sentence.
        public static var compareTile: String {
            String(localized: "lt.compareTile", defaultValue: "Compared frame",
                   comment: "The accessibility label of one tile in Compare.")
        }

        // MARK: - the control bar (§2.5.2)

        public static var undo: String {
            String(localized: "lt.undo", defaultValue: "Undo", comment: "The control bar's undo button.")
        }
        public static var previousFrame: String {
            String(localized: "lt.previousFrame", defaultValue: "Previous Frame", comment: "Left chevron.")
        }
        public static var nextFrame: String {
            String(localized: "lt.nextFrame", defaultValue: "Next Frame", comment: "Right chevron.")
        }
        public static var nextBurst: String {
            String(localized: "lt.nextBurst", defaultValue: "Next Burst",
                   comment: "N. Leaving a burst forward records it as looked through.")
        }
        public static var nextBurstHelp: String {
            String(localized: "lt.nextBurstHelp",
                   defaultValue: "Finishes this burst, as → on its last frame does. Frames you didn't press a key on keep the cull's call, marked as agreed — not as yours.",
                   comment: "Next Burst is the one control that records something he did not press.")
        }
        public static var previousBurst: String {
            String(localized: "lt.previousBurst", defaultValue: "Previous Burst",
                   comment: "P. Records nothing.")
        }
        public static var compareHelp: String {
            String(localized: "lt.compareHelp", defaultValue: "Compare the frames that look alike (C)",
                   comment: "Help tag on the Compare button in the control bar.")
        }

        /// `Keep (K)`: a control's name and the key that does the same. The
        /// bar's buttons hold no key themselves — the one path is the light
        /// table's own (§2.5.3) — so this is how each of them teaches it.
        public static func withKey(_ text: String, _ key: String?) -> String {
            guard let key, !key.isEmpty else { return text }
            return String(localized: "lt.withKey", defaultValue: "\(text) (\(key))",
                          comment: "A help tag: what the control does, then its key in brackets.")
        }

        /// `04330 · burst 3`. The frame's place in the burst is the label
        /// between Drop and Keep; this is the one place that says which burst,
        /// and at 1100 pt the longer caption cut off exactly that number.
        public static func frameCaption(_ frame: String, burst: Int) -> String {
            String(localized: "lt.frameCaption", defaultValue: "\(frame) · burst \(burst)",
                   comment: "The control bar's leading caption, first line: the frame number and its burst.")
        }
        /// `2 of 7` — the label that sits between Drop and Keep and names what
        /// is being decided, so the two opposite controls are never adjacent.
        public static func position(_ n: Int, _ of: Int) -> String {
            String(localized: "lt.position", defaultValue: "\(n) of \(of)",
                   comment: "The frame label between Drop and Keep.")
        }
        /// `Kept 5 · Out 1 · 1 left` — his numbers only, for this burst: the
        /// frames he has not marked, which on the last frame of a burst are
        /// not "to go" — there is nothing left to go to. Short, because at
        /// 1100 pt the tally has 137 pt beside Next Burst.
        public static func tally(kept: Int, out: Int, toGo: Int) -> String {
            String(localized: "lt.tally", defaultValue: "Kept \(kept) · Out \(out) · \(toGo) left",
                   comment: "The control bar's trailing tally. His presses only, never the cull's.")
        }

        // MARK: - what the cull says, and what he said (§2.13)

        public static var cullClearWin: String {
            String(localized: "lt.cullClearWin", defaultValue: "the cull: clear win — only frame",
                   comment: "Never 'AI', never 'score', never 'confidence'.")
        }
        public static var cullMaybe: String {
            String(localized: "lt.cullMaybe", defaultValue: "the cull: maybe", comment: "The cull's line.")
        }
        public static var cullAside: String {
            String(localized: "lt.cullAside", defaultValue: "the cull: set aside", comment: "The cull's line.")
        }
        /// `the cull: eyes closed` — the fault itself, straight after the
        /// colon. "a fault it can name — " in front of it took 100 pt of the
        /// 146 the caption has beside Drop at the default window, and the
        /// fault, which is the one word worth reading, was the part cut off.
        public static func cullFault(_ fault: String) -> String {
            String(localized: "lt.cullFault", defaultValue: "the cull: \(fault)",
                   comment: "The cull set this frame aside for a fault it named; the fault, in the report's words.")
        }
        public static func cullMaybeWhy(_ why: String) -> String {
            String(localized: "lt.cullMaybeWhy", defaultValue: "the cull: maybe — \(why)",
                   comment: "The cull's line with its own reason after it.")
        }
        public static var softerThanMost: String {
            String(localized: "lt.softerThanMost", defaultValue: "the face is softer than most here",
                   comment: "The cull's reason on a borderline frame.")
        }

        public static var youKept: String {
            String(localized: "lt.youKept", defaultValue: "you kept this", comment: "His verdict, in his words.")
        }
        public static var youPutOut: String {
            String(localized: "lt.youPutOut", defaultValue: "you put this out", comment: "His verdict.")
        }
        public static var youAgreed: String {
            String(localized: "lt.youAgreed", defaultValue: "you agreed with the cull here",
                   comment: "Its own third state. Never rendered as a press he did not make.")
        }
        public static var youHaventMarked: String {
            String(localized: "lt.youHaventMarked", defaultValue: "you haven't marked this",
                   comment: "No verdict of his on this frame.")
        }

        // MARK: - stacks (§2.5.9, §2.5.12)

        /// `4 similar`. The bracket in the filmstrip and the badge on the
        /// frame label both print this.
        public static func similar(_ n: Int) -> String {
            String(localized: "lt.similar", defaultValue: "\(n) similar",
                   comment: "A run of frames taken back to back that look alike.")
        }
        public static var similarHelp: String {
            String(localized: "lt.similarHelp",
                   defaultValue: "These frames were taken back to back and look alike. The one on top is the cull's guess. Press C to compare them.",
                   comment: "Hover on the stack badge.")
        }
        /// The quiet line under the picture on first entry to a burst with a
        /// stack of more than three. Compare never opens by itself.
        public static func stackInvitation(_ n: Int) -> String {
            String(localized: "lt.stackInvitation", defaultValue: "\(n) similar frames · Compare (C)",
                   comment: "An invitation, never an automatic view change.")
        }
        public static var cullsGuess: String {
            String(localized: "lt.cullsGuess", defaultValue: "the cull's guess",
                   comment: "The top frame of a stack. Never 'the best'.")
        }
        /// "similar" only for a stack the cull found: a set he ⌘-clicked
        /// together is his choice, and nothing says the frames look alike.
        public static func compareHeader(_ n: Int) -> String {
            String(localized: "lt.compareHeader",
                   defaultValue: "Compare \(n) similar frames · E keep · D drop · ⇧E keep only this one",
                   comment: "The header of Compare, on a stack the cull found. Frames he picked: `comparePicked`.")
        }
        /// `2 of 4 compared` — the label between Drop and Keep in Compare.
        public static func comparedPosition(_ n: Int, _ of: Int) -> String {
            String(localized: "lt.comparedPosition", defaultValue: "\(n) of \(of) compared",
                   comment: "The frame label in Compare: which tile has the ring.")
        }
        /// The link in Compare's header that goes back to one frame.
        public static var backToOneFrame: String {
            String(localized: "lt.backToOneFrame", defaultValue: "Back to One Frame",
                   comment: "Compare's header link. Esc or C do the same.")
        }
        public static func comparePage(_ shown: Int, _ of: Int) -> String {
            String(localized: "lt.comparePage", defaultValue: "\(shown) of \(of)",
                   comment: "Compare scrolls past six tiles.")
        }
        public static var keepOnly: String {
            String(localized: "lt.keepOnly", defaultValue: "Keep Only This One",
                   comment: "⇧E (or ⇧K) in Compare: keeps this frame and puts the rest of the stack out, in one undo step.")
        }
        /// `53, and most frames here are near 40`
        /// The inspector's focus row: the figure, and where the burst's
        /// frames mostly are. It used to set the figure against the focus
        /// setting of the next cull — 1.9, printed as "near 1".
        public static func focusAgainstTypical(_ value: Int, _ typical: Int) -> String {
            String(localized: "lt.focusAgainstTypical",
                   defaultValue: "\(value) · most in this burst near \(typical)",
                   comment: "The cull's own focus figure as a plain number, with the middle of its burst's figures.")
        }
        /// Under the Compare tile the cull measures sharpest.
        public static func compareSharpest(of n: Int) -> String {
            String(localized: "lt.compareSharpest", defaultValue: "sharpest of \(n)",
                   comment: "Under the Compare tile with the highest focus figure. The cull's measure, not a verdict.")
        }
        /// Under every other Compare tile: how far under the sharpest it measures.
        public static func compareSofter(_ percent: Int) -> String {
            percent <= 0
                ? String(localized: "lt.compareAsSharp", defaultValue: "as sharp",
                         comment: "Under a Compare tile within half a percent of the sharpest.")
                : String(localized: "lt.compareSofter", defaultValue: "\(percent)% softer",
                         comment: "Under a Compare tile: its focus figure this far under the sharpest tile's.")
        }
        /// The hover on either: the plain figures, and whose measure they are.
        public static func compareFocusHelp(_ value: Int, best: Int, bestFrame: String, of n: Int) -> String {
            String(localized: "lt.compareFocusHelp",
                   defaultValue: "Focus \(value), against \(best) for \(bestFrame), the sharpest of these \(n) by the cull's own measure.",
                   comment: "Hover on a Compare tile's focus line.")
        }
        public static var focusLabel: String {
            String(localized: "lt.focusLabel", defaultValue: "focus", comment: "Under a Compare tile.")
        }

        // MARK: - looking through the frames one fault covers (§2.6)

        /// The report's faults line, hovered: each fault is a way in.
        public static var faultsLinkHelp: String {
            String(localized: "lt.faultsLinkHelp",
                   defaultValue: "Click a fault to look through just those frames in Choose Keepers.",
                   comment: "Hover on the cull report's line of faults.")
        }
        /// What the report's "5 other" looks through.
        public static var anotherFault: String {
            String(localized: "lt.anotherFault", defaultValue: "another fault",
                   comment: "The name of the faults the report does not name one by one.")
        }
        /// Over the photograph while he looks through them: where he is, the
        /// key on, and the key out.
        public static func lookingThrough(_ fault: String, at n: Int?, of total: Int,
                                          next: String, stop: String) -> String {
            let place = n.map { "\($0) of \(total)" } ?? "\(total) frames"
            return String(localized: "lt.lookingThrough",
                          defaultValue: "Put aside for \(fault) · \(place) · \(next) the next · \(stop) stops",
                          comment: "The line over the photograph while he looks through the frames the cull put aside for one fault.")
        }
        public static var stopLookingThrough: String {
            String(localized: "lt.stopLookingThrough", defaultValue: "Stop",
                   comment: "The link on that line; Esc does the same.")
        }

        // MARK: - the end of a burst, and the end of the shoot (§2.5.2)

        public static func endOfShoot(kept: Int, of: Int) -> String {
            String(localized: "lt.endOfShoot",
                   defaultValue: "That was the last burst. You kept \(kept) of \(of).",
                   comment: "N on the last burst. A Continue to Presets link follows it, so the sentence does not say it too.")
        }
        public static var continueToPresets: String {
            String(localized: "lt.continueToPresets", defaultValue: "Continue to Presets",
                   comment: "The button on the end-of-shoot line.")
        }

        // MARK: - why it is out (§2.5.3)

        /// The strip that appears for 3 s after D. It blocks nothing. It names
        /// the frame it asks about, because Drop has already moved him on and
        /// a digit labels the frame he dropped, not the one on screen.
        public static func reasonPrompt(_ frame: String) -> String {
            String(localized: "lt.reasonPrompt",
                   defaultValue: "\(frame) is out. Why? 1 shadow · 2 cut off · 3 face · 4 blur · 5 exposure · 6 framing — optional; it helps the cull spot this.",
                   comment: "Shown for three seconds after D, naming the frame he dropped. Every reason is a nameable fault.")
        }
        public static var reasonOnKeptTitle: String {
            String(localized: "lt.reasonOnKeptTitle", defaultValue: "This is one you kept.",
                   comment: "A reason implies out, so on a frame he kept the app asks first.")
        }
        public static func reasonOnKeptBody(_ reason: String) -> String {
            String(localized: "lt.reasonOnKeptBody",
                   defaultValue: "Marking it '\(reason)' puts it out. Do that?",
                   comment: "The question under the title.")
        }
        /// Under the question: the answer that is his is one key away, the
        /// same one he just pressed.
        public static func reasonOnKeptAgain(_ key: Int) -> String {
            String(localized: "lt.reasonOnKeptAgain",
                   defaultValue: "Press \(key) again to put it out. Return leaves it kept.",
                   comment: "The keys that answer the question on a kept frame.")
        }
        public static var putItOut: String {
            String(localized: "lt.putItOut", defaultValue: "Put It Out", comment: "The confirming button.")
        }
        public static var leaveItKept: String {
            String(localized: "lt.leaveItKept", defaultValue: "Leave It Kept", comment: "The default button.")
        }
        public static var clearTheMark: String {
            String(localized: "lt.clearTheMark", defaultValue: "Clear the Mark",
                   comment: "0. Back to unmarked, which is not the same as putting it out.")
        }

        // MARK: - zoom (§2.5.7)

        public static var oneToOne: String {
            String(localized: "lt.oneToOne", defaultValue: "1:1",
                   comment: "One image pixel on one device pixel.")
        }
        public static var aimFace: String {
            String(localized: "lt.aimFace", defaultValue: "on the face",
                   comment: "The zoom says where it is pointing. A silent wrong aim is worse than a stated fallback.")
        }
        public static var aimSubject: String {
            String(localized: "lt.aimSubject", defaultValue: "no face found, on the subject", comment: "Zoom aim.")
        }
        public static var aimCentre: String {
            String(localized: "lt.aimCentre", defaultValue: "centered", comment: "Zoom aim.")
        }
        public static var aimHeld: String {
            String(localized: "lt.aimHeld", defaultValue: "held in place",
                   comment: "This frame has nothing to aim at, so the view does not jump.")
        }
        public static var fit: String {
            String(localized: "lt.fit", defaultValue: "Fit", comment: "The whole frame in the viewer.")
        }
        public static var sharpening: String {
            String(localized: "lt.sharpening", defaultValue: "Sharpening…",
                   comment: "A small corner indicator while a 1:1 cut is in flight. Never a spinner over the photograph.")
        }

        // MARK: - the scrubber and All Bursts (§2.5.10, §2.5.11)

        public static var burstScrubber: String {
            String(localized: "lt.burstScrubber", defaultValue: "Bursts", comment: "The scrubber's accessibility label.")
        }
        /// `Burst 3 of 19, looked through`
        public static func scrubberValue(_ n: Int, _ of: Int, seen: Bool) -> String {
            seen
                ? String(localized: "lt.scrubberValueSeen", defaultValue: "Burst \(n) of \(of), looked through",
                         comment: "The scrubber reads as a slider.")
                : String(localized: "lt.scrubberValue", defaultValue: "Burst \(n) of \(of), not looked through yet",
                         comment: "The scrubber reads as a slider.")
        }
        /// `Burst 41 · 12 frames · 3 kept`
        public static func burstCaption(_ n: Int, frames: Int, kept: Int) -> String {
            let count = frames == 1
                ? String(localized: "lt.oneFrame", defaultValue: "1 frame",
                         comment: "A burst of a single frame.")
                : String(localized: "lt.manyFrames", defaultValue: "\(frames) frames",
                         comment: "How many frames a burst holds.")
            return String(localized: "lt.burstCaption", defaultValue: "Burst \(n) · \(count) · \(kept) kept",
                          comment: "The scrubber's popover and every All Bursts cover. The last number is his.")
        }
        public static var findBurst: String {
            String(localized: "lt.findBurst", defaultValue: "Burst number",
                   comment: "⌘F focuses a small field; a number and Return jump there.")
        }

        // MARK: - resume (§2.5.13)

        public static func resumeLeftOff(_ n: Int, _ of: Int, _ seen: Int, _ toGo: Int) -> String {
            String(localized: "lt.resumeLeftOff",
                   defaultValue: "Back where you left off: burst \(n) of \(of). \(seen) looked through, \(toGo) to go.",
                   comment: "Opening Choose Keepers on a shoot he has been in.")
        }
        public static func resumeMoved(_ of: Int) -> String {
            String(localized: "lt.resumeMoved",
                   defaultValue: "The burst you were in is not in this cull any more. Burst 1 of \(of).",
                   comment: "The cull was run again and the burst he was in is gone.")
        }
        public static func resumeAllSeen(_ kept: Int, _ frames: Int) -> String {
            String(localized: "lt.resumeAllSeen", defaultValue: "Every burst has been looked through. You kept \(kept).",
                   comment: "Nothing left to go through.")
        }
        public static func resumeFresh(_ of: Int) -> String {
            String(localized: "lt.resumeFresh",
                   defaultValue: "Burst 1 of \(of). E keep, D drop, F next frame, R next burst. Press ? for the rest.",
                   comment: "A shoot he has not been into yet.")
        }
        public static var unmarkBurst: String {
            String(localized: "lt.unmarkBurst", defaultValue: "Mark this burst as not looked through",
                   comment: "A burst can be un-marked from the header link.")
        }

        // MARK: - review mode (§2.9)

        public static var reviewNoVerdicts: String {
            String(localized: "lt.reviewNoVerdicts",
                   defaultValue: "This is a look back at frames you already kept. Nothing here can be marked.",
                   comment: "Why K and D are off in the learning screen's review.")
        }

        // MARK: - the frame inspector (⌥⌘I)

        public static var yourCall: String {
            String(localized: "lt.yourCall", defaultValue: "Your call",
                   comment: "The inspector's first section: what he decided, and the three buttons.")
        }
        public static var theCull: String {
            String(localized: "lt.theCull", defaultValue: "The cull",
                   comment: "The inspector's second section. It never merges with the first.")
        }
        public static var thisFrame: String {
            String(localized: "lt.thisFrame", defaultValue: "This frame",
                   comment: "The inspector's third section: the frame's own facts.")
        }
        public static var size: String {
            String(localized: "lt.size", defaultValue: "Size", comment: "The frame's pixels.")
        }
        public static var takenAt: String {
            String(localized: "lt.takenAt", defaultValue: "Taken", comment: "When the shutter went.")
        }
        public static var reasonLabel: String {
            String(localized: "lt.reasonLabel", defaultValue: "Why it is out",
                   comment: "The fault he named, in the inspector.")
        }

        // MARK: - VoiceOver (§2.15)

        /// *"Frame 04330, 2 of 7 in burst 3. You kept it. The cull's guess:
        /// maybe. In a stack of 4 similar frames."*
        public static func frameAnnouncement(frame: String, n: Int, of: Int, burst: Int,
                                             his: String, cull: String, stack: Int?) -> String {
            var text = String(localized: "lt.announceFrame",
                              defaultValue: "Frame \(frame), \(n) of \(of) in burst \(burst).",
                              comment: "The first sentence VoiceOver reads on a frame.")
            text += " " + his + "." + " " + cull + "."
            if let stack, stack > 1 {
                text += " " + String(localized: "lt.announceStack",
                                     defaultValue: "In a stack of \(stack) similar frames.",
                                     comment: "Said only when the frame is in one.")
            }
            return text
        }
    }
}
