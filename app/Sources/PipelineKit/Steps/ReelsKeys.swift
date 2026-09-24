import AppKit
import SwiftUI

/// What a press means on the Reels page's frames (DESIGN.md §2.6).
///
/// **There is no key table of the page's own.** Which physical key is which
/// action is `KeyMap`'s, the table Choose Keepers reads, so a key means here
/// what it means there and on the Instagram step: S F and the arrows move, E
/// puts a frame in and D leaves it out, X clears the mark, R and W go to the
/// next and previous burst, Space opens the frame large and Q takes the last
/// change back. The grid had a table of its own, and X ticked a frame in or
/// out where everywhere else X clears the mark, E and D did nothing, and the
/// bursts were N and P only. He had asked for "control parity so same way
/// you maneuver the other steps carries over and i'm not doing different
/// buttons for forward and backward".
///
/// A frame of a reel is in until he takes it out, so clearing its mark puts
/// it back in: X is E without the move on.
public enum ReelsMeaning: Equatable, Sendable {
    /// Keepers' next and previous frame, and its ↓ ↑: a row of the grid.
    case next, previous, rowDown, rowUp
    /// Keepers' Keep, Drop and Clear the Mark: in the reel and on to the
    /// next frame, out of it and on, and back to how it started (in).
    case include, leaveOut, clear
    /// Space: the frame large, in the app's viewer.
    case open
    /// R and W (or N and P): the next and previous burst in the list.
    case nextBurst, previousBurst
    case undo, redo
    /// Esc, taken: there is nothing on this page to leave, and passed on it
    /// only sounded the beep, as it did on the light table.
    case nothing
    case shortcuts
    /// The page's own, on keys Keepers leaves unused: the reel starts, or
    /// ends, on the frame the keys are on.
    case startHere, endHere
}

@MainActor
public enum ReelsKeys {

    /// Keepers' action, as this page's meaning. Total over every action;
    /// `nil` is a key the page does not take, and it goes on as it would.
    public static func meaning(of a: KeyMap.Action) -> ReelsMeaning? {
        switch a {
        case .nextFrame: return .next
        case .previousFrame: return .previous
        case .nextPick: return .rowDown
        case .previousPick: return .rowUp
        case .keep: return .include
        case .drop: return .leaveOut
        case .clearMark: return .clear
        case .toggleFullImage: return .open
        case .nextBurst: return .nextBurst
        case .previousBurst: return .previousBurst
        case .undo: return .undo
        case .redo: return .redo
        case .leave: return .nothing
        case .shortcuts: return .shortcuts
        // The light table's own: a reason, Keep Only, Compare, All Bursts,
        // Single, and the zoom — the viewer a frame opens in has no 1:1.
        case .reason, .keepOnly, .compare, .allBursts, .single, .oneToOne, .toggleOneToOne, .fit,
             .zoomIn, .zoomOut, .pan:
            return nil
        }
    }

    /// The page's own keys, read only when Keepers' table has nothing for the
    /// press. Each is a key `KeyMap` leaves unused in every mode, which the
    /// parity test asserts, so it can never shadow one of his.
    public static let ownKeys: [String: ReelsMeaning] = ["i": .startHere, "o": .endHere]

    /// Keepers' action for a press, read as Single reads it. Space is the
    /// frame large whatever Settings ▸ Choosing says about Space: that
    /// setting is about finishing a burst on the light table, and nothing is
    /// finished here.
    public static func keepersAction(_ p: KeyMap.Press) -> KeyMap.Action? {
        KeyMap.action(for: p, mode: .single, spaceShowsWholePicture: true)
    }

    /// What a press means here, and whether the page takes it at all.
    public static func action(_ p: KeyMap.Press) -> ReelsMeaning? {
        if let a = keepersAction(p) { return meaning(of: a) }
        guard !p.command, !p.option, !p.control, p.key == nil else { return nil }
        return ownKeys[p.characters]
    }

    /// Only movement repeats: a held D leaves one frame out, as a held D
    /// drops one on the light table.
    public static func allowsRepeat(_ p: KeyMap.Press) -> Bool {
        keepersAction(p)?.allowsRepeat ?? false
    }

    /// What the page takes from anywhere in its window (`ReelsKeySink`):
    /// every key it reads, from the bursts list, the inspector or the
    /// sidebar as much as from the frames — except ↑ and ↓ while the frames
    /// do not have the keyboard, which are then the list's own, walking the
    /// bursts, or whatever else has it. The page read keys only while its
    /// grid had the keyboard, so after he walked the list with ↓ — which
    /// keeps the keys there on purpose — E, D, S, F, R, W, Q and Space did
    /// nothing, or beeped, while ↓ went to the next burst.
    public static func taken(_ p: KeyMap.Press, framesHaveKeys: Bool) -> ReelsMeaning? {
        guard let m = action(p) else { return nil }
        if !framesHaveKeys, m == .rowDown || m == .rowUp { return nil }
        return m
    }

    /// Whether a key taken while the keyboard was elsewhere hands it to the
    /// frames, so the ring shows the frame it acted on and the next ↑ or ↓
    /// is a row of them. R and W leave it where it was: walking the list,
    /// the next ↓ still goes down it.
    public static func handsTheKeysToTheFrames(_ m: ReelsMeaning) -> Bool {
        switch m {
        case .nextBurst, .previousBurst, .nothing, .shortcuts: return false
        default: return true
        }
    }

