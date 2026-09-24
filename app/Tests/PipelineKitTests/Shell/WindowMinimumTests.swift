import Foundation
import AppKit
import SwiftUI
import Testing
@testable import PipelineKit

/// The app lets SwiftUI set the window's minimum from its content
/// (`.windowResizability(.contentMinSize)`), so the documented 900 × 620 is
/// only true if what the root asks for adds up to it (DESIGN.md §2.1). Two
/// things once made it larger: the root asked for the whole 620 below a 52 pt
/// toolbar (672), and a frame-based `minSize` set beside `contentMinSize` made
/// SwiftUI ask for 640. Measured the way SwiftUI measures it: a hosting view
/// that sizes its window's minimum from its content, in a window that is never
/// shown.
@Suite("The smallest window is the documented one", .serialized)
@MainActor
struct WindowMinimumTests {

    static func minimum<V: View>(_ view: V) -> CGSize {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1100, height: 780),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.toolbarStyle = .unified
        defer { w.close() }
        let h = NSHostingView(rootView: view)
        h.sizingOptions = [.minSize]
        w.contentView = h
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            h.layoutSubtreeIfNeeded()
        }
        return w.contentMinSize
    }

    @Test("the root, with its toolbar and the window's own settings, asks for 900 × 620 and no more")
    func rootAsksForTheDocumentedMinimum() throws {
        let remembered = WindowFrameMemory.remembers
        WindowFrameMemory.remembers = false
        defer { WindowFrameMemory.remembers = remembered }
        let app = AppModel(preview: Library(preview: try LastPlaceTests.shoots()), state: .stopped,
                           navigation: Navigation(selection: .allShoots))
        #expect(Self.minimum(RootView(app: app)) == Tokens.Metric.minimumWindow)
        app.navigation.inspectorShown = true
        #expect(Self.minimum(RootView(app: app)) == Tokens.Metric.minimumWindow)
    }
}
