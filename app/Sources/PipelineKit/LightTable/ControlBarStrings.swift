import Foundation

/// What the control bar says about its own buttons (DESIGN.md §2.5.2).
///
/// The same rules as `LightTableStrings.swift`: his words, never the machine's
/// in his voice, nothing from the retired list.
extension Strings.LightTable {

    /// The bar's name to VoiceOver, said before its first button.
    public static var frameControls: String {
        String(localized: "lt.frameControls", defaultValue: "Frame controls",
               comment: "VoiceOver's name for the control bar under the photograph: Undo, the arrows, Drop, Keep, Compare and Next Burst.")
    }

    // MARK: - the step arrows, which cross bursts as S and F do

    /// Each of these is a help tag's words; its keys follow in brackets, read
    /// from the menu bar's table (`LightTableKeys`), so the tag names the
    /// left hand's key first and the arrow after it.
    public static var previousFrameHelp: String {
        String(localized: "lt.previousFrameHelp", defaultValue: "Previous frame",
               comment: "Help tag on the control bar's left chevron, before its keys.")
    }

    /// On the first frame of a burst: S or ← goes back to the last frame of
    /// the burst before, and writes nothing.
    public static var previousBurstEndHelp: String {
        String(localized: "lt.previousBurstEndHelp",
               defaultValue: "Last frame of the burst before",
               comment: "Help tag on the control bar's left chevron on the first frame of a burst, before its keys.")
    }

    public static var nextFrameHelp: String {
        String(localized: "lt.nextFrameHelp", defaultValue: "Next frame",
               comment: "Help tag on the control bar's right chevron, before its keys.")
    }

    /// On the last frame of a burst: F or → goes on into the next, and
    /// finishes this one exactly as R does, so it says so and names both.
    public static var nextFrameFinishesHelp: String {
        String(localized: "lt.nextFrameFinishesHelp",
               defaultValue: "Finish this burst and open the next",
               comment: "Help tag on the control bar's right chevron on the last frame of a burst, before its keys. It records the burst as been through, as R does.")
    }
    public static var nextFrameFinishesLastHelp: String {
        String(localized: "lt.nextFrameFinishesLastHelp", defaultValue: "Finish this burst, the last",
               comment: "› on the last frame of the last burst, before it is finished: there is no next to open.")
    }

    // MARK: - Compare, on the frames he picked

    /// The Compare button's help tag once he has ⌘-clicked two or more frames
    /// in the strip: C opens those, not the stack.
    public static var comparePickedHelp: String {
        String(localized: "lt.comparePickedHelp", defaultValue: "Compare the frames you picked (C)",
               comment: "Help tag on the Compare button in the control bar after he has ⌘-clicked two or more frames in the filmstrip.")
    }

    // MARK: - Next Burst, on the last burst

    /// Next Burst's title on the last burst, where there is no next one and
    /// what comes next is Presets. Continue to Presets, the line's own link,
    /// is wider than the button.
    public static var onToPresets: String {
        String(localized: "lt.onToPresets", defaultValue: "On to Presets",
               comment: "The control bar's Next Burst button on the shoot's last burst. It records the burst as looked through, if it is not yet, and opens Presets.")
    }

    public static var onToPresetsHelp: String {
        String(localized: "lt.onToPresetsHelp",
               defaultValue: "Finishes this last burst, if you haven't, and goes on to Presets. Frames you didn't press a key on keep the cull's call, marked as agreed — not as yours.",
               comment: "Help tag on the Next Burst button on the last burst.")
    }

    // MARK: - the caption beside the cluster

    /// `04330 · burst 3`: the frame and the burst. Where he is in the burst is
    /// the frame label's, between Drop and Keep.
    public static func barCaption(_ frame: String, burst: Int) -> String {
        String(localized: "lt.barCaption", defaultValue: "\(frame) · burst \(burst)",
               comment: "The control bar's leading caption: the frame's number, then the burst it is in.")
    }
}
