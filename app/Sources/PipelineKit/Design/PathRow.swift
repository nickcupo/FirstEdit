import SwiftUI
import AppKit

/// A real `NSPathControl`: the path he can click through, exactly as Finder
/// draws it. Every "where will this go" and "where is it" in the steps is one.
///
/// Double-clicking a part of it shows that folder or file in Finder, the way
/// a double-click opens in Finder itself. It used to look clickable and do
/// nothing. A single click still does nothing: this row is in Settings, the
/// first-run sheet, Copy the Card and every step, and a stray click while
/// reading a path must not take him out of the app. Where a path is the thing
/// to act on, a Show in Finder button sits beside it.
public struct PathRow: NSViewRepresentable {
    public let url: URL

    public init(_ url: URL) { self.url = url }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSPathControl {
        let p = NSPathControl()
        p.pathStyle = .standard
        p.isEditable = false
        p.focusRingType = .default
        p.backgroundColor = .clear
        p.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        p.url = url
        p.setAccessibilityLabel(url.path)
        p.target = context.coordinator
        p.doubleAction = #selector(Coordinator.clicked(_:))
        return p
    }

    @MainActor
    public final class Coordinator: NSObject {
        @objc func clicked(_ sender: NSPathControl) {
            guard let url = sender.clickedPathItem?.url ?? sender.url else { return }
            NSWorkspace.shared.activateFileViewerSelecting([Self.nearestThatExists(url)])
        }

        /// A path that has not been made yet — where something will go — is
        /// shown by the nearest folder above it that has. Showing never makes
        /// anything (§7.10).
        nonisolated static func nearestThatExists(_ url: URL) -> URL {
            var u = url.standardizedFileURL
            while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 {
                u = u.deletingLastPathComponent()
            }
            return u
        }
    }

    public func updateNSView(_ p: NSPathControl, context: Context) {
        if p.url != url {
            p.url = url
            p.setAccessibilityLabel(url.path)
        }
    }
}
