import Foundation
import AppKit
import SwiftUI
import Testing
@testable import PipelineKit

/// NAT-18 asks for a transparent title bar over full-size content, and the
/// cost of that pair is that the **empty** parts of the bar hit-test straight
/// through to whatever SwiftUI has underneath, which eats the click. Probed on
/// the real window at the vertical middle of the 52 pt bar, Choose Keepers
/// leaked 506 pt of 1100 — including one run of 444 pt between the mode picker
/// and the inspector button — and every screen leaked the 117 pt beside the
/// traffic lights. Those strips neither acted nor dragged the window.
@Suite("The title bar's empty strip keeps its clicks", .serialized)
@MainActor
struct TitleBarStripTests {

    static func window() -> NSWindow {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        return w
    }

    @Test("the band is exactly what the frame has that the content layout does not")
    func height() {
        #expect(TitleBarStrip.height(frameHeight: 780, contentLayoutHeight: 728) == 52)
        // Full screen: the bar is not there and neither is the strip.
        #expect(TitleBarStrip.height(frameHeight: 1080, contentLayoutHeight: 1080) == 0)
        // Never negative, whatever AppKit reports mid-transition.
        #expect(TitleBarStrip.height(frameHeight: 400, contentLayoutHeight: 500) == 0)
    }

    @Test("it lands in front of the content, across the top, and only there")
    func inFrontAcrossTheTop() {
        let w = Self.window()
        defer { w.close() }
        let content = w.contentView!
        let swiftUI = NSView(frame: content.bounds)
        swiftUI.autoresizingMask = [.width, .height]
        content.addSubview(swiftUI)

        TitleBarStrip.install(in: w)
        let strip = content.subviews.compactMap { $0 as? TitleBarStrip }.first
        #expect(strip != nil)
        guard let strip else { return }

        // In front of what was swallowing the clicks.
        #expect(content.subviews.last === strip)
        // The full width of the window, and the height of the bar.
        #expect(strip.frame.width == content.bounds.width)
        #expect(strip.frame.height == TitleBarStrip.height(frameHeight: w.frame.height,
                                                           contentLayoutHeight: w.contentLayoutRect.height))
        #expect(strip.frame.maxY == content.bounds.maxY, "pinned to the top")
        // And nothing below it: the first band of the light table starts where
        // the strip ends.
        #expect(strip.frame.minY == content.bounds.height - strip.frame.height)
    }

    /// His window is SwiftUI's, and its content view is a hosting view, which
    /// is flipped. The strip was placed at `bounds.height - h` - the top of an
    /// ordinary view and the bottom of a flipped one - so it lay across the
    /// foot of the window, in front of every step page's main button, and a
    /// click on Open My Keepers in PhotoLab dragged the window by nothing.
    /// The test above uses a plain content view and could never see it.
    @Test("in SwiftUI's window, whose content view is flipped, the band is the top of the window and not its foot")
    func acrossTheTopOfAFlippedWindow() throws {
        let w = Self.window()
        defer { w.close(); TitleBarStrip.eventBeingRouted = { NSApp.currentEvent?.type } }
        let hosting = NSHostingView(rootView: Color.clear)
        hosting.sizingOptions = []
        w.contentView = hosting
        #expect(hosting.isFlipped, "the test did not reproduce his window")
        TitleBarStrip.install(in: w)
        let strip = try #require(hosting.subviews.compactMap { $0 as? TitleBarStrip }.first)
        let band = TitleBarStrip.height(frameHeight: w.frame.height, contentLayoutHeight: w.contentLayoutRect.height)
        #expect(band > 0)

        func inWindow() -> NSRect { strip.convert(strip.bounds, to: nil) }
        #expect(inWindow().maxY == w.frame.height, "pinned to the top of the window: \(inWindow())")
        #expect(inWindow().height == band)
        #expect(inWindow().minY >= w.contentLayoutRect.maxY, "over none of the content")

        // Where a press lands, asked the way the window asks: a point in the
        // content view's superview, which is the window's own space.
        func hit(_ p: NSPoint) -> NSView? {
            TitleBarStrip.eventBeingRouted = { .leftMouseDown }
            return hosting.hitTest(p)
        }
        #expect(hit(NSPoint(x: w.frame.width / 2, y: w.frame.height - band / 2)) === strip,
                "a press on the empty title bar is the strip's")
        // The action bar's box sits 14 pt above the foot of the window.
        let box = StepMetric.barVerticalPadding + StepMetric.primaryBox.height / 2
        for x in stride(from: CGFloat(10), to: w.frame.width, by: 50) {
            #expect(hit(NSPoint(x: x, y: box)) !== strip, "the strip took a press at the foot of the window, x \(x)")
        }

        // A resize keeps it at the top.
        w.setContentSize(NSSize(width: 1000, height: 700))
        strip.refit()
        #expect(inWindow().maxY == w.frame.height)
        #expect(inWindow().width == w.frame.width)
    }

    @Test("the band's rectangle is the top of the window in either kind of view")
    func frameForEitherKindOfView() {
        let bounds = NSRect(x: 0, y: 0, width: 1100, height: 780)
        #expect(TitleBarStrip.frame(in: bounds, flipped: false, height: 52) == NSRect(x: 0, y: 728, width: 1100, height: 52))
        #expect(TitleBarStrip.frame(in: bounds, flipped: true, height: 52) == NSRect(x: 0, y: 0, width: 1100, height: 52))
        #expect(TitleBarStrip.pinnedToTheTop(flipped: false) == [.width, .minYMargin])
        #expect(TitleBarStrip.pinnedToTheTop(flipped: true) == [.width, .maxYMargin])
    }

    @Test("a window just come back to is draggable on the first press")
    func firstMouse() {
        let w = Self.window()
        defer { w.close() }
        TitleBarStrip.install(in: w)
        let strip = w.contentView!.subviews.compactMap { $0 as? TitleBarStrip }.first
        #expect(strip?.acceptsFirstMouse(for: nil) == true)
        // It is a place to press, never a place to type: it must not be able
        // to take the keyboard off the photograph.
        #expect(strip?.acceptsFirstResponder == false)
    }

    @Test("installing twice leaves one strip")
    func idempotent() {
        let w = Self.window()
        defer { w.close() }
        TitleBarStrip.install(in: w)
        TitleBarStrip.install(in: w)
        TitleBarStrip.install(in: w)
        #expect(w.contentView!.subviews.compactMap { $0 as? TitleBarStrip }.count == 1)
    }

    // MARK: - a press, and nothing else

    /// `NSResponder`'s `scrollWheel(with:)` and `rightMouseDown(with:)` hand
    /// the event to the **superview**, never to the sibling underneath. So a
    /// strip that only overrides `mouseDown` still swallows both — and with
    /// `.fullSizeContentView` a SwiftUI sidebar's scroll view extends under
    /// the bar by design, which is what "clicking on the top is unresponsive"
    /// and "the mouse moves weird" were made of.
    @Test("a scroll, a right click and a moved pointer reach what is drawn under the band")
    func everythingButAPressFallsThrough() {
        let w = Self.window()
        defer { w.close(); TitleBarStrip.eventBeingRouted = { NSApp.currentEvent?.type } }
        let content = w.contentView!

        // A real scroll view where the sidebar's `List` is: under the band.
        let scroll = NSScrollView(frame: content.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 4000))
        scroll.documentView = document
        content.addSubview(scroll)

        TitleBarStrip.install(in: w)
        let strip = content.subviews.compactMap { $0 as? TitleBarStrip }.first!
        // The vertical middle of the 52 pt band, in the content view's space.
        let inTheBand = NSPoint(x: content.bounds.midX, y: strip.frame.midY)
        #expect(strip.frame.contains(inTheBand))

        func hit(_ type: NSEvent.EventType?) -> NSView? {
            TitleBarStrip.eventBeingRouted = { type }
            return content.hitTest(inTheBand)
        }

        // A press is the strip's, and drags the window.
        #expect(hit(.leftMouseDown) === strip)
        // Everything else goes to the scroll view under it.
        for type: NSEvent.EventType in [.scrollWheel, .rightMouseDown, .otherMouseDown,
                                        .mouseMoved, .cursorUpdate, .magnify] {
            let found = hit(type)
            #expect(found !== strip, "the strip took a \(type)")
            #expect(found?.isDescendant(of: scroll) == true, "\(type) did not reach the scroll view")
        }
        // And with no event at all — an accessibility probe, a cursor rect —
        // the strip is not in the way either.
        #expect(hit(nil) !== strip)
    }

    @Test("the claim is one press, named once")
    func claimsOnlyAPress() {
        #expect(TitleBarStrip.claims(.leftMouseDown))
        #expect(!TitleBarStrip.claims(.scrollWheel))
        #expect(!TitleBarStrip.claims(.rightMouseDown))
        #expect(!TitleBarStrip.claims(.otherMouseDown))
        #expect(!TitleBarStrip.claims(nil))
    }

    // MARK: - and it stays in front

    /// `refit()` ran on resize and on full screen only. SwiftUI replaces its
    /// hosting view without either — a sheet, the inspector, a split-view
    /// change — and the new one went in last, in front of the strip, which
    /// then did nothing at all and said nothing about it.
    ///
    /// `NSWindow.update()` is what AppKit sends every window once per pass of
    /// the event loop, and it is called here for exactly that reason: it is
    /// the real mechanism, not a stand-in for it.
    @Test("a hosting view SwiftUI puts in later is behind the strip again by the next pass")
    func itStaysInFront() {
        let w = Self.window()
        defer { w.close() }
        let content = w.contentView!
        content.addSubview(NSView(frame: content.bounds))
        TitleBarStrip.install(in: w)
        let strip = content.subviews.compactMap { $0 as? TitleBarStrip }.first!
        #expect(content.subviews.last === strip)

        // No resize, no full screen: just SwiftUI swapping what it draws.
        for _ in 0..<3 {
            let replacement = NSView(frame: content.bounds)
            content.addSubview(replacement)
            #expect(content.subviews.last === replacement, "the test did not reproduce it")
            w.update()
            #expect(content.subviews.last === strip,
                    "the strip stayed behind a view added with no resize")
            #expect(content.subviews.contains(replacement))
        }
        // And an update that changes nothing changes nothing: the check is one
        // pointer comparison and it runs every pass of the event loop.
        let order = content.subviews
        w.update()
        #expect(content.subviews == order)
    }

    @Test("a double click does what System Settings says, Fill included")
    func doubleClick() {
        #expect(TitleBarStrip.doubleClick("Fill") == .fill)
        #expect(TitleBarStrip.doubleClick("Minimize") == .minimize)
        #expect(TitleBarStrip.doubleClick("None") == .nothing)
        #expect(TitleBarStrip.doubleClick("Maximize") == .zoom)
        #expect(TitleBarStrip.doubleClick(nil) == .zoom)
    }
}
