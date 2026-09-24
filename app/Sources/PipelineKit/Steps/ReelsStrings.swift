import Foundation

/// Every sentence the Reels step says for itself (DESIGN.md §2.6).
///
/// The same two rules as `StepStrings.swift`. Nothing the extension offers is
/// here — a further thing for the crop to follow arrives at runtime with its
/// own words. And nothing the engine writes is here either: a refusal from
/// `/api/reel` is printed exactly as the engine wrote it.
extension Strings {

    public enum Reels {
        private static func t(_ key: String, _ value: String, _ comment: String) -> String {
            Bundle.main.localizedString(forKey: key, value: value, table: nil)
        }

        public static var title: String { t("reels.title", "Reels", "The step's name, for VoiceOver.") }

        // MARK: - the primary

        public static var cutIt: String { t("reels.cutIt", "Cut It", "The step's primary (§2.4).") }

        // MARK: - format

        public static var format: String { t("reels.format", "Format", "The inspector's first group.") }

        public static func formatName(_ f: ReelFormat) -> String {
            switch f {
            case .cut: return t("reels.format.cut", "Push In", "A format.")
            case .sequence: return t("reels.format.sequence", "Sequence", "A format.")
            case .loop: return t("reels.format.loop", "Loop", "A format.")
            case .boomerang: return t("reels.format.boomerang", "Boomerang", "A format.")
            case .timelapse: return t("reels.format.timelapse", "Timelapse", "A format.")
            }
        }

        /// The one line under each format, which is the whole of what it does.
        public static func formatNote(_ f: ReelFormat) -> String {
            switch f {
            case .cut:
                return t("reels.format.cut.note", "The burst, landing on the frame that mattered and pushing in on it.",
                         "Under Cut.")
            case .sequence:
                return t("reels.format.sequence.note", "The burst played through, the crop staying on the subject.",
                         "Under Sequence.")
            case .loop:
                return t("reels.format.loop.note", "The burst round and round, trimmed where the wrap does not show.",
                         "Under Loop.")
            case .boomerang:
                return t("reels.format.boomerang.note", "The burst forward and then back, until it is long enough to watch.",
                         "Under Boomerang.")
            case .timelapse:
                return t("reels.format.timelapse.note", "Not a burst: the whole day, or one name, in the order it happened.",
                         "Under Timelapse.")
            }
        }

        // MARK: - speed, crop, size

        public static var speed: String { t("reels.speed", "Speed", "A picker: frames a second.") }
        public static func perSecond(_ n: Int) -> String {
            String(localized: "reels.perSecond", defaultValue: "\(n) frames a second",
                   comment: "A speed. The number is photographs a second.")
        }
        public static func perSecondSlow(_ n: Int) -> String {
            String(localized: "reels.perSecondSlow", defaultValue: "\(n) frames a second, deliberate",
                   comment: "The slowest speed.")
        }
        public static func perSecondFast(_ n: Int) -> String {
            String(localized: "reels.perSecondFast", defaultValue: "\(n) frames a second, smoothest",
                   comment: "The fastest speed.")
        }

        public static var follows: String { t("reels.follows", "Crop follows", "A picker.") }
        public static var followAction: String { t("reels.follow.action", "Whatever is moving", "What the crop stays on.") }
        public static var followPeople: String { t("reels.follow.people", "The people", "What the crop stays on.") }
        public static var followNone: String { t("reels.follow.none", "Nothing, locked off", "What the crop stays on.") }
        public static var followNoneNote: String {
            t("reels.follow.none.note", "The widest upright frame the picture can give, the same on every frame. Much the fastest.",
              "Under the picker, when Nothing is chosen.")
        }

        public static var slowIn: String { t("reels.slowIn", "Slow into the push-in", "A checkbox, Push In only.") }
        public static var slowInNote: String {
            t("reels.slowIn.note", "The last frames before the push-in are held a beat longer.", "Under the checkbox.")
        }

        public static var size: String { t("reels.size", "Size", "A picker: the reel's width.") }
        public static func sizeName(_ s: ReelSize) -> String {
            switch s {
            case .w1080: return t("reels.size.1080", "1080 wide, for Instagram", "A size.")
            case .w1440: return t("reels.size.1440", "1440 wide", "A size.")
            case .w2160: return t("reels.size.2160", "2160 wide", "A size.")
            case .native: return t("reels.size.native", "As big as your frames allow", "A size.")
            }
        }

