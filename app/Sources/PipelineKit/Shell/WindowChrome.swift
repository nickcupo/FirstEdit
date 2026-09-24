import SwiftUI
import AppKit

/// Who holds the keyboard when the window becomes key.
///
/// NAT-01 is a blocker today: K, D and N do nothing on the first press of a
/// launch and of every ⌘-tab back, because nothing on the page has focus. Here
/// the view that owns single-letter keys — the light table's stage — registers
/// itself, and the window hands it first responder the moment it becomes key,
/// before the first frame paints. It is made impossible by construction rather
/// than fixed by a click.
@MainActor
public enum KeyFocus {
    private final class Box { weak var view: NSView? }
    private static let box = Box()

    /// The view that should have the keyboard. Weak: when the stage goes away
    /// the window's own default takes over.
    public static var preferred: NSView? {
        get { box.view }
        set { box.view = newValue }
    }

    /// Makes `preferred` first responder if it is in this window. A text field
    /// that already has focus keeps it: typing "k" into a search box types a k.
    @discardableResult
    public static func restore(in window: NSWindow) -> Bool {
        guard let v = preferred, v.window === window, v.acceptsFirstResponder else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return false }
        return window.makeFirstResponder(v)
    }

    /// Every window, at launch.
    public static func restoreAll() {
        for w in NSApp.windows where w.isVisible { restore(in: w) }
    }

    /// After a control in the toolbar has taken the keyboard, on the next turn
    /// of the run loop — so the control finishes handling its own press first,
    /// and the photograph has K, D and N back by the time his hand is off the
    /// mouse.
    public static func restoreSoon(in window: NSWindow?) {
        guard let window else { return }
        Task { @MainActor in restore(in: window) }
    }
}

/// Whether a window remembers where it was.
///
/// On for his app, where reopening the window where he left it is the whole
/// point. Off for the snapshot harness: it renders the same screen at three
/// sizes in one process, and a remembered frame put the last size back over
/// the next one, so a picture asked for at 1512 pt came out at 900 — the same
/// picture twice under two names. It also kept the harness out of the
/// defaults on his Mac.
@MainActor
public enum WindowFrameMemory {
    public static var remembers = true
}

/// The window's AppKit settings, applied from inside SwiftUI: a transparent
/// title bar over full-size content with a unified toolbar (NAT-18), primary
/// full screen (NAT-03), the minimum size, no tabs, and the saved frame.
struct WindowChrome: NSViewRepresentable {
    var autosaveName = "main"
    /// Whether the page on screen keeps the keyboard on the light table's
    /// photograph whatever else is clicked (`ChromeView.takeKeysBack`).
    var keysBelongToTheStage: @MainActor () -> Bool = { false }
    /// The window's width, told when the view joins the window and after
    /// each resize — from AppKit, on the next turn, never from inside a
    /// layout pass. Measured in SwiftUI instead, with the toolbar's content
    /// depending on it, it made a layout cycle that never settled.
    var widthChanged: @MainActor (CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> ChromeView {
        let v = ChromeView(autosaveName: autosaveName)
        v.keysBelongToTheStage = keysBelongToTheStage
        v.widthChanged = widthChanged
        return v
    }
    func updateNSView(_ v: ChromeView, context: Context) {
        v.keysBelongToTheStage = keysBelongToTheStage
        v.widthChanged = widthChanged
    }

    final class ChromeView: NSView {
        let autosaveName: String
        private weak var observed: NSWindow?
        var keysBelongToTheStage: @MainActor () -> Bool = { false }
        var widthChanged: @MainActor (CGFloat) -> Void = { _ in }
        private var toldWidth: CGFloat = -1
        /// A mouse button went down in this window and the pass that follows
        /// its handling has not yet looked at who holds the keyboard.
        private(set) var pressPending = false
        private var pressWatch: Any?
        /// Whether any mouse button is held. Replaced in tests, which cannot
        /// press one.
        static var buttonsHeld: @MainActor () -> Bool = { NSEvent.pressedMouseButtons != 0 }

        init(autosaveName: String) {
            self.autosaveName = autosaveName
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        /// A press of any button in this window: what `takeKeysBack` answers,
        /// and the only thing it answers.
        func pressed() { pressPending = true }

        private func watchPresses() {
            guard pressWatch == nil else { return }
            pressWatch = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, let w = self.window, event.window === w { self.pressed() }
                }
                return event
            }
        }

        private func stopWatchingPresses() {
            if let m = pressWatch { NSEvent.removeMonitor(m) }
            pressWatch = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            watchPresses()
            WindowChrome.configure(w, autosaveName: autosaveName)
            // A selector, not a block: AppKit posts this on the main thread
            // and the method is main-actor code already, so nothing has to
            // assert isolation from inside a notification callout.
            if observed !== w {
                if let old = observed { stopObserving(old) }
                NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                                       name: NSWindow.didBecomeKeyNotification, object: w)
                NotificationCenter.default.addObserver(self, selector: #selector(takeKeysBack(_:)),
                                                       name: NSWindow.didUpdateNotification, object: w)
                NotificationCenter.default.addObserver(self, selector: #selector(windowResized(_:)),
                                                       name: NSWindow.didResizeNotification, object: w)
                observed = w
            }
            tellWidth()
            KeyFocus.restore(in: w)
        }

