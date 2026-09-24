import Foundation

/// Every word in the menu bar, the Shortcuts window and the Activity window.
///
/// They live here rather than in `Design/Strings.swift` because the menu bar
/// is this crew's, and because `tools/vocabulary-scan.sh` reads the string
/// files: a retired word from DESIGN.md §2.13 in any of these fails the scan
/// before a commit is written. Not one of them is a word the private
/// extension contributes — those arrive at runtime in `ExtConfig.labels`.
public enum Words {

    private static func s(_ key: String, _ value: String, _ comment: String) -> String {
        Bundle.main.localizedString(forKey: key, value: value, table: nil)
    }

    // MARK: menu titles

    public enum Menus {
        public static var file: String { s("menu.file", "File", "Menu bar title.") }
        public static var edit: String { s("menu.edit", "Edit", "Menu bar title.") }
        public static var frame: String { s("menu.frame", "Frame", "Menu bar title. One photograph.") }
        public static var view: String { s("menu.view", "View", "Menu bar title.") }
        public static var go: String { s("menu.go", "Go", "Menu bar title.") }
        public static var shoot: String { s("menu.shoot", "Shoot", "Menu bar title.") }
        public static var window: String { s("menu.window", "Window", "Menu bar title.") }
        public static var help: String { s("menu.help", "Help", "Menu bar title.") }
    }

    // MARK: First Edit

    public enum App {
        public static var about: String { s("command.about", "About First Edit", "Menu item.") }
        public static var checkForUpdates: String {
            s("command.checkForUpdates", "Check for Updates…", "Menu item.")
        }
        public static var settings: String { s("command.settings", "Settings…", "Menu item, ⌘,.") }
        public static var services: String { s("command.services", "Services", "The system submenu.") }
        public static var hide: String { s("command.hide", "Hide First Edit", "Menu item.") }
        public static var hideOthers: String { s("command.hideOthers", "Hide Others", "Menu item.") }
        public static var showAll: String { s("command.showAll", "Show All", "Menu item.") }
        public static var quit: String { s("command.quit", "Quit First Edit", "Menu item.") }
    }

    // MARK: File

    public enum File {
        public static var newShoot: String {
            s("command.newShoot", "New Shoot from a Memory Card…", "Menu item, ⌘N.")
        }
        public static var addFolder: String {
            s("command.addFolder", "Add a Folder of Photographs…", "Menu item, ⇧⌘N.")
        }
        public static var eject: String { s("command.eject", "Eject the Memory Card", "Menu item, ⌘E.") }
        public static var showShoot: String {
            s("command.showShoot", "Show the Shoot in Finder", "Menu item, ⌥⌘R.")
        }
        public static var showExports: String {
            s("command.showExports", "Show the Export Folder", "Menu item, ⌥⌘X.")
        }
        public static var closeWindow: String { s("command.closeWindow", "Close Window", "Menu item, ⌘W.") }
    }

    // MARK: Edit

    public enum Edit {
        public static var undo: String {
            s("command.undo", "Undo", "Menu item, ⌘Z; Q and U undo too on the light table.")
        }
        public static func undoNamed(_ step: String) -> String {
            String(localized: "command.undoNamed", defaultValue: "Undo \(step)",
                   comment: "Edit ▸ Undo, naming the verdict it takes back: Undo Keep 04330.")
        }
        public static var redo: String { s("command.redo", "Redo", "Menu item, ⇧⌘Z.") }
        public static func redoNamed(_ step: String) -> String {
            String(localized: "command.redoNamed", defaultValue: "Redo \(step)",
                   comment: "Edit ▸ Redo, naming the verdict it puts back: Redo Keep 04330.")
        }
        public static var cut: String { s("command.cut", "Cut", "Menu item, ⌘X.") }
        public static var copy: String { s("command.copy", "Copy", "Menu item, ⌘C.") }
        public static var paste: String { s("command.paste", "Paste", "Menu item, ⌘V.") }
        public static var selectAll: String { s("command.selectAll", "Select All", "Menu item, ⌘A.") }
        public static var findBurst: String { s("command.findBurst", "Find Burst…", "Menu item, ⌘F.") }
        public static var emoji: String { s("command.emoji", "Emoji & Symbols", "The system item.") }
        public static var dictation: String { s("command.dictation", "Start Dictation", "The system item.") }
    }