        public static var picturesFrom: String { t("reels.picturesFrom", "Exports from", "A picker: which export folder.") }
        public static var everywhere: String {
            t("reels.everywhere", "Everywhere they can be found", "The default: the engine looks in every folder.")
        }
        public static func folder(_ path: String, _ n: Int) -> String {
            String(localized: "reels.folder", defaultValue: "\(path) — \(n) frames",
                   comment: "One export folder, and how many of this shoot's frames are in it.")
        }

        public static var savedIn: String { t("reels.savedIn", "Saved in", "The output folder's row.") }

        // MARK: - the bursts list

        public static var findPrompt: String { t("reels.find", "Burst number", "The search field's placeholder.") }
        public static var findHelp: String {
            t("reels.find.help", "Type a burst's number and press Return to go to it (⌘F). Escape empties the field.",
              "The search field's help tag.")
        }
        public static var byNumber: String { t("reels.order.number", "By Number", "Sort the bursts.") }
        public static var bestFirst: String { t("reels.order.best", "Best First", "Sort the bursts: the lister's ranking.") }
        public static var order: String { t("reels.order", "Order", "The sort control's label, for VoiceOver.") }
        public static func burst(_ b: String) -> String {
            String(localized: "reels.burst", defaultValue: "Burst \(b)", comment: "A row in the bursts list.")
        }
        public static func exportedOf(_ exported: Int, _ frames: Int) -> String {
            String(localized: "reels.exportedOf", defaultValue: "\(exported) of \(frames) exported",
                   comment: "Under a burst's name.")
        }
        /// How long a burst lasted, from its capture times: to the tenth
        /// where the times carry fractions, and otherwise to the second they
        /// are written to, said as such.
        public static func lasted(_ l: BurstLength) -> String {
            if l.exact {
                let tenths = (l.seconds * 10).rounded() / 10
                return String(localized: "reels.lasted.exact", defaultValue: "\(tenths.formatted(.number.precision(.fractionLength(1)))) s",
                              comment: "How long a burst lasted, from capture times with fractions of a second, e.g. 1.2 s.")
            }
            let whole = Int(l.seconds.rounded())
            guard whole > 0 else {
                return String(localized: "reels.lasted.underOne", defaultValue: "under 1 s",
                              comment: "A burst whose frames were all taken within the same second.")
            }
            return String(localized: "reels.lasted", defaultValue: "about \(whole) s",
                          comment: "How long a burst lasted, from capture times written to the second.")
        }
        /// The same where there is less room: "3 s", "<1 s".
        public static func lastedShort(_ l: BurstLength) -> String {
            if l.exact { return lasted(l) }
            let whole = Int(l.seconds.rounded())
            guard whole > 0 else {
                return String(localized: "reels.lasted.underOne.short", defaultValue: "<1 s",
                              comment: "A burst taken within one second, where there is little room.")
            }
            return String(localized: "reels.lasted.short", defaultValue: "\(whole) s",
                          comment: "How long a burst lasted, where there is little room.")
        }
        public static var lastedHelp: String {
            t("reels.lasted.help", "How long the burst lasted, from its first frame's capture time to its last's.",
              "The help tag on a burst's length in the list.")
        }
        public static var keptOne: String {
            t("reels.keptOne", "You kept a frame of this burst", "The dot beside a burst's number, and VoiceOver.")
        }
        public static func bursts(_ n: Int) -> String {
            String(localized: "reels.bursts", defaultValue: "\(n) bursts", comment: "Under the list.")
        }
        public static func found(_ n: Int, of all: Int) -> String {
            String(localized: "reels.found", defaultValue: "\(n) of \(all) bursts", comment: "Under the list, searching.")
        }
        public static var noBursts: String {
            t("reels.noBursts", "Nothing with three frames in it yet. Cull this shoot and every burst shows up here.",
              "The list is empty.")
        }