        private func stopObserving(_ old: NSWindow) {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification,
                         NSWindow.didResizeNotification] {
                NotificationCenter.default.removeObserver(self, name: name, object: old)
            }
        }

        @objc private func windowResized(_ note: Notification) { tellWidth() }

        private func tellWidth() {
            guard let width = window?.frame.width, width != toldWidth else { return }
            toldWidth = width
            let tell = widthChanged
            Task { @MainActor in tell(width) }
        }

        @objc private func windowBecameKey(_ note: Notification) {
            guard let w = note.object as? NSWindow else { return }
            KeyFocus.restore(in: w)
        }

        /// A click in the sidebar while the light table is on screen — the
        /// Choose Keepers row he is already on, a disclosure triangle, the
        /// Finished heading — made the sidebar's list first responder, and
        /// kept it. The menu hands bare K, D and N to the first responder, so
        /// they went dead; ↑ and ↓ moved the selection to Cull or Presets and
        /// took him off the step mid-burst, and the list's type-select could
        /// jump to a row by its first letter. So once the event that did it
        /// has been handled, the photograph has the keyboard back.
        ///
        /// On `NSWindow.didUpdateNotification`, which is posted once per pass
        /// of the event loop, after the list's own mouse tracking has ended
        /// (AppKit does not update windows while it tracks). Only while the
        /// selection is still Choose Keepers: a click that leaves for another
        /// page leaves the keyboard with the list.
        ///
        /// **Only after a mouse press.** It ran on every pass, so the sidebar
        /// could not be reached from the keyboard at all on this step: Tab,
        /// Full Keyboard Access and VoiceOver's keyboard focus following its
        /// cursor all put the list first and all had it taken back on the next
        /// pass. A press is noted by a local monitor as it arrives and looked
        /// at once, on the first pass with every button up, and then
        /// forgotten; a keyboard route into the list never sets it.
        ///
        /// Compare and All Bursts have no photograph to hold the keyboard
        /// (`KeyFocus.preferred` is the stage's), so there the window itself
        /// takes it: the list cannot keep ↑ and ↓ and move him off the step.
        @objc func takeKeysBack(_ note: Notification) {
            guard pressPending, !Self.buttonsHeld(), let w = note.object as? NSWindow else { return }
            pressPending = false
            guard w.firstResponder is NSOutlineView, keysBelongToTheStage() else { return }
            if !KeyFocus.restore(in: w) { w.makeFirstResponder(nil) }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                stopWatchingPresses()
                pressPending = false
            }
            if newWindow == nil, let old = observed {
                stopObserving(old)
                observed = nil
                toldWidth = -1
            }
        }
    }

    @MainActor
    static func configure(_ w: NSWindow, autosaveName: String) {
        w.titlebarAppearsTransparent = true
        w.styleMask.insert(.fullSizeContentView)
        TitleBarStrip.install(in: w)
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.tabbingMode = .disallowed
        // The content minimum only. Setting the frame-based `minSize` beside
        // it made SwiftUI, which sizes this window from its content, ask for a
        // 640 pt minimum instead of 620 (DESIGN.md §2.1, WindowMinimumTests).
        w.contentMinSize = Tokens.Metric.minimumWindow
        if WindowFrameMemory.remembers {
            if w.frameAutosaveName != autosaveName {
                w.setFrameAutosaveName(autosaveName)
            }
        } else if !w.frameAutosaveName.isEmpty {
            w.setFrameAutosaveName("")
        }
    }
}

