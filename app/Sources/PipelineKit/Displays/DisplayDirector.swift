import Foundation
import Observation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

/// The one object that knows about the second screen.
///
/// The rule it exists to keep: **the second screen owns nothing that can be
/// lost.** The cursor, every verdict, the undo stack, the zoom, the aim, the
/// filmstrip scroll and the "been through" set live in `ShootSession` and the
/// light table, both owned by the main window. The picture window is a view.
/// The only state held here is the mode, the fill flag and the held frame —
/// and the mode and the fill flag are on disk before they can be lost.
@MainActor @Observable
public final class DisplayDirector {

    public enum Mode: String, CaseIterable, Codable, Sendable {
        /// Whatever the light table is doing, bigger. The default, and the one
        /// he will leave it in: zero new state, nothing to remember, and it can
        /// never be showing something stale.
        case follow
        /// The current frame, always, even while the laptop is in Compare or
        /// All Bursts.
        case frame
        /// A contact sheet of the burst he is in.
        case wholeBurst

        public var title: String {
            switch self {
            case .follow: return DisplayStrings.Menu.follow
            case .frame: return DisplayStrings.Menu.alwaysTheFrame
            case .wholeBurst: return DisplayStrings.Menu.theWholeBurst
            }
        }
    }

    public enum Presence: Equatable, Sendable {
        case closed
        case open(ScreenKey)
        case presenting(ScreenKey)

        public var key: ScreenKey? {
            switch self {
            case .closed: return nil
            case .open(let k), .presenting(let k): return k
            }
        }
    }

    public enum CompareTarget: Sendable, Equatable { case mainWindow, pictureWindow }

    // MARK: - read by the light table

    public private(set) var presence: Presence = .closed
    public var isOpen: Bool { presence != .closed }
    public var isPresenting: Bool { if case .presenting = presence { return true }; return false }

    /// `.pictureWindow` only when the window is open **and** the setting is on.
    /// With it off, or with no picture window, `C` behaves exactly as
    /// `DESIGN.md` describes and the main window becomes Compare.
    public var compareTarget: CompareTarget {
        guard case .open = presence, settings.compareOnTheOtherScreen else { return .mainWindow }
        return .pictureWindow
    }

    /// The frame frozen on the other screen, if any. Hold keeps its own zoom.
    public private(set) var heldStem: String?
    public private(set) var heldContent: BigPictureContent?

    /// One plain sentence for the control bar, in ordinary text — a screen
    /// coming or going is not a refusal. It carries `RefusalOwner.displays`, so
    /// it can never wipe a live verdict refusal and a later unrelated success
    /// can never wipe it.
    public private(set) var note: String?

    /// The deck, while a deck is being shown.
    public private(set) var deck: PresentationDeck?

    /// The mode of the screen the window is on now, or of the screen it would
    /// open on.
    public private(set) var mode: Mode = .follow
    public private(set) var fills: Bool = true

    /// What the picture window last actually drew. It goes **only** here and to
    /// the HUD. It never reaches `ShootSession.displayed`, because the picture
    /// window's screen can be asleep, occluded, disconnected or showing a
    /// contact sheet — gating his verdicts on a window that may not be drawing
    /// would make a verdict impossible to record for reasons he cannot see
    /// (§2.6).
    public private(set) var pictureDisplayed: (stem: String, generation: Int)?

    /// Set once per launch, the first time the HUD is revealed.
    public private(set) var hasSaidKeysStayPut = false

    // MARK: - what it is built from

    public let settings: SettingsStore
    public let screens: ScreenWatcher
    /// Set at init for a test, and again by the app the first time the engine
    /// is up: the pump does not exist until there is an endpoint to read
    /// photographs from, and it is made again on every engine restart.
    private var pump: ImagePump?
    private let jobs: JobModel?

    /// The light table, while Choose Keepers is on screen.
    private weak var table: (any LightTable)?
    private weak var session: ShootSession?
    /// A page that asked for frames to be shown large (§5.3). It is consulted
    /// only while the light table is not attached, so his own culling always
    /// wins the screen.
    private weak var guest: (any BigPictureSource)?
    private var guestContent: BigPictureContent?

    /// The engine's own sentence, when it is down.
    public var engineSentence: String?

    /// Called after the screen list has changed and this object has finished
    /// with it, so the menu bar's list of screens can be rebuilt. Set by the
    /// app; the watcher's own `onChange` belongs to this object.
    public var onScreensChanged: (@MainActor () -> Void)?

