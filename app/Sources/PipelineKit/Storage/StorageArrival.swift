import AppKit
import SwiftUI

/// "Take me to this shoot's storage", handed from the library's Storage page
/// to the panel on that shoot's Finish page.
///
/// A row there used to open the shoot's overview. He had clicked it to deal
/// with its storage, and had to find Finish in the sidebar and scroll to the
/// bottom of it for the panel. Now the row goes to Finish and leaves the
/// shoot's name here; the panel takes it the first time it appears, and
/// brings itself into view once its figures are in.
@MainActor
public enum StorageArrival {
    private static var waiting: String?

    /// The row's half: which shoot's panel should show itself.
    public static func ask(for shoot: String) { waiting = shoot }

    /// The panel's half: whether it was asked for. Asked once — any panel
    /// that appears clears it, so a request that was never met does not
    /// scroll some later visit.
    static func take(_ shoot: String) -> Bool {
        defer { waiting = nil }
        return waiting == shoot
    }
}

/// A point at the top of the view it is attached to that, once `armed`,
/// scrolls the scroll view around it so that point sits a window margin below
/// the top of what is visible.
///
/// Used by the storage panel, which is never a scroll view of its own: it is
/// held in Finish's, which belongs to the page and not to the panel.
struct RevealMarker: NSViewRepresentable {
    let armed: Bool

    func makeNSView(context: Context) -> Marker { Marker() }

    func updateNSView(_ marker: Marker, context: Context) {
        guard armed, !marker.revealed else { return }
        marker.revealed = true
        // After this pass has been laid out, when the page is as tall as the
        // panel makes it; and once more a moment later, for a page whose
        // other cards were still arriving.
        DispatchQueue.main.async { marker.reveal() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { marker.reveal() }
    }

    final class Marker: NSView {
        var revealed = false
        override var isFlipped: Bool { true }
        // Never in the way of a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func reveal() {
            guard let clip = enclosingScrollView?.contentView else { return }
            // A rect exactly as tall as what is visible, starting a margin
            // above this point: the least scroll that shows it puts this
            // point a margin from the top.
            scrollToVisible(NSRect(x: 0, y: -Tokens.Metric.windowMargin,
                                   width: 1, height: clip.bounds.height))
        }
    }
}
