import Foundation

/// One way to move, decide and look, wherever photographs are shown
/// (DESIGN.md §2.5.3, "One scheme").
///
/// He asked for it in so many words: "make sure there is control parity so
/// same way you maneuver the other steps carries over and i'm not doing
/// different buttons for forward and backward". So a key means one thing on
/// every page that shows photographs — Choose Keepers in each of its views,
/// Instagram's wall and editor, the Reels frames, the viewer a frame opens
/// in, the learning screen's review and a presentation on the other screen:
///
/// | Keys | Means |
/// |---|---|
/// | S F, ← → | the previous and next photograph |
/// | ↑ ↓ | the other way: a row of a grid, the cull's picks, a burst of a show |
/// | W R (P N) | the previous and next burst |
/// | E (K) · D · X (0) | keep or include · drop or leave out · clear the mark |
/// | Space · Z | the photograph large, and back · 1:1 |
/// | Esc · Q (U, ⌘Z) · Return | back · undo · the page's main button |
///
/// Which physical key is which is `KeyMap`'s alone; every place reads that
/// table and says what each of its actions does there. A place may also have
/// keys of its own (Reels' I and O, the Instagram editor's A, T, V, − and =),
/// on keys the table leaves unused, so they can never shadow one of these.
/// `KeyParityTests` walks every place below, press by press, and fails when a
/// shared key means something else anywhere.
public enum Control: String, CaseIterable, Sendable {
    // Moving.
    case previous, next, up, down, previousBurst, nextBurst
    // Deciding.
    case include, leaveOut, clear, undo, redo
    // Looking.
    case large, oneToOne, fit, back
    // The page.
    case primary, shortcuts
    // The light table's alone. No other place may give their keys a meaning
    // of its own.
    case reason, keepOnly, compare, allBursts, pan, zoomIn, zoomOut
}

/// What a place does with a press: one of the scheme's meanings, or one of
/// its own on a key the scheme leaves free.
public enum KeyReading: Equatable, Sendable, CustomStringConvertible {
    case shared(Control)
    case own(String)

    public var description: String {
        switch self {
        case .shared(let c): return c.rawValue
        case .own(let s): return "its own \(s)"
        }
    }
}

/// A place that shows photographs and takes keys, and how it reads them.
public struct KeyPlace: Sendable {
    public let id: String
    /// The step it belongs to, by the id `StepRegistry` knows it by, or a
    /// library page's.
    public let step: String
    /// What the place does with a press, read off the same function its key
    /// handling calls — never a copy of it.
    public let reads: @MainActor @Sendable (KeyMap.Press) -> KeyReading?

    public init(_ id: String, step: String, reads: @escaping @MainActor @Sendable (KeyMap.Press) -> KeyReading?) {
        self.id = id
        self.step = step
        self.reads = reads
    }
}

@MainActor
public enum KeyParity {

    /// Choose Keepers' action, in the scheme's words. Total.
    public static func control(of a: KeyMap.Action) -> Control {
        switch a {
        case .previousFrame: return .previous
        case .nextFrame: return .next
        case .previousPick: return .up
        case .nextPick: return .down
        case .previousBurst: return .previousBurst
        case .nextBurst: return .nextBurst
        case .keep: return .include
        case .drop: return .leaveOut
        case .clearMark: return .clear
        case .reason: return .reason
        case .keepOnly: return .keepOnly
        case .toggleFullImage: return .large
        case .oneToOne, .toggleOneToOne: return .oneToOne
        case .fit: return .fit
        case .zoomIn: return .zoomIn
        case .zoomOut: return .zoomOut
        case .pan: return .pan
        case .compare: return .compare
        case .allBursts: return .allBursts
        // Return on a cover in All Bursts: that view's main act.
        case .single: return .primary
        case .undo: return .undo
        case .redo: return .redo
        case .shortcuts: return .shortcuts
        case .leave: return .back
        }
    }

    /// Space, Esc or Return closing something: which of the scheme's
    /// meanings the press is — Space puts back what Space opened, Esc goes
    /// back, Return is the main button (Done).
    static func closing(_ p: KeyMap.Press) -> KeyReading? {
        switch p.key {
        case .space?: return .shared(.large)
        case .escape?: return .shared(.back)
        case .return?: return .shared(.primary)
        default: return nil
        }
    }

    // MARK: - the places

    static func keepers(_ p: KeyMap.Press, _ mode: KeyMap.Mode) -> KeyReading? {
        KeyMap.action(for: p, mode: mode).map { .shared(control(of: $0)) }
    }

    static func instagram(_ p: KeyMap.Press, _ place: InstagramPlace) -> KeyReading? {
        guard let m = InstagramKeys.action(p, place) else { return nil }
        switch m {
        case .next: return .shared(.next)
        case .previous: return .shared(.previous)
        case .rowDown: return .shared(.down)
        case .rowUp: return .shared(.up)
        case .include: return .shared(.include)
        case .leaveOut: return .shared(.leaveOut)
        case .clear: return .shared(.clear)
        case .open(.oneToOne), .toggleOneToOne, .oneToOne: return .shared(.oneToOne)
        case .open: return .shared(.large)
        case .fit: return .shared(.fit)
        // ⇧ and an arrow moves what is under it by a step: the view at 1:1
        // in Keepers, the cut here.
        case .nudge: return .shared(.pan)
        case .undo: return .shared(.undo)
        case .redo: return .shared(.redo)
        case .close: return closing(p)
        case .nothing: return .shared(.back)
        case .shortcuts: return .shared(.shortcuts)
        case .automatic, .cutOrWhole, .result, .smaller, .larger: return .own("\(m)")
        }
    }

