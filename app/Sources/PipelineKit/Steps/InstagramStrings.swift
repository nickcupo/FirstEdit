import Foundation

/// Every sentence the Instagram step says for itself (DESIGN.md §2.17).
///
/// The same two rules as `StepStrings.swift`. A refusal from the engine is
/// printed exactly as the engine wrote it, never here. And **no key is ever
/// written into a sentence for a meaning Choose Keepers owns**: its name comes
/// from `LightTableKeys.key`, which reads the menu bar's own table, so the
/// sentence names whatever key Keepers uses today and cannot drift from it.
extension Strings {

    @MainActor
    public enum Instagram {
        private static func t(_ key: String, _ value: String, _ comment: String) -> String {
            Bundle.main.localizedString(forKey: key, value: value, table: nil)
        }

        public static var title: String { t("ig.title", "Instagram", "The step's name, for VoiceOver.") }
        public static var wallLabel: String { t("ig.wall", "Instagram cuts", "The wall, for VoiceOver.") }

        // MARK: - the primary

        /// "Make 5 Copies", "Make 1 Copy", and "Make Copies" greyed when there
        /// is nothing to make — the line beside it says why.
        public static func make(_ n: Int) -> String {
            switch n {
            case 0: return t("ig.make.none", "Make Copies", "The step's primary, greyed: nothing to make.")
            case 1: return t("ig.make.one", "Make 1 Copy", "The step's primary, one copy.")
            default: return String(format: t("ig.make.many", "Make %d Copies", "The step's primary."), n)
            }
        }

        // MARK: - the make line

        public static func makesAllBut(_ n: Int, leftOut: Int) -> String {
            String(format: t("ig.makes.allBut", "Makes %d — all but the %d you left out.",
                             "Beside the primary, when he left some out."), n, leftOut)
        }
        public static func makesIncluded(_ n: Int) -> String {
            String(format: t("ig.makes.included", "Makes %d — the ones you included.",
                             "Beside the primary, when he ticked some."), n)
        }
        public static func makesNotMade(_ n: Int) -> String {
            String(format: t("ig.makes.notMade", "Makes %d — every one not made yet.",
                             "Beside the primary, with nothing ticked."), n)
        }
        public static func alreadyMade(_ n: Int) -> String {
            n == 1 ? t("ig.alreadyMade.one", "1 is already made as shown.", "Added to the make line.")
                : String(format: t("ig.alreadyMade", "%d are already made as shown.", "Added to the make line."), n)
        }
        public static func notIncludedYet(_ n: Int) -> String {
            n == 1 ? t("ig.notIncludedYet.one", "1 still being worked out is not included.", "Added to the make line.")
                : String(format: t("ig.notIncludedYet", "%d still being worked out are not included.",
                                   "Added to the make line."), n)
        }
        /// The same, when nothing is working them out: after a Stop, a
        /// failure, or while a job of his holds the slot.
        public static func notWorkedOutNotIncluded(_ n: Int) -> String {
            n == 1 ? t("ig.notWorkedOut.one", "1 not worked out yet is not included.",
                       "Added to the make line, while nothing works it out.")
                : String(format: t("ig.notWorkedOut", "%d not worked out yet are not included.",
                                   "Added to the make line, while nothing works them out."), n)
        }

        // MARK: - why the primary makes nothing

        public static func allMade(_ n: Int) -> String {
            n == 1 ? t("ig.allMade.one", "It is made as shown. A cut you change is made again at once.",
                       "Beside a greyed primary, when the one chosen is made.")
                : String(format: t("ig.allMade", "All %d are made as shown. A cut you change is made again at once.",
                                   "Beside a greyed primary."), n)
        }
        public static var allLeftOut: String {
            t("ig.allLeftOut", "You left every photograph out.", "Beside a greyed primary.")
        }
        public static var stillWorking: String {
            t("ig.stillWorking", "Still working out these cuts.", "Beside a greyed primary.")
        }
        public static var notWorkedOutYet: String {
            t("ig.notWorkedOutYet", "These cuts are not worked out yet.",
              "Beside a greyed primary, while nothing works them out.")
        }
        /// The planning bar's value for VoiceOver: "40 percent".
        public static func percent(_ fraction: Double) -> String {
            fraction.formatted(.percent.precision(.fractionLength(0)))
        }
        public static func nothingExported(_ editor: String) -> String {
            String(format: t("ig.nothingExported",
                             "Nothing is exported yet. The copies are cut from your finished photographs, so export from %@ first.",
                             "The step before anything is exported; the editor's name."), editor)
        }

        // MARK: - the header