/// The strip of title bar that is not a control, given its clicks back.
///
/// NAT-18 asks for `titlebarAppearsTransparent` with `.fullSizeContentView`,
/// and the cost of the pair is that the **empty** parts of the title bar hit-
/// test straight through: `NSTitlebarContainerView` is in front, but it
/// returns nil over its own gaps, and the click falls to the split view's
/// content hosting view underneath, which eats it. Probed on the real window
/// at y = 26, the vertical middle of the 52 pt bar: Choose Keepers leaked
/// **506 pt of 1100** — one run of 444 pt between the mode picker and the
/// inspector button alone — and every other screen leaked the 117 pt beside
/// the traffic lights. Those strips did nothing at all, and the window could
/// not be dragged by them either, which is the first thing a title bar is for.
///
/// So the content gets a transparent view of its own across that band — the
/// top of the window, whichever way the content view counts (`frame(in:)`) —
/// added as the last subview of the window's content view: in front of the
/// SwiftUI content that was swallowing the clicks, behind the title bar container
/// that owns the real controls, so nothing that already worked changes. It
/// drags the window, zooms on a double click the way the system preference
/// says, and accepts the first mouse, because a window you have just come back
/// to should be draggable on the first press.
///
/// **It claims a press and nothing else.** It is a behaviour attached to one
/// event, not a thing sitting on top of the window, so `hitTest` answers only
/// for a left mouse down and returns nil for everything else — a scroll, a
/// right click, a middle click, a moved pointer, an accessibility probe — and
/// the hit test carries on to the view underneath, which is where those
/// belong. Overriding `mouseDown` alone was not enough: `NSResponder`'s own
/// `scrollWheel(with:)` and `rightMouseDown(with:)` pass an event to the
/// **superview**, never to the sibling beneath, so anything scrollable that
/// `.fullSizeContentView` puts under the 52 pt band — a `List` in the sidebar
/// does exactly that, by design — stopped scrolling whenever the pointer was
/// up there, and had no context menu.
@MainActor
final class TitleBarStrip: NSView {

    /// The band's height: what the window frame has that its content layout
    /// rect does not. Zero in full screen, where the bar is not there.
    static func height(frameHeight: CGFloat, contentLayoutHeight: CGFloat) -> CGFloat {
        max(0, frameHeight - contentLayoutHeight)
    }

    static func install(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let existing = content.subviews.compactMap { $0 as? TitleBarStrip }.first
        let strip = existing ?? TitleBarStrip(frame: .zero)
        if existing == nil { content.addSubview(strip) }
        strip.refit()
    }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// It is a place to press, never a place to type.
    override var acceptsFirstResponder: Bool { false }

    // MARK: - what it claims

