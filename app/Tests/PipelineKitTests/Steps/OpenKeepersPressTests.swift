import AppKit
import SwiftUI
import Foundation
import Testing
@testable import PipelineKit

/// "Open my keepers in PhotoLab doesn't work": he pressed the Edit page's
/// main button and nothing at all happened - no PhotoLab, no line on the page,
/// and no request ever reached the engine.
///
/// The press was lost before SwiftUI saw it. The window's content view is a
/// hosting view, which is flipped, and the strip that gives the empty title
/// bar its clicks back was laid out as though it were not: across the foot of
/// the window, in front of the action bar, where it took the click as the
/// start of a window drag. Return and ⇧⌘E never pass through a hit test, so
/// they still worked, which is why only his click was lost.
///
/// These run the page the way the app does: the real window root, in a window
/// that is never put on screen, against an engine stood in for by a URL
/// protocol that records what it is asked and opens nothing.
@Suite("Open My Keepers in PhotoLab: the press reaches the engine", .serialized)
@MainActor
struct OpenKeepersPressTests {

    /// The engine: `/api/open` is recorded and answered as `answer` says;
    /// anything else is the light shoot, so the page can count its exports.
    final class Engine: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var _opened: [[String: String]] = []
        nonisolated(unsafe) static var answer: [String: Any] = ["ok": true, "folder": "/shoot/edit",
                                                                "app": "DXOPhotoLab10.app"]

