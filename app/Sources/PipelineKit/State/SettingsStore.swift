import Foundation
import Observation

/// Typed `UserDefaults`, and the part of the child's environment that comes
/// from Settings (DESIGN.md §3.8).
///
/// The library folder and the extension folder are also handed to
/// the engine when it starts, which is why changing the library folder
/// restarts the engine. The window frame is not here: AppKit's own autosave
/// keeps it.
///
/// `UserDefaults` is safe to use from any thread, which is what makes this
/// class `Sendable`: it holds nothing else.
public final class SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore()

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public enum Key: String, CaseIterable, Sendable {
        case libraryFolder = "general.libraryFolder"
        case editor = "general.editor"
        case checkForUpdates = "general.checkForUpdates"
        case appearance = "general.appearance"
        case extensionFolder = "advanced.extensionFolder"
        case webInspector = "advanced.webInspector"
        case viewerBackground = "choosing.viewerBackground"
        case spaceShowsWholePicture = "choosing.spaceShowsWholePicture"
        case afterLastFrameGoesOn = "choosing.afterLastFrameGoesOn"
        case reasonsStripAfterDrop = "choosing.reasonsStripAfterDrop"
        case openLargeStacksInCompare = "choosing.openLargeStacksInCompare"
        case showCullMarks = "choosing.showCullMarks"
        case learnAutomatically = "learning.automatically"
        case learnOnlyWhenIdle = "learning.onlyWhenIdle"
        case firstRunDone = "app.firstRunDone"
        case copyCheck = "copying.check"
        case ejectAfterCopying = "copying.ejectAfter"
        /// The shoot and the step he was on (`LastPlace`), not a preference.
        case lastPlace = "app.lastPlace"
        /// Per shoot, the step he was last on in it (`ShootSteps`).
        case shootSteps = "app.shootSteps"
        /// ⌥⌘I, once he has pressed it: shown or hidden. Absent until then.
        case inspectorPinned = "view.inspectorPinned"
        /// The sidebar's Finished section, once he has opened or closed it.
        case finishedExpanded = "view.finishedExpanded"
    }

    // MARK: General

    /// `PHOTOS_ROOT` for the engine. `nil` means the engine's own default, or
    /// whatever the environment the app was started with already says.
    ///
    /// Normalised both ways, through `LibraryFolder` — on the way in so the
    /// folder he picked is the folder that works, and on the way *out* so a
    /// value written by an older build fixes itself the next time the app
    /// starts rather than needing a hand at the defaults. A folder no shoot
    /// can be found under is stored and returned exactly as he gave it: the
    /// app never points the engine somewhere he did not choose.
    public var libraryFolder: URL? {
        get { url(.libraryFolder).map { LibraryFolder.normalised($0) } }
        set { set(.libraryFolder, newValue.map { LibraryFolder.normalised($0).path }) }
    }

    /// What he actually typed or picked, before normalising. Only the Settings
    /// control needs this, to say "you chose X; the shoots are in Y".
    public var libraryFolderAsChosen: URL? { url(.libraryFolder) }
    public var editor: String? {
        get { defaults.string(forKey: Key.editor.rawValue) }
        set { set(.editor, newValue) }
    }
    public var checkForUpdates: Bool {
        get { bool(.checkForUpdates, default: true) }
        set { set(.checkForUpdates, newValue) }
    }

    /// Light, dark, or whatever the Mac is set to (the default). Applied to the
    /// whole app by `AppearanceController`; the surround the photograph sits on
    /// is a separate setting and does not move with it.
    public var appearance: AppAppearance {
        get { defaults.string(forKey: Key.appearance.rawValue).flatMap(AppAppearance.init) ?? .system }
        set { set(.appearance, newValue.rawValue) }
    }

    // MARK: Advanced

    /// `PIPELINE_EXT` for the engine, when he has pointed it somewhere.
    public var extensionFolder: URL? {
        get { url(.extensionFolder) }
        set { set(.extensionFolder, newValue?.path) }
    }
    /// Sets `isInspectable` on the extension's pages. Off by default (NAT-17).
    public var webInspector: Bool {
        get { bool(.webInspector, default: false) }
        set { set(.webInspector, newValue) }
    }

    // MARK: Choosing (§2.11)

    public var viewerBackground: ViewerBackground {
        get { defaults.string(forKey: Key.viewerBackground.rawValue).flatMap(ViewerBackground.init) ?? .neutralGrey }
        set { set(.viewerBackground, newValue.rawValue) }
    }
    /// On: Space is Full Image. Off: Space goes to the next burst, as before.
    public var spaceShowsWholePicture: Bool {
        get { bool(.spaceShowsWholePicture, default: true) }
        set { set(.spaceShowsWholePicture, newValue) }
    }
    /// After the last frame of a burst: go on to the next (the default) or
    /// stay. He asked not to press N at the end of every burst (§2.11).
    public var afterLastFrameGoesOn: Bool {
        get { bool(.afterLastFrameGoesOn, default: true) }
        set { set(.afterLastFrameGoesOn, newValue) }
    }
    public var reasonsStripAfterDrop: Bool {
        get { bool(.reasonsStripAfterDrop, default: true) }
        set { set(.reasonsStripAfterDrop, newValue) }
    }
    /// Off by default: a view change arriving under a moving hand is how a
    /// keystroke lands in the wrong place (§2.5.12).
    public var openLargeStacksInCompare: Bool {
        get { bool(.openLargeStacksInCompare, default: false) }
        set { set(.openLargeStacksInCompare, newValue) }
    }
    public var showCullMarks: Bool {
        get { bool(.showCullMarks, default: true) }
        set { set(.showCullMarks, newValue) }
    }

    // MARK: Storage

    // The days before archived RAWs may be let go are not here: they are the
    // library's, on the engine (`EngineSettings`), the one number a shoot's
    // Storage panel shows. A copy kept here was read by nothing. Nor is a
    // switch to copy new shoots to iCloud: nothing read it, and a copy up is
    // his press of Copy the RAWs to iCloud (§2.8).

    // MARK: Learning

    public var learnAutomatically: Bool {
        get { bool(.learnAutomatically, default: true) }
        set { set(.learnAutomatically, newValue) }
    }
    public var learnOnlyWhenIdle: Bool {
        get { bool(.learnOnlyWhenIdle, default: true) }
        set { set(.learnOnlyWhenIdle, newValue) }
    }

    // MARK: Copying a card (§2.6)

    /// How the last copy was checked, and whether the card was ejected after
    /// it. Habits of his, not of a card: they were asked again, reset to the
    /// defaults, every time the page opened — every evening.
    public var copyCheck: String? {
        get { defaults.string(forKey: Key.copyCheck.rawValue) }
        set { set(.copyCheck, newValue) }
    }
    public var ejectAfterCopying: Bool {
        get { bool(.ejectAfterCopying, default: false) }
        set { set(.ejectAfterCopying, newValue) }
    }

    /// The inspector as he last pinned it with ⌥⌘I; `nil` until he has,
    /// which leaves the light table's portrait default in charge.
    public var inspectorPinned: Bool? {
        get { defaults.object(forKey: Key.inspectorPinned.rawValue) == nil ? nil : bool(.inspectorPinned, default: false) }
        set { set(.inspectorPinned, newValue) }
    }

    /// The Finished section as he last left it; `nil` until he has touched
    /// it, which leaves the sidebar's own default in charge.
    public var finishedExpanded: Bool? {
        get { defaults.object(forKey: Key.finishedExpanded.rawValue) == nil ? nil : bool(.finishedExpanded, default: false) }
        set { set(.finishedExpanded, newValue) }
    }

    public var firstRunDone: Bool {
        get { bool(.firstRunDone, default: false) }
        set { set(.firstRunDone, newValue) }
    }

    /// The settings that the engine reads at start. A change to any of them
    /// needs the engine restarted, and the sheet says so (§2.11). Not the
    /// editor: nothing hands it to the engine at start; the Presets step sends
    /// it with each request.
    public static let restartsEngine: Set<Key> = [.libraryFolder, .extensionFolder]

    // MARK: -

    private func bool(_ k: Key, default d: Bool) -> Bool {
        defaults.object(forKey: k.rawValue) == nil ? d : defaults.bool(forKey: k.rawValue)
    }
    private func url(_ k: Key) -> URL? {
        guard let s = defaults.string(forKey: k.rawValue), !s.isEmpty else { return nil }
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
    }
    private func set(_ k: Key, _ v: Any?) {
        if let v { defaults.set(v, forKey: k.rawValue) } else { defaults.removeObject(forKey: k.rawValue) }
    }
}

/// The settings a view draws with, as something SwiftUI can watch (§2.11).
///
/// `SettingsStore` is plain `UserDefaults`, so a view that read the viewer
/// background from it drew what it read and was never told of a change: Black
/// from View ▸ Viewer Background or Settings ▸ Choosing waited for his next
/// keypress to repaint the surround, and Settings' picker went on showing the
/// old choice after the menu had changed it. This mirrors the value and
/// follows every write, whoever makes it, through `UserDefaults`' own notice.
@MainActor @Observable
public final class LiveSettings {
    public static let shared = LiveSettings(store: .shared)

    public private(set) var viewerBackground: ViewerBackground

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var watch: NSObjectProtocol?

    public init(store: SettingsStore) {
        self.store = store
        viewerBackground = store.viewerBackground
        watch = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                       object: store.defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reread() }
        }
    }

    /// Read again now. Setting an observed value redraws whoever reads it, so
    /// an unchanged one is left alone.
    public func reread() {
        let v = store.viewerBackground
        if v != viewerBackground { viewerBackground = v }
    }

    public func setViewerBackground(_ v: ViewerBackground) {
        store.viewerBackground = v
        reread()
    }
}