    /// The event kinds the strip is for. A press on the empty title bar drags
    /// the window; everything else belongs to whatever is drawn under the
    /// band, and the strip must not stand between them.
    static func claims(_ type: NSEvent.EventType?) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: return true
        default: return false
        }
    }

    /// What is being routed right now. `NSApp.currentEvent` during real
    /// routing; a test sets it directly, because `sendEvent` is the only thing
    /// that can set the real one.
    static var eventBeingRouted: () -> NSEvent.EventType? = { NSApp.currentEvent?.type }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Not claimed: answer as though the strip were not there at all, and
        // the content view's hit test carries on to the sibling underneath.
        guard Self.claims(Self.eventBeingRouted()) else { return nil }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let w = window else { return }
        for name: NSNotification.Name in [NSWindow.didResizeNotification,
                                          NSWindow.didEnterFullScreenNotification,
                                          NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refit),
                                                   name: name, object: w)
        }
        // Those three fire on a resize and on full screen and on nothing else,
        // so a hosting view SwiftUI replaced without one — opening the
        // inspector, presenting a sheet, changing the split view — landed in
        // front of the strip, and the strip stopped working silently until the
        // next drag of the window's edge. `NSWindow.update()` is sent once per
        // pass of the event loop and posts this; the check it runs is one
        // pointer comparison. KVO on the content view's `subviews` is not an
        // option: `addSubview` does not post it (measured — zero
        // notifications for two adds).
        NotificationCenter.default.addObserver(self, selector: #selector(raise),
                                               name: NSWindow.didUpdateNotification, object: w)
        refit()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func refit() {
        guard let w = window, let content = w.contentView else { return }
        let h = Self.height(frameHeight: w.frame.height, contentLayoutHeight: w.contentLayoutRect.height)
        frame = Self.frame(in: content.bounds, flipped: content.isFlipped, height: h)
        autoresizingMask = Self.pinnedToTheTop(flipped: content.isFlipped)
        raise()
    }

    /// The band in the content view's own space: across the top of the
    /// **window**, whichever way that view counts.
    ///
    /// His window's content view is SwiftUI's hosting view, and it is flipped.
    /// `bounds.height - h`, the top of an ordinary view, is the bottom of a
    /// flipped one, so the strip lay across the foot of the window in front of
    /// every step page's main button and took each click on it as the start
    /// of a window drag. Open My Keepers in PhotoLab did nothing at all, and
    /// no request reached the engine; Return and ⇧⌘E, which never pass
    /// through a hit test, still worked. The empty title bar it was put there
    /// for went on swallowing its clicks.
    static func frame(in bounds: NSRect, flipped: Bool, height h: CGFloat) -> NSRect {
        NSRect(x: bounds.minX, y: flipped ? bounds.minY : bounds.maxY - h, width: bounds.width, height: h)
    }

    /// The margin that stretches on a resize is the one away from the top.
    static func pinnedToTheTop(flipped: Bool) -> NSView.AutoresizingMask {
        flipped ? [.width, .maxYMargin] : [.width, .minYMargin]
    }

    /// Last, so it stays in front of the hosting view SwiftUI keeps replacing
    /// underneath it.
    @objc func raise() {
        guard let content = window?.contentView, content.subviews.last !== self else { return }
        content.addSubview(self)
    }

    /// What System Settings ▸ Desktop & Dock ▸ "Double-click a window's
    /// title bar to" says. "Fill" is macOS 15's; it was sent to zoom with
    /// everything else it did not name.
    enum DoubleClick: Equatable { case zoom, fill, minimize, nothing }

    static func doubleClick(_ setting: String?) -> DoubleClick {
        switch setting {
        case "Minimize": return .minimize
        case "None": return .nothing
        case "Fill": return .fill
        default: return .zoom   // "Maximize", and unset
        }
    }

    override func mouseDown(with e: NSEvent) {
        guard let w = window else { return }
        if e.clickCount == 2 {
            // Whatever he has set in System Settings. Nothing here decides it.
            switch Self.doubleClick(UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")) {
            case .minimize: w.performMiniaturize(nil)
            case .nothing: break
            case .fill:
                if let screen = w.screen {
                    w.setFrame(screen.visibleFrame, display: true, animate: !Motion.reduced)
                }
            case .zoom: w.performZoom(nil)
            }
            return
        }
        w.performDrag(with: e)
    }
}
