import AppKit
import SwiftUI

/// Where on the Instagram step a key lands: the wall of cuts, or the editor
/// open on one of them.
public enum InstagramPlace: Sendable, Equatable {
    case wall, editor
}

/// How the editor shows the photograph.
public enum InstagramEditorView: String, Sendable, Equatable, CaseIterable, Identifiable {
    /// The whole export, the cut drawn on it.
    case fit
    /// One pixel of the export to one pixel of the screen, centred on the cut.
    case oneToOne
    /// The copy as it would be written: the export cut to the window.
    case result
    public var id: String { rawValue }
}

/// What a press means on this step (DESIGN.md §2.17).
///
/// **There is no second key table.** Which physical key is which action is
/// always `KeyMap`'s, the table Choose Keepers reads, so a key means here what
/// it means there: he said "make sure there is control parity so same way you
/// maneuver the other steps carries over and i'm not doing different buttons
/// for forward and backward". The only thing this step decides is what each
/// of Keepers' actions does to a wall of cuts (`meaning(of:in:)`), plus the
/// editor's few keys for things Keepers has no action for — each one a key
/// Keepers leaves unused, so it can never shadow one of his.
public enum InstagramMeaning: Equatable, Sendable {
    /// Keepers' next / previous frame: the next photograph.
    case next, previous
    /// Keepers' ↓ / ↑: a row of the wall down or up.
    case rowDown, rowUp
    /// Keep, Drop, Clear the Mark: included, left out, unmarked.
    case include, leaveOut, clear
    /// Open the editor on the ringed photograph, in this view.
    case open(InstagramEditorView)
    case toggleOneToOne, oneToOne, fit
    /// Move the cut by one step of 0.005 of the frame.
    case nudge(dx: Int, dy: Int)
    case undo, redo
    /// Save the cut and go back to the wall.
    case close
    /// Taken, and nothing happens: Esc on the wall, as on Keepers with
    /// nothing to leave. Passed on, it only sounded the beep.
    case nothing
    case shortcuts
    // The editor's own, for meanings Keepers has no key for.
    case automatic, cutOrWhole, result, smaller, larger
}

@MainActor
public enum InstagramKeys {

    /// Keepers' mode each place reads the table in: the wall is a page of
    /// photographs, as Single is; the editor is one photograph large, as
    /// Full Image is.
    public static func mode(_ place: InstagramPlace) -> KeyMap.Mode {
        place == .wall ? .single : .fullImage
    }

    /// Keepers' action, as this step's meaning. Total over every action, and
    /// `nil` is a key this step does not take: it goes on as it would.
    public static func meaning(of a: KeyMap.Action, in place: InstagramPlace) -> InstagramMeaning? {
        switch (a, place) {
        case (.nextFrame, _): return .next
        case (.previousFrame, _): return .previous
        case (.nextPick, .wall): return .rowDown
        case (.previousPick, .wall): return .rowUp
        case (.nextPick, .editor), (.previousPick, .editor): return nil
        case (.keep, _): return .include
        case (.drop, _): return .leaveOut
        case (.clearMark, _): return .clear
        case (.toggleFullImage, .wall): return .open(.fit)
        case (.toggleFullImage, .editor): return .close
        case (.toggleOneToOne, .wall): return .open(.oneToOne)
        case (.toggleOneToOne, .editor): return .toggleOneToOne
        case (.oneToOne, .wall): return .open(.oneToOne)
        case (.oneToOne, .editor): return .oneToOne
        case (.fit, .wall): return nil
        case (.fit, .editor): return .fit
        case (.pan, .wall): return nil
        case (.pan(let dx, let dy), .editor): return .nudge(dx: dx, dy: dy)
        case (.undo, _): return .undo
        case (.redo, _): return .redo
        case (.leave, .wall): return .nothing
        case (.leave, .editor): return .close
        case (.shortcuts, _): return .shortcuts
        case (.reason, _), (.nextBurst, _), (.previousBurst, _), (.compare, _), (.keepOnly, _),
             (.allBursts, _), (.single, _), (.zoomIn, _), (.zoomOut, _):
            return nil
        }
    }