        // Timelapse: the list becomes what to play.
        public static var wholeDay: String { t("reels.wholeDay", "The whole day", "Timelapse: every frame on the card.") }
        public static func frames(_ n: Int) -> String {
            String(localized: "reels.frames", defaultValue: "\(n) frames", comment: "Under a timelapse row.")
        }
        public static var nothingTagged: String {
            t("reels.nothingTagged", "Nothing is filed under that name.", "A timelapse with no frames.")
        }

        // MARK: - the burst and its frames

        public static var reading: String { t("reels.reading", "Reading your exports…", "While the lister runs.") }
        public static func exportsFound(_ n: Int) -> String {
            String(localized: "reels.exportsFound", defaultValue: "\(n) exported frames found.",
                   comment: "Above the frames.")
        }
        public static var nothingExported: String {
            t("reels.nothingExported",
              "Nothing exported yet. Every burst can still be cut as a draft off the RAWs, which is how you find the one worth finishing.",
              "Above the frames, when there are no exports.")
        }
        public static func inTheCut(_ n: Int, of all: Int) -> String {
            String(localized: "reels.inTheCut", defaultValue: "\(n) of \(all) frames in the reel",
                   comment: "Under the burst's name.")
        }
        public static var fromExports: String {
            t("reels.fromExports", "Cut from your exports.", "The whole burst has been through PhotoLab.")
        }
        public static func draft(_ missing: Int, of all: Int) -> String {
            String(localized: "reels.draft",
                   defaultValue: "A draft, off the RAWs: \(missing) of its \(all) frames are not exported. Its file name will say draft.",
                   comment: "The burst will cut from the cull's decodes, not his finished work.")
        }
        public static var needThree: String {
            t("reels.needThree", "A reel needs three frames. Put some back, or choose another burst.",
              "Fewer than three frames are ticked.")
        }
        /// The keys named from the menu bar's own table — the key each row
        /// shows, the left hand's — so the line can never teach a key the
        /// menu does not: E, D and X as they are on the light table and on
        /// Instagram.
        @MainActor public static var gridNote: String {
            func key(_ id: CommandID, _ fallback: String) -> String {
                CommandTable.command(id)?.shortcut?.display ?? fallback
            }
            return String(format: t("reels.gridNote",
                                    "%@: in. %@: out. %@: back in. Click: in or out. Shift-click: from the last. %@ and %@: start and end. Space: large.",
                                    "Above the frames, one line: what each key and a click does to a frame."),
                          key(CommandTable.ID.keep, "E"), key(CommandTable.ID.drop, "D"),
                          key(CommandTable.ID.clearMark, "X"),
                          ReelsKeys.ownKey(.startHere), ReelsKeys.ownKey(.endHere))
        }
        public static var notExported: String {
            t("reels.notExported", "Not exported", "A badge on a tile, when the burst is only partly exported.")
        }
        public static var outBadge: String { t("reels.outBadge", "Out", "A badge on a tile he took out of the reel.") }
        public static var noPicture: String { t("reels.noPicture", "No picture yet", "On a tile with nothing to show.") }
        public static var inReel: String { t("reels.inReel", "In the reel", "VoiceOver: the tile's checkbox is ticked.") }
        public static var leftOut: String { t("reels.leftOut", "Left out", "VoiceOver: the tile's checkbox is clear.") }
        public static var openLarge: String { t("reels.openLarge", "Open Large", "VoiceOver action on a tile.") }
        /// Frame ▸ Keep and Drop while Reels is on screen, as they read on
        /// Instagram: E is Keep on the light table and Include here.
        public static var include: String { t("reels.include", "Include", "Frame ▸ Keep on Reels, with no frame.") }
        public static var leaveOut: String { t("reels.leaveOut", "Leave Out", "Frame ▸ Drop on Reels, with no frame.") }
        public static func includeNamed(_ stem: String) -> String {
            String(format: t("reels.includeNamed", "Include %@", "Frame ▸ Keep on Reels: Include 06264."), stem)
        }
        public static func leaveOutNamed(_ stem: String) -> String {
            String(format: t("reels.leaveOutNamed", "Leave Out %@", "Frame ▸ Drop on Reels: Leave Out 06264."), stem)
        }
        public static var includeHelp: String {
            t("reels.includeHelp", "Puts the frame in the reel, then goes to the next.", "Frame ▸ Keep's help tag on Reels.")
        }
        public static var leaveOutHelp: String {
            t("reels.leaveOutHelp", "Leaves the frame out of the reel, then goes to the next.", "Frame ▸ Drop's help tag on Reels.")
        }
        public static var nextBurstHelp: String {
            t("reels.nextBurstHelp", "Opens the next burst in the list.", "Frame ▸ Next Burst's help tag on Reels.")
        }
        public static func clearNamed(_ stem: String) -> String {
            String(format: t("reels.clearNamed", "Clear %@", "Edit ▸ Undo on Reels: Undo Clear 06264."), stem)
        }
        public static var putBackAll: String {
            t("reels.putBackAll", "Put Them All Back", "Every frame of the burst on screen back in the reel.")
        }
        public static var leaveAllOut: String {
            t("reels.leaveAllOut", "Leave Them All Out", "Every frame of the burst on screen out, to click back the few he wants.")
        }
        public static var startHere: String {
            t("reels.startHere", "Start the Reel Here", "VoiceOver action on a tile; the I key.")
        }
        public static var endHere: String {
            t("reels.endHere", "End the Reel Here", "VoiceOver action on a tile; the O key.")
        }

