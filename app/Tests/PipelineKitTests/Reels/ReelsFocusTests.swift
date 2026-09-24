import AppKit
import SwiftUI
import Foundation
import Testing
@testable import PipelineKit

/// Where the keyboard is on the Reels page (DESIGN.md §2.6), asserted on the
/// real page rather than on a stored flag: the page is hosted in a window
/// that is never put on screen, and keys are sent to it as AppKit routes
/// them.
@Suite("Reels: where the keyboard is", .serialized)
@MainActor
struct ReelsFocusTests {

    /// Says it is key without ever being ordered in, so the first responder
    /// and the field editor behave as they do in his window.
    final class OffscreenKeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    final class Calls { var fetches: [String] = []; var cuts: [[String: JSONValue]] = [] }

    @MainActor
    struct Page {
        let window: NSWindow
        let model: ReelsModel
        let calls: Calls
        let field: NSTextField
        let list: NSTableView
        /// The page's key monitor, which AppKit asks before anything else.
        let sink: ReelsKeyView

        func close() {
            window.contentView = nil
            window.close()
            ReelsModelStore.shared.reset()
        }
    }

    /// Time for the main run loop, which the test runner keeps turning, to
    /// do AppKit's and SwiftUI's work.
    func spin(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }

    func key(_ chars: String, code: UInt16, in w: NSWindow, _ mods: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, characters: chars,
                                      charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
    }

    /// As AppKit routes a key: the app's local monitors first — the page's
    /// own among them — then key equivalents, then the first responder.
    /// Sent straight to the window, not through the app's queue, so
    /// `NSApp.currentEvent` is not this key: the list's own ↓ is driven
    /// through `choose(burst:byKeys:)`, which is what its selection calls
    /// for a key.
    func press(_ e: NSEvent, in p: Page) {
        if p.sink.handle(e) { return }
        if p.window.performKeyEquivalent(with: e) { return }
        p.window.sendEvent(e)
    }

    func returnKey(_ w: NSWindow) throws -> NSEvent { try key("\r", code: 36, in: w) }

    /// The editing field inside the burst field, when it has the keyboard.
    func typing(in p: Page) -> Bool { p.field.currentEditor() != nil && p.window.firstResponder is NSTextView }

