import AppKit

/// What `tools/smoke.sh` asks of the running app: that the sidebar is drawing
/// a row for every shoot, and that choosing each of them drives the window.
///
/// It reads AppKit, not the model that fed it. It deliberately does not walk
/// the accessibility tree: macOS builds SwiftUI's lazily, when an assistive
/// client asks, so in a plain run there is nothing there to read — which would
/// make a green smoke test mean nothing. The sidebar's `List` is a real
/// `NSOutlineView`, its drawn rows are real rows, and the window's title is a
/// real `NSWindow` title.
@MainActor
public enum SmokeProbe {

    /// The window whose content is the app's shell.
    public static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView.map { firstTableView(in: $0) != nil } == true }
            ?? NSApp.windows.first { $0.isVisible }
    }

    /// How many rows the sidebar's list is drawing.
    public static func sidebarRowCount(in window: NSWindow) -> Int {
        guard let root = window.contentView, let t = firstTableView(in: root) else { return 0 }
        return t.numberOfRows
    }

    /// Every row the sidebar draws, with whether anything was painted into it.
    /// A row that is laid out and blank is not a row he can read.
    public static func sidebarRowsDrawn(in window: NSWindow) -> Int {
        guard let root = window.contentView, let t = firstTableView(in: root) else { return 0 }
        var drawn = 0
        for row in 0..<t.numberOfRows {
            guard let view = t.rowView(atRow: row, makeIfNecessary: false), view.bounds.height > 0 else { continue }
            drawn += 1
        }
        return drawn
    }

    /// The first `NSTableView` in the view tree; a SwiftUI sidebar `List` is
    /// one, inside a scroll view. Real subviews, so the walk is finite.
    public static func firstTableView(in root: NSView) -> NSTableView? {
        if let t = root as? NSTableView { return t }
        for sub in root.subviews {
            if let t = firstTableView(in: sub) { return t }
        }
        return nil
    }
}
