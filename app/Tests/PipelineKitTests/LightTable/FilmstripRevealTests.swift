import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// §2.5.9: the frame he is on is in the strip, ringed, wherever he arrived
/// from. The reveal asked the flow layout where the thumbnail was, and
/// straight after `reloadData` — or before the strip's first layout — the
/// layout had nothing to say, so the reveal gave up: on the last frame of a
/// burst reached with ←, on a light table reopened deep in a burst, and after
/// ⌘Z into another burst, the strip showed its first page and no ring at all.
@Suite("The filmstrip shows the frame he is on", .serialized)
@MainActor
struct FilmstripRevealTests {

    /// Where the page lands is what is tested, not the slide there, which a
    /// window never put on a screen does not run.
    init() { FilmstripView.slides = false }

    /// The strip in an offscreen window, `width` wide: four frames a page, so
    /// the fixture's longest burst is several pages.
    static func strip(_ m: ViewerModel, width: CGFloat = 420) throws -> (NSWindow, FilmstripView, NSScrollView) {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 200),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        w.contentView = root
        let strip = FilmstripView(model: m)
        strip.frame = NSRect(x: 0, y: 0, width: width, height: Tokens.Metric.filmstrip)
        // What `makeNSView` does: one refresh before the strip has ever been
        // laid out.
        strip.refresh()
        root.addSubview(strip)
        let scroll = try #require(strip.subviews.compactMap { $0 as? NSScrollView }.first)
        return (w, strip, scroll)
    }

    /// Long enough for a page turn inside a burst, which slides, to land.
    static func settle(_ root: NSView?) {
        for _ in 0..<12 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            root?.layoutSubtreeIfNeeded()
        }
    }

    /// Until `done`, for as long as a busy machine takes to finish the slide:
    /// a fixed 0.36 s failed whenever the tests ran beside a build.
    static func settle(_ root: NSView?, until done: () -> Bool) {
        settle(root)
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            root?.layoutSubtreeIfNeeded()
        }
    }

    /// The cursor's thumbnail, whole, inside what the strip shows.
    static func cursorIsShown(_ m: ViewerModel, _ scroll: NSScrollView) throws -> Bool {
        let collection = try #require(scroll.documentView as? NSCollectionView)
        let path = IndexPath(item: m.frameIndex, section: 0)
        let frame = try #require(collection.layoutAttributesForItem(at: path)?.frame)
        let visible = scroll.contentView.documentVisibleRect
        return frame.minX >= visible.minX && frame.maxX <= visible.maxX
    }

    @Test("opened on the last frame of a long burst, the strip shows that frame")
    func openedDeepInABurst() throws {
        let m = try ViewerTests.model()
        #expect(m.frames.count >= 6, "a burst longer than one page of this strip")
        m.goToFrame(m.frames.count - 1)
        let (w, strip, scroll) = try Self.strip(m)
        defer { w.close() }
        Self.settle(w.contentView)
        #expect(try Self.cursorIsShown(m, scroll))
        _ = strip
    }

    @Test("← off the first frame lands on the last frame of the burst before, and the strip goes with it")
    func backIntoTheBurstBefore() async throws {
        let m = try ViewerTests.model()
        let long = m.burstIndex
        #expect(m.frames.count >= 6)
        let (w, strip, scroll) = try Self.strip(m)
        defer { w.close() }
        Self.settle(w.contentView)
        m.goToBurst(long + 1)
        strip.refresh()
        Self.settle(w.contentView)
        #expect(m.frameIndex == 0)
        await ViewerTests.press(m, .previousFrame)
        #expect(m.burstIndex == long)
        #expect(m.frameIndex == m.frames.count - 1)
        strip.refresh()          // what SwiftUI does with the new token
        #expect(try Self.cursorIsShown(m, scroll), "shown on the same pass, not after something else moves")
        Self.settle(w.contentView)
        #expect(try Self.cursorIsShown(m, scroll))
    }

    /// A picture `width` pixels wide, so a test can tell which frame it is.
    nonisolated static func png(width: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 20,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        return rep?.representation(using: .png, properties: [:]) ?? Data()
    }

    /// The dog shoot as one burst, many pages long: his own bursts run to
    /// 32 frames, and the fixture's longest is only a page and a half.
    static func oneLongBurst() throws -> ShootResponse {
        let data = try Fixture.data("shoot")
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try #require(obj["rows"] as? [[String: Any]])
        let first = try #require(rows.first)
        for i in rows.indices {
            rows[i]["scene"] = first["scene"]
            rows[i]["burst"] = first["burst"]
        }
        obj["rows"] = rows
        return try JSONDecoder().decode(ShootResponse.self,
                                        from: JSONSerialization.data(withJSONObject: obj))
    }

    /// The thumbnails arrive after the strip has turned to the cursor's page,
    /// and the cells that asked for them have been handed to other frames by
    /// then. A thumbnail used to land on whichever frame its cell now showed:
    /// on the last frame of a long burst the ringed thumbnail wore the picture
    /// of a frame from the first page.
    @Test("a thumbnail that arrives after its cell went to another frame is not put on that frame")
    func lateThumbnailsLandOnTheirOwnFrame() async throws {
        let response = try Self.oneLongBurst()
        let order = response.rows.map(\.stem)
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"))
        let pump = ImagePump(budget: .base, loader: { route in
            guard case .thumb(_, let stem) = route else { return Data() }
            try await Task.sleep(for: .milliseconds(900))
            return Self.png(width: 40 + 2 * (order.firstIndex(of: stem) ?? 0))
        })
        let session = ShootSession(response: response, ext: nil, client: client, pump: pump,
                                   queue: VerdictQueue(sender: { _ in .failure(.offline) }))
        let m = ViewerModel(session: session, navigation: Navigation())
        #expect(m.frames.count >= 20, "a burst many pages long")
        let (w, strip, scroll) = try Self.strip(m)
        defer { w.close() }
        Self.settle(w.contentView)                 // the first page asks for its pictures
        m.goToFrame(m.frames.count - 1)
        strip.refresh()
        Self.settle(w.contentView)                 // and its cells go to the last page's frames
        try await Task.sleep(for: .milliseconds(1200))
        Self.settle(w.contentView) { (try? Self.cursorIsShown(m, scroll)) == true }
        #expect(try Self.cursorIsShown(m, scroll))
        let collection = try #require(scroll.documentView as? NSCollectionView)
        var checked = 0
        for item in collection.visibleItems() {
            guard let i = collection.indexPath(for: item)?.item,
                  let image = (item as? FilmstripItem)?.thumb.image else { continue }
            let expected = 40 + 2 * (order.firstIndex(of: m.frames[i]) ?? 0)
            #expect(image.width == expected, "frame \(i + 1) shows its own picture")
            checked += 1
        }
        #expect(checked > 0, "the pictures arrived")
    }

    @Test("an arrow inside the page does not move the strip; one past it turns a whole page")
    func pagesNotSlides() throws {
        let m = try ViewerTests.model()
        let (w, strip, scroll) = try Self.strip(m)
        defer { w.close() }
        Self.settle(w.contentView)
        #expect(scroll.contentView.bounds.minX == 0)
        m.goToFrame(2)
        strip.refresh()
        #expect(scroll.contentView.bounds.minX == 0, "frame 3 is on the first page")
        m.goToFrame(5)
        strip.refresh()
        Self.settle(w.contentView) { (try? Self.cursorIsShown(m, scroll)) == true }
        #expect(scroll.contentView.bounds.minX > 0)
        #expect(try Self.cursorIsShown(m, scroll))
    }
}