    /// `lister`: how long the lister takes to answer, so the page can
    /// arrive before the frames do, as it does on a big shoot.
    func open(lister: Duration = .zero) async throws -> Page {
        _ = NSApplication.shared
        ReelsModelStore.shared.reset()
        ReelsModelStore.shared.memory = .none
        let c = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "t"))
        let r = try Fixture.decode(ShootResponse.self, "shoot-decided")
        let s = ShootSession(response: r, ext: nil, client: c, pump: ImagePump(client: c))
        let m = ReelsModelStore.shared.model(for: s, jobs: StepJobs.model(client: c))
        let calls = Calls()
        m.fetchOptions = { _, burst, _ in
            calls.fetches.append(burst ?? "")
            if lister > .zero { try await Task.sleep(for: lister) }
            return try ReelsScaffold.options(about: burst ?? "93")
        }
        m.sendReel = { _, body in calls.cuts.append(body) }
        m.burst = "93"
        let w = OffscreenKeyWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1440, height: 900),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ReelsStep(session: s, client: c, pump: ImagePump(client: c)))
        await spin(0.5)
        if calls.fetches.isEmpty { m.appeared() }
        for _ in 0..<200 where m.framesBurst != "93" { await spin(0.01) }
        await spin(0.3)
        let all = views(try #require(w.contentView))
        let field = try #require(all.compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let list = try #require(all.compactMap { $0 as? NSTableView }.first)
        let sink = try #require(all.compactMap { $0 as? ReelsKeyView }.first)
        #expect(sink.isListening, "the page's key monitor is installed while it is in a window")
        return Page(window: w, model: m, calls: calls, field: field, list: list, sink: sink)
    }

    @Test("the frames have the keyboard when the page comes on screen, so D leaves a frame out at once")
    func framesOnArrival() async throws {
        let p = try await open(lister: .milliseconds(600))
        defer { p.close() }
        #expect(p.model.frames.count == 13)
        press(try key("d", code: 2, in: p.window), in: p)
        await spin(0.1)
        #expect(p.model.chosen.count == 12)
    }

    @Test("arrowing down the bursts list leaves the keyboard in the list once each burst's frames come")
    func theListKeepsTheKeys() async throws {
        let p = try await open()
        defer { p.close() }
        p.window.makeFirstResponder(p.list)
        await spin(0.2)
        #expect(p.window.firstResponder === p.list)
        // As the list's selection does for an arrow: chosen by the keys, and
        // asked about once he pauses on it.
        p.model.choose(burst: "5", byKeys: true)
        for _ in 0..<200 where p.model.framesBurst != "5" { await spin(0.01) }
        await spin(0.2)
        #expect(p.model.framesBurst == "5")
        #expect(p.window.firstResponder === p.list)
        // A burst seen already this visit comes back at once; still the list's.
        p.model.choose(burst: "93", byKeys: true)
        await spin(0.4)
        #expect(p.model.framesBurst == "93")
        #expect(p.window.firstResponder === p.list)
        // Two more, as a held ↓ does: the frames never take the keys, so the
        // next arrow still moves down the list rather than the ring.
        for b in ["94", "95"] {
            p.model.choose(burst: b, byKeys: true)
            for _ in 0..<200 where p.model.framesBurst != b { await spin(0.01) }
            await spin(0.2)
            #expect(p.window.firstResponder === p.list)
        }
    }

    @Test("with the bursts list holding the keys, R and W change burst there, ↓ stays the list's, and E and D act on the frames and hand them the keys")
    func theSchemeFromTheList() async throws {
        let p = try await open()
        defer { p.close() }
        p.window.makeFirstResponder(p.list)
        await spin(0.3)
        #expect(p.window.firstResponder === p.list)
        // ↓ and ↑ are the list's own, walking the bursts.
        #expect(!p.sink.handle(try key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, in: p.window)))
        #expect(!p.sink.handle(try key(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126, in: p.window)))
        // R and W go to the next and previous burst, and the list keeps the
        // keys, so the next ↓ still goes down it.
        let list = p.model.shownBursts.map(\.burst)
        let i = try #require(list.firstIndex(of: "93"))
        press(try key("r", code: 15, in: p.window), in: p)
        #expect(p.model.burst == list[i + 1])
        press(try key("w", code: 13, in: p.window), in: p)
        #expect(p.model.burst == "93")
        await spin(0.2)
        #expect(p.window.firstResponder === p.list)
        for _ in 0..<200 where p.model.framesBurst != "93" { await spin(0.01) }
        // S, F, E and D reach the frames from the list.
        let first = p.model.cursor
        press(try key("f", code: 3, in: p.window), in: p)
        #expect(p.model.cursor != first)
        press(try key("s", code: 1, in: p.window), in: p)
        #expect(p.model.cursor == first)
        press(try key("d", code: 2, in: p.window), in: p)
        #expect(p.model.chosen.count == p.model.frames.count - 1)
        press(try key("e", code: 14, in: p.window), in: p)
        #expect(p.model.chosen.count == p.model.frames.count - 1, "E put in the frame D moved on to, which was in")
        press(try key("q", code: 12, in: p.window), in: p)
        press(try key("q", code: 12, in: p.window), in: p)
        #expect(p.model.chosen.count == p.model.frames.count)
        // A key that acted on a frame gave the frames the keys: the ring is
        // drawn, and ↓ is a row of them now.
        await spin(0.3)
        #expect(p.window.firstResponder !== p.list)
        #expect(p.sink.handle(try key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, in: p.window)))
    }

    @Test("Return in the burst field goes to the burst typed, cuts nothing, and gives the frames the keys")
    func returnInTheField() async throws {
        let p = try await open()
        defer { p.close() }
        p.model.choose(burst: "231")
        await spin(0.3)
        p.window.makeFirstResponder(p.field)
        await spin(0.2)
        p.model.search = "93"
        await spin(0.2)
        press(try returnKey(p.window), in: p)
        await spin(0.4)
        #expect(p.calls.cuts.isEmpty)
        #expect(p.model.burst == "93" && p.model.search.isEmpty)
        #expect(!typing(in: p))
        press(try key("d", code: 2, in: p.window), in: p)
        await spin(0.1)
        #expect(p.model.chosen.count == 12)
    }

    @Test("Return in an empty burst field changes nothing and gives the frames the keys")
    func returnInAnEmptyField() async throws {
        let p = try await open()
        defer { p.close() }
        p.model.choose(burst: "231")
        for _ in 0..<200 where p.model.framesBurst != "231" { await spin(0.01) }
        p.window.makeFirstResponder(p.field)
        await spin(0.2)
        press(try returnKey(p.window), in: p)
        await spin(0.4)
        #expect(p.model.burst == "231")
        #expect(p.calls.cuts.isEmpty)
        #expect(!typing(in: p))
        // The next Return is Cut It, on the burst he was on.
        press(try returnKey(p.window), in: p)
        await spin(0.2)
        #expect(p.calls.cuts.last?["burst"] == .string("231"))
    }

    @Test("Edit ▸ Find Burst… puts the keyboard in the burst field")
    func findReachesTheField() async throws {
        let p = try await open()
        defer { p.close() }
        #expect(!typing(in: p))
        p.model.find()
        await spin(0.4)
        #expect(typing(in: p))
        // While it is there, Return is the field's, not Cut It.
        p.model.search = "231"
        await spin(0.2)
        press(try returnKey(p.window), in: p)
        await spin(0.3)
        #expect(p.calls.cuts.isEmpty && p.model.burst == "231")
        // ⌘F again, then Escape: the frames have the keys back.
        p.model.find()
        await spin(0.3)
        #expect(typing(in: p))
        press(try key("\u{1b}", code: 53, in: p.window), in: p)
        await spin(0.2)
        #expect(!typing(in: p))
        press(try key("d", code: 2, in: p.window), in: p)
        await spin(0.1)
        #expect(p.model.chosen.count == p.model.frames.count - 1)
    }
}