    /// The editor's own keys, read only when Keepers' table has nothing for
    /// the press and no ⌘, ⌥ or ⌃ is held. Every one is a key `KeyMap`
    /// leaves unused in every mode, which a test asserts.
    public static let editorKeys: [String: InstagramMeaning] = [
        "a": .automatic, "t": .cutOrWhole, "v": .result,
        "-": .smaller, "_": .smaller, "=": .larger, "+": .larger,
    ]

    /// Keepers' action for a press, as this step reads the table.
    ///
    /// Settings ▸ Choosing's Space chooses between Space's two meanings in
    /// Keepers, the whole picture and the next burst. This step has no
    /// bursts, so with the second Space did nothing here at all. So the
    /// table is read with Space as the whole picture whatever the setting:
    /// on this step Space opens the editor and closes it.
    public static func keepersAction(_ p: KeyMap.Press, _ place: InstagramPlace) -> KeyMap.Action? {
        KeyMap.action(for: p, mode: mode(place), spaceShowsWholePicture: true)
    }

    /// What a press means here, and whether this step takes it at all.
    public static func action(_ p: KeyMap.Press, _ place: InstagramPlace) -> InstagramMeaning? {
        if let a = keepersAction(p, place) {
            return meaning(of: a, in: place)
        }
        guard place == .editor, !p.command, !p.option, !p.control else { return nil }
        // Return in the editor is Done, as it is on any sheet with a Done
        // button. On the wall it is not taken: it presses the step's primary.
        if p.key == .return { return .close }
        guard p.key == nil else { return nil }
        return editorKeys[p.characters]
    }

    /// Whether holding the key down repeats it. Keepers' rule for every key
    /// of its own; of the editor's, only the two that size the cut.
    public static func allowsRepeat(_ p: KeyMap.Press, _ place: InstagramPlace) -> Bool {
        if let a = keepersAction(p, place) {
            return a.allowsRepeat
        }
        switch action(p, place) {
        case .smaller?, .larger?: return true
        default: return false
        }
    }

    /// The name of an editor key, for its help tag and the keys line.
    public static func editorKey(_ m: InstagramMeaning) -> String {
        switch m {
        case .automatic: return "A"
        case .cutOrWhole: return "T"
        case .result: return "V"
        case .smaller: return "−"
        case .larger: return "="
        default: return ""
        }
    }

    // MARK: - the one way a key reaches the step

    /// One key event, pressed or let go, following `LightTableKeys.route`
    /// guard for guard: the event's own window, no sheet, nothing being
    /// typed, nothing with first claim on the key, and — with Full Keyboard
    /// Access — Space or Return on a button he tabbed to belong to it.
    public static func route(_ e: NSEvent, to model: InstagramModel, in window: NSWindow?) -> Bool {
        guard let window, window.windowNumber > 0, e.windowNumber == window.windowNumber else { return false }
        guard window.attachedSheet == nil,
              !MenuValidation.isTextEditing(in: window),
              !LightTableKeys.yields(e) else { return false }
        let press = KeyMap.Press(event: e)
        guard !LightTableKeys.pressesAFocusedControl(press, in: window) else { return false }
        switch e.type {
        case .keyDown:
            // A tile he tabbed to with Full Keyboard Access opens on Return
            // as well as Space: it is a button. Without that setting Return
            // is the step's primary, as on every step.
            if press.key == .return, model.editor == nil, !press.command, !press.option, !press.control,
               LightTableKeys.fullKeyboardAccess(), let stem = model.keyFocus {
                model.open(stem)
                return true
            }
            return model.key(press)
        case .keyUp:
            return action(press, model.place) != nil
        default:
            return false
        }
    }
}

/// Where the monitor lives: a view of no size behind the step, installed the
/// moment the step joins a window and removed the moment it leaves one — the
/// `LightTableKeyView` pattern.
@MainActor
public final class InstagramKeyView: NSView {
    let model: InstagramModel
    private var monitor: Any?

    public init(model: InstagramModel) {
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
                guard let self else { return false }
                return InstagramKeys.route(event, to: self.model, in: self.window)
            }
            return taken ? nil : event
        }
    }

    func stopListening() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