    /// Where a gesture on the picture window goes. Every one of these lands in
    /// the light table's own model on the **main** window, so zoom, aim and the
    /// cursor stay single-valued. Nothing here writes without going through the
    /// light table's display gate.
    public weak var input: (any PictureInput)?

    /// The pump the picture window's views draw from.
    public var pumpForViews: ImagePump? { pump }
    public var shootName: String { session?.name ?? table?.shoot ?? "" }
    public var currentJob: Job? { jobs?.job }

    /// Makes the window. Replaced in tests by something that records instead
    /// of drawing, so every rule here is asserted with no display attached.
    public var makeWindow: @MainActor (ScreenInfo, DisplayDirector) -> any PicturePresenting

    /// Installs the app-wide watch for Esc and the arrows while a deck runs.
    /// Returns a token to remove. Replaced in tests.
    public var installPresentationWatch: @MainActor (DisplayDirector) -> Any?
    public var removePresentationWatch: @MainActor (Any) -> Void
    private var presentationWatch: Any?

    private var window: (any PicturePresenting)?
    #if canImport(AppKit)
    var screensPanel: ScreensPanelController?
    #endif
    private var memory = DisplayMemory()
    private var noteTimer: Task<Void, Never>?
    private var prefetcher: PicturePrefetcher?

    // MARK: - init

