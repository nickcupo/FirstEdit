import Foundation

/// Every SF Symbol name the design fixes (§2.1, §2.4, §2.5, §2.9), so a symbol
/// is changed in one place and a test can check each one exists.
public enum Symbols {
    // §2.1 sidebar
    public static let allShoots = "photo.on.rectangle.angled"
    public static let learned = "graduationcap"
    public static let storage = "externaldrive"
    public static let memoryCard = "sdcard.fill"
    public static let eject = "eject.fill"
    public static let shootInProgress = "photo.stack"
    public static let shootFinished = "photo.badge.checkmark"
    public static let update = "arrow.down.circle"
    public static let extensionStep = "puzzlepiece.extension"
    public static let brokenShoot = "exclamationmark.triangle.fill"

    // §2.4 steps, keyed by the engine's own step ids.
    public static let stepIngest = "sdcard"
    public static let stepCull = "line.3.horizontal.decrease.circle"
    public static let stepKeepers = "checkmark.rectangle.stack"
    public static let stepPresets = "slider.horizontal.3"
    public static let stepEdit = "arrow.up.forward.app"
    public static let stepInstagram = "crop"
    public static let stepReels = "film"
    public static let stepDone = "flag.checkered"

    public static func step(_ id: String) -> String {
        switch id {
        case "ingest": return stepIngest
        case "cull": return stepCull
        case "keepers": return stepKeepers
        case "presets": return stepPresets
        case "edit": return stepEdit
        case "instagram": return stepInstagram
        case "reels": return stepReels
        case "done": return stepDone
        default: return extensionStep
        }
    }

    // §2.3 toolbar
    public static let single = "rectangle"
    public static let compare = "rectangle.split.2x1"
    public static let allBursts = "square.grid.2x2"
    public static let inspector = "sidebar.trailing"

    // §2.5.2 control bar
    public static let undo = "arrow.uturn.backward"
    public static let previous = "chevron.left"
    public static let next = "chevron.right"
    public static let drop = "xmark"
    public static let keep = "checkmark"
    public static let nextBurst = "forward.end.fill"
    public static let fullImage = "arrow.up.left.and.arrow.down.right"

    // §2.5.9 marks. His are filled; the machine's are outlines; never shared.
    public static let hisKeep = "checkmark.circle.fill"
    public static let hisDrop = "xmark.circle.fill"
    public static let cullForward = "circle"
    public static let cullAside = "circle.dotted"
    public static let cullFault = "exclamationmark.triangle"
    public static let agreed = "checkmark.circle"
    /// Agreed on a frame the cull set aside: it stays out, and says so.
    public static let agreedOut = "xmark.circle"
    /// The other screen holding a frame while the laptop moves on.
    public static let hold = "pin.fill"
    /// Under the Compare tile the cull's focus figure puts first (§2.5.12).
    /// A measure, not a mark of his or the cull's call: neither a circle nor
    /// a check.
    public static let sharpest = "scope"

    // §2.9 learner status: always a symbol and a word, never colour alone.
    public static let inUse = "checkmark.circle.fill"
    public static let notInUse = "pause.circle.fill"
    public static let notEnough = "hourglass"
    public static let couldNotCheck = "exclamationmark.triangle.fill"
    public static let learnNow = "arrow.triangle.2.circlepath"
    public static let more = "ellipsis.circle"

    // Shell
    public static let engineDown = "exclamationmark.triangle"
    public static let refusal = "exclamationmark.circle"
    public static let activity = "list.bullet.rectangle"
    /// A new library folder, waiting for a job to end.
    public static let restartWaiting = "clock.arrow.circlepath"

    /// Every name above, for the test that asks the system for each one.
    public static let all: [String] = [
        allShoots, learned, storage, memoryCard, eject, shootInProgress, shootFinished, update,
        extensionStep, brokenShoot, stepIngest, stepCull, stepKeepers, stepPresets, stepEdit,
        stepInstagram, stepReels, stepDone, single, compare, allBursts, inspector, undo, previous, next, drop,
        keep, nextBurst, fullImage, hisKeep, hisDrop, cullForward, cullAside, cullFault, agreed,
        agreedOut, hold, inUse, notInUse, notEnough, couldNotCheck, learnNow, more, engineDown, refusal,
        activity, restartWaiting,
        sharpest,
    ]
}
