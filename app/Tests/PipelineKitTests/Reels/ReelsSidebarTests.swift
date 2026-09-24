import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PipelineKit

/// "At 900x620 the sidebar and the burst list both stay open. The frame grid
/// gets two columns and only the top of the first row shows." Reels puts the
/// sidebar away in a narrow window, by the light table's rule and with the
/// light table's one memory of it (DESIGN.md §2.1, §2.6).
@Suite("Reels puts the sidebar away in a narrow window")
@MainActor
struct ReelsSidebarTests {

    /// What a page does at one width of window, with the sidebar as it is.
    static func layout(_ page: UUID, _ nav: Navigation, window: CGFloat) {
        nav.sidebarPage(page, laidOutAt: window - (nav.sidebarShown ? Tokens.Metric.sidebarDefault : 0))
    }

    @Test("below 1280 pt of window it goes while Reels is up, and comes back on leaving")
    func narrowHides() {
        for window: CGFloat in [900, 1100] {
            let nav = Navigation(selection: .step(shoot: "2026-09-19", step: "reels"))
            let reels = UUID()
            Self.layout(reels, nav, window: window)
            #expect(!nav.sidebarShown, "at \(window)")
            nav.sidebarPageLeft(reels)
            #expect(nav.sidebarShown)
        }
    }

    @Test("with the sidebar gone, the minimum window folds the inspector under the frames rather than squeezing them")
    func foldsAtTheMinimum() {
        #expect(!ReelsStep.sideBySide(Tokens.Metric.minimumWindow.width))
        #expect(ReelsStep.sideBySide(1100))
        #expect(ReelsStep.sideBySide(1440 - Tokens.Metric.sidebarDefault))
    }

    @Test("a wide window keeps it, and ⌃⌘S at a width sticks for that width")
    func wideAndHisChoice() {
        let nav = Navigation(selection: .step(shoot: "2026-09-19", step: "reels"))
        let reels = UUID()
        Self.layout(reels, nav, window: 1440)
        #expect(nav.sidebarShown)

        Self.layout(reels, nav, window: 1000)
        #expect(!nav.sidebarShown)
        // He shows it by hand at the same width: it stays.
        nav.sidebarShown = true
        Self.layout(reels, nav, window: 1000)
        #expect(nav.sidebarShown)
        // Leaving does not hide what he showed.
        nav.sidebarPageLeft(reels)
        #expect(nav.sidebarShown)
    }

    /// The order SwiftUI uses, measured offscreen: the page arriving appears,
    /// and is laid out, before the page leaving goes.
    @Test("between Choose Keepers and Reels at 1100 it stays away, and comes back on leaving both")
    func betweenTheTwo() {
        let nav = Navigation(selection: .step(shoot: "2026-09-19", step: "keepers"))
        let keepers = UUID(), reels = UUID()
        Self.layout(keepers, nav, window: 1100)
        #expect(!nav.sidebarShown)
        // ⌘6: Reels arrives in a pane the whole window wide, then the light
        // table goes. Each page keeping its own memory, the light table gave
        // the sidebar back here and Reels took that for his ⌃⌘S.
        Self.layout(reels, nav, window: 1100)
        nav.sidebarPageLeft(keepers)
        Self.layout(reels, nav, window: 1100)
        #expect(!nav.sidebarShown, "on Reels")
        // And back to the light table: it lost its own auto-hide after any
        // visit to Reels.
        let keepersAgain = UUID()
        Self.layout(keepersAgain, nav, window: 1100)
        nav.sidebarPageLeft(reels)
        Self.layout(keepersAgain, nav, window: 1100)
        #expect(!nav.sidebarShown, "on Choose Keepers")
        // On to Presets, which does not put it away: it comes back.
        nav.sidebarPageLeft(keepersAgain)
        #expect(nav.sidebarShown)
    }

    @Test("his ⌃⌘S on one of the two goes with him to the other at the same width")
    func hisChoiceCrossesOver() {
        let nav = Navigation(selection: .step(shoot: "2026-09-19", step: "keepers"))
        let keepers = UUID(), reels = UUID()
        Self.layout(keepers, nav, window: 1100)
        nav.sidebarShown = true
        Self.layout(keepers, nav, window: 1100)
        #expect(nav.sidebarShown)
        Self.layout(reels, nav, window: 1100)
        nav.sidebarPageLeft(keepers)
        #expect(nav.sidebarShown, "the window did not change, so the choice is still his")
        // His hiding it on a page that does not do so is his too.
        nav.sidebarPageLeft(reels)
        nav.sidebarShown = false
        let again = UUID()
        Self.layout(again, nav, window: 1100)
        nav.sidebarPageLeft(again)
        #expect(!nav.sidebarShown, "nothing of ours to give back")
    }