    public init(settings: SettingsStore = .shared,
                pump: ImagePump? = nil,
                jobs: JobModel? = nil,
                screens: ScreenWatcher) {
        self.settings = settings
        self.pump = pump
        self.jobs = jobs
        self.screens = screens
        #if canImport(AppKit)
        self.makeWindow = { info, director in PictureWindowController(on: info, director: director) }
        self.installPresentationWatch = { director in
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let taken = MainActor.assumeIsolated { () -> Bool in
                    guard let k = PresentationKey.from(event) else { return false }
                    return director.presentationKey(k)
                }
                return taken ? nil : event
            }
        }
        self.removePresentationWatch = { token in NSEvent.removeMonitor(token) }
        #else
        self.makeWindow = { info, _ in NullPicture(screenKey: info.key) }
        self.installPresentationWatch = { _ in nil }
        self.removePresentationWatch = { _ in }
        #endif
        if let pump { prefetcher = PicturePrefetcher(pump: pump) }
        memory = DisplayMemory.load(from: settings.defaults)
        memory.prune()
        memory.save(to: settings.defaults)
        screens.onChange = { [weak self] set in self?.screensChanged(set) }
        screens.onReconfiguring = { [weak self] on in self?.window?.setFrozen(on) }
    }

    /// The engine came up, or came back. Everything that reads photographs is
    /// new, so the prefetcher is too; anything the old one had in flight is
    /// for an endpoint that no longer answers.
    public func attach(pump: ImagePump?) {
        guard pump !== self.pump else { return }
        prefetcher?.cancelAll()
        self.pump = pump
        prefetcher = pump.map { PicturePrefetcher(pump: $0) }
        refresh()
    }

    // MARK: - the light table, twice

    public func attach(_ viewer: any LightTable, session: ShootSession) {
        table = viewer
        self.session = session
        guest = nil
        guestContent = nil
        refresh()
    }

    /// He has left Choose Keepers. The shoot is still open, so the screen says
    /// which one and then goes quiet; a held frame belongs to the step he left,
    /// so it is released.
    public func detach() {
        table = nil
        heldStem = nil
        heldContent = nil
        endPresentation(quietly: true)
        refresh()
    }

    /// The open shoot changed, or there is no longer one. Called by the shell,
    /// not by the light table.
    public func shootOpened(_ session: ShootSession?) {
        self.session = session
        if session == nil {
            table = nil
            heldStem = nil
            heldContent = nil
            endPresentation(quietly: true)
        }
        refresh()
    }

    /// Anything with frames to show large (§5.3): the extension's grids, the
    /// reels grid, the learning screen's review Compare.
    public func present(_ content: BigPictureContent, from source: any BigPictureSource) {
        guest = source
        guestContent = content
        if !isOpen { open(on: nil) }
        refresh()
    }

    // MARK: - opening and closing

    public func toggleWindow() {
        isOpen ? close() : open(on: nil)
    }

    /// `nil` is §3.3's choice: the screen it was last open on if it is here,
    /// otherwise the largest external, otherwise the built-in.
    public func open(on key: ScreenKey?) {
        guard let info = screens.screens.best(preferring: key ?? lastUsedKey()) else { return }
        if let window, window.screenKey == info.key { return }
        window?.close()
        let remembered = memory.panel(for: info.key)
        mode = remembered?.mode ?? .follow
        // A window on the built-in floats rather than fills, so the light
        // table underneath stays reachable.
        fills = remembered?.fills ?? !info.isBuiltIn
        let w = makeWindow(info, self)
        window = w
        presence = .open(info.key)
        w.fill(fills)
        w.setMode(mode)
        memory.remember(open: true, on: info.key, mode: mode, fills: fills)
        memory.save(to: settings.defaults)
        refresh()
    }

    public func close() {
        endPresentation(quietly: true)
        if let key = presence.key {
            memory.remember(open: false, on: key, mode: mode, fills: fills)
            memory.save(to: settings.defaults)
        }
        window?.close()
        window = nil
        presence = .closed
        // Closing the window releases the hold and writes nothing.
        heldStem = nil
        heldContent = nil
        prefetcher?.cancelAll()
        refresh()
    }

    public func setMode(_ m: Mode) {
        mode = m
        window?.setMode(m)
        if let key = presence.key {
            memory.remember(open: true, on: key, mode: m, fills: fills)
            memory.save(to: settings.defaults)
        }
        announce(DisplayStrings.Picture.announceMode(m.title))
        refresh()
    }

    public func fillScreen(_ on: Bool) {
        fills = on
        window?.fill(on)
        if let key = presence.key {
            memory.remember(open: true, on: key, mode: mode, fills: on)
            memory.save(to: settings.defaults)
        }
    }

    /// Refuses politely rather than blanking the laptop: with "Displays have
    /// separate Spaces" off, full screen on one display darkens every other
    /// one — including the screen with his control bar on it.
    public func enterFullScreen() {
        guard let window else { return }
        if !window.screensHaveSeparateSpaces {
            window.showHUD(DisplayStrings.Refusal.fullScreenWouldDarkenTheOther, seconds: 4)
            fillScreen(true)
            return
        }
        window.enterFullScreen()
    }

    // MARK: - Hold (H)

    /// Freezes whatever is there now — frame, zoom and aim — and the laptop
    /// keeps moving. *Is this new one better than the one I already kept?*
    /// Through a thirty-frame burst that question is asked constantly and today
    /// it can only be answered from memory.
    public func toggleHold() {
        guard isOpen, !isPresenting else { return }
        if heldStem != nil {
            heldStem = nil
            heldContent = nil
        } else {
            let live = liveContent()
            guard let stem = live.stem else { return }
            heldStem = stem
            heldContent = live
            announce(DisplayStrings.Picture.announceHold(ShootSession.shortStem(stem)))
        }
        refresh()
    }

    /// Esc releases a hold, but only after the main window has run out of
    /// things of its own to leave — Full Image, Compare, All Bursts and review
    /// mode all come first, as §2.5.3 already orders them.
    @discardableResult
    public func escapeReleasesHold() -> Bool {
        guard heldStem != nil else { return false }
        heldStem = nil
        heldContent = nil
        refresh()
        return true
    }

    // MARK: - Presentation (§5.6)

    public func beginPresentation(_ kind: PresentationDeck.Kind = .whatIKept) {
        guard let session else { return }
        var made = PresentationDeck.make(kind, from: session)
        if made.isEmpty, kind == .whatIKept {
            made = PresentationDeck.make(.thisBurst, from: session)
            say(DisplayStrings.Note.nothingKeptYet)
        }
        guard !made.isEmpty else { return }
        if !isOpen { open(on: nil) }
        guard let key = presence.key else { return }
        deck = made
        heldStem = nil
        heldContent = nil
        presence = .presenting(key)
        window?.beginPresentation()
        presentationWatch = installPresentationWatch(self)
        refresh()
    }

    public func endPresentation() { endPresentation(quietly: false) }

    private func endPresentation(quietly: Bool) {
        guard deck != nil || isPresenting else { return }
        deck = nil
        if let token = presentationWatch { removePresentationWatch(token) }
        presentationWatch = nil
        window?.endPresentation()
        if case .presenting(let key) = presence { presence = .open(key) }
        if !quietly { refresh() }
    }

    /// The keys a guest can press, arriving app-wide so a Space switch can
    /// never strand them. Returns true when it was handled here.
    @discardableResult
    public func presentationKey(_ key: PresentationKey) -> Bool {
        guard deck != nil else { return false }
        if key == .escape { endPresentation(); return true }
        guard var d = deck else { return false }
        let moved: Bool
        switch key {
        case .right: moved = d.next()
        case .left: moved = d.previous()
        case .down, .nextBurst: moved = d.nextBurst()
        case .up, .previousBurst: moved = d.previousBurst()
        case .home: moved = d.first()
        case .end: moved = d.last()
        case .escape: moved = false
        }
        deck = d
        if moved {
            refresh()
        } else {
            window?.rubberBand()
        }
        return true
    }

    /// The light table asks before it acts, so Presentation's refusals live in
    /// one place rather than in nine.
    public func allows(_ action: DisplayAction) -> Bool {
        guard isPresenting else { return true }
        return !action.decidesSomething
    }

    /// The sentence to show when `allows(_:)` said no.
    public var refusalWhilePresenting: String {
        DisplayStrings.Refusal.nothingDecidedWhilePresenting
    }

    // MARK: - what is on the screen

    /// Recomputed whenever anything it reads has changed. Hold wins over
    /// everything except Presentation, which has its own cursor.
    public var content: BigPictureContent {
        if let deck, let stem = deck.currentStem {
            return .frame(stem: stem, caption: deckCaption(stem, deck), zoom: .fit)
        }
        if let held = heldContent { return held }
        return liveContent()
    }

    private func liveContent() -> BigPictureContent {
        if let sentence = engineSentence { return .engineDown(sentence: sentence) }

        if let table {
            switch mode {
            case .frame:
                return frameContent(table)
            case .wholeBurst:
                return .burst(id: table.burstIdentifier, cells: table.burstCells, cursor: table.cursorInBurst)
            case .follow:
                switch table.lightTableMode {
                case .single:
                    return frameContent(table)
                case .compare:
                    return .tiles(table.compareTiles, focus: table.compareFocus, zoom: table.zoomState)
                case .allBursts:
                    // The whole burst he is in, not the cover grid: covers are
                    // for aiming, and aiming is on the laptop.
                    return .burst(id: table.burstIdentifier, cells: table.burstCells,
                                  cursor: table.cursorInBurst)
                }
            }
        }

        if let guestContent { return guestContent }

        if let job = jobs?.job, job.running, job.fraction >= 0 {
            return .job(title: job.title.isEmpty ? job.kind : job.title,
                        stage: job.stage, fraction: job.fraction)
        }
        if let session {
            return .nothing(line: DisplayStrings.Picture.shootAndStep(session.name, stepWord()))
        }
        return .nothing(line: DisplayStrings.Picture.noShootOpen)
    }

    private func frameContent(_ table: any LightTable) -> BigPictureContent {
        guard let stem = table.currentStem, let caption = table.currentCaption else {
            return .nothing(line: nil)
        }
        return .frame(stem: stem, caption: withCullsLine(caption), zoom: table.zoomState)
    }

    /// The cull's line is off on this screen by default, and never over the
    /// photograph even when it is on.
    private func withCullsLine(_ c: FrameCaption) -> FrameCaption {
        guard settings.cullsLineOnTheOtherScreen else {
            return FrameCaption(shoot: c.shoot, shortStem: c.shortStem, indexInBurst: c.indexInBurst,
                                framesInBurst: c.framesInBurst, burstNumber: c.burstNumber,
                                burstsInShoot: c.burstsInShoot, his: c.his, cullsLine: nil)
        }
        return c
    }

    private func deckCaption(_ stem: String, _ d: PresentationDeck) -> FrameCaption {
        let burst = (d.currentBurst ?? 0) + 1
        return FrameCaption(shoot: session?.name ?? "", shortStem: ShootSession.shortStem(stem),
                            indexInBurst: d.index + 1, framesInBurst: d.count,
                            burstNumber: burst, burstsInShoot: session?.bursts.count ?? burst,
                            his: .unmarked, cullsLine: nil)
    }

    private func stepWord() -> String { "Cull" }

    // MARK: - drawing it

    /// Hand the window its content and ask for what comes next.
    public func refresh() {
        let c = content
        window?.show(c)
        prefetchAround(c)
    }

    private func prefetchAround(_ c: BigPictureContent) {
        guard let prefetcher, let window, let session else { return }
        guard window.isDrawing else { prefetcher.cancelAll(); return }
        let px = window.pixelsWanted
        // The laptop is always served first: its size is smaller and lands
        // sooner, so the display gate is satisfied at the earliest possible
        // moment and this screen catches up a frame-time later.
        prefetcher.want(shoot: session.name, stems: neighbours(of: c), pixels: px)
    }

    /// The frame he is on and one in each direction — a ring of three. He does
    /// not arrow backwards through fifteen frames at 4096; he moves forward,
    /// and the thumbnail and `/large` sizes are still underneath for anything
    /// further, so it is progressive and never blank.
    private func neighbours(of c: BigPictureContent) -> [String] {
        switch c {
        case .frame(let stem, _, _):
            guard let session, let b = session.currentBurst,
                  let i = b.frames.firstIndex(of: stem) else { return [stem] }
            return [i, i + 1, i - 1].filter(b.frames.indices.contains).map { b.frames[$0] }
        case .tiles(let t, _, _):
            return t.map(\.stem)
        case .burst, .nothing, .job, .engineDown:
            return []
        }
    }

    /// The picture window drew a frame. This is measurement and a HUD, and
    /// nothing else: a unit test asserts it can never satisfy the display gate.
    public func pictureDidDisplay(stem: String, generation: Int) {
        pictureDisplayed = (stem, generation)
    }

    public func hudWasRevealed() {
        hasSaidKeysStayPut = true
    }

    // MARK: - screens coming and going (§3.7)

    func screensChanged(_ set: ScreenSet) {
        // Every window re-reads its backing scale and its screen's colour
        // space; the sizes asked for are recomputed from there.
        window?.screensChanged(set)

        if let key = presence.key {
            if let here = set[key] {
                // Still here. The lid may have closed, which puts both windows
                // on one screen.
                if here.isBuiltIn, set.screens.count == 1, fills {
                    fillScreen(false)
                    say(DisplayStrings.Note.oneScreenNow)
                }
                if here.isAsleep { window?.setDrawing(false) } else { window?.setDrawing(true) }
            } else {
                lost(key)
            }
        } else if settings.bringThePictureBack {
            // A screen it has been used on before, and only that.
            for info in set.externals where memory.wasOpen(on: info.key) {
                open(on: info.key)
                say(DisplayStrings.Note.screenIsBack)
                break
            }
        }
        refresh()
        onScreensChanged?()
    }

    /// At launch, once the screen list is known.
    ///
    /// The picture comes back on a screen it has been used on before, and only
    /// on one of those. It says nothing about it: nothing went away, so there
    /// is nothing to tell him — the note belongs to a screen that came back
    /// while he was working.
    public func restoreAtLaunch() {
        guard !isOpen, settings.bringThePictureBack else { return }
        for info in screens.screens.externals where memory.wasOpen(on: info.key) {
            open(on: info.key)
            break
        }
        refresh()
    }

    /// The window is closed and released, its state written, and **nothing
    /// else happens**. No alert, no sheet, no confirmation, no re-layout, no
    /// scroll, no focus change, no navigation. He is mid-burst and the next K
    /// must land on the same frame it would have landed on a second earlier.
    private func lost(_ key: ScreenKey) {
        let wasPresenting = isPresenting
        memory.remember(open: true, on: key, mode: mode, fills: fills)
        memory.save(to: settings.defaults)
        endPresentation(quietly: true)
        window?.close()
        window = nil
        presence = .closed
        heldStem = nil
        heldContent = nil
        // The big requests in flight are cancelled at once so they do not
        // queue ahead of the laptop's next frame.
        prefetcher?.cancelAll()
        say(wasPresenting ? DisplayStrings.Note.presentationScreenWentAway
                          : DisplayStrings.Note.screenWentAway)
    }

    private func lastUsedKey() -> ScreenKey? {
        memory.mostRecentlyOpen(among: screens.screens)
    }

    // MARK: - the one-line note

    public func say(_ sentence: String) {
        note = sentence
        noteTimer?.cancel()
        noteTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.note = nil
        }
    }

    /// His next key press clears it, whichever comes first.
    public func clearNote() {
        noteTimer?.cancel()
        noteTimer = nil
        note = nil
    }

    private func announce(_ sentence: String) {
        #if canImport(AppKit)
        NSAccessibility.post(element: NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: sentence,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        #endif
    }
}