    // MARK: Edit ▸ Find Burst…

    public enum FindBurst {
        public static var title: String {
            s("findBurst.title", "Find Burst", "The sheet ⌘F opens over the light table.")
        }
        public static func range(_ bursts: Int) -> String {
            String(localized: "findBurst.range", defaultValue: "Type a burst number, 1 to \(bursts).",
                   comment: "Under the sheet's title. Going there records nothing.")
        }
        public static var placeholder: String {
            s("findBurst.placeholder", "Burst number", "The field in the sheet.")
        }
        public static var go: String { s("findBurst.go", "Go", "The sheet's default button, Return.") }
        public static var cancel: String { s("findBurst.cancel", "Cancel", "The sheet's other button, Escape.") }
    }

    // MARK: Frame

    public enum Frame {
        public static var keep: String { s("command.keep", "Keep", "Menu item, E (or K). Never abbreviated.") }
        public static var drop: String { s("command.drop", "Drop", "Menu item, D.") }
        public static var clearMark: String {
            s("command.clearMark", "Clear the Mark", "Menu item, X (or 0). Not the same as writing a zero.")
        }
        public static var whyItIsOut: String {
            s("command.whyItIsOut", "Why It Is Out", "A submenu of the six nameable faults.")
        }
        public static var compare: String {
            s("command.compare", "Compare Similar Frames", "Menu item, C.")
        }
        public static var keepOnly: String {
            s("command.keepOnly", "Keep Only This One", "Menu item, ⇧E (or ⇧K). Drops the rest of the stack.")
        }
        public static var nextFrame: String { s("command.nextFrame", "Next Frame", "Menu item, F (or →).") }
        public static var previousFrame: String {
            s("command.previousFrame", "Previous Frame", "Menu item, S (or ←).")
        }
        public static var nextForward: String {
            s("command.nextForward", "Next Frame the Cull Put Forward", "Menu item, ↓. The machine's shortlist.")
        }
        public static var previousForward: String {
            s("command.previousForward", "Previous Frame the Cull Put Forward", "Menu item, ↑.")
        }
        public static var finishBurst: String {
            s("command.finishBurst", "Next Burst",
              "Menu item, R (or N). The same words as the button under the picture.")
        }
        public static var finishBurstHelp: String {
            s("command.finishBurstHelp", "Marks this burst as looked through and opens the next one.",
              "The help tag on Next Burst. Leaving a burst forward is what records it as looked through.")
        }
        public static var previousBurst: String {
            s("command.previousBurst", "Previous Burst", "Menu item, W (or P).")
        }
        public static var showInFinder: String {
            s("command.showFrameInFinder", "Show in Finder", "Menu item, ⇧⌥⌘R. This frame's own file.")
        }
        public static var copyNumber: String {
            s("command.copyNumber", "Copy Frame Number", "Menu item, ⌥⌘C.")
        }
    }

    // MARK: View

    public enum View {
        public static var single: String { s("command.single", "Single Frame", "Menu item; Esc or Return from All Bursts.") }
        public static var compare: String { s("command.viewCompare", "Compare", "Menu item, C.") }
        public static var allBursts: String { s("command.allBursts", "All Bursts", "Menu item, G.") }
        public static var fullImage: String {
            s("command.fullImage", "Full Image", "Menu item, Space. The whole photograph, nothing else.")
        }
        public static var enterFullScreen: String {
            s("command.enterFullScreen", "Enter Full Screen", "Menu item, ⌃⌘F.")
        }
        public static var actualSize: String {
            s("command.actualSize", "Actual Size (1:1)", "Menu item, ⌘0.")
        }
        public static var zoomToFit: String { s("command.zoomToFit", "Zoom to Fit", "Menu item, ⌘9.") }
        public static var zoomIn: String { s("command.zoomIn", "Zoom In", "Menu item, ⌘+.") }
        public static var zoomOut: String { s("command.zoomOut", "Zoom Out", "Menu item, ⌘−.") }
        public static var showSidebar: String {
            s("command.showSidebar", "Show Sidebar", "Menu item, ⌃⌘S, while it is hidden.")
        }
        public static var hideSidebar: String {
            s("command.hideSidebar", "Hide Sidebar", "The same item while it is shown.")
        }
        public static var showInspector: String {
            s("command.showInspector", "Show Inspector", "Menu item, ⌥⌘I, while it is hidden.")
        }
        public static var hideInspector: String {
            s("command.hideInspector", "Hide Inspector", "The same item while it is shown.")
        }
        public static var viewerBackground: String {
            s("command.viewerBackground", "Viewer Background",
              "A submenu. A photographer judges tone against a known surround.")
        }
        public static var neutralGrey: String {
            s("command.neutralGrey", "Neutral Gray", "Viewer Background, the default.")
        }
        public static var matchTheSystem: String {
            s("command.matchTheSystem", "Match the Mac", "Viewer Background. The same words as Appearance's.")
        }
        public static var black: String { s("command.black", "Black", "Viewer Background.") }
    }

