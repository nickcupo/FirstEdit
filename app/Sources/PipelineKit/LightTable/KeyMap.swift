import Foundation
import AppKit

/// Every key of DESIGN.md §2.5.3, as a pure function of a key press and a mode.
///
/// **One hand.** His right hand is on the mouse, so everything a cull needs
/// sits under the left: E keep · D drop · S previous frame · F next frame ·
/// R next burst · W previous burst · Q undo · X clear the mark · C compare ·
/// Z zoom · G all bursts · Space the whole picture · 1–6 why it is out. He
/// had K for keep, a hand's width to the right of D, and said so: "I hate k
/// and being so far i need 2 hands." The keys he had learned — K, N, P, U, 0
/// and the arrows — go on working beside them.
///
/// Pure on purpose: `(descriptor, Mode) -> Action?` is unit-tested without a
/// window, an event or a run loop, and the two rules that matter most are
/// properties of the table rather than of the view that reads it —
///
/// * **no verdict action allows repeat.** LT-06 measured a held K writing
///   three frames he never saw in 90 ms.
/// * **no single-letter action exists while a text field has the keyboard.**
///
/// Both are asserted over every row, so a key added later cannot break them
/// quietly.
public enum KeyMap {

    // MARK: - what a press can mean

    public enum Action: Equatable, Sendable {
        case keep                     // E, K
        case drop                     // D
        case clearMark                // X, 0
        case reason(Int)              // 1–6
        case previousFrame            // S, ←
        case nextFrame                // F, →
        case previousPick             // ↑ — the cull's shortlist, or stack to stack
        case nextPick                 // ↓
        case nextBurst                // R, N — leaving a burst forward is what records "looked through"
        case previousBurst            // W, P — records nothing
        case toggleFullImage          // Space
        case oneToOne                 // ⌘0
        case toggleOneToOne           // Z: 1:1, and Z again back to Fit
        case fit                      // ⌘9
        case zoomIn
        case zoomOut
        case pan(dx: Int, dy: Int)    // ⇧ arrows
        case compare                  // C
        case keepOnly                 // ⇧E, ⇧K
        case allBursts                // G
        case single                   // Return in All Bursts: the ringed burst, one frame at a time
        case undo                     // ⌘Z, Q, U
        case redo                     // ⇧⌘Z
        case shortcuts                // ? / ⌘/
        case leave                    // Esc

        /// A press that writes something of his. Never allowed to repeat, and
        /// always gated on the frame being on screen.
        public var isVerdict: Bool {
            switch self {
            case .keep, .drop, .clearMark, .reason, .keepOnly: return true
            default: return false
            }
        }

        /// A press about how the frame on screen is looked at: Full Image and
        /// the zoom. All Bursts shows covers and no frame, so there it is
        /// refused like a verdict, as its greyed menu rows say.
        public var looksAtTheFrame: Bool {
            switch self {
            case .toggleFullImage, .oneToOne, .toggleOneToOne, .fit, .zoomIn, .zoomOut, .pan: return true
            default: return false
            }
        }

        /// Only movement repeats, and it is coalesced to one move per display
        /// refresh. Everything else is one press, one act.
        public var allowsRepeat: Bool {
            switch self {
            case .previousFrame, .nextFrame, .previousPick, .nextPick, .pan: return true
            default: return false
            }
        }

        /// Holding a key that does not repeat is not a mistake, but it is worth
        /// saying once: "Holding a key marks one frame only."
        public var explainsHeldKey: Bool {
            switch self {
            case .keep, .drop: return true
            default: return false
            }
        }
    }

    // MARK: - where the press landed

    public enum Mode: Equatable, Sendable {
        case single
        case fullImage
        case compare
        case allBursts
        /// The learning screen's read-only review. Verdicts are refused with a
        /// line saying why, rather than silently doing nothing.
        case review
        /// A text field has the keyboard. It always wins: no single letter is
        /// an action here.
        case textEditing
    }

    // MARK: - an NSEvent, without needing one

    /// What the map reads off a press. `NSEvent` fills it in; a test writes one
    /// by hand.
    public struct Press: Equatable, Sendable {
        /// `charactersIgnoringModifiers`, lowercased. Empty for an arrow.
        public let characters: String
        public let key: SpecialKey?
        public let command: Bool
        public let shift: Bool
        public let option: Bool
        public let control: Bool
        public let isARepeat: Bool

        public init(_ characters: String = "", key: SpecialKey? = nil, command: Bool = false,
                    shift: Bool = false, option: Bool = false, control: Bool = false,
                    isARepeat: Bool = false) {
            self.characters = characters.lowercased()
            self.key = key
            self.command = command
            self.shift = shift
            self.option = option
            self.control = control
            self.isARepeat = isARepeat
        }

        public init(event e: NSEvent) {
            let flags = e.modifierFlags
            let raw = e.charactersIgnoringModifiers ?? ""
            self.init(Press.plainCharacters(raw),
                      key: SpecialKey(raw: raw, keyCode: e.keyCode),
                      command: flags.contains(.command),
                      shift: flags.contains(.shift),
                      option: flags.contains(.option),
                      control: flags.contains(.control),
                      isARepeat: e.isARepeat)
        }