    /// What the Reels page takes, as its key sink asks: with the frames
    /// holding the keyboard, or with the bursts list (or anything else)
    /// holding it.
    static func reels(_ p: KeyMap.Press, framesHaveKeys: Bool) -> KeyReading? {
        guard let m = ReelsKeys.taken(p, framesHaveKeys: framesHaveKeys) else { return nil }
        switch m {
        case .next: return .shared(.next)
        case .previous: return .shared(.previous)
        case .rowDown: return .shared(.down)
        case .rowUp: return .shared(.up)
        case .include: return .shared(.include)
        case .leaveOut: return .shared(.leaveOut)
        case .clear: return .shared(.clear)
        case .open: return .shared(.large)
        case .nextBurst: return .shared(.nextBurst)
        case .previousBurst: return .shared(.previousBurst)
        case .undo: return .shared(.undo)
        case .redo: return .shared(.redo)
        case .nothing: return .shared(.back)
        case .shortcuts: return .shared(.shortcuts)
        case .startHere, .endHere: return .own("\(m)")
        }
    }

    static func viewer(_ p: KeyMap.Press, _ marking: ExtViewerMarking) -> KeyReading? {
        guard let m = ExtViewerKeys.action(p, marking: marking) else { return nil }
        switch m {
        case .previous: return .shared(.previous)
        case .next: return .shared(.next)
        case .include: return .shared(.include)
        case .leaveOut: return .shared(.leaveOut)
        case .clear: return .shared(.clear)
        case .undo: return .shared(.undo)
        case .close: return closing(p)
        case .toggle(let id): return .own("mark \(id)")
        }
    }

    static func review(_ p: KeyMap.Press, enlarged: Bool) -> KeyReading? {
        guard let m = ReviewKeys.action(p, enlarged: enlarged) else { return nil }
        switch m {
        case .previous: return .shared(.previous)
        case .next: return .shared(.next)
        case .rowUp: return .shared(.up)
        case .rowDown: return .shared(.down)
        case .large: return .shared(.large)
        case .back: return .shared(.back)
        }
    }

    static func presentation(_ p: KeyMap.Press) -> KeyReading? {
        switch PresentationKey.from(p) {
        case .left?: return .shared(.previous)
        case .right?: return .shared(.next)
        case .up?: return .shared(.up)
        case .down?: return .shared(.down)
        case .nextBurst?: return .shared(.nextBurst)
        case .previousBurst?: return .shared(.previousBurst)
        case .escape?: return .shared(.back)
        case .home?, .end?: return .own("first or last")
        case nil: return nil
        }
    }

    /// A page's marks as `pipeline.viewFrames` hands them over, one on each
    /// kind of key a page can ask for: a keep's, a drop's, a letter of its
    /// own, and one of the scheme's that is not its to take.
    static var aPagesMarking: ExtViewerMarking {
        ExtViewerMarking(actions: ExtViewerAction.parse([
            ["id": "yes", "label": "Yes", "key": "k"], ["id": "no", "label": "No", "key": "d"],
            ["id": "later", "label": "Later", "key": "l"], ["id": "moves", "label": "Moves", "key": "f"],
        ]))
    }

    /// Every place in the app that shows photographs and takes keys.
    public static let places: [KeyPlace] = [
        KeyPlace("keepers.single", step: "keepers") { keepers($0, .single) },
        KeyPlace("keepers.fullImage", step: "keepers") { keepers($0, .fullImage) },
        KeyPlace("keepers.compare", step: "keepers") { keepers($0, .compare) },
        KeyPlace("keepers.allBursts", step: "keepers") { keepers($0, .allBursts) },
        KeyPlace("keepers.review", step: "keepers") { keepers($0, .review) },
        KeyPlace("keepers.presentation", step: "keepers") { presentation($0) },
        KeyPlace("instagram.wall", step: "instagram") { instagram($0, .wall) },
        KeyPlace("instagram.editor", step: "instagram") { instagram($0, .editor) },
        KeyPlace("reels.frames", step: "reels") { reels($0, framesHaveKeys: true) },
        // The same page with the bursts list holding the keyboard: every key
        // but ↑ and ↓, which walk the list.
        KeyPlace("reels.list", step: "reels") { reels($0, framesHaveKeys: false) },
        KeyPlace("reels.large", step: "reels") {
            viewer($0, ExtViewerMarking(actions: ReelsModel.lookActions, verdicts: ReelsModel.lookVerdicts))
        },
        KeyPlace("extension.viewer", step: "extension") { viewer($0, aPagesMarking) },
        KeyPlace("learned.review", step: "learned") { review($0, enlarged: false) },
        KeyPlace("learned.review.large", step: "learned") { review($0, enlarged: true) },
    ]

    /// The steps and library pages that show no photograph a key acts on:
    /// their only key is Return, the step's main button. The cull's report
    /// links open Choose Keepers on the frames they name, so its lists are
    /// the light table's.
    public static let noPhotographKeys: Set<String> = [
        "ingest", "cull", "presets", "edit", "done", "card", "storage", "library",
    ]
}
