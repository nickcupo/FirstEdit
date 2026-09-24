import AppKit
import SwiftUI

/// The one way a key reaches the light table (DESIGN.md §2.5.3).
///
/// There used to be two. The photograph's own `keyDown`, which is where the
/// repeat rule, the held-key line and the per-refresh arrow coalescing live;
/// and a bare `.keyboardShortcut` on Keep, Drop, Next Burst, Compare and
/// Compare's Single link. AppKit offers a key to the window's key equivalents
/// before the first responder's `keyDown`, so the buttons won every time: a
/// held K kept each frame it landed on, a held N marked bursts he never looked
/// at as been through, and "Holding K keeps one frame only" never appeared.
/// The photograph's path also died whenever it lost the keyboard — Compare and
/// All Bursts have no photograph to hold it, coming back from Full Image left
/// nothing holding it, and a click on the sidebar or the filmstrip gave the arrows to
/// a list — and then only the buttons' shortcuts still worked.
///
/// Now the buttons carry no key, and one local event monitor, installed while
/// the light table is on screen, hands every key pressed in its window to
/// `ViewerModel.key(_:at:)`. Nothing else has to hold the keyboard, so the
/// same keys work in Single, Full Image, Compare and All Bursts, and after any
/// click anywhere in the window.
///
/// It stands aside for exactly four things: a text field that has the
/// keyboard (a "k" typed into Find Burst… is a k), a sheet in front of the
/// window, a key someone else has first claim on (`yields`), and — with Full
/// Keyboard Access on — Space or Return while a button he tabbed to has the
/// keyboard, which is how that setting presses a button.
@MainActor
public enum LightTableKeys {

    /// A key that belongs to something else even while the light table's
    /// window is in front — the arrows and Esc while a presentation runs on
    /// the other screen. Monitors run in the order they were installed, and
    /// the light table's is usually the older — it goes in when the light
    /// table appears, a presentation's when one starts — so whoever owns such
    /// a key says so here rather than relying on the order. Set once at
    /// launch.
    public static var yields: @MainActor (NSEvent) -> Bool = { _ in false }

    /// System Settings ▸ Keyboard ▸ Keyboard navigation. A seam for the tests.
    static var fullKeyboardAccess: @MainActor () -> Bool = { NSApp.isFullKeyboardAccessEnabled }

    /// Space and Return press whatever control Full Keyboard Access has put
    /// its focus ring on. The light table's own Space (Full Image) took them
    /// first, so with that setting on no button in the window could be
    /// pressed from the keyboard. Only a button or a segmented control: the
    /// sidebar and the filmstrip are controls too, and a click there must not
    /// take Space from the photograph.
    static func pressesAFocusedControl(_ press: KeyMap.Press, in window: NSWindow) -> Bool {
        guard press.key == .space || press.key == .return,
              !press.command, !press.option, !press.control, fullKeyboardAccess() else { return false }
        return window.firstResponder is NSButton || window.firstResponder is NSSegmentedControl
    }

    /// Whether ⇧⌘Z has anything to redo. When it has not, the light table
    /// takes the key and does nothing, as it did before this path existed:
    /// passed on, it went to a greyed Redo and then to the system beep.
    static func canRedo(in window: NSWindow) -> Bool {
        (window.firstResponder?.undoManager ?? window.undoManager)?.canRedo ?? false
    }

    /// One key event, pressed or let go. Returns true when the light table
    /// took it, and the event then goes no further.
    public static func route(_ e: NSEvent, to model: ViewerModel, in window: NSWindow?) -> Bool {
        // A window that has never been on a screen has no number yet, and
        // neither does an event that belongs to no window: neither is his.
        guard let window, window.windowNumber > 0, e.windowNumber == window.windowNumber else { return false }
        guard window.attachedSheet == nil,
              !MenuValidation.isTextEditing(in: window),
              !yields(e) else { return false }
        let press = KeyMap.Press(event: e)
        guard !pressesAFocusedControl(press, in: window) else { return false }
        switch e.type {
        case .keyDown:
            if model.key(press, at: e.timestamp) { return true }
            return KeyMap.action(for: press, mode: model.keyMode) == .redo && !canRedo(in: window)
        case .keyUp:
            // Every release counts — any key let go ends a held arrow — but
            // only the release of a key the light table reads is kept from
            // the rest of the window, which never saw it go down.
            model.keyReleased(press, at: e.timestamp)
            return KeyMap.action(for: press, mode: model.keyMode) != nil
        default:
            return false
        }
    }
}

/// Where the monitor lives: a view of no size behind the light table, so it
/// is installed the moment the light table joins a window and removed the
/// moment it leaves one, and it knows which window is its own.
@MainActor
public final class LightTableKeyView: NSView {
    let model: ViewerModel
    private var monitor: Any?

    public init(model: ViewerModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    /// It is not a place: a click, a scroll or a probe goes to whatever is
    /// drawn where it is.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var acceptsFirstResponder: Bool { false }

    /// Whether the monitor is installed, for the tests.
    var isListening: Bool { monitor != nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopListening()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                return LightTableKeys.route(event, to: self.model, in: self.window)
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
public struct LightTableKeySink: NSViewRepresentable {
    let model: ViewerModel

    public init(model: ViewerModel) { self.model = model }

    public func makeNSView(context: Context) -> LightTableKeyView { LightTableKeyView(model: model) }
    public func updateNSView(_ v: LightTableKeyView, context: Context) {}
    public static func dismantleNSView(_ v: LightTableKeyView, coordinator: ()) { v.stopListening() }
}

// MARK: - the key a control teaches

extension LightTableKeys {
    /// What a help tag prints for a command's key — `E or K`, `⌘Z, Q or U`,
    /// `F or →` — read once from the menu bar's own table, so a button can
    /// never name a key the menu does not. The left hand's key comes first,
    /// as the menu shows it, and the one he learned before it after (§2.5.3).
    /// The bar's buttons carry no key of their own, so this and the menus
    /// are how the keys are learned (§2.5.2).
    public static func key(_ id: CommandID) -> String? { keys(id) }

    /// Several commands that do the same thing from here — F and R on a
    /// burst's last frame, R and ⌘] on the last burst — as one tag:
    /// `F, →, R or N`.
    public static func keys(_ ids: CommandID...) -> String? {
        let names = ids.flatMap { keyNames[$0] ?? [] }
        return names.isEmpty ? nil : Words.Shortcuts.either(names)
    }

    private static let keyNames: [CommandID: [String]] = {
        var out: [CommandID: [String]] = [:]
        for c in CommandTable.allCommands {
            if let s = c.shortcut, out[c.id] == nil { out[c.id] = [s.display] + c.alternates }
        }
        return out
    }()
}
