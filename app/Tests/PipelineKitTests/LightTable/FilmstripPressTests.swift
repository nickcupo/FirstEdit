import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// §2.5.9: a click on a thumbnail goes to that frame — every time, never a
/// verdict — and the keyboard stays with the photograph.
///
/// The strip used the collection view's own selection. The first click made
/// the strip the keyboard's, so the arrows and Space went to it instead of the
/// photograph, and a thumbnail it still held selected ignored the next click
/// on it: he clicked 5, arrowed to 9, clicked 5 again, and stayed on 9.
@Suite("A click in the filmstrip", .serialized)
@MainActor
struct FilmstripPressTests {

    /// The strip in an offscreen window, laid out, with a stand-in for the
    /// photograph holding the keyboard.
    @MainActor
    final class Rig {
        let window: NSWindow
        let strip: FilmstripView
        let photograph: Photograph
        let collection: NSCollectionView

        final class Photograph: NSView {
            override var acceptsFirstResponder: Bool { true }
        }

        init(_ model: ViewerModel) throws {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1100, height: 400),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 400))
            window.contentView = root
            photograph = Photograph(frame: NSRect(x: 0, y: 100, width: 1100, height: 300))
            root.addSubview(photograph)
            strip = FilmstripView(model: model)
            strip.frame = NSRect(x: 0, y: 0, width: 1100, height: Tokens.Metric.filmstrip)
            root.addSubview(strip)
            let scroll = try #require(strip.subviews.compactMap { $0 as? NSScrollView }.first)
            collection = try #require(scroll.documentView as? NSCollectionView)
            for _ in 0..<5 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                root.layoutSubtreeIfNeeded()
                strip.refresh()
            }
            window.makeFirstResponder(photograph)
            KeyFocus.preferred = photograph
        }

        func thumb(_ i: Int) throws -> FilmstripItemView {
            let item = try #require(collection.item(at: IndexPath(item: i, section: 0)) as? FilmstripItem)
            return item.thumb
        }

        /// A mouse-down on thumbnail `i`, delivered the way the window
        /// delivers one: to the view the point hits, which the window makes
        /// first responder only if that view will take it. (An offscreen
        /// window that is never ordered in does not route a synthetic event
        /// itself, and ordering one in would put it on his screen.)
        func click(_ i: Int, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws {
            let view = try thumb(i)
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let root = try #require(window.contentView)
            let hit = try #require(root.hitTest(root.convert(point, from: nil)))
            #expect(hit === view, "the press lands on the thumbnail, not the strip behind it")
            let e = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                                    modifierFlags: modifiers, timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: count, pressure: 1))
            if hit.acceptsFirstResponder { window.makeFirstResponder(hit) }
            hit.mouseDown(with: e)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        func close() { window.close() }
    }

    @Test("a thumbnail clicked before, then left by the arrows, goes there again when clicked again")
    func sameThumbnailTwice() async throws {
        let m = try ViewerTests.model()
        #expect(m.frames.count >= 6)
        let rig = try Rig(m)
        defer { rig.close() }
        try rig.click(2)
        #expect(m.frameIndex == 2)
        await ViewerTests.press(m, .nextFrame)
        await ViewerTests.press(m, .nextFrame)
        #expect(m.frameIndex == 4)
        try rig.click(2)
        #expect(m.frameIndex == 2, "the second click on the same thumbnail is a click too")
    }

    @Test("a click in the strip leaves the keyboard with the photograph")
    func keyboardStaysWithThePhotograph() throws {
        let m = try ViewerTests.model()
        let rig = try Rig(m)
        defer { rig.close() }
        try rig.click(3)
        #expect(m.frameIndex == 3)
        #expect(rig.window.firstResponder === rig.photograph)
        #expect(!rig.collection.acceptsFirstResponder)
        #expect(try !rig.thumb(3).acceptsFirstResponder)
    }

    @Test("a double-click is Full Image, on the frame the first click went to")
    func doubleClickIsFullImage() async throws {
        let m = try ViewerTests.model()
        let rig = try Rig(m)
        defer { rig.close() }
        try rig.click(1, count: 1)
        try rig.click(1, count: 2)
        await ViewerTests.press(m, .fit)          // lets the queued press through
        #expect(m.frameIndex == 1)
        #expect(m.fullImage)
        m.setFullImage(false)
    }

    @Test("one ⌘-click on another frame is a pair with the one he is on, and C opens exactly that pair")
    func commandClickPairOpensInCompare() async throws {
        let m = try ViewerTests.model()
        let rig = try Rig(m)
        defer { rig.close() }
        m.goToFrame(4)
        try rig.click(5, modifiers: .command)
        #expect(m.frameIndex == 4, "a ⌘-click builds the set; it does not move him")
        #expect(m.compareSelection == [m.frames[4], m.frames[5]])
        let pair = m.compareSelection
        await ViewerTests.press(m, .compare)
        #expect(m.mode == .compare)
        #expect(m.compareSelection == pair, "C opens on the frames he picked, not the stack")
        m.leaveMode()
    }

    /// C opened a pair picked outside any stack, but the Compare button and
    /// Frame ▸ Compare were both greyed there: they asked only about stacks.
    @Test("with a pair picked outside any stack, the Compare button and Frame ▸ Compare are live and open that pair")
    func pickedPairMakesCompareLive() async throws {
        let m = try ViewerTests.model()
        let rig = try Rig(m)
        defer { rig.close() }
        let loose = m.frames.indices.filter { Stacks.stack(for: m.frames[$0], in: m.stacks) == nil }
        try #require(loose.count >= 2, "the fixture has two frames outside any stack")
        m.goToFrame(loose[0])
        #expect(ControlBar(model: m).compareCount == nil, "nothing to compare yet, so it is greyed")
        #expect(!LightTableCommands.enabled(.compare, m))
        try rig.click(loose[1], modifiers: .command)
        #expect(ControlBar(model: m).compareCount == 2)
        #expect(LightTableCommands.enabled(.compare, m))
        let pair = m.compareSelection
        await ViewerTests.press(m, .compare)
        #expect(m.mode == .compare)
        #expect(m.compareSelection == pair)
        m.leaveMode()
        #expect(ControlBar(model: m).compareCount == nil, "leaving Compare lets the pair go")
    }

    @Test("⌘-click takes a frame back out, ⇧-click takes in a run, a plain click lets the set go")
    func compareSetRules() throws {
        let frames = (0..<12).map { String(format: "f%02d", $0) }
        var set = FilmstripView.compareSet([], frames: frames, cursor: 3, pressed: 6,
                                           extendingFrom: nil, extend: false)
        #expect(set == ["f03", "f06"])
        set = FilmstripView.compareSet(set, frames: frames, cursor: 3, pressed: 3,
                                       extendingFrom: 6, extend: false)
        #expect(set == ["f06"])
        set = FilmstripView.compareSet(set, frames: frames, cursor: 3, pressed: 9,
                                       extendingFrom: 6, extend: true)
        #expect(set == ["f06", "f07", "f08", "f09"])
        set = FilmstripView.compareSet(set, frames: frames, cursor: 3, pressed: 0,
                                       extendingFrom: 11, extend: true)
        #expect(set.count == 8, "never more than Compare can lay out")
        #expect(set == Array(frames.prefix(8)))
        // A set left over from another burst is not carried into this one.
        set = FilmstripView.compareSet(["elsewhere"], frames: frames, cursor: 1, pressed: 2,
                                       extendingFrom: nil, extend: false)
        #expect(set == ["f01", "f02"])

        let m = try ViewerTests.model()
        let rig = try Rig(m)
        defer { rig.close() }
        try rig.click(2, modifiers: .command)
        #expect(m.compareSelection.count == 2)
        try rig.click(3)
        #expect(m.compareSelection.isEmpty)
        #expect(m.frameIndex == 3)
    }

    @Test("each thumbnail is a button VoiceOver can press, and says which one he is on")
    func thumbnailsAreButtons() throws {
        let m = try ViewerTests.model()
        let rig = try Rig(m)
        defer { rig.close() }
        let thumb = try rig.thumb(4)
        #expect(thumb.isAccessibilityElement())
        #expect(thumb.accessibilityRole() == .button)
        #expect(!(thumb.accessibilityLabel() ?? "").isEmpty)
        #expect(thumb.accessibilityPerformPress())
        #expect(m.frameIndex == 4)
        rig.strip.refresh()
        #expect(try rig.thumb(4).isAccessibilitySelected())
        #expect(try !rig.thumb(0).isAccessibilitySelected())
    }
}
