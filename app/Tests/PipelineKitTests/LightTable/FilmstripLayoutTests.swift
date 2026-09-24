import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// §2.5.9: nothing in the strip is hidden, and that includes the frame numbers
/// under the thumbnails and the count over a run. A scroller used to sit
/// across the caption lane — first the whole overlay scroller, then its knob
/// in the band's last few points — and painted over the bottom of every number
/// whenever it showed; its legacy style took height out of the band.
@Suite("The filmstrip's captions and counts are whole", .serialized)
@MainActor
struct FilmstripLayoutTests {

    @Test("the document stops 5 pt above the band's foot and every item ends above it")
    func captionsInsideTheBand() throws {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1100, height: 780),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        defer { w.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 780))
        w.contentView = root
        let strip = FilmstripView(model: try ViewerTests.model())
        strip.frame = NSRect(x: 0, y: 0, width: 1100, height: Tokens.Metric.filmstrip)
        root.addSubview(strip)
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            root.layoutSubtreeIfNeeded()
            strip.refresh()
        }
        let scroll = try #require(strip.subviews.compactMap { $0 as? NSScrollView }.first)
        let collection = try #require(scroll.documentView as? NSCollectionView)

        // The scroll view is the whole band; the document stops 5 pt short.
        #expect(scroll.frame.height == Tokens.Metric.filmstrip)
        #expect(!scroll.automaticallyAdjustsContentInsets, "a title bar above must not push the strip down")
        #expect(scroll.contentInsets.bottom == 5)
        #expect(collection.frame.height == Tokens.Metric.filmstrip - 5)

        let items = collection.visibleItems()
        #expect(!items.isEmpty)
        for item in items {
            let r = strip.convert(item.view.bounds, from: item.view)   // flipped: y grows down
            #expect(r.height == FilmstripItemView.itemHeight, "the picture keeps its 60 pt")
            #expect(r.maxY <= Tokens.Metric.filmstrip - 5, "the caption ends inside the band")
        }
    }

    /// His Mac has a wheel mouse attached, so the system prefers the legacy
    /// scroller, and AppKit hands every scroll view that preference whenever it
    /// changes. The legacy scroller took 11 pt out of the clip view, the item
    /// was laid out 5 pt above the band, and the "4 similar" over a run lost
    /// the top of its letters to the control bar; the overlay one's knob ran
    /// across the bottom of the frame numbers. The strip has no scroll bar.
    @Test("with the legacy scroller style forced on it, the strip has no scroll bar and every item sits whole in the band")
    func noScrollBarWhateverTheStyle() throws {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1100, height: 780),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        defer { w.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 780))
        w.contentView = root
        let strip = FilmstripView(model: try ViewerTests.model())
        strip.frame = NSRect(x: 0, y: 0, width: 1100, height: Tokens.Metric.filmstrip)
        root.addSubview(strip)
        let scroll = try #require(strip.subviews.compactMap { $0 as? NSScrollView }.first)
        let collection = try #require(scroll.documentView as? NSCollectionView)

        // What AppKit does when the preference changes, done by hand.
        scroll.scrollerStyle = .legacy
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification,
                                        object: nil)
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            root.layoutSubtreeIfNeeded()
            strip.refresh()
        }

        #expect(!scroll.hasHorizontalScroller)
        #expect(scroll.horizontalScroller?.isHidden ?? true)
        #expect(scroll.contentView.frame.height == Tokens.Metric.filmstrip,
                "no scroller track takes height out of the band")
        #expect(scroll.contentView.bounds.minY == 0)
        let items = collection.visibleItems()
        #expect(!items.isEmpty)
        for item in items {
            let r = strip.convert(item.view.bounds, from: item.view)   // flipped: y grows down
            #expect(r.minY >= 0, "the bracket lane, and the count in it, start inside the band")
            #expect(r.maxY <= Tokens.Metric.filmstrip - 5)
        }
    }

    @Test("the count over a run fits the bracket lane it is drawn in")
    func stackLabelFitsItsLane() {
        let font = FilmstripItemView.stackLabelFont
        #expect(NSLayoutManager().defaultLineHeight(for: font) <= FilmstripItemView.bracket)
        #expect(font.pointSize >= 10)
    }
}
