#if canImport(AppKit)
import AppKit
import SwiftUI
import QuartzCore

/// The window that cannot take the keyboard.
///
/// This is the whole of the focus argument. AppKit will not make a window key
/// that says it cannot be: not a click, not `makeKeyAndOrderFront(_:)`, not
/// ⌘-tab, not window restoration. So the main window is always the app's key
/// window, `StageView` is always its first responder, and K/D/N can never be
/// dead because the picture window has them — the failure `DESIGN.md` NAT-01
/// describes, which Lightroom's secondary display ships on purpose.
///
/// Every other focus question in the feature collapses to the same answer.
public final class PictureWindow: NSWindow {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// The green button fills the screen rather than doing AppKit's zoom.
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        super.constrainFrameRect(frameRect, to: screen)
    }
}

/// The window, its chrome, its content and everything that happens to it when
/// a screen changes underneath it.
@MainActor
public final class PictureWindowController: NSWindowController, NSWindowDelegate, PicturePresenting {

    public private(set) var screenKey: ScreenKey
    private weak var director: DisplayDirector?
    private let state = PictureViewState()
    private var content: PictureContentView!
    private var hosting: NSHostingView<PictureRootView>!
    private var chromeTimer: Task<Void, Never>?
    private var hudTimer: Task<Void, Never>?
    private var badgeTimer: Task<Void, Never>?
    private var occlusionObserver: NSObjectProtocol?
    /// His click on the close button comes back here through the director, so
    /// the two paths out meet exactly once.
    private var isClosing = false
    /// The viewer background as it changes, from View ▸ Viewer Background or
    /// Settings, so this screen's surround follows at once as the main
    /// window's does. It read the setting only when a frame was shown, and
    /// stayed on the old grey until he moved.
    private let live: LiveSettings

