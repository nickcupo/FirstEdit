import Foundation
import AppKit
import Observation

/// Notices a memory card going in and coming out.
///
/// It does not decide what a card *is*. `cards()` on the engine does that —
/// a volume with photographs on it — and `/api/ingest` checks the path it is
/// given against that same list, so a card the app invented could never be
/// copied anyway (SEC-05). This watches the mount notifications and says which
/// volume came or went; the list on screen is always the engine's.
///
/// One of these runs for as long as the app is open (`ImportModel`). It used
/// to be the card page's own, started when that page appeared — and the page
/// is only reachable with a card in, so a card put in while he was anywhere
/// else was never noticed.
@MainActor
public final class CardWatcher {
    /// A volume came or went. The path is the system's, and may be missing.
    public enum Change: Equatable, Sendable {
        case mounted(String?)
        case unmounted(String?)
    }

    private var observers: [NSObjectProtocol] = []
    private let changed: @MainActor (Change) async -> Void

    public init(changed: @escaping @MainActor (Change) async -> Void) {
        self.changed = changed
    }

    public var isWatching: Bool { !observers.isEmpty }

    public func start() {
        guard observers.isEmpty else { return }
        let centre = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let isMount = name == NSWorkspace.didMountNotification
            observers.append(centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let change: Change = isMount ? .mounted(path) : .unmounted(path)
                    Task { await self.changed(change) }
                }
            })
        }
    }

    public func stop() {
        let centre = NSWorkspace.shared.notificationCenter
        for o in observers { centre.removeObserver(o) }
        observers.removeAll()
    }

    /// Eject, when he asked for the card to go out after the copy. A failure
    /// is a sentence beside the button, never an alert: the copy is safely
    /// done either way and Finder can always do it.
    public nonisolated static func eject(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The same, off the main thread. Unmounting waits for the card to let
    /// go, which for a busy or slow card is seconds, and on the main thread
    /// that is a spinning cursor over the whole app.
    public nonisolated static func ejectOffTheMainThread(_ path: String) async -> String? {
        await Task.detached(priority: .userInitiated) { eject(path) }.value
    }

    /// Whether a copy is running off a card or waiting its turn to. Ejecting
    /// then pulls a card the copy still needs; the engine copes with the
    /// card being gone, but the evening's copy does not happen.
    @MainActor
    public static func copyNeedsTheCard(job: Job?, running: Bool, waiting: [QueueItem]) -> Bool {
        (running && job?.kind == "ingest") || waiting.contains { $0.kind == "ingest" }
    }

    /// The last component of a volume path, which is what the card calls
    /// itself in Finder.
    public static func volumeName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