        static var opened: [[String: String]] { lock.lock(); defer { lock.unlock() }; return _opened }
        static func reset(answer a: [String: Any]) {
            lock.lock(); _opened = []; answer = a; lock.unlock()
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var body = Data("{\"error\": \"not a route this test answers\"}".utf8)
            var status = 404
            if request.url?.path == "/api/open", request.httpMethod == "POST" {
                let sent = (request.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                            as? [String: Any]) ?? [:]
                Self.lock.lock()
                Self._opened.append(sent.compactMapValues { $0 as? String })
                let a = Self.answer
                Self.lock.unlock()
                body = (try? JSONSerialization.data(withJSONObject: a)) ?? Data()
                status = 200
            } else if request.url?.path == "/api/shoot", let light = try? Fixture.data("shoot-light") {
                body = light
                status = 200
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["content-type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    static let shoot = "2026-09-13-dog"

    /// Says it is key without ever being ordered in, so Return reaches the
    /// page's default button as it does in his window.
    final class OffscreenKeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    @MainActor
    struct Page {
        let app: AppModel
        let window: NSWindow
        let model: StepsModel
        let rememberedFrames: Bool

        func close() {
            window.contentView = nil
            window.close()
            WindowFrameMemory.remembers = rememberedFrames
            StepsModelStore.shared.reset()
            StepSlots.reset()
            TitleBarStrip.eventBeingRouted = { NSApp.currentEvent?.type }
        }
    }

    func spin(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// The app's window, on the Edit or the Presets page of a shoot whose
    /// presets are written: either page's primary is Open My Keepers in
    /// PhotoLab.
    func open(_ step: String = "edit", presetsWritten: Bool = true,
              answer: [String: Any] = ["ok": true, "folder": "/shoot/edit", "app": "DXOPhotoLab10.app"]) async throws -> Page {
        _ = NSApplication.shared
        Engine.reset(answer: answer)
        StepsModelStore.shared.reset()
        PagePresses.shared.reset()
        StepJobs.reset()
        WorkflowSteps.register()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Engine.self]
        let endpoint = EngineHost.Endpoint(base: URL(string: "http://127.0.0.1:9/")!, key: "k")
        let c = StudioClient(endpoint: endpoint, session: URLSession(configuration: config))
        let library = Library(preview: try LastPlaceTests.shoots(), client: c, pump: ImagePump(client: c))
        var response = try #require(JSONSerialization.jsonObject(with: Fixture.data("shoot-bursts")) as? [String: Any])
        if !presetsWritten {
            var info = try #require(response["info"] as? [String: Any])
            info["presets"] = 0
            info["sidecars"] = 0
            response["info"] = info
        }
        let decoded = try JSONDecoder().decode(ShootResponse.self, from: JSONSerialization.data(withJSONObject: response))
        let session = ShootSession(response: decoded, ext: nil, client: c, pump: ImagePump(client: c))
        library.adopt(session)
        let app = AppModel(preview: library, state: .running(endpoint),
                           navigation: Navigation(selection: .step(shoot: Self.shoot, step: step)))
        StepJobs.shared = { app.jobs }
        StepSlots.showStep = { shoot, step in app.navigation.selection = .step(shoot: shoot, step: step) }

        let remembered = WindowFrameMemory.remembers
        WindowFrameMemory.remembers = false
        // His window, as SwiftUI makes it: full-size content under a
        // transparent title bar, and a hosting view as the content view.
        let w = OffscreenKeyWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 1512, height: 945),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.toolbarStyle = .unified
        let hosting = NSHostingView(rootView: RootView(app: app))
        hosting.sizingOptions = []
        w.contentView = hosting
        for _ in 0..<20 {
            await spin(0.05)
            hosting.layoutSubtreeIfNeeded()
        }
        // What AppKit sends the window once per pass of the event loop, which
        // is when the strip puts itself back in front.
        w.update()
        let model = StepsModelStore.shared.model(for: session, jobs: app.jobs)
        return Page(app: app, window: w, model: model, rememberedFrames: remembered)
    }

    /// Where AppKit would deliver a left mouse down at `p`, a point in the
    /// window's own space - the content view's superview's.
    func pressLandsOn(_ p: NSPoint, in page: Page) -> NSView? {
        TitleBarStrip.eventBeingRouted = { .leftMouseDown }
        defer { TitleBarStrip.eventBeingRouted = { NSApp.currentEvent?.type } }
        return page.window.contentView?.hitTest(p)
    }

    func returnKey(_ w: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, characters: "\r",
                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    @Test("a click on the main button of Edit or Presets is the page's, not the title bar strip's",
          arguments: ["edit", "presets"])
    func theClickReachesThePage(_ step: String) async throws {
        let page = try await open(step)
        defer { page.close() }
        let w = page.window
        let content = try #require(w.contentView)
        #expect(content.isFlipped, "the test did not reproduce his window")
        #expect(content.subviews.last is TitleBarStrip, "the strip is in front, as it is after every pass")
        #expect(page.app.navigation.selection == .step(shoot: Self.shoot, step: step))

        // The action bar's box: bottom right of the page's column, its middle
        // `barVerticalPadding + height / 2` above the foot of the window. The
        // whole foot of the window is swept, so no button in any step's bar
        // can be under the strip.
        let y = StepMetric.barVerticalPadding + StepMetric.primaryBox.height / 2
        for x in stride(from: CGFloat(8), to: w.frame.width, by: 24) {
            let hit = pressLandsOn(NSPoint(x: x, y: y), in: page)
            #expect(!(hit is TitleBarStrip), "a click at the foot of the window, x \(x), went to the title bar strip")
        }
        // And the strip is still where it belongs: over the empty title bar.
        let band = w.frame.height - w.contentLayoutRect.maxY
        #expect(band > 0)
        #expect(pressLandsOn(NSPoint(x: w.frame.width / 2, y: w.frame.height - band / 2), in: page) is TitleBarStrip)
    }

    @Test("pressing Open My Keepers in PhotoLab on Edit or Presets asks the engine to open them and says it did on Edit",
          arguments: ["edit", "presets"])
    func thePressOpensTheKeepers(_ step: String) async throws {
        let page = try await open(step)
        defer { page.close() }
        #expect(Engine.opened.isEmpty)
        // The button's own action, by the key that presses it; the click above
        // now reaches the same button.
        #expect(page.window.performKeyEquivalent(with: try returnKey(page.window)))
        for _ in 0..<100 where page.model.openedAt == nil && page.model.openRefusal == nil { await spin(0.05) }
        #expect(Engine.opened == [["name": Self.shoot, "what": "photolab", "editor": "dxo"]])
        #expect(page.model.openedAt != nil, "the page says the editor was asked to open")
        #expect(page.model.openRefusal == nil)
        // Presets goes to Edit, where the opening and the exports are said.
        #expect(page.app.navigation.selection == .step(shoot: Self.shoot, step: "edit"))
    }

    /// Shoot ▸ Open My Keepers in PhotoLab (⇧⌘E) never passed through the
    /// strip, and still reaches the engine from the page itself and from a
    /// page of the shoot that is not Edit: the row goes there, and the page
    /// presses its own button.
    @Test("Shoot ▸ Open My Keepers in PhotoLab reaches the engine from Edit and from elsewhere in the shoot",
          arguments: ["edit", "overview"])
    func theMenuRowOpensTheKeepers(_ from: String) async throws {
        let page = try await open("edit")
        defer { page.close() }
        if from == "overview" {
            page.app.navigation.selection = .shoot(Self.shoot)
            await spin(0.3)
        }
        let host = CommandHost(model: page.app, center: CommandCenter())
        host.registerEverything()
        #expect(host.center.canRun(CommandTable.ID.openInEditor))
        #expect(host.center.run(CommandTable.ID.openInEditor))
        for _ in 0..<100 where page.model.openedAt == nil && page.model.openRefusal == nil { await spin(0.05) }
        #expect(page.app.navigation.selection == .step(shoot: Self.shoot, step: "edit"))
        #expect(Engine.opened == [["name": Self.shoot, "what": "photolab", "editor": "dxo"]])
        #expect(page.model.openedAt != nil)
        #expect(PagePresses.shared.pending == nil, "the page took the press")
    }

    @Test("the sidebar opens the right-clicked shoot without relying on the selected shoot or a global command")
    func sidebarOpensItsOwnShoot() async throws {
        let page = try await open("edit")
        defer { page.close() }
        page.app.navigation.selection = .shoot("2026-09-21")
        let row = try #require(page.app.library.row(named: Self.shoot))
        let menu = ShootContextMenu(app: page.app, row: row)
        #expect(ShootContextMenu.canOpenInEditor(row))
        menu.openInEditor()
        #expect(PagePresses.shared.pending?.shoot == Self.shoot)
        #expect(page.app.navigation.selection == .step(shoot: Self.shoot, step: "edit"))
        for _ in 0..<100 where page.model.openedAt == nil && page.model.openRefusal == nil { await spin(0.05) }
        #expect(Engine.opened == [["name": Self.shoot, "what": "photolab", "editor": "dxo"]])
        #expect(page.model.openedAt != nil)
        #expect(PagePresses.shared.pending == nil)
    }

    @Test("a sidebar press whose presets have changed says why it cannot open")
    func sidebarWithStalePresets() async throws {
        let page = try await open("edit", presetsWritten: false)
        defer { page.close() }
        // The library row still has presets; the freshly read page does not.
        let row = try #require(page.app.library.row(named: Self.shoot))
        #expect(ShootContextMenu.canOpenInEditor(row))
        ShootContextMenu(app: page.app, row: row).openInEditor()
        for _ in 0..<100 where page.model.openRefusal == nil { await spin(0.05) }
        #expect(page.model.openRefusal == Strings.Edit.presetsNotWritten("PhotoLab"))
        #expect(page.model.openedAt == nil)
        #expect(Engine.opened.isEmpty)
        #expect(PagePresses.shared.pending == nil)
    }

    @Test("leaving after a sidebar press never opens the newly selected shoot")
    func sidebarDoesNotFollowAChangedSelection() async throws {
        let page = try await open("edit")
        defer { page.close() }
        let row = try #require(page.app.library.row(named: Self.shoot))
        ShootContextMenu(app: page.app, row: row).openInEditor()
        page.app.navigation.selection = .shoot("2026-09-21")
        PagePresses.shared.forget(unlessOn: page.app.navigation.selection)
        for _ in 0..<10 { await spin(0.05) }
        #expect(Engine.opened.isEmpty)
        #expect(PagePresses.shared.pending == nil)
    }

    @Test("a sidebar row without presets cannot navigate or enqueue an open")
    func sidebarWithoutPresets() async throws {
        let page = try await open("edit")
        defer { page.close() }
        let row = try ShootContextMenuTests.row(culled: true, keepers: 12, presets: 0)
        let selection = page.app.navigation.selection
        ShootContextMenu(app: page.app, row: row).openInEditor()
        #expect(page.app.navigation.selection == selection)
        #expect(PagePresses.shared.pending == nil)
        #expect(Engine.opened.isEmpty)
    }

    @Test("when the editor refuses or times out the page says so and allows another try", arguments: [
        "PhotoLab did not open: The application cannot be opened for an unexpected reason.",
        "PhotoLab did not open: macOS did not confirm opening within 10 seconds; check the editor before trying again"
    ])
    func aFailedOpenIsALine(_ said: String) async throws {
        let page = try await open(answer: ["ok": false, "error": said])
        defer { page.close() }
        #expect(page.window.performKeyEquivalent(with: try returnKey(page.window)))
        for _ in 0..<100 where page.model.openRefusal == nil { await spin(0.05) }
        #expect(Engine.opened.count == 1)
        #expect(page.model.openRefusal == said)
        #expect(page.model.openedAt == nil, "it never says it opened")
        for _ in 0..<40 where page.model.buildingEditFolder { await spin(0.05) }
        #expect(!page.model.buildingEditFolder, "the button comes back for another try")
    }

    @Test("a partial open keeps the engine note for the Edit page instead of generic success",
          arguments: ["edit", "presets"])
    func partialOpenKeepsTheNote(_ step: String) async throws {
        let note = "Opened 1 of 27 keepers in PhotoLab. 26 originals were not found: "
            + "FRAME001.jpg, FRAME002.jpg, FRAME003.jpg and 23 more."
        let page = try await open(step, answer: [
            "ok": true, "folder": "/shoot/edit", "app": "PhotoLab.app", "note": note,
            "gather": ["total": 27, "gathered": 1, "missing": 26,
                       "missing_files": ["FRAME001.jpg"]]
        ])
        defer { page.close() }
        #expect(page.window.performKeyEquivalent(with: try returnKey(page.window)))
        for _ in 0..<100 where page.model.openNote == nil && page.model.openRefusal == nil {
            await spin(0.05)
        }
        #expect(page.model.openNote == note)
        #expect(page.model.openRefusal == nil)
        #expect(page.model.openedAt != nil)
        #expect(page.app.navigation.selection == .step(shoot: Self.shoot, step: "edit"))
    }

}