    // MARK: Go

    public enum Go {
        public static var allShoots: String { s("command.goAllShoots", "All Shoots", "Menu item, ⇧⌘0.") }
        public static var learned: String {
            s("command.goLearned", "What the Cull Has Learned", "Menu item, ⇧⌘L.")
        }
        public static var storage: String { s("command.goStorage", "Storage", "Menu item, ⇧⌘S: the library's Storage page.") }
        public static var nextStep: String { s("command.nextStep", "Next Step", "Menu item, ⌘].") }
        public static var previousStep: String {
            s("command.previousStep", "Previous Step", "Menu item, ⌘[.")
        }
        public static var resume: String {
            s("command.resume", "Back to Where I Left Off", "Menu item, ⌘J.")
        }
    }

    // MARK: Shoot

    public enum Shoot {
        public static var cull: String { s("command.cull", "Cull It", "Menu item, ⌘R.") }
        public static var cullAgain: String {
            s("command.cullAgain", "Cull Again…", "Menu item. Replaces the machine's own work.")
        }
        public static var writePresets: String {
            s("command.writePresets", "Write the Presets", "Menu item.")
        }
        public static var writePresetsAgain: String {
            s("command.writePresetsAgain", "Write the Presets Again…",
              "Write the Presets once they are written: the Presets page's Write Them Again…, which asks first.")
        }
        public static var openInEditor: String {
            s("command.openInEditor", "Open My Keepers in PhotoLab", "Menu item, ⇧⌘E.")
        }
        public static var cutAReel: String { s("command.cutAReel", "Cut a Reel", "Menu item.") }
        public static var finished: String {
            s("command.finished", "Finish This Shoot", "Menu item. The same words as the Finish page's button.")
        }
        public static var stopJob: String { s("command.stopJob", "Stop What Is Running", "Menu item, ⌘.") }
        public static var storage: String { s("command.storage", "Storage", "A submenu.") }
        public static var copyUp: String {
            s("command.copyUp", "Copy the RAWs to iCloud…", "Storage submenu.")
        }
        public static var bringBack: String {
            s("command.bringBack", "Bring the RAWs Back…", "Storage submenu.")
        }
        public static var checkEvery: String {
            s("command.checkEvery", "Check Every Original", "Storage submenu.")
        }
        public static var takeBackCache: String {
            s("command.takeBackCache", "Take Back the Cache…", "Storage submenu.")
        }
        public static var removeLocal: String {
            s("command.removeLocal", "Remove the Local RAWs…",
              "Storage submenu, in its own section at the bottom. Removes a copy, keeps a checked one.")
        }
        public static var letGo: String {
            s("command.letGo", "Let Go of the RAWs in iCloud…",
              "Storage submenu, in its own section at the bottom. The one that cannot be undone.")
        }
    }

    // MARK: Window

    public enum Window {
        public static var minimize: String { s("command.minimize", "Minimize", "Menu item, ⌘M.") }
        public static var zoom: String { s("command.zoom", "Zoom", "Menu item.") }
        public static var fill: String { s("command.fill", "Fill", "Menu item. The window fills the screen.") }
        public static var centre: String { s("command.centre", "Center", "Menu item.") }
        public static var activity: String { s("command.activity", "Activity", "Menu item, ⌥⌘L.") }
        public static var bringAllToFront: String {
            s("command.bringAllToFront", "Bring All to Front", "Menu item.")
        }
    }