        public static var portraits: String { t("ig.portraits", "Portraits", "The first picker's label.") }
        public static var landscapes: String { t("ig.landscapes", "Landscapes", "The second picker's label.") }
        public static var whole: String { t("ig.whole", "Whole", "A landscape left whole; the editor's Whole.") }
        public static var cut: String { t("ig.cut", "Cut", "A landscape cut to the portrait shape.") }
        public static func ratioHelp(_ ratio: String) -> String {
            ratio == "4:5"
                ? t("ig.ratio.45.help", "1080 × 1350, the shape posts had before 2025. Keeps more of a tall photograph than 3:4 would.",
                    "Help on 4:5.")
                : t("ig.ratio.34.help", "1080 × 1440, the tallest post and the shape of the profile grid.", "Help on 3:4.")
        }
        public static var wholeHelp: String {
            t("ig.whole.help", "A landscape stays whole, 1080 wide. The profile grid shows only its middle.",
              "Help on Whole.")
        }
        public static var cutHelp: String {
            t("ig.cut.help", "A landscape is cut to the portrait shape too, around its subject: one shape for a carousel.",
              "Help on Cut.")
        }
        public static func counts(exported: Int, planned: Int, made: Int) -> String {
            String(format: t("ig.counts", "%d exported · %d worked out · %d made", "The header's numbers."),
                   exported, planned, made)
        }
        public static func gridMisses(_ n: Int) -> String {
            n == 1 ? t("ig.misses.one", "1 would lose the subject in the profile grid. It is first.", "Header line.")
                : String(format: t("ig.misses", "%d would lose the subject in the profile grid. They are first.",
                                   "Header line."), n)
        }
        /// The same, where the header has room for little.
        public static func gridMissesShort(_ n: Int) -> String {
            String(format: t("ig.misses.short", "%d lose the subject in the grid", "Header line, narrow."), n)
        }
        public static func waitingFor(_ what: String) -> String {
            String(format: t("ig.waiting", "The cuts are worked out when %@ is done.",
                             "Header line: a job of his holds the slot."), what)
        }
        public static var stopped: String { t("ig.stopped", "Stopped.", "Header line: he stopped the pass.") }
        public static var workOutTheRest: String { t("ig.workOutTheRest", "Work Out the Rest", "Button.") }
        public static func failed(_ line: String) -> String {
            String(format: t("ig.failed", "Could not work out the cuts: %@", "Header line, the pass's last line."), line)
        }
        public static var planFailed: String {
            t("ig.planFailed", "the pass ended without finishing. The log says why.", "When the pass said nothing.")
        }
        public static var tryAgain: String { t("ig.tryAgain", "Try Again", "Button.") }
        public static var showTheFolder: String { t("ig.showTheFolder", "Show the Folder", "Button.") }
        public static var showTheFolderHelp: String {
            t("ig.showTheFolder.help", "The copies' folder in Finder.", "Help on Show the Folder.")
        }

        // MARK: - a tile

        public static func cutTo(_ ratio: String) -> String {
            String(format: t("ig.cutTo", "cut to %@", "A tile's state: cut to 3:4."), ratio)
        }
        public static var leftWhole: String { t("ig.leftWhole", "left whole", "A tile's state.") }
        public static var madeWord: String { t("ig.made", "made", "A tile's state: its copy is the cut shown.") }
        public static func madeAt(_ shape: String) -> String {
            String(format: t("ig.madeAt", "made at %@", "A tile's state: made at another shape."), shape)
        }
        public static var madeBefore: String {
            t("ig.madeBefore", "made before this cut", "A tile's state: its copy is an earlier cut.")
        }
        public static var yourCut: String { t("ig.yourCut", "your cut", "A cut he placed himself.") }
        public static var automaticWord: String { t("ig.automatic.word", "automatic", "A cut worked out for him.") }
        public static var exportedAgain: String { t("ig.exportedAgain", "exported again", "A tile's state.") }
        public static var exportedAgainMade: String {
            t("ig.exportedAgainMade", "exported again since it was made", "A tile's state.")
        }
        public static var workingOut: String { t("ig.workingOut", "working out…", "A tile being worked out.") }
        public static var notWorkedOut: String { t("ig.notWorkedOut", "not worked out yet", "A tile's state.") }
        public static var gridCuts: String { t("ig.gridCuts", "the grid cuts the subject", "A tile's state.") }
        public static var leftOut: String { t("ig.leftOut", "Left out", "Across a tile he left out.") }
        public static var includeBox: String { t("ig.includeBox", "Include", "The tile's checkbox, for VoiceOver.") }
        public static var gridBadge: String {
            t("ig.gridBadge", "The profile grid would cut the subject", "The tile's warning badge.")
        }
        public static var yoursBadge: String { t("ig.yoursBadge", "You set this cut", "The tile's pencil badge.") }

