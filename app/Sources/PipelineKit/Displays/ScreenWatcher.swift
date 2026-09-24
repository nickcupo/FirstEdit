import Foundation
import Observation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

/// What screens there are, and when that changes.
///
/// `NSApplication.didChangeScreenParametersNotification` is the single source
/// of truth: it is delivered on the main thread, it coalesces, and it covers
/// connect, disconnect, resolution change, scale change, arrangement change and
/// wake-from-sleep re-enumeration. macOS emits three to five of them during one
/// dock event, so it is debounced by 250 ms with a trailing edge (§3.7).
///
/// `CGDisplayRegisterReconfigurationCallback` is registered as well, for one
/// job only: the *begin* edge, which arrives before the mode change. On that
/// edge the picture window freezes its layer contents and pauses its prefetch,
/// so the one to three seconds a mode change takes does not produce a stretched
/// frame, a flash of the wrong size, or a burst of image requests at a size
/// that is about to be wrong.
@MainActor @Observable
public final class ScreenWatcher {

    /// macOS emits three to five parameter notifications per dock event.
    public static let debounce: Duration = .milliseconds(250)

    public private(set) var screens: ScreenSet
    /// True between a display's begin-configuration edge and the change
    /// landing. While it is true the picture window holds what it has.
    public private(set) var isReconfiguring = false
    /// Every screen the system says is asleep. A sleeping display is not an
    /// event and nothing is announced.
    public private(set) var asleep: Set<ScreenKey> = []

    /// How many times the set has actually been rebuilt. The debounce test
    /// reads this.
    public private(set) var rebuilds = 0

    /// Called after each rebuild, on the main actor.
    public var onChange: ((ScreenSet) -> Void)?
    /// Called on the begin-configuration edge and again when it settles.
    public var onReconfiguring: ((Bool) -> Void)?

    private let read: @MainActor () -> ScreenSet
    private let wait: Duration
    private var pending: Task<Void, Never>?
    #if canImport(AppKit)
    private var appObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    #endif
    private var registeredCallback = false

    // MARK: - init

    /// The live watcher: AppKit's screens, AppKit's notifications.
    @MainActor
    public convenience init() {
        self.init(reading: { ScreenSet.current() }, debounce: ScreenWatcher.debounce)
        startObserving()
    }

    /// A watcher with no AppKit under it, for tests and for the snapshot
    /// harness: hand it a reader and drive it with `simulate(_:)`.
    public init(reading read: @escaping @MainActor () -> ScreenSet,
                debounce: Duration = ScreenWatcher.debounce) {
        self.read = read
        self.wait = debounce
        self.screens = read()
    }

    /// A fixed set that never changes on its own.
    public convenience init(fixed set: ScreenSet, debounce: Duration = .zero) {
        var current = set
        self.init(reading: { current }, debounce: debounce)
        self.replace = { current = $0 }
    }

    private var replace: ((ScreenSet) -> Void)?

    // MARK: - driving it

    /// For a test or the harness: this is the new truth, delivered through the
    /// same debounce as a real notification.
    public func simulate(_ set: ScreenSet) {
        replace?(set)
        changed()
    }

    /// One parameter notification arrived. Three to five of these are one
    /// event.
    public func changed() {
        pending?.cancel()
        guard wait > .zero else { rebuild(); return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: self?.wait ?? ScreenWatcher.debounce)
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    /// Flush a pending change now. Used by the test that asserts 500
    /// notifications in 200 ms are one rebuild, and by wake, where waiting
    /// another quarter second on a black picture window is the wrong trade.
    public func flush() {
        pending?.cancel()
        pending = nil
        rebuild()
    }

    private func rebuild() {
        pending = nil
        let set = read()
        screens = set
        asleep = Set(set.screens.filter(\.isAsleep).map(\.key))
        rebuilds += 1
        if isReconfiguring { setReconfiguring(false) }
        onChange?(set)
    }

    public func setReconfiguring(_ on: Bool) {
        guard isReconfiguring != on else { return }
        isReconfiguring = on
        onReconfiguring?(on)
    }

    // MARK: - AppKit

    #if canImport(AppKit)
    /// Everything that can change the answer, in one place.
    public func startObserving() {
        guard appObservers.isEmpty, workspaceObservers.isEmpty else { return }
        func watch(_ name: Notification.Name, _ on: NotificationCenter) -> NSObjectProtocol {
            on.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            }
        }
        appObservers = [watch(NSApplication.didChangeScreenParametersNotification, .default)]

        // Waking re-reads backing properties and colour space — both can
        // change — rebuilds the display link and re-requests the current
        // frame. Sleeping stops the link and pauses prefetch.
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            watch(NSWorkspace.screensDidSleepNotification, workspace),
            watch(NSWorkspace.screensDidWakeNotification, workspace),
            watch(NSWorkspace.didWakeNotification, workspace),
        ]

        registerReconfiguration()
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        for o in appObservers { NotificationCenter.default.removeObserver(o) }
        for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        appObservers.removeAll()
        workspaceObservers.removeAll()
        if registeredCallback {
            CGDisplayRemoveReconfigurationCallback(ScreenWatcher.reconfigured, nil)
            registeredCallback = false
        }
        ScreenWatcher.live = nil
    }

    /// The callback fires on an arbitrary thread and does nothing but hop a
    /// flag onto the main actor.
    private nonisolated static let reconfigured: CGDisplayReconfigurationCallBack = { _, flags, _ in
        let beginning = flags.contains(.beginConfigurationFlag)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let w = ScreenWatcher.live else { return }
                if beginning {
                    w.setReconfiguring(true)
                } else {
                    w.changed()
                }
            }
        }
    }

    /// The one watcher the C callback can reach. There is one screen list, so
    /// there is one watcher.
    @MainActor private static weak var live: ScreenWatcher?

    private func registerReconfiguration() {
        ScreenWatcher.live = self
        guard !registeredCallback else { return }
        CGDisplayRegisterReconfigurationCallback(ScreenWatcher.reconfigured, nil)
        registeredCallback = true
    }
    #else
    public func startObserving() {}
    public func stop() { pending?.cancel(); pending = nil }
    #endif
}