    // MARK: Help

    public enum Help {
        public static var appHelp: String { s("command.appHelp", "First Edit Help", "Menu item.") }
        public static var shortcuts: String {
            s("command.shortcuts", "Keyboard Shortcuts", "Menu item, ⌘/. Opens a real window, not a sheet.")
        }
        public static var showLog: String { s("command.showLog", "Show the Log", "Menu item.") }
        public static var report: String {
            s("command.report", "Report a Problem…", "Menu item.")
        }
    }

    // MARK: the Shortcuts window

    public enum Shortcuts {
        public static var title: String {
            s("shortcuts.title", "Keyboard Shortcuts", "The window's title.")
        }
        public static var search: String { s("shortcuts.search", "Search", "The search field.") }
        public static var print: String { s("shortcuts.print", "Print", "Button.") }
        public static var moving: String {
            s("shortcuts.moving", "Moving Around", "A group of shortcuts.")
        }
        public static var deciding: String {
            s("shortcuts.deciding", "Deciding", "A group of shortcuts.")
        }
        public static var looking: String {
            s("shortcuts.looking", "Looking Closer", "A group of shortcuts.")
        }
        public static var everything: String {
            s("shortcuts.everything", "Everything Else", "A group of shortcuts.")
        }
        public static var everywhere: String {
            s("shortcuts.everywhere", "The Same on Every Page With Photographs",
              "The first group of shortcuts: the keys Choose Keepers, Instagram, Reels and the viewer share.")
        }
        public static var nothingFound: String {
            s("shortcuts.nothingFound", "No shortcut by that name", "The search found nothing.")
        }
        public static var tryAnother: String {
            s("shortcuts.tryAnother", "Try the name of the action, or the key itself.",
              "Under the empty search result.")
        }
        public static var noKey: String {
            s("shortcuts.noKey", "no key", "An action reachable only from a menu or a click.")
        }
        /// Keys that do the same thing, for a help tag: `E or K`,
        /// `⌘Z, Q or U`.
        public static func either(_ keys: [String]) -> String {
            guard let last = keys.last else { return "" }
            guard keys.count > 1 else { return last }
            let rest = keys.dropLast().joined(separator: ", ")
            return String(localized: "shortcuts.either", defaultValue: "\(rest) or \(last)",
                          comment: "Two or more keys that do the same thing, in a help tag.")
        }
        public static func orPlain(_ key: String) -> String {
            String(localized: "shortcuts.orPlain", defaultValue: "or \(key)",
                   comment: "A second way to reach the same thing, such as ? for ⌘/.")
        }
        public static var footer: String {
            s("shortcuts.footer",
              "A key does the same on every page with photographs, and nothing while you are typing.",
              "A line at the bottom of the window.")
        }
        public static var noShortcut: String {
            s("shortcuts.noShortcut", "No shortcut. Nothing that deletes photographs has one.",
              "A help tag on a destructive menu item.")
        }
    }

    // MARK: spoken