    public init(on info: ScreenInfo, director: DisplayDirector) {
        self.screenKey = info.key
        self.director = director
        self.live = director.settings === SettingsStore.shared ? .shared : LiveSettings(store: director.settings)
        let w = PictureWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: 960, height: 640)),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: w)

        state.surround = director.settings.viewerBackground
        state.hidePointerWhenStill = director.settings.hidePointerOnTheOtherScreen

        content = PictureContentView(state: state, director: director)
        hosting = NSHostingView(rootView: PictureRootView(state: state))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: content.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        content.onChromeReveal = { [weak self] on in self?.revealChrome(on) }
        content.onPointerMoved = { [weak self] in self?.revealHUD() }

        configure(w, on: info)
        w.contentView = content
        w.delegate = self

        place(on: info)
        w.orderFront(nil)
        watchOcclusion(w)
        followSurround()
    }

    /// Watches the one value, and repaints the surround and the window
    /// behind it when it changes. Observation tells once, so it asks again.
    private func followSurround() {
        withObservationTracking {
            _ = live.viewerBackground
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.surround = self.live.viewerBackground
                self.window?.backgroundColor = DisplaySurround.color(self.state.surround,
                                                                     wide: self.state.fills || self.state.isPresenting)
                self.followSurround()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    // MARK: - the window, exactly (§3.2)

    private func configure(_ w: PictureWindow, on info: ScreenInfo) {
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // A background drag must pan the photograph, not move the window.
        w.isMovableByWindowBackground = false
        // Not `.canJoinAllSpaces`: a picture window that follows him into
        // every Space is a picture window in the way.
        w.collectionBehavior = [.managed, .fullScreenPrimary, .ignoresCycle]
        // Without this, "prefer tabs when opening documents" can absorb the
        // picture window into the main window's tab bar — which would put it
        // on the laptop, silently, and delete the feature.
        w.tabbingMode = .disallowed
        // We restore it ourselves, after the screen list is known: scene
        // restoration runs before we know which displays are attached and
        // would place it on the wrong one.
        w.isRestorable = false
        // No genie on a photograph.
        w.animationBehavior = .none
        w.isExcludedFromWindowsMenu = false
        w.hasShadow = true
        w.backgroundColor = DisplaySurround.color(director?.settings.viewerBackground ?? .neutralGrey,
                                                  wide: true)
        w.minSize = NSSize(width: 480, height: 360)
        // The window's appearance is not set here: light or dark is his, it is
        // applied to the whole app at once, and this window follows it like
        // every other. What does not follow it is the surround, and the two
        // hairlines and the quiet lines drawn straight onto the surround take
        // their contrast from the surround rather than from the appearance.
        // A minimised picture window is an invisible feature with no way back
        // except the Dock, so it cannot be minimised at all.
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        // It never floats: a window that stays above PhotoLab is a nuisance in
        // the one workflow that mixes them.
        w.level = .normal
        setChrome(visible: false, animated: false)
    }

    private func place(on info: ScreenInfo) {
        guard let w = window else { return }
        let name = "picture.\(info.key.sanitised)"
        // `setFrameAutosaveName` does nothing and returns false if the name is
        // already in use, and swapping without clearing is the classic way
        // this silently stops saving.
        w.setFrameAutosaveName("")
        let restored = w.setFrameUsingName(name)
        w.setFrameAutosaveName(name)
        if !restored {
            w.setFrame(defaultFrame(on: info), display: true)
        }
        w.title = state.windowTitle
        w.subtitle = state.windowSubtitle
    }

    /// Filling the screen on an external; a floating frame inset 80 pt on the
    /// built-in, where "the other screen" would be a lie and the light table
    /// underneath has to stay reachable.
    private func defaultFrame(on info: ScreenInfo) -> NSRect {
        info.isBuiltIn ? info.visibleFrame.insetBy(dx: 80, dy: 80) : info.visibleFrame
    }

    // MARK: - PicturePresenting

    public var pixelsWanted: Int {
        let scale = window?.backingScaleFactor ?? 2
        let box = content?.pictureBox ?? CGRect(x: 0, y: 0, width: 960, height: 640)
        return PixelTier.px(forPointWidth: box.width, scale: scale)
    }

    public private(set) var isDrawing = true

    public func show(_ c: BigPictureContent) {
        let changedBurst = state.content.caption?.burstNumber != c.caption?.burstNumber
        let changedVerdict = state.content.caption?.his != c.caption?.his
            && state.content.stem == c.stem
        state.content = c
        state.pump = director?.pumpForViews
        state.shoot = director?.shootName ?? ""
        state.heldStem = director?.heldStem
        state.surround = director?.settings.viewerBackground ?? .neutralGrey
        state.hidePointerWhenStill = director?.settings.hidePointerOnTheOtherScreen ?? true
        // Only while a job is running; it disappears when the job ends, like
        // the toolbar item.
        let job = director?.currentJob
        state.jobFraction = (job?.running == true) ? job?.fraction : nil
        state.onDisplay = { [weak self] stem, generation in
            self?.director?.pictureDidDisplay(stem: stem, generation: generation)
        }
        state.onPick = { [weak self] stem in
            self?.director?.input?.moveCursor(toStem: stem)
        }
        window?.title = state.windowTitle
        window?.subtitle = state.windowSubtitle
        // A burst change is rare and orienting, so it shows the HUD. A frame
        // change never does: a capsule that flashed on every K press would be
        // three hundred flashes an hour.
        if changedBurst, c.caption != nil { revealHUD(seconds: 1.2) }
        if changedVerdict, let his = c.caption?.his, his != .unmarked { flashBadge(his) }
    }

    /// His verdict is always echoed here, in the surround, never over the
    /// photograph: his eyes are on this screen when he presses, and a silent
    /// verdict here would be the app refusing to say what it just did.
    public func flashBadge(_ his: VerdictValue.His) {
        state.badge = his
        badgeTimer?.cancel()
        badgeTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1050))
            guard !Task.isCancelled else { return }
            self?.state.badge = nil
        }
    }

    public func setMode(_ mode: DisplayDirector.Mode) {
        state.mode = mode
    }

    public func fill(_ on: Bool) {
        state.fills = on
        guard let w = window, let screen = w.screen else { return }
        if on { w.setFrame(screen.visibleFrame, display: true) }
        w.backgroundColor = DisplaySurround.color(state.surround, wide: on || state.isPresenting)
    }

    public func setDrawing(_ on: Bool) {
        guard isDrawing != on else { return }
        isDrawing = on
        state.isDrawing = on
        content?.setDrawing(on)
    }

    /// Between a display's begin-configuration edge and the change landing,
    /// the window holds exactly what it has: no stretched frame, no flash of
    /// the wrong size, no burst of requests at a size about to be wrong.
    public func setFrozen(_ on: Bool) {
        state.isFrozen = on
        content?.setFrozen(on)
    }

    public func screensChanged(_ set: ScreenSet) {
        guard let w = window, let screen = w.screen else { return }
        let key = ScreenKey(screen)
        if key != screenKey {
            screenKey = key
            place(on: ScreenInfo(screen, menuBarScreen: NSScreen.screens.first))
        }
        content?.backingChanged()
    }

    public var screensHaveSeparateSpaces: Bool { NSScreen.screensHaveSeparateSpaces }

    public func enterFullScreen() {
        window?.toggleFullScreen(nil)
    }

    public func showHUD(_ sentence: String, seconds: Double) {
        state.hudExtraLine = sentence
        revealHUD(seconds: seconds)
    }

    public func rubberBand() {
        state.rubberBand &+= 1
    }

    public func beginPresentation() {
        state.isPresenting = true
        state.chromeRevealed = false
        setChrome(visible: false, animated: false)
        window?.backgroundColor = DisplaySurround.color(state.surround, wide: true)
        if NSScreen.screensHaveSeparateSpaces {
            // True full screen hides the menu bar on that display only, by the
            // system's own doing. `NSApplication.presentationOptions` is
            // application-wide and would take the menu bar off the laptop too,
            // where he still needs it.
            window?.toggleFullScreen(nil)
        } else if let screen = window?.screen {
            window?.setFrame(screen.frame, display: true)
            NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        }
        state.exitHint = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.state.exitHint = false
        }
        content?.setPointerHiding(after: 2)
    }

    public func endPresentation() {
        state.isPresenting = false
        state.exitHint = false
        if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
        NSApp.presentationOptions = []
        content?.setPointerHiding(after: 1.5)
        fill(state.fills)
    }

    public override func close() {
        guard !isClosing else { return }
        isClosing = true
        chromeTimer?.cancel()
        hudTimer?.cancel()
        badgeTimer?.cancel()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        occlusionObserver = nil
        content?.tearDown()
        window?.delegate = nil
        window?.orderOut(nil)
        window?.close()
    }

    // MARK: - chrome that is not there until he looks for it

    /// QuickTime Player's pattern, and HIG-correct: a window he cannot close
    /// from the keyboard is not acceptable, and a title bar permanently over a
    /// photograph is not either.
    private func revealChrome(_ on: Bool) {
        guard !state.isPresenting else { return }
        chromeTimer?.cancel()
        if on {
            setChrome(visible: true, animated: true)
        } else {
            chromeTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                self?.setChrome(visible: false, animated: true)
            }
        }
    }

    private func setChrome(visible: Bool, animated: Bool) {
        guard let w = window else { return }
        state.chromeRevealed = visible
        w.titleVisibility = visible ? .visible : .hidden
        // Revealed, it is the system's own bar, with the system's own backing —
        // a name written straight onto a photograph is a name nobody can read.
        // Hidden, it is transparent and the photograph has the whole window.
        // The content view is full-size either way, so nothing reflows.
        w.titlebarAppearsTransparent = !visible
        let buttons: [NSWindow.ButtonType] = [.closeButton, .zoomButton]
        let target: CGFloat = visible ? 1 : 0
        for b in buttons {
            guard let button = w.standardWindowButton(b) else { continue }
            if animated && !Motion.reduced {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    button.animator().alphaValue = target
                }
            } else {
                button.alphaValue = target
            }
        }
    }

    private func revealHUD(seconds: Double = 1.5) {
        guard !state.isPresenting else { return }
        if director?.hasSaidKeysStayPut == false {
            // The one macOS reflex this design breaks is "click a window to
            // type in it". Once per launch, never again.
            state.hudOnceLine = DisplayStrings.Picture.keysStayOnTheOtherScreen
            director?.hudWasRevealed()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.state.hudOnceLine = nil
            }
        }
        state.hudVisible = true
        hudTimer?.cancel()
        hudTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.state.hudVisible = false
            self?.state.hudExtraLine = nil
        }
    }

    // MARK: - NSWindowDelegate

    /// The green button fills the screen: the menu bar and the Dock keep their
    /// strip and the window covers everything else.
    public func windowWillUseStandardFrame(_ sender: NSWindow, defaultFrame: NSRect) -> NSRect {
        sender.screen?.visibleFrame ?? defaultFrame
    }

    public func windowDidChangeScreen(_ notification: Notification) {
        guard let w = window, let screen = w.screen else { return }
        let key = ScreenKey(screen)
        guard key != screenKey else { content?.backingChanged(); return }
        screenKey = key
        place(on: ScreenInfo(screen, menuBarScreen: NSScreen.screens.first))
        content?.backingChanged()
    }

    public func windowDidChangeBackingProperties(_ notification: Notification) {
        content?.backingChanged()
    }

    /// After every full-screen transition: a picture window that cannot be
    /// key, alone in a full-screen Space, is the one arrangement in which keys
    /// could otherwise go nowhere. `makeKey()`, not `makeKeyAndOrderFront(_:)`,
    /// so the laptop's window becomes key without being dragged into view over
    /// anything.
    public func windowDidEnterFullScreen(_ notification: Notification) { assertKeyIsElsewhere() }
    public func windowDidExitFullScreen(_ notification: Notification) { assertKeyIsElsewhere() }

    private func assertKeyIsElsewhere() {
        guard NSApp.keyWindow == nil else { return }
        let main = NSApp.windows.first { $0 !== window && $0.canBecomeKey }
        main?.makeKey()
    }

    public func windowWillClose(_ notification: Notification) {
        director?.close()
    }

    /// The cheap win that keeps two windows from costing two windows' worth of
    /// memory and power for the eighty per cent of a session where one of them
    /// is covered.
    private func watchOcclusion(_ w: NSWindow) {
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let w = self.window else { return }
                self.setDrawing(w.occlusionState.contains(.visible))
            }
        }
    }
}
#endif