// MARK: - what a gesture on the far screen reaches

/// The light table's own model, as the picture window's gestures need to see
/// it. Zoom and aim are **one** piece of state, shared: two independent zoom
/// levels would mean two answers to "am I at 1:1", and §2.5.7's whole design —
/// holding the aim relative to the face across a burst — only works if there is
/// one aim.
@MainActor
public protocol PictureInput: AnyObject {
    func toggleFitOneToOne(atFramePoint point: CGPoint)
    func pinch(scaleBy factor: CGFloat, atFramePoint point: CGPoint)
    func smartZoom(atFramePoint point: CGPoint)
    func peek(_ on: Bool, atFramePoint point: CGPoint)
    func pan(byFramePoints delta: CGSize)
    /// Two-finger swipe, through the same gate that never lands on an
    /// undecoded frame.
    func step(forward: Bool)
    func focusTile(_ index: Int)
    func moveCursor(toStem stem: String)
    /// A context-menu verdict, taken on the main window, through the main
    /// window's display gate.
    func verdict(_ action: DisplayAction, onStem stem: String)
}

// MARK: - files, for the context menu and the drag (§5.5)

extension DisplayDirector {
    /// The exported JPEG for a frame, if the engine has written one.
    public func exportedFile(for stem: String) -> URL? {
        guard let session, !session.info.export.isEmpty else { return nil }
        let url = URL(fileURLWithPath: session.info.export).appendingPathComponent("\(stem).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    #if canImport(AppKit)
    /// The finished file if there is one, and a promise fetched from
    /// `/full?px=4096` if there is not. Never the RAW.
    public func pasteboardWriter(for stem: String) -> NSPasteboardWriting? {
        let shoot = shootName
        guard !shoot.isEmpty else { return nil }
        let client = session?.client
        return FrameDrag.pasteboardWriter(for: stem, exported: exportedFile(for: stem)) {
            guard let client else { return nil }
            let route = ImageRoute.full(shoot: shoot, stem: stem, px: 4096)
            guard let got = try? await URLSession.studio.data(for: client.imageRequest(route)),
                  let http = got.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return nil }
            return got.0
        }
    }
    #endif
}

// MARK: - the window, behind a seam

/// What the director needs a window to do. The real one is an `NSWindow`; the
/// tests hand in one that records, so every rule above is asserted on a build
/// machine with no display attached.
@MainActor
public protocol PicturePresenting: AnyObject {
    var screenKey: ScreenKey { get }
    /// The pixels this window wants for one frame, from its own point size and
    /// its own backing scale.
    var pixelsWanted: Int { get }
    /// False while its screen is asleep or the window is covered: the display
    /// link is stopped, the ring is 1 and prefetch is paused.
    var isDrawing: Bool { get }