    public enum Spoken {
        public static var keep: String {
            s("a11y.keep", "Keep", "The VoiceOver name of the Keep action on a frame.")
        }
        public static var drop: String { s("a11y.drop", "Drop", "The VoiceOver name of the Drop action.") }
        public static var clearMark: String {
            s("a11y.clearMark", "Clear the Mark", "A VoiceOver custom action on a frame.")
        }
        public static var compare: String {
            s("a11y.compare", "Compare", "A VoiceOver custom action on a frame.")
        }
        public static func frame(_ number: String) -> String {
            String(localized: "a11y.frame", defaultValue: "Frame \(number)",
                   comment: "The first clause of a frame's spoken description.")
        }
        public static func positionInBurst(_ n: Int, _ of: Int, _ burst: Int) -> String {
            String(localized: "a11y.positionInBurst", defaultValue: "\(n) of \(of) in burst \(burst)",
                   comment: "Where the frame sits. Spoken after the frame number.")
        }
        public static var youKept: String {
            s("a11y.youKept", "You kept it.", "His verdict, spoken. Never the cull's.")
        }
        public static var youPutOut: String { s("a11y.youPutOut", "You put it out.", "His verdict, spoken.") }
        public static var unmarked: String {
            s("a11y.unmarked", "You haven't marked it.", "No verdict of his on this frame.")
        }
        public static func cullGuess(_ words: String) -> String {
            String(localized: "a11y.cullGuess", defaultValue: "The cull's guess: \(words)",
                   comment: "The machine's opinion, spoken, always named as the cull's.")
        }
        public static func inStack(_ n: Int) -> String {
            String(localized: "a11y.inStack", defaultValue: "In a stack of \(n) similar frames.",
                   comment: "Spoken last.")
        }
        public static func jobStarted(_ what: String) -> String {
            String(localized: "a11y.jobStarted", defaultValue: "\(what) started",
                   comment: "Announced politely at the start of a long job, and not again until it ends.")
        }
        public static func jobFinished(_ what: String) -> String {
            String(localized: "a11y.jobFinished", defaultValue: "\(what) finished",
                   comment: "Announced politely when a long job ends.")
        }
    }

    // MARK: the Dock and notifications

    public enum Dock {
        /// "Cull · 2026-09-19 — 38%": the app's word for the work, the shoot
        /// once, and how far, with no space before the sign, as US English
        /// writes it. It was the engine's "culling 2026-09-19 — 38 %".
        public static func running(_ what: String, shoot: String, percent: Int) -> String {
            shoot.isEmpty
                ? String(localized: "dock.running", defaultValue: "\(what) — \(percent)%",
                         comment: "The Dock menu's first line while a job runs.")
                : String(localized: "dock.runningIn", defaultValue: "\(what) · \(shoot) — \(percent)%",
                         comment: "The Dock menu's first line while a job on a shoot runs.")
        }
    }

    public enum Notify {
        public static func finished(_ what: String) -> String {
            String(localized: "notify.finished", defaultValue: "\(what) finished",
                   comment: "A notification's title when a job ends and the window is not in front. The shoot is the subtitle.")
        }
        public static func failed(_ what: String) -> String {
            String(localized: "notify.failed", defaultValue: "\(what) failed",
                   comment: "A notification's title when a job crashed. The shoot is the subtitle.")
        }
        public static func stopped(_ what: String) -> String {
            String(localized: "notify.stopped", defaultValue: "\(what) stopped",
                   comment: "A notification's title when he stopped a job. The shoot is the subtitle.")
        }
        /// A card copy that ended part way: pulled out, no room, a failed
        /// check. Not "failed" and not "stopped", which is what he did.
        public static func didNotFinish(_ what: String) -> String {
            String(localized: "notify.didNotFinish", defaultValue: "\(what) did not finish",
                   comment: "A notification's title when a card copy ended part way. The shoot is the subtitle.")
        }
        /// Said no on purpose, with its sentence as the body: not a failure,
        /// and the list's own word for it is "refused".
        public static func refused(_ what: String) -> String {
            String(localized: "notify.refusedTitle", defaultValue: "\(what) did not run",
                   comment: "A notification's title when a plan refused on purpose. Its sentence is the body.")
        }
        public static var failedBody: String {
            s("notify.failedBody", "Something went wrong. Click to see the log in Activity.",
              "A notification's body after a job crashed. Clicking it opens the Activity window.")
        }
        public static var copyFailedBody: String {
            s("notify.copyFailedBody", "It stopped part way. Click to see what reached the shoot and why.",
              "A notification's body after a card copy ended part way. Clicking it opens the card's page.")
        }
        public static var stoppedBody: String {
            s("notify.stoppedBody", "What it had already done stays.",
              "A notification's body after a job was stopped.")
        }
        public static func culled(_ forward: Int, of: Int) -> String {
            String(localized: "notify.culled", defaultValue: "\(forward) of \(of) frames put forward.",
                   comment: "A notification's body after a cull. The cull's number, named as the cull's.")
        }
        public static var refusedBody: String {
            s("notify.refused", "It stopped and said why. Open Activity to read it.",
              "A notification's body after a plan that refused on purpose.")
        }
    }
}