/// The monitor, in SwiftUI. It draws nothing.
public struct InstagramKeySink: NSViewRepresentable {
    let model: InstagramModel
    public init(model: InstagramModel) { self.model = model }
    public func makeNSView(context: Context) -> InstagramKeyView { InstagramKeyView(model: model) }
    public func updateNSView(_ v: InstagramKeyView, context: Context) {}
    public static func dismantleNSView(_ v: InstagramKeyView, coordinator: ()) { v.stopListening() }
}

// MARK: - the scroll over the photograph

/// Where a scroll over the editor's photograph is read: a view of the
/// photograph's size behind it, which is never hit by a click, so every drag
/// and pinch stays the photograph's. While it is in a window it watches the
/// scrolls, and one over its own rectangle, at Fit or Result, steps
/// photographs exactly as a scroll over the fitted frame steps frames in
/// Choose Keepers — the same `ScrollInput.FrameScroll`, so a wheel notch is
/// one photograph and a firm flick of a trackpad is one, never on momentum.
/// At 1:1 the scroll is left alone and pans the photograph.
@MainActor
public final class InstagramScrollView: NSView {
    weak var model: InstagramModel?
    private var monitor: Any?
    private var frameScroll = ScrollInput.FrameScroll()

    init(model: InstagramModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var acceptsFirstResponder: Bool { false }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopListening()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            let taken = MainActor.assumeIsolated { () -> Bool in
                self?.scrolled(event) ?? false
            }
            return taken ? nil : event
        }
    }

    func stopListening() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    /// Whether the scroll was this photograph's.
    private func scrolled(_ e: NSEvent) -> Bool {
        guard let window, window.windowNumber > 0, e.windowNumber == window.windowNumber,
              window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor,
              let model, let editor = model.editor, editor.view != .oneToOne else { return false }
        guard visibleRect.contains(convert(e.locationInWindow, from: nil)) else { return false }
        // Momentum is the trackpad still coasting after his fingers left it:
        // taken, and never a step, or one flick would run through the shoot.
        guard !ScrollInput.isMomentum(e) else { return true }
        let d = ScrollInput.points(e)
        let across = ScrollInput.points(precise: e.hasPreciseScrollingDeltas, deltaX: e.scrollingDeltaX,
                                        deltaY: 0, inverted: false).dx
        model.scrolled(frameScroll.steps(down: d.dy, across: across, precise: e.hasPreciseScrollingDeltas,
                                         began: e.phase == .began,
                                         option: e.modifierFlags.contains(.option), at: e.timestamp))
        return true
    }
}

/// The scroll's view, in SwiftUI. It draws nothing and is never clicked.
struct InstagramScrollArea: NSViewRepresentable {
    let model: InstagramModel
    func makeNSView(context: Context) -> InstagramScrollView { InstagramScrollView(model: model) }
    func updateNSView(_ v: InstagramScrollView, context: Context) { v.model = model }
    static func dismantleNSView(_ v: InstagramScrollView, coordinator: ()) { v.stopListening() }
}

// MARK: - the Keyboard Shortcuts window

extension InstagramKeys {
    /// The editor's own keys, and the ⇧-arrows that move the cut here, for
    /// the Keyboard Shortcuts window: none of them has a menu row, so like
    /// Keepers' pan and Esc they are listed by where they work
    /// (`ShortcutsCatalog.extraKeys`). Every other key of this step is one
    /// of Keepers' rows, already listed under its menu.
    public static var shortcutRows: [ShortcutRow] {
        let here = Strings.Steps.instagram
        func row(_ id: String, _ title: String, _ keys: String, alternate: String? = nil,
                 _ group: ShortcutGroup = .deciding, typed: [String] = []) -> ShortcutRow {
            ShortcutRow(id: CommandID("help.instagram.\(id)"), title: title, menu: here, keys: keys,
                        alternate: alternate, note: nil, group: group, otherKeys: typed)
        }
        return [
            row("move", Strings.Instagram.moveTheCut, "⇧←→↑↓"),
            // The window writes a true minus; a search types a hyphen.
            row("smaller", Strings.Instagram.smallerCut, editorKey(.smaller), typed: ["-"]),
            row("larger", Strings.Instagram.largerCut, editorKey(.larger), alternate: Words.Shortcuts.orPlain("+"),
                typed: ["+"]),
            row("automatic", Strings.Instagram.automaticCut, editorKey(.automatic)),
            row("cutOrWhole", Strings.Instagram.cutOrWhole, editorKey(.cutOrWhole)),
            row("result", Strings.Instagram.result, editorKey(.result), .looking),
        ]
    }
}