        // MARK: - finishing a burst in PhotoLab

        /// What `/api/spread` does, said as it does it. It passes `--standard`:
        /// the shoot's own preset, not a copy of an edit of his, goes beside
        /// every frame of the burst that has no sidecar yet, and a frame that
        /// has one is left alone. The label once promised his edit instead.
        public static var spread: String {
            t("reels.spread", "Write Presets and Open PhotoLab",
              "Button: the shoot's own preset goes beside every frame of the burst he has not edited, and PhotoLab opens on the burst.")
        }
        /// One line under the button. How many are exported is said once, in
        /// the draft line above it; what is and is not done to his edits is
        /// the button's help and the "?", not a paragraph read on every burst.
        public static var spreadNote: String {
            t("reels.spreadNote",
              "Puts the shoot's own preset on every frame of the burst you have not edited and opens it in PhotoLab. Export it and the reel cuts itself.",
              "Under the button.")
        }
        public static var spreadHelp: String {
            t("reels.spreadHelp",
              "The shoot's own preset, its exposure levelled so the light matches down the burst, goes beside every frame you have not edited. Your edit is not copied, and a frame you edited is left as it is.",
              "The button's help tag: the detail the note leaves out.")
        }
        public static func waiting(_ burst: String) -> String {
            String(localized: "reels.waiting", defaultValue: "Waiting for you to export burst \(burst) from PhotoLab…",
                   comment: "While the export count has not moved.")
        }
        public static func soFar(_ burst: String, _ n: Int, of total: Int?) -> String {
            guard let total else {
                return String(localized: "reels.soFar.count", defaultValue: "Burst \(burst): \(n) exported so far…",
                              comment: "While exports are arriving, when the burst's size is not known.")
            }
            return String(localized: "reels.soFar", defaultValue: "Burst \(burst): \(n) of \(total) exported so far…",
                          comment: "While exports are arriving.")
        }
        public static func cutsIn(_ seconds: Int) -> String {
            String(localized: "reels.cutsIn", defaultValue: "Cutting from these in \(seconds) s unless more arrive.",
                   comment: "After the waiting line, once exports have paused before the whole burst is there.")
        }
        public static func someOfTheBurst(_ n: Int, of total: Int) -> String {
            String(localized: "reels.someOfTheBurst", defaultValue: "Your reel is \(n) of the \(total): Cut Now once those are exported.",
                   comment: "After the waiting line, when he took frames out of the reel: the wait counts the whole burst.")
        }
        public static func cutting(_ burst: String, _ n: Int, of total: Int?) -> String {
            guard let total else {
                return String(localized: "reels.cutting.count", defaultValue: "Burst \(burst): \(n) exported. Cutting.",
                              comment: "The exports stopped arriving, when the burst's size is not known.")
            }
            return String(localized: "reels.cutting", defaultValue: "Burst \(burst): \(n) of \(total) exported. Cutting.",
                          comment: "The exports are all there, or stopped arriving.")
        }
        public static var cutNow: String {
            t("reels.cutNow", "Cut Now", "Button and the step's primary while waiting: stop waiting and cut what is exported.")
        }
        public static var cutNowNote: String {
            t("reels.cutNow.note", "Waiting for your exports. Cut Now cuts from what is there.",
              "Beside the primary while it reads Cut Now.")
        }
        public static var frozen: String {
            t("reels.frozen",
              "The reel is cut as this burst was when you pressed Write Presets and Open PhotoLab. What you have changed since is not in it.",
              "Under the waiting line, when he changed frames or settings after pressing.")
        }
        public static func waitLost(_ burst: String) -> String {
            String(localized: "reels.waitLost",
                   defaultValue: "Stopped waiting for burst \(burst) when this shoot was opened again. Cut It once it is exported.",
                   comment: "A wait for presets could not follow the shoot being reopened.")
        }
        public static var stopWaiting: String { t("reels.stopWaiting", "Stop Waiting", "Button beside the waiting line.") }
        public static func preparing(_ burst: String) -> String {
            String(localized: "reels.preparing",
                   defaultValue: "Writing the presets for burst \(burst). PhotoLab opens when they are written; export the burst from it and the reel cuts itself.",
                   comment: "While /api/spread runs, before the wait for exports begins.")
        }
        public static var spreadFailed: String {
            t("reels.spreadFailed",
              "Writing the presets stopped with an error, so nothing is being waited for. The job's log says why.",
              "The spread ended with a traceback rather than a sentence.")
        }
        public static func slower(minutes: Int, every seconds: Int) -> String {
            String(localized: "reels.slower",
                   defaultValue: "Nothing new for \(minutes) min; it looks every \(seconds) s now.",
                   comment: "After the waiting line, once the wait on PhotoLab has slowed down: it never gives up by itself.")
        }

