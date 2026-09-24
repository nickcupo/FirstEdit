#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers

/// Dragging a frame out to Finder or into another app — from the filmstrip,
/// from the All Bursts grid, from the picture window in Frame mode, and from
/// The Whole Burst's cells. Never from Presentation.
///
/// **The RAW is never on the pasteboard.** Dragging a RAW out of the library is
/// one Finder gesture away from moving it out of the library, and the app never
/// removes photographs except through the engine's plan-token-apply path
/// (`DESIGN.md` §2.8).
public enum FrameDrag {

    /// What is on the pasteboard, in order of preference:
    ///
    /// 1. the exported JPEG's file URL, if one exists — this is what another
    ///    app actually wants, it is a finished file, and dragging it copies it;
    /// 2. otherwise a promise for a JPEG, written on drop from `/full?px=4096`
    ///    into the destination the receiver chose, named `<stem>.jpg`.
    ///
    /// Either way the frame number goes on as text, so dropping into a message
    /// or a text field types `04330`.
    public static func pasteboardWriter(for stem: String,
                                        exported: URL?,
                                        fetch: @escaping @Sendable () async -> Data?) -> NSPasteboardWriting? {
        if let exported, FileManager.default.fileExists(atPath: exported.path) {
            return exported as NSURL
        }
        return FramePromise(stem: stem, fetch: fetch)
    }

    /// The text that rides along: the number he reads off the camera.
    ///
    /// Two crews wrote this rule; the one kept is `ShootSession.shortStem`,
    /// which owns what a frame is called. It is `nonisolated` now, so a
    /// promise written off the main actor can call it and this is a name for
    /// it rather than a second copy.
    public static func number(for stem: String) -> String {
        ShootSession.shortStem(stem)
    }
}

/// AppKit hands the promise an ordinary completion handler, which Swift 6 will
/// not let cross into a task on its own. It is called exactly once, from one
/// place.
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// A JPEG written only if something actually asks for it.
final class FramePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let stem: String
    private let fetch: @Sendable () async -> Data?

    init(stem: String, fetch: @escaping @Sendable () async -> Data?) {
        self.stem = stem
        self.fetch = fetch
        super.init()
        fileType = UTType.jpeg.identifier
        delegate = self
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        "\(stem).jpg"
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let fetch = self.fetch
        let done = UncheckedBox(completionHandler)
        Task {
            guard let data = await fetch() else {
                done.value(CocoaError(.fileNoSuchFile))
                return
            }
            do {
                try data.write(to: url)
                done.value(nil)
            } catch {
                done.value(error)
            }
        }
    }

    /// The frame number as well, so a drop into text types `04330`.
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.string]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .string ? FrameDrag.number(for: stem) : super.pasteboardPropertyList(forType: type)
    }
}
#endif