    func show(_ content: BigPictureContent)
    func setMode(_ mode: DisplayDirector.Mode)
    func fill(_ on: Bool)
    func setDrawing(_ on: Bool)
    /// Between a display's begin-configuration edge and the change landing,
    /// the window holds exactly what it has.
    func setFrozen(_ on: Bool)
    func screensChanged(_ set: ScreenSet)
    func enterFullScreen()
    var screensHaveSeparateSpaces: Bool { get }
    func showHUD(_ sentence: String, seconds: Double)
    func rubberBand()
    func beginPresentation()
    func endPresentation()
    func close()
}

/// A window that draws nothing, for a platform with no AppKit and for tests.
@MainActor
public final class NullPicture: PicturePresenting {
    public let screenKey: ScreenKey
    public var pixelsWanted = 4096
    public var isDrawing = true
    public private(set) var shown: BigPictureContent = .nothing(line: nil)
    public private(set) var mode: DisplayDirector.Mode = .follow
    public private(set) var fills = true
    public private(set) var isClosed = false
    public private(set) var hud: String?
    public private(set) var rubberBands = 0
    public var screensHaveSeparateSpaces = true

    public init(screenKey: ScreenKey) { self.screenKey = screenKey }

    public func show(_ content: BigPictureContent) { shown = content }
    public func setMode(_ mode: DisplayDirector.Mode) { self.mode = mode }
    public func fill(_ on: Bool) { fills = on }
    public func setDrawing(_ on: Bool) { isDrawing = on }
    public func setFrozen(_ on: Bool) {}
    public func screensChanged(_ set: ScreenSet) {}
    public func enterFullScreen() {}
    public func showHUD(_ sentence: String, seconds: Double) { hud = sentence }
    public func rubberBand() { rubberBands += 1 }
    public func beginPresentation() {}
    public func endPresentation() {}
    public func close() { isClosed = true }
}
