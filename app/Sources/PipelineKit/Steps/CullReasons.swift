import Foundation

/// What the cull said, recognised from the engine's own words.
///
/// This lives beside `StepStrings.swift` rather than in it on purpose. That
/// file holds sentences a person reads, and the vocabulary scan reads every
/// `*Strings.swift` whole for the retired words of DESIGN.md §2.13. The
/// engine's word for a frame that resembles the one beside it is one of them,
/// and it has to be spelled out somewhere to be recognised at all — the same
/// exception the scan already makes for `rating`, `tier` and `CSV`, which the
/// app spells to decode and never to label. Recognising it here and naming it
/// there keeps the retired word out of every file a label can come from.
public enum CullReason: Sendable, Hashable {
    case soft
    case looksAlike
    case blownHighlights
    case noFocus
    case eyesClosed
    case cutOff
    case midWord
    case faceInShadow
    case tooDark
    case unreadable
    /// The engine said something this build has no phrase for; it is printed
    /// as the engine wrote it.
    case unknown

    /// The engine's raw reason, trimmed and lowercased, read into one of the
    /// above.
    public static func of(_ raw: String) -> CullReason {
        let w = raw.trimmingCharacters(in: .whitespaces).lowercased()
        // Softness first: a frame the cull called soft AND alike is a frame
        // that is soft, and saying only that it resembles its neighbour would
        // leave out the fault the cull actually named.
        if w.contains("soft") { return .soft }
        if w.contains("dupl") || w == alike || w.hasSuffix(" " + alike) { return .looksAlike }
        // The engine's own words, as `cull.py` and `faces.py` write them into
        // the reason column, beside the words a person would use. A blown
        // face is a face in the highlights that blew, and it is counted with
        // them rather than on a line of its own that says the same thing.
        switch w {
        case "blown highlights", "blown face": return .blownHighlights
        case "no focus", "nothing in focus": return .noFocus
        case "blink", "eyes closed", "eyes shut": return .eyesClosed
        case "head cut", "cut off": return .cutOff
        case "mid-word", "mid-word?": return .midWord
        case "face in the dark", "face in shadow": return .faceInShadow
        case "too dark": return .tooDark
        case "no preview": return .unreadable
        default: return .unknown
        }
    }

    private static let alike = "dup"
}
