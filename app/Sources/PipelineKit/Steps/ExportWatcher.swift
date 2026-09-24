import Foundation
import CoreServices

/// Notices that something happened in the folders a shoot's exports land in.
///
/// It is a doorbell, not a counter. Exports are found in the export folder, in
/// the editing folder, or in iCloud, and only the engine looks in all three —
/// so this says "go and ask again" and the number on screen stays the engine's
/// (§2.6, Edit in PhotoLab).
///
/// `FSEventStream` is a C API with a function-pointer callback, which is why
/// the bridge is a class held by an unmanaged pointer rather than a closure
/// capture. It runs on its own serial queue and hops to the caller.
public final class ExportWatcher: @unchecked Sendable {
    private let paths: [String]
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "photopipeline.exports", qos: .utility)
    private var stream: FSEventStreamRef?
    private let lock = NSLock()

    /// Coalesced: a PhotoLab export writes a file at a time and this is not a
    /// progress bar.
    public static let latency: CFTimeInterval = 1.0

    public init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        // A path that is not there yet is still watched: FSEvents carries the
        // parent, so the folder appearing is itself the event.
        self.paths = paths.filter { !$0.isEmpty }
        self.onChange = onChange
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil, release: { info in
                guard let info else { return }
                Unmanaged<ExportWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ExportWatcher>.fromOpaque(info).takeUnretainedValue().fire()
        }

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
                                     kFSEventStreamCreateFlagNoDefer |
                                     kFSEventStreamCreateFlagIgnoreSelf))
        else {
            // The stream could not be made — an unreadable folder, or none of
            // them on disk. The five-second poll beside this is the answer,
            // and it is already running.
            Unmanaged.passUnretained(self).release()
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    private func fire() { onChange() }

    deinit { stop() }
}