// MARK: - the menu rows

/// The Frame, View and Edit rows Choose Keepers answers, answered by the
/// Instagram step while it is on screen, with this step's meanings and each
/// row naming what it does here — "Include 05901" (DESIGN.md §2.12, §2.17).
///
/// The `ReelsCommands` pattern: the owner each row had is kept, and a row is
/// answered by the step only while a step is attached. Edit ▸ Undo and Redo
/// are the app's own rows (`CommandHost`) and go back to it on detach. The
/// Frame and View rows are the light table's, which registers them afresh
/// whenever it comes on screen, so here they simply grey when no step is
/// attached — rather than hand the light table's rows back to a light table
/// that is no longer showing, or take them away from one that has just come
/// on screen before this page's detach arrived.
@MainActor
public enum InstagramCommands {
    typealias ID = CommandTable.ID

    private static weak var attached: InstagramModel?
    private static var found: (center: CommandCenter, actions: [CommandID: CommandAction])?

    /// Row → the meaning it has on this step.
    static let frameRows: [(CommandID, InstagramMeaning)] = [
        (ID.keep, .include), (ID.drop, .leaveOut), (ID.clearMark, .clear),
        (ID.nextFrame, .next), (ID.previousFrame, .previous),
        (ID.fullImage, .open(.fit)), (ID.actualSize, .oneToOne), (ID.zoomToFit, .fit),
    ]
    /// The app's own rows, which go back to their owner on detach.
    static let appRows: [(CommandID, InstagramMeaning)] = [(ID.undo, .undo), (ID.redo, .redo)]

    public static var rows: [CommandID] { (frameRows + appRows).map(\.0) }

    /// The step came on screen. Safe to call again: it is, once more on the
    /// next turn of the main queue, because the light table's detach
    /// unregisters its rows whatever answers them now, and coming straight
    /// from Choose Keepers it can arrive after this step's appear.
    public static func attach(_ model: InstagramModel, center: CommandCenter = .shared) {
        attached = model
        if found?.center !== center {
            var actions: [CommandID: CommandAction] = [:]
            for (id, _) in appRows { actions[id] = center.action(id) }
            found = (center, actions)
        }
        for (id, meaning) in frameRows { answer(id, meaning, in: center, fallback: nil) }
        for (id, meaning) in appRows { answer(id, meaning, in: center, fallback: found?.actions[id]) }
    }

    /// The step went away. Only its own model, and only if a newer one has
    /// not already taken its place.
    public static func detach(_ model: InstagramModel) {
        guard attached === model else { return }
        attached = nil
        guard let (center, actions) = found else { return }
        found = nil
        for (id, _) in appRows {
            if let a = actions[id] { center.register(id, a) } else { center.unregister(id) }
        }
    }

    private static func answer(_ id: CommandID, _ meaning: InstagramMeaning, in center: CommandCenter,
                               fallback: CommandAction?) {
        center.register(id, isEnabled: {
            guard let m = attached else { return fallback?.isEnabled() ?? false }
            return m.canPerform(meaning)
        }, state: {
            guard let m = attached else { return fallback?.state() }
            return meaning == .open(.fit) ? m.editor != nil : nil
        }, title: {
            guard let m = attached else { return fallback?.title() }
            return m.rowTitle(meaning)
        }) {
            guard let m = attached else { fallback?.run(); return }
            // A row is the whole meaning, from the menu: Full Image closes
            // the editor when it is open, as Space does there.
            if meaning == .open(.fit), m.editor != nil { m.perform(.close); return }
            if meaning == .oneToOne, m.editor == nil { m.perform(.open(.oneToOne)); return }
            m.perform(meaning)
        }
    }
}