        // MARK: - the preview

        public static var lastCut: String { t("reels.lastCut", "The last reel cut", "The player, for VoiceOver.") }
        /// Under the player, before the file's name: whose reel it is not is
        /// said by saying whose it is — the shoot's last, whichever burst.
        public static func lastCutAt(_ when: String) -> String {
            String(localized: "reels.lastCutAt", defaultValue: "This shoot's last reel, \(when)",
                   comment: "Under the player: the reel is the shoot's newest, and when it was cut, e.g. 'Yesterday at 3:16 PM' or 'Sep 20, 3:16 PM'.")
        }
        public static var noneYet: String {
            t("reels.noneYet", "Nothing has been cut from this shoot yet. The last reel you cut plays here.",
              "Where the player goes.")
        }
        public static func reelLine(_ name: String, _ size: String, _ at: String) -> String {
            String(localized: "reels.reelLine", defaultValue: "\(name) · \(size) · \(at)",
                   comment: "Under the player: the file, its size, when it was cut.")
        }
        public static func reelsCut(_ n: Int) -> String {
            String(localized: "reels.reelsCut", defaultValue: "\(n) reels cut from this shoot.",
                   comment: "Beside the output folder.")
        }

        // MARK: - the "?"

        public static var aboutHelp: String { t("reels.aboutButton", "About Reels", "The ? button's help tag.") }
        public static var aboutText: String {
            t("reels.aboutText",
              """
              A reel is a burst of your photographs cut into an upright 9:16 clip, the shape Instagram wants.

              Every burst can be cut straight off the RAWs before anything has been through PhotoLab, so you can find the one worth finishing. Those are drafts, and their file names say so. Once a burst is exported, the same cut is made from your exports, and that is the one to post.

              A burst with frames not yet exported can be finished from here. Write Presets and Open PhotoLab gives every frame of it you have not edited the shoot's own preset, with the exposure levelled down the burst, and opens the burst in PhotoLab. It does not copy an edit of yours, and it leaves a frame you have edited as it is. Export them, and when the exports stop arriving the reel cuts itself.

              The frames are always played in the order the shutter fired, whatever order you ticked them in. Add sound in Instagram: a silent reel is skipped.
              """,
              "The static explanation behind the ? (FLOW-05).")
        }
    }
}
