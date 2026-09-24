import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// Full Image (DESIGN.md §2.5.7): one stage in charge at a time, the keyboard
/// back where it was afterwards, and a held Space that is a peek.
///
/// No window here is ever ordered onto a screen.
@Suite("Full Image has one stage in charge", .serialized)
@MainActor
struct FullImageTests {

    static func window(_ w: CGFloat = 1100, _ h: CGFloat = 780) -> NSWindow {
        _ = NSApplication.shared
        let win = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: w, height: h),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        return win
    }

    /// The table's stage, 8 pt in from a 1100 × 542 viewer, and the Full
    /// Image stage over the whole window — the two sizes that took turns.
    static func twoStages(_ m: ViewerModel) -> (NSWindow, StageLayerView, StageLayerView) {
        let w = window()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 780))
        w.contentView = content
        let table = StageLayerView(model: m)
        table.role = .table
        table.frame = NSRect(x: 8, y: 230, width: 1084, height: 526)
        content.addSubview(table)
        let full = StageLayerView(model: m)
        full.role = .fullImage
        full.frame = NSRect(x: 0, y: 0, width: 1100, height: 780)
        content.addSubview(full)
        return (w, table, full)
    }

    @Test("only the stage he can see measures the viewport, so the two never take turns overwriting it")
    func oneMeasures() throws {
        let m = try ViewerTests.model()
        let (w, table, full) = Self.twoStages(m)
        defer { table.tearDown(); full.tearDown(); w.close() }

        table.refresh(); full.refresh()
        #expect(m.viewport == table.bounds.size, "out of Full Image the table's stage is in charge")

        m.setFullImage(true)
        full.refresh(); table.refresh(); table.layout(); full.refresh(); table.refresh()
        #expect(m.viewport == full.bounds.size,
                "the covered stage went on writing its own size under Full Image")
        #expect(m.heldMoves === full)

        m.setFullImage(false)
        full.refresh(); table.refresh(); full.layout()
        #expect(m.viewport == table.bounds.size)
    }

    @Test("coming back from Full Image, the table's stage has the held arrows and the keyboard again")
    func focusComesBack() throws {
        let m = try ViewerTests.model()
        let (w, table, full) = Self.twoStages(m)
        defer { table.tearDown(); full.tearDown(); w.close() }
        table.refresh()
        #expect(w.firstResponder === table)

        m.setFullImage(true)
        full.refresh()
        #expect(w.firstResponder === full)

        // The overlay goes; the table's stage is uncovered.
        m.setFullImage(false)
        full.removeFromSuperview()
        table.refresh()
        #expect(w.firstResponder === table, "the window itself was left holding the keyboard")
        #expect(m.heldMoves === table)
        #expect(KeyFocus.preferred === table)
    }

    @Test("a tapped Space stays in Full Image; a held Space is a peek that ends when he lets go")
    func spacePeek() async throws {
        let m = try ViewerTests.model()
        let space = KeyMap.Press(key: .space)

        _ = m.key(space, at: 10)
        await ViewerTests.press(m, .fit)            // lets the toggle through the queue
        #expect(m.fullImage)
        m.keyReleased(space, at: 10.1)
        #expect(m.fullImage, "a tap is a toggle")

        _ = m.key(space, at: 20)
        await ViewerTests.press(m, .fit)
        #expect(!m.fullImage)
        m.keyReleased(space, at: 21)
        #expect(!m.fullImage, "a long press that left Full Image is not a peek")

        _ = m.key(space, at: 30)
        _ = m.key(KeyMap.Press(key: .space, isARepeat: true), at: 30.4)
        await ViewerTests.press(m, .fit)
        #expect(m.fullImage)
        m.keyReleased(space, at: 30.6)
        #expect(!m.fullImage, "a held Space left Full Image up after he let go")
    }
}

/// The sizes the light table asks the engine for (DESIGN.md §2.5.7, §3.9).
@Suite("The light table asks for the size it draws", .serialized)
@MainActor
struct PictureSizeTests {

    @Test("the prefetch asks for the size the stage will draw, not the viewport's")
    func prefetchMatchesTheStage() throws {
        let m = try ViewerTests.model()
        m.viewport = CGSize(width: 1084, height: 526)
        m.backingScale = 2
        let a = m.aspect
        let drawn = a > 1084.0 / 526 ? CGSize(width: 1084, height: 1084 / a) : CGSize(width: 526 * a, height: 526)
        #expect(m.prefetchPixels == LightTableSeams.current.fullPixels(forPoints: drawn, scale: 2))
    }

    @Test("nothing caps the picture at 2600 or a tile at 3000 any more")
    func noOldCaps() {
        // Full Image on a 14" laptop: 1417 × 945 pt at 2×.
        #expect(LightTableSeams.current.fullPixels(forPoints: CGSize(width: 1417, height: 945), scale: 2) > 2600)
        #expect(LightTableSeams.current.maximumTilePixels >= 4096)
        let tile = TileFetcher.tile(aim: CGPoint(x: 0.5, y: 0.5), viewportPixels: CGSize(width: 2834, height: 1890))
        #expect(tile.px > 3000)
    }
}
