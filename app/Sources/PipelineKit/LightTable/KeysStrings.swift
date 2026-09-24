import Foundation

/// What the light table says about its keys: the strip after D, and the lines
/// that tell him which key does what (DESIGN.md §2.5.3, §2.13).
///
/// The same rules as `LightTableStrings.swift`: his words, never the machine's
/// in his voice, nothing from the retired list.
extension Strings.LightTable {

    // MARK: - the strip after D (§2.5.3)

    /// `04328 is out. Why?` — the frame it asks about, by the number he reads
    /// off the camera, because D has already moved him on to the next one.
    public static func reasonPromptFor(_ frame: String) -> String {
        String(localized: "lt.reasonPromptFor", defaultValue: "\(frame) is out. Why?",
               comment: "Shown for three seconds after D. The number is the frame D put out, not the one now on screen.")
    }

    /// `4 blur` — one button, the key and the word together.
    public static func reasonButton(_ key: Int, _ word: String) -> String {
        String(localized: "lt.reasonButton", defaultValue: "\(key) \(word)",
               comment: "One button on the strip after D: the digit that gives this reason, and the reason.")
    }

    public static var reasonOptional: String {
        String(localized: "lt.reasonOptional",
               defaultValue: "Optional. A reason helps the cull spot this fault.",
               comment: "Help tag on the strip after D.")
    }

    // MARK: - Compare (§2.5.12)

    /// `Compare 2 frames · E keep · D drop · ⇧E keep only this one` — frames he
    /// picked himself, which the cull never said were alike. The left hand's
    /// keys, as the menus show them (§2.5.3).
    public static func comparePicked(_ n: Int) -> String {
        String(localized: "lt.comparePicked",
               defaultValue: "Compare \(n) frames · E keep · D drop · ⇧E keep only this one",
               comment: "The header of Compare on frames he ⌘-clicked, not a stack the cull found.")
    }

    /// Under the picture while he is ⌘-clicking frames to compare.
    public static func pickedForCompare(_ n: Int) -> String {
        n < 2
            ? String(localized: "lt.pickedOne", defaultValue: "1 picked · ⌘-click another to compare · Esc clears",
                     comment: "One frame ⌘-clicked in the filmstrip; Compare needs two.")
            : String(localized: "lt.pickedMany", defaultValue: "\(n) picked · C compares them · Esc clears",
                     comment: "Frames ⌘-clicked in the filmstrip, waiting for C.")
    }

    // MARK: - his reason, as his (§2.13)

    /// `you put this out — shadow`: the reason he gave, in his line, never the
    /// cull's.
    public static func youPutOutBecause(_ reason: String) -> String {
        String(localized: "lt.youPutOutBecause", defaultValue: "you put this out — \(reason)",
               comment: "His verdict with the reason he gave. Never shown as the cull's.")
    }

    // MARK: - the end of a burst (§2.5.2)

    /// The line on the last frame of a burst. F and R go on, the left hand's
    /// keys, and → and N — the ones he learned first — still do; the line
    /// says all four, the left hand's first (§2.5.3).
    public static func endOfBurstGoOn(_ n: Int, kept: Int, out: Int, unmarked: Int) -> String {
        // Every frame marked: no "0 you haven't marked" to read past.
        unmarked == 0
            ? String(localized: "lt.endOfBurstAllMarked",
                     defaultValue: "End of burst \(n) — \(kept) kept, \(out) out. Next burst: F or R (→, N)",
                     comment: "The line on the last frame of a burst he marked every frame of.")
            : String(localized: "lt.endOfBurstGoOn",
                     defaultValue: "End of burst \(n) — \(kept) kept, \(out) out, \(unmarked) you haven't marked. Next burst: F or R (→, N)",
                     comment: "A quiet line on the last frame of a burst. All four keys finish the burst and open the next.")
    }

    /// The same line in a burst he has already been through, in the tally's
    /// words.
    public static func endOfBurstAgreed(_ n: Int, kept: Int, out: Int, agreed: Int) -> String {
        String(localized: "lt.endOfBurstAgreed",
               defaultValue: "End of burst \(n) — \(kept) kept, \(out) out, \(agreed) agreed. Next burst: F or R (→, N)",
               comment: "The line on the last frame of a burst he has been through before.")
    }

    /// The link on that line, in a burst he has not been through: to the
    /// first frame he left unmarked, counted, so sixteen frames are never
    /// "the one".
    public static func goToUnmarked(_ count: Int) -> String {
        count == 1
            ? String(localized: "lt.goToTheUnmarked", defaultValue: "Go to the one you haven't marked (↓)",
                     comment: "The end-of-burst link when one frame of the burst is unmarked.")
            : String(localized: "lt.goToFirstUnmarked", defaultValue: "Go to the first you haven't marked (↓)",
                     comment: "The end-of-burst link when several frames of the burst are unmarked.")
    }

    /// `Kept 5 · Out 1 · 1 agreed` — a burst he has been through, where a
    /// frame he left alone is the cull's call agreed, not work to go.
    public static func tallyAgreed(kept: Int, out: Int, agreed: Int) -> String {
        String(localized: "lt.tallyAgreed", defaultValue: "Kept \(kept) · Out \(out) · \(agreed) agreed",
               comment: "The tally in a burst he has been through. His presses, and the frames he left to the cull.")
    }


    // MARK: - the toolbar's modes (§2.3)

    /// `Compare (C)` — a segment's help tag, which is its only name.
    public static func modeHelp(_ mode: String, key: String) -> String {
        String(localized: "lt.modeHelp", defaultValue: "\(mode) (\(key))",
               comment: "Help tag on one segment of the toolbar's mode picker: the mode and its key.")
    }

    public static var compareNothingHere: String {
        String(localized: "lt.compareNothingHere",
               defaultValue: "Compare (C) — this frame is in no stack. ⌘-click frames in the filmstrip to compare them.",
               comment: "Help tag on the Compare segment when there is nothing to compare from here.")
    }

    /// What VoiceOver calls the picker as a whole.
    public static var viewModes: String {
        String(localized: "lt.viewModes", defaultValue: "View", comment: "The toolbar's mode picker, as a whole.")
    }
}
