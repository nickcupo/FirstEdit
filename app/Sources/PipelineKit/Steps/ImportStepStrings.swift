import Foundation

// What Copy the Card says about a card and a copy that outlive the page
// (DESIGN.md §2.6). The page's own form words are with the other steps' in
// `StepStrings.swift`; these are the sentences the app-wide `ImportModel`
// and the page's endings say.
extension Strings.Import {

    private static func t(_ key: String, _ value: String, _ comment: String) -> String {
        Bundle.main.localizedString(forKey: key, value: value, table: nil)
    }

    public static func cardIsIn(_ card: String) -> String {
        String(localized: "import.cardIsIn", defaultValue: "\(card) is in. ⌘N to copy it.",
               comment: "The line at the top of the window when a card goes in and the sidebar is hidden. ⌘N opens the card's page; the copy is still his press there.")
    }

    public static var openTheCard: String {
        t("import.openTheCard", "Opens the card's page.", "Help on the line about a card at the top of the window.")
    }

    // MARK: the name

    public static func nameHint(_ day: String) -> String {
        String(localized: "import.nameHint", defaultValue: "Add what it was if you like: \(day)-lake.",
               comment: "Under the name field, in the muted colour, while it holds the card's date.")
    }
    public static func nameHintTaken(_ day: String) -> String {
        String(localized: "import.nameHintTaken",
               defaultValue: "\(day) is already in your library. Add what this one was: \(day)-lake.",
               comment: "Under the name field, in the muted colour, when a shoot of the card's day exists.")
    }
    public static var nameStart: String {
        t("import.nameStart", "Start with a letter or a number.",
          "Under the name field. The engine refuses a name that starts with a dot or a dash.")
    }

    // MARK: the button

    public static func copyCount(_ n: Int) -> String {
        n == 1
            ? t("import.copyOne", "Copy 1 Frame", "The primary, when the card holds one.")
            : String(localized: "import.copyCount", defaultValue: "Copy \(n) Frames",
                     comment: "The primary, when the count is known.")
    }

    // MARK: while it copies

    public static var cardCameOutRunning: String {
        t("import.cardCameOutRunning", "The card came out. The copy stops at the next frame.",
          "Red, beside the bar, when the card is pulled while it copies.")
    }

    // MARK: into a shoot that exists

    public static var copyInto: String { t("import.copyInto", "Copy into", "A picker: a new shoot, or one already in the library.") }
    public static var aNewShoot: String { t("import.aNewShoot", "A new shoot", "In the Copy into picker.") }
    public static func finishInto(_ shoot: String) -> String {
        String(localized: "import.finishInto", defaultValue: "\(shoot), to finish the copy",
               comment: "In the Copy into picker: the shoot a copy of this card stopped part way into.")
    }
    public static func addToBeingCulled(_ shoot: String) -> String {
        String(localized: "import.addToBeingCulled", defaultValue: "\(shoot), being culled now",
               comment: "In the Copy into picker: a shoot of the card's day whose cull is running.")
    }
    public static func beingCulledNote(_ shoot: String) -> String {
        String(localized: "import.beingCulledNote",
               defaultValue: "\(shoot) is being culled now, so a card is not added to it. Stop its cull in Activity to add this one, or copy it into a new shoot.",
               comment: "Under the picker, with a shoot being culled chosen. Copy waits.")
    }
    public static var finishTheCopy: String {
        t("import.finishTheCopy", "Finish the Copy", "The primary, finishing a copy that stopped once every file had arrived.")
    }
    public static func addTo(_ shoot: String) -> String {
        String(localized: "import.addTo", defaultValue: "\(shoot), adding this card",
               comment: "In the Copy into picker: a shoot of the card's day that has not been culled.")
    }
    public static func finishNote(_ shoot: String) -> String {
        String(localized: "import.finishNote",
               defaultValue: "Only what did not reach \(shoot) is copied. What did stays exactly as it is.",
               comment: "Under the picker, finishing a copy that stopped.")
    }
    public static func addNote(_ shoot: String) -> String {
        String(localized: "import.addNote",
               defaultValue: "Its frames join \(shoot). Nothing already in it is changed, and a frame that shares a name with one there is kept beside it.",
               comment: "Under the picker, adding a second card to a shoot.")
    }
    public static func finishCopying(_ n: Int) -> String {
        n == 1
            ? t("import.finishCopyingOne", "Finish Copying 1 Frame", "The primary, finishing a copy that stopped.")
            : String(localized: "import.finishCopying", defaultValue: "Finish Copying \(n) Frames",
                     comment: "The primary, finishing a copy that stopped: the frames that did not arrive.")
    }
    public static func addCount(_ n: Int) -> String {
        n == 1
            ? t("import.addOne", "Add 1 Frame", "The primary, adding a card to a shoot.")
            : String(localized: "import.addCount", defaultValue: "Add \(n) Frames",
                     comment: "The primary, adding a card to a shoot.")
    }
    /// A card copied into the shoot before the last one, by its own log:
    /// finished, or the red sentence of one that did not finish.
    public static func earlier(_ c: EarlierCopy) -> String {
        switch c.state {
        case "done": return earlierCard(c.files, proof: c.proof)
        case "stopped":
            return String(localized: "import.earlierStopped",
                          defaultValue: "Before it, another card's copy stopped after \(c.files) of \(c.of) frames. Put that card back to finish it.",
                          comment: "Red, under the copy's sentence: an earlier card's copy into the shoot did not finish.")
        case "failed":
            return t("import.earlierFailed",
                     "Before it, another card's copy FAILED its check. Put that card back to finish it.",
                     "Red, under the copy's sentence: an earlier card's copy into the shoot was not proved.")
        default:
            return t("import.earlierUnclear",
                     "Before it, another card's copy ended in a way its log does not say. Put that card back to finish it.",
                     "Red, under the copy's sentence: an earlier card's copy into the shoot ended unreadably.")
        }
    }
    /// A card copied into the shoot before the last one, by its own log.
    public static func earlierCard(_ files: Int, proof: String) -> String {
        proof.isEmpty
            ? String(localized: "import.earlierCardNoProof", defaultValue: "Before it, another card: \(files) frames copied.",
                     comment: "Under the copy's sentence, for a shoot a second card was added to.")
            : String(localized: "import.earlierCard", defaultValue: "Before it, another card: \(files) frames copied, \(proof).",
                     comment: "Under the copy's sentence, for a shoot a second card was added to. The proof is the copy's own words.")
    }
    // MARK: the cull that follows it