        // For VoiceOver: one value, only the parts that are true.
        public static func spokenCut(_ shape: String, out: PixelSize, kept: Int) -> String {
            String(format: t("ig.spoken.cut", "cut to %@, %d by %d, keeps %d percent", "A tile's value."),
                   shape, out.w, out.h, kept)
        }
        public static func spokenWhole(out: PixelSize, kept: Int) -> String {
            String(format: t("ig.spoken.whole", "left whole, %d by %d, keeps %d percent", "A tile's value."),
                   out.w, out.h, kept)
        }
        public static var spokenGrid: String {
            t("ig.spoken.grid", "the profile grid would cut the subject", "A tile's value.")
        }
        public static var spokenMade: String { t("ig.spoken.made", "made", "A tile's value.") }
        public static var spokenIncluded: String { t("ig.spoken.included", "included", "A tile's value.") }
        public static var spokenLeftOut: String { t("ig.spoken.leftOut", "left out", "A tile's value.") }
        public static var spokenWorking: String { t("ig.spoken.working", "working out its cut", "A tile's value.") }
        public static var tileHint: String {
            String(format: t("ig.tile.hint", "%@ adjusts the cut", "A tile's hint: Space adjusts the cut."),
                   LightTableKeys.key(CommandTable.ID.fullImage) ?? "Space")
        }

        // MARK: - rows and actions

        public static var include: String { t("ig.include", "Include", "Button and action.") }
        public static var leaveOut: String { t("ig.leaveOutAction", "Leave Out", "Button and action.") }
        public static var clear: String { t("ig.clear", "Clear", "Action.") }
        public static var clearTheMark: String { t("ig.clearTheMark", "Clear the Mark", "Frame ▸ Clear the Mark.") }
        public static var adjustTheCut: String { t("ig.adjust", "Adjust the Cut", "View ▸ Full Image, here.") }
        public static var backToThePhotographs: String {
            t("ig.back", "Back to the Photographs", "View ▸ Full Image in the editor.")
        }
        public static var nextPhotograph: String { t("ig.next", "Next Photograph", "Frame ▸ Next, here.") }
        public static var previousPhotograph: String { t("ig.previous", "Previous Photograph", "Frame ▸ Previous, here.") }
        public static func includeNamed(_ stem: String) -> String {
            String(format: t("ig.includeNamed", "Include %@", "Include 05901."), stem)
        }
        public static func leaveOutNamed(_ stem: String) -> String {
            String(format: t("ig.leaveOutNamed", "Leave Out %@", "Leave Out 05901."), stem)
        }
        public static func clearNamed(_ stem: String) -> String {
            String(format: t("ig.clearNamed", "Clear %@", "Undo Clear 05901."), stem)
        }
        public static func cutNamed(_ stem: String) -> String {
            String(format: t("ig.cutNamed", "Cut %@", "Undo Cut 05901."), stem).trimmingCharacters(in: .whitespaces)
        }

        // MARK: - the editor