    // MARK: - the one way a key reaches the page

    /// One key event, pressed or let go, following `LightTableKeys.route`
    /// guard for guard: the event's own window, no sheet (the frame open
    /// large is one, and reads its own keys), nothing being typed (the burst
    /// field), nothing with first claim on the key, and — with Full Keyboard
    /// Access — Space or Return on a button he tabbed to belong to it.
    public static func route(_ e: NSEvent, to model: ReelsModel, in window: NSWindow?,
                             framesHaveKeys: Bool, giveTheFramesTheKeys: () -> Void) -> Bool {
        guard let window, window.windowNumber > 0, e.windowNumber == window.windowNumber else { return false }
        guard window.attachedSheet == nil,
              !MenuValidation.isTextEditing(in: window),
              !LightTableKeys.yields(e) else { return false }
        let press = KeyMap.Press(event: e)
        guard !LightTableKeys.pressesAFocusedControl(press, in: window),
              let m = taken(press, framesHaveKeys: framesHaveKeys) else { return false }
        switch e.type {
        case .keyDown:
            guard model.key(press) else { return false }
            if !framesHaveKeys, handsTheKeysToTheFrames(m) { giveTheFramesTheKeys() }
            return true
        case .keyUp:
            // The release of a key the page took is kept from the rest of
            // the window, which never saw it go down.
            return true
        default:
            return false
        }
    }

    /// The name of one of the page's own keys, for the note and the
    /// Keyboard Shortcuts window.
    public static func ownKey(_ m: ReelsMeaning) -> String {
        ownKeys.first { $0.value == m }.map { $0.key.uppercased() } ?? ""
    }

    /// The page's own keys for the Keyboard Shortcuts window: none has a
    /// menu row, so like the Instagram editor's they are listed by where
    /// they work (`ShortcutsCatalog.extraKeys`). Every other key of the page
    /// is one of Keepers' rows, already listed under its menu.
    public static var shortcutRows: [ShortcutRow] {
        let here = Strings.Steps.reels
        func row(_ id: String, _ title: String, _ m: ReelsMeaning) -> ShortcutRow {
            ShortcutRow(id: CommandID("help.reels.\(id)"), title: title, menu: here, keys: ownKey(m),
                        alternate: nil, note: nil, group: .deciding)
        }
        return [
            row("startHere", Strings.Reels.startHere, .startHere),
            row("endHere", Strings.Reels.endHere, .endHere),
        ]
    }
}

/// Where the monitor lives: a view of no size behind the page, installed the
/// moment the page joins a window and removed the moment it leaves one — the
/// `LightTableKeyView` pattern, which Choose Keepers and Instagram use too.
@MainActor
public final class ReelsKeyView: NSView {
    let model: ReelsModel
    /// Whether the frames have the keyboard now, from the page's focus.
    var framesHaveKeys = true
    /// Gives the frames the keyboard.
    var giveTheFramesTheKeys: () -> Void = {}
    private var monitor: Any?

    init(model: ReelsModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var acceptsFirstResponder: Bool { false }

    var isListening: Bool { monitor != nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopListening()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let taken = MainActor.assumeIsolated { () -> Bool in
                self?.handle(event) ?? false
            }
            return taken ? nil : event
        }
    }

    /// One event, as the monitor hands it over. Whether the page took it.
    func handle(_ e: NSEvent) -> Bool {
        ReelsKeys.route(e, to: model, in: window, framesHaveKeys: framesHaveKeys,
                        giveTheFramesTheKeys: giveTheFramesTheKeys)
    }

    func stopListening() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

/// The monitor, in SwiftUI. It draws nothing.
struct ReelsKeySink: NSViewRepresentable {
    let model: ReelsModel
    let framesHaveKeys: Bool
    let giveTheFramesTheKeys: () -> Void

    func makeNSView(context: Context) -> ReelsKeyView {
        let v = ReelsKeyView(model: model)
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: ReelsKeyView, context: Context) {
        v.framesHaveKeys = framesHaveKeys
        v.giveTheFramesTheKeys = giveTheFramesTheKeys
    }

    static func dismantleNSView(_ v: ReelsKeyView, coordinator: ()) { v.stopListening() }
}

// MARK: - a SwiftUI press, as the table reads one

extension KeyMap.Press {
    /// A press as `.onKeyPress` hands it over, in the form `KeyMap` reads,
    /// so a SwiftUI view reads the one table and not a list of its own.
    public init(_ p: KeyPress) {
        let special: KeyMap.SpecialKey?
        switch p.key {
        case .leftArrow: special = .left
        case .rightArrow: special = .right
        case .upArrow: special = .up
        case .downArrow: special = .down
        case .escape: special = .escape
        case .space: special = .space
        case .return: special = .return
        default: special = nil
        }
        // An arrow or Esc arrives with a private-use scalar for its
        // characters; it is the key, not a letter. Space is the key too.
        let plain = special == nil ? p.characters : ""
        self.init(plain, key: special,
                  command: p.modifiers.contains(.command),
                  shift: p.modifiers.contains(.shift),
                  option: p.modifiers.contains(.option),
                  control: p.modifiers.contains(.control),
                  isARepeat: p.phase == .repeat)
    }
}