    /// The window was the pane plus a sidebar of the default 256 pt, so with
    /// the sidebar dragged to any other width it was one window with the
    /// sidebar out and another with it away.
    @Test("his ⌃⌘S sticks whatever width he has dragged the sidebar to")
    func hisChoiceAtAnySidebarWidth() {
        for sidebar: CGFloat in [Tokens.Metric.sidebarMin, 300, Tokens.Metric.sidebarMax] {
            let nav = Navigation(selection: .step(shoot: "2026-09-19", step: "keepers"))
            let keepers = UUID()
            nav.sidebarPage(keepers, laidOutAt: 1100 - sidebar, window: 1100)
            #expect(!nav.sidebarShown, "a \(sidebar) pt sidebar at 1100")
            nav.sidebarPage(keepers, laidOutAt: 1100, window: 1100)
            nav.sidebarShown = true
            nav.sidebarPage(keepers, laidOutAt: 1100 - sidebar, window: 1100)
            #expect(nav.sidebarShown, "a \(sidebar) pt sidebar: his ⌃⌘S was read as the window changing")
        }
    }
}

// MARK: - in a real split view

/// What the pages told, in the order SwiftUI told it.
@MainActor final class SidebarPagesLog {
    var lines: [String] = []
    var appeared: Set<String> = []
    var gone: Set<String> = []
    /// The width each page that puts the sidebar away was last laid out at.
    var width: [String: CGFloat] = [:]
}

/// A page that puts the sidebar away exactly as Choose Keepers and Reels do:
/// the same modifier, on what a `GeometryReader` measured.
private struct NarrowPage: View {
    let name: String
    let nav: Navigation
    let log: SidebarPagesLog
    var body: some View {
        GeometryReader { geo in
            Color.gray
                .putsTheSidebarAway(nav, in: geo)
                .onAppear {
                    log.lines.append("appear \(name) \(Int(geo.size.width))")
                    log.appeared.insert(name)
                    log.width[name] = geo.size.width
                }
                .onChange(of: geo.size.width) { _, w in log.width[name] = w }
                .onDisappear { log.lines.append("disappear \(name)"); log.gone.insert(name) }
        }
    }
}