        /// Arrows and Escape arrive as private-use scalars; they are the
        /// `key`, not a character.
        private static func plainCharacters(_ raw: String) -> String {
            guard let first = raw.unicodeScalars.first, first.value < 0xF700, first.value != 27 else { return "" }
            return raw
        }
    }

    public enum SpecialKey: Equatable, Sendable {
        case left, right, up, down, escape, space, `return`

        init?(raw: String, keyCode: UInt16) {
            switch keyCode {
            case 123: self = .left
            case 124: self = .right
            case 125: self = .down
            case 126: self = .up
            case 53: self = .escape
            case 49: self = .space
            case 36, 76: self = .return
            default:
                switch raw.unicodeScalars.first?.value {
                case UInt32(NSLeftArrowFunctionKey): self = .left
                case UInt32(NSRightArrowFunctionKey): self = .right
                case UInt32(NSUpArrowFunctionKey): self = .up
                case UInt32(NSDownArrowFunctionKey): self = .down
                case 27: self = .escape
                case 32: self = .space
                case 13: self = .return
                default: return nil
                }
            }
        }
    }

    // MARK: - the table

    /// The one function. Everything else here is a property of it.
    ///
    /// `spaceShowsWholePicture` is Settings ▸ Choosing's Space key, handed in
    /// rather than read here so the table stays a pure function: on, Space is
    /// Full Image; off, it is N, as it was on the page (§2.5.3).
    public static func action(for p: Press, mode: Mode, spaceShowsWholePicture: Bool = true) -> Action? {
        // A text field always wins. Only the menu's own shortcuts, which carry
        // a modifier, reach past it — and those are the menu's to handle.
        if mode == .textEditing { return nil }

        // Modifier combinations first: ⌘Z before Z, ⇧K before K.
        if p.command {
            switch p.characters {
            case "z": return p.shift ? .redo : .undo
            case "0": return .oneToOne
            case "9": return .fit
            case "+", "=": return .zoomIn
            case "-": return .zoomOut
            case "/": return .shortcuts
            default: return nil
            }
        }
        if p.option || p.control { return nil }

        if let key = p.key {
            switch key {
            case .left:  return p.shift ? .pan(dx: -1, dy: 0) : .previousFrame
            case .right: return p.shift ? .pan(dx: 1, dy: 0) : .nextFrame
            case .up:    return p.shift ? .pan(dx: 0, dy: -1) : .previousPick
            case .down:  return p.shift ? .pan(dx: 0, dy: 1) : .nextPick
            case .escape: return .leave
            case .space: return spaceShowsWholePicture ? .toggleFullImage : .nextBurst
            case .return: return mode == .allBursts ? .single : nil
            }
        }

        if p.shift {
            switch p.characters {
            case "e", "k": return .keepOnly
            case "?", "/": return .shortcuts
            default: return nil
            }
        }

        switch p.characters {
        // The left hand's keys first, then the ones he learned before them.
        case "e", "k": return .keep
        case "d": return .drop
        case "x", "0": return .clearMark
        case "1", "2", "3", "4", "5", "6": return .reason(Int(p.characters) ?? 1)
        // S and F are ← and → in every mode, All Bursts' covers included:
        // S was Single there, so going forward was F and going back was ←,
        // two hands for one row of covers. He asked for the opposite in so
        // many words — "i'm not doing different buttons for forward and
        // backward" (§2.5.3, KeyParity). Single is Return, Esc or G again.
        case "f": return .nextFrame
        case "s": return .previousFrame
        case "r", "n": return .nextBurst
        case "w", "p": return .previousBurst
        case "z": return .toggleOneToOne
        case "c": return .compare
        case "g": return .allBursts
        case "q", "u": return .undo
        case "?": return .shortcuts
        default: return nil
        }
    }

    /// Every action the table can produce, for the tests that assert a
    /// property of all of them.
    public static var everyAction: [Action] {
        var out: [Action] = []
        for mode in [Mode.single, .fullImage, .compare, .allBursts, .review] {
            for press in everyPress {
                if let a = action(for: press, mode: mode) { out.append(a) }
            }
        }
        return out
    }

    /// Every press worth trying: each letter and digit, plain, shifted and
    /// commanded, plus the arrows and Escape.
    public static var everyPress: [Press] {
        var out: [Press] = []
        let letters = "abcdefghijklmnopqrstuvwxyz0123456789?/+=-"
        for c in letters {
            let s = String(c)
            out.append(Press(s))
            out.append(Press(s, shift: true))
            out.append(Press(s, command: true))
            out.append(Press(s, command: true, shift: true))
        }
        for k in [SpecialKey.left, .right, .up, .down, .escape, .space, .return] {
            out.append(Press(key: k))
            out.append(Press(key: k, shift: true))
        }
        return out
    }

    /// Whether a press should be acted on at all, given repeat. This is rule 5
    /// in one line, and the stage calls exactly this.
    public static func accepts(_ p: Press, mode: Mode) -> Action? {
        guard let a = action(for: p, mode: mode) else { return nil }
        if p.isARepeat && !a.allowsRepeat { return nil }
        return a
    }
}