    /// `asLast` only when a shoot here has been culled: with none, the cull
    /// starts on 1.9 and off, and "as your last shoot" named nothing.
    public static func cullFollows(asLast: Bool) -> String {
        asLast
            ? t("import.cullFollows", "When the copy is done, the cull starts by itself, set as your last shoot was culled.",
                "Beside the Copy button and while it copies. A copy that does not finish is followed by nothing.")
            : t("import.cullFollowsFirst", "When the copy is done, the cull starts by itself.",
                "Beside the Copy button and while it copies, before any shoot has been culled.")
    }
    public static var cullRunning: String {
        t("import.cullRunning", "Its cull has started by itself.", "After a copy, while the cull that followed it runs.")
    }
    public static var cullWaiting: String {
        t("import.cullWaiting", "Its cull is in Up Next and starts by itself.",
          "After a copy, while the cull that follows it waits behind other work.")
    }

    // MARK: after it

    public static func onToCull(_ shoot: String) -> String {
        String(localized: "import.onToCull", defaultValue: "Cull \(shoot) ›",
               comment: "The primary after a copy: goes to the new shoot's Cull step, where the cull that started by itself is.")
    }
    public static var copiedTo: String { t("import.copiedTo", "Copied to", "A row with the new shoot's folder.") }
    public static func copiedInto(_ shoot: String) -> String {
        String(localized: "import.copiedInto", defaultValue: "The card was copied into \(shoot).",
               comment: "After a copy, before the library has said how it was checked.")
    }
    public static func didNotFinish(_ shoot: String) -> String {
        String(localized: "import.didNotFinish", defaultValue: "The copy into \(shoot) did not finish.",
               comment: "Red. A copy that ended without its own sentence.")
    }
    public static var cardCameOut: String {
        t("import.cardCameOut", "The card came out before the copy finished.", "Under the copy's own sentence.")
    }
    public static var youStopped: String {
        t("import.youStopped", "You stopped the copy.", "Under the copy's own sentence.")
    }
    public static var engineStopped: String {
        t("import.engineStopped", "The engine stopped while it copied.",
          "Under the copy's own sentence, when the engine restarted during the copy and the app did not see it end.")
    }
    public static var canComeOut: String {
        t("import.canComeOut", "The card can come out.",
          "The body of the notification when a copy of the card finished and the window is not in front.")
    }
    public static var putItBack: String {
        t("import.putItBack", "Put the card back in to copy it again.", "After a copy the card left early.")
    }
    public static func againNeedsANewName(_ shoot: String) -> String {
        String(localized: "import.againNeedsANewName",
               defaultValue: "Copying it again needs a new name. What already reached \(shoot) stays there.",
               comment: "After a copy that did not finish, above the form for the same card.")
    }
    /// A line for the top of the window: "2026-09-23-night: 1,558 frames
    /// copied, verified byte for byte, both sides."
    public static func about(_ shoot: String, _ sentence: String) -> String {
        String(localized: "import.about", defaultValue: "\(shoot): \(sentence)",
               comment: "The line at the top of the window when a copy ends while he is elsewhere. The sentence is the copy's own.")
    }
}