        public static func cutToButton(_ ratio: String) -> String {
            String(format: t("ig.ed.cutTo", "Cut to %@", "The editor's Cut."), ratio)
        }
        public static var fit: String { t("ig.ed.fit", "Fit", "The editor's view.") }
        public static var oneToOne: String { t("ig.ed.oneToOne", "1:1", "The editor's view.") }
        public static var result: String { t("ig.ed.result", "Result", "The editor's view.") }
        public static var automatic: String { t("ig.ed.automatic", "Automatic", "Button.") }
        public static var done: String { t("ig.ed.done", "Done", "Button.") }
        public static func position(_ i: Int, of n: Int) -> String {
            String(format: t("ig.ed.position", "%d of %d", "3 of 40."), i, n)
        }
        public static func size(_ out: PixelSize, kept: Int) -> String {
            String(format: t("ig.ed.size", "%d × %d · keeps %d%% of the frame", "The editor's line."),
                   out.w, out.h, kept)
        }
        public static var gridWarning: String {
            t("ig.ed.grid", "⚠ the profile grid would cut the subject", "The editor's line.")
        }
        public static var notMadeYet: String { t("ig.ed.notMade", "not made yet", "The editor's line.") }
        public static var savedAndMade: String { t("ig.ed.savedMade", "Saved and made again.", "After a save.") }
        public static var savedNotMade: String {
            t("ig.ed.savedNotMade", "Saved. It is made when you make the copies.", "After a save.")
        }
        public static var cannotAdjustYet: String {
            t("ig.ed.notYet", "Its cut is still being worked out.", "The editor on a frame with no cut yet.")
        }
        public static var theCut: String { t("ig.ed.theCut", "The cut", "The cut, for VoiceOver.") }
        public static var moveLeft: String { t("ig.ed.left", "Move Left", "Action.") }
        public static var moveRight: String { t("ig.ed.right", "Move Right", "Action.") }
        public static var moveUp: String { t("ig.ed.up", "Move Up", "Action.") }
        public static var moveDown: String { t("ig.ed.down", "Move Down", "Action.") }
        public static var cutOrWhole: String { t("ig.ed.cutOrWhole", "Cut or Whole", "Action.") }
        // The Keyboard Shortcuts window's rows for the editor's own keys.
        public static var moveTheCut: String { t("ig.ed.moveTheCut", "Move the Cut", "A key with no menu item.") }
        public static var smallerCut: String { t("ig.ed.smaller", "Make the Cut Smaller", "A key with no menu item.") }
        public static var largerCut: String { t("ig.ed.larger", "Make the Cut Larger", "A key with no menu item.") }
        public static var automaticCut: String {
            t("ig.ed.automaticCut", "Back to the Automatic Cut", "A key with no menu item.")
        }
        public static var previousHelp: String {
            String(format: t("ig.ed.previousHelp", "The previous photograph (%@)", "Help on ‹."),
                   LightTableKeys.key(CommandTable.ID.previousFrame) ?? "←")
        }
        public static var nextHelp: String {
            String(format: t("ig.ed.nextHelp", "The next photograph (%@)", "Help on ›."),
                   LightTableKeys.key(CommandTable.ID.nextFrame) ?? "→")
        }
        public static var doneHelp: String {
            String(format: t("ig.ed.doneHelp", "Save the cut and go back to the photographs (%@)", "Help on Done."),
                   "Esc")
        }
        public static var automaticHelp: String {
            String(format: t("ig.ed.automaticHelp", "Back to the cut worked out for you (%@)", "Help on Automatic."),
                   InstagramKeys.editorKey(.automatic))
        }
        public static var cutOrWholeHelp: String {
            String(format: t("ig.ed.cutOrWholeHelp", "Cut to the shoot's shape, or leave it whole (%@)", "Help."),
                   InstagramKeys.editorKey(.cutOrWhole))
        }
        public static var resultHelp: String {
            String(format: t("ig.ed.resultHelp", "The copy as it will be written (%@)", "Help on Result."),
                   InstagramKeys.editorKey(.result))
        }
        public static var oneToOneHelp: String {
            String(format: t("ig.ed.oneToOneHelp", "One pixel of the photograph to one of the screen (%@)",
                             "Help on 1:1."), LightTableKeys.key(CommandTable.ID.actualSize) ?? "⌘0")
        }
        public static var fitHelp: String {
            String(format: t("ig.ed.fitHelp", "The whole photograph (%@)", "Help on Fit."),
                   LightTableKeys.key(CommandTable.ID.zoomToFit) ?? "⌘9")
        }
        public static var includeHelp: String {
            String(format: t("ig.ed.includeHelp", "Make a copy of this one, then the next photograph (%@)", "Help."),
                   LightTableKeys.key(CommandTable.ID.keep) ?? "K")
        }
        public static var leaveOutHelp: String {
            String(format: t("ig.ed.leaveOutHelp", "Make no copy of this one, then the next photograph (%@)", "Help."),
                   LightTableKeys.key(CommandTable.ID.drop) ?? "D")
        }

        /// The editor's keys, from the tables they live in: Keepers' own for
        /// every meaning Keepers has, the editor's for the rest.
        public static var keysLine: String {
            let prev = LightTableKeys.key(CommandTable.ID.previousFrame) ?? "←"
            let next = LightTableKeys.key(CommandTable.ID.nextFrame) ?? "→"
            // Z is Actual Size's second key in the menu bar's own table.
            let zoom = CommandTable.command(CommandTable.ID.actualSize)?.alternateDisplay ?? "Z"
            return String(format: t("ig.ed.keys",
                                    "%@ previous · %@ next · drag or ⇧ arrows to move · pinch or %@ %@ to size · %@ cut or whole · %@ automatic · %@ 1:1 · %@ result · Esc done",
                                    "The editor's keys line."),
                          prev, next, InstagramKeys.editorKey(.smaller), InstagramKeys.editorKey(.larger),
                          InstagramKeys.editorKey(.cutOrWhole), InstagramKeys.editorKey(.automatic), zoom,
                          InstagramKeys.editorKey(.result))
        }
    }
}