/// `RootView`'s split view and `StepDetail`'s switch, crossfade and identity,
/// with the pages that matter standing in for their photographs.
private struct SplitRoot: View {
    @Bindable var nav: Navigation
    let log: SidebarPagesLog
    /// The sidebar's width as he left it: the default, or wherever he dragged it.
    var sidebar: CGFloat = Tokens.Metric.sidebarDefault
    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { nav.sidebarShown ? .all : .detailOnly },
                                                      set: { nav.sidebarShown = ($0 != .detailOnly) })) {
            List { Text(verbatim: "shoot"); Text(verbatim: "step") }
                .navigationSplitViewColumnWidth(min: Tokens.Metric.sidebarMin, ideal: sidebar,
                                                max: Tokens.Metric.sidebarMax)
        } detail: {
            Group {
                switch nav.step {
                case "keepers": NarrowPage(name: "keepers", nav: nav, log: log).id("s/keepers")
                case "reels": NarrowPage(name: "reels", nav: nav, log: log).id("s/reels")
                default:
                    Color.white.id("s/\(nav.step ?? "")")
                        .onAppear { log.lines.append("appear \(nav.step ?? "")"); log.appeared.insert(nav.step ?? "") }
                }
            }
            .animation(Motion.step, value: nav.selection)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

@Suite("Between Choose Keepers and Reels in a real split view", .serialized)
@MainActor
struct SidebarAcrossPagesTests {
    final class OffscreenKeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    /// The pages that put the sidebar away.
    static let narrow: Set<String> = ["keepers", "reels"]

    /// Opens a 1100 pt window on the first page, goes to each of the others
    /// in turn, and says whether the sidebar is out on the last, before the
    /// window closes — closing it takes the last page away too — with what
    /// was logged.
    ///
    /// Nothing here waits a length of time. Each step waits for what it
    /// needs to have happened, however busy the run: the page he goes to is
    /// up, the one he leaves has gone, and a page that puts the sidebar away
    /// has been laid out with the sidebar as it now is.
    func walk(_ pages: [String], width: CGFloat = 1100, sidebar: CGFloat = Tokens.Metric.sidebarDefault,
              between: (@MainActor (Navigation) -> Void)? = nil) async throws -> (shown: Bool, lines: [String]) {
        _ = NSApplication.shared
        let nav = Navigation(selection: .step(shoot: "s", step: pages[0]))
        let log = SidebarPagesLog()
        let w = OffscreenKeyWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 780),
                                   styleMask: [.titled, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        defer { w.contentView = nil; w.close() }
        /// A page that puts the sidebar away has had its say about it once it
        /// has been laid out at a width that is a window, not a layout in
        /// progress, and laid out again after the sidebar last moved: across
        /// the whole window with the sidebar away, across less than the window
        /// with it out.
        func laidOut(_ page: String) async throws {
            guard Self.narrow.contains(page) else { return }
            try await waitUntil(.seconds(30)) {
                guard let pane = log.width[page], pane >= LightTableGeometry.smallestBelievablePane else { return false }
                return nav.sidebarShown ? pane <= width - Tokens.Metric.sidebarMin : abs(pane - width) < 1
            }
        }
        w.contentView = NSHostingView(rootView: SplitRoot(nav: nav, log: log, sidebar: sidebar))
        try await waitUntil(.seconds(30)) { log.appeared.contains(pages[0]) }
        // His ⌃⌘S means something only after the page has put the sidebar
        // away. The page appears at a width that is a layout in progress and
        // acts at the next; on a busy run that can come long after, and a
        // press before it was a press on a sidebar that was still out.
        try await laidOut(pages[0])
        if let between {
            between(nav)
            try await laidOut(pages[0])
        }
        var last = pages[0]
        for page in pages.dropFirst() {
            log.lines.append("-- to \(page), sidebar \(nav.sidebarShown ? "out" : "away")")
            log.appeared.remove(page)
            log.width[page] = nil
            nav.selection = .step(shoot: "s", step: page)
            try await waitUntil(.seconds(30)) { log.appeared.contains(page) }
            if Self.narrow.contains(last) {
                let leaving = last
                try await waitUntil(.seconds(30)) { log.gone.contains(leaving) }
                log.gone.remove(leaving)
            }
            try await laidOut(page)
            last = page
        }
        return (nav.sidebarShown, log.lines)
    }

    @Test("Presets, then Reels, then Choose Keepers at 1100: away on both")
    func reelsThenKeepers() async throws {
        let (shown, lines) = try await walk(["presets", "reels", "keepers"])
        #expect(!shown, "\(lines)")
        let (onReels, back) = try await walk(["presets", "reels"])
        #expect(!onReels, "\(back)")
    }

    @Test("Presets, then Choose Keepers, then Reels at 1100: away on both")
    func keepersThenReels() async throws {
        let (shown, lines) = try await walk(["presets", "keepers", "reels"])
        #expect(!shown, "\(lines)")
        let (onKeepers, back) = try await walk(["presets", "keepers"])
        #expect(!onKeepers, "\(back)")
    }

    @Test("leaving the light table for Presets brings it back, after Reels too")
    func backOnLeaving() async throws {
        let (shown, lines) = try await walk(["presets", "keepers", "presets"])
        #expect(shown, "\(lines)")
        let (after, more) = try await walk(["presets", "keepers", "reels", "presets"])
        #expect(after, "\(more)")
    }

    @Test("his ⌃⌘S on the light table at 1100 sticks, there and on Reels")
    func hisChoiceSticks() async throws {
        let (shown, lines) = try await walk(["keepers", "reels"]) { nav in nav.sidebarShown = true }
        #expect(shown, "\(lines)")
    }

    @Test("and with the sidebar dragged narrower or wider than it starts")
    func hisChoiceSticksAtAnySidebarWidth() async throws {
        for sidebar: CGFloat in [200, 300] {
            let (shown, lines) = try await walk(["keepers", "reels"], sidebar: sidebar) { nav in nav.sidebarShown = true }
            #expect(shown, "a \(Int(sidebar)) pt sidebar: \(lines)")
        }
    }
}
