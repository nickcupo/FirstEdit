import Foundation
import AppKit
import SwiftUI
import Testing
@testable import PipelineKit

/// One shoot whose decisions file will not read cost the whole window: the
/// sentence under All Shoots' table was `.fixedSize(vertical:)` beneath a
/// `Table` that takes every point it is offered, the split view found no
/// height it could settle on, and it drew nothing at all — no table, no
/// sidebar, not the red row (DESIGN.md §7.13). Measured on a real window that
/// is never shown, the way the snapshot harness draws it.
@Suite("A broken shoot costs one row, not the window", .serialized)
@MainActor
struct BrokenShootWindowTests {

    /// Every `NSTableView` in the window. SwiftUI draws both the sidebar's
    /// list and All Shoots' `Table` as outline views; the list is the one
    /// with a single column.
    static func tables(in root: NSView) -> [NSTableView] {
        var out: [NSTableView] = []
        if let t = root as? NSTableView { out.append(t) }
        for sub in root.subviews { out += tables(in: sub) }
        return out
    }

    static func host(_ app: AppModel) -> (NSWindow, [NSTableView]) {
        _ = NSApplication.shared
        let remembered = WindowFrameMemory.remembers
        WindowFrameMemory.remembers = false
        defer { WindowFrameMemory.remembers = remembered }
        let w = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1100, height: 780),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.toolbarStyle = .unified
        let h = NSHostingView(rootView: RootView(app: app))
        // The window's size is the test's, as it is the harness's: the root
        // would otherwise hand the window its own minimum.
        h.sizingOptions = []
        w.contentView = h
        w.contentMinSize = NSSize(width: 1100, height: 780)
        w.contentMaxSize = NSSize(width: 1100, height: 780)
        w.setContentSize(NSSize(width: 1100, height: 780))
        for _ in 0..<12 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            w.contentView?.layoutSubtreeIfNeeded()
            w.displayIfNeeded()
        }
        return (w, tables(in: w.contentView!))
    }

    /// Rows the list actually made a view for and gave a height.
    static func drawn(_ t: NSTableView) -> Int {
        (0..<t.numberOfRows).filter { (t.rowView(atRow: $0, makeIfNecessary: false)?.bounds.height ?? 0) > 0 }.count
    }

    /// The table's scroll view is no taller than the window it is in.
    static func fits(_ t: NSTableView, in w: NSWindow) -> Bool {
        guard let box = t.enclosingScrollView else { return false }
        return box.frame.height > 0 && box.frame.height <= w.frame.height
    }

    static func app(_ r: ShootsResponse) -> AppModel {
        AppModel(preview: Library(preview: r), state: .running(.init(base: URL(string: "http://127.0.0.1:1/")!, key: "k")),
                 navigation: Navigation(selection: .allShoots))
    }

    @Test("with only a broken shoot, the sidebar still draws its rows and All Shoots its table")
    func onlyBroken() throws {
        let (w, tables) = Self.host(Self.app(try LastPlaceTests.shoots("shoots-broken")))
        defer { w.close() }
        let sidebar = try #require(tables.first { $0.numberOfColumns == 1 })
        // Library's three rows, the In Progress heading and the red row,
        // each drawn. Blank, the list had its rows and drew none of them.
        #expect(sidebar.numberOfRows >= 4)
        #expect(Self.drawn(sidebar) >= 4)
        // Blank, All Shoots' table was laid out 1,394 pt tall in a 780 pt
        // window, so the split view could not settle and painted nothing.
        let table = try #require(tables.first { $0.numberOfColumns > 1 })
        #expect(Self.fits(table, in: w))
    }

    @Test("a broken shoot beside good ones leaves the good ones in the table")
    func brokenBesideGood() throws {
        let broken = try #require(JSONSerialization.jsonObject(with: Fixture.data("shoots-broken")) as? [String: Any])
        let bad = try #require((broken["shoots"] as? [[String: Any]])?.first)
        let r = try LastPlaceTests.shoots { rows in rows.append(bad) }
        let (w, tables) = Self.host(Self.app(r))
        defer { w.close() }
        let table = try #require(tables.first { $0.numberOfColumns > 1 })
        #expect(table.numberOfRows == r.ok.count)
        #expect(Self.fits(table, in: w))
        let sidebar = try #require(tables.first { $0.numberOfColumns == 1 })
        #expect(Self.drawn(sidebar) > r.ok.count / 2)
    }
}
