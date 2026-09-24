import AppKit
import Foundation
import Testing
import WebKit
@testable import PipelineKit

/// The host against a real extension server on its own port: what actually
/// travels, and what is actually refused.
@Suite("An extension page, loaded for real", .serialized)
@MainActor
struct ExtWebViewTests {

    @Test("the page and every subresource carry the key, and without it the server refuses")
    func theKeyReachesEverything() async throws {
        let server = try StubExtensionServer(key: "a-test-key")
        try await server.start()
        defer { server.stop() }

        // A forged request — anything else on this Mac — gets nothing.
        let forged = URLRequest(url: server.base.appendingPathComponent("two"))
        let (body, response) = try await URLSession.studio.data(for: forged)
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
        #expect(String(decoding: body, as: UTF8.self) == "no key")
        #expect(server.hits(forPath: "/two").first?.key == nil)

        let (view, coordinator) = host(server, page: "one")
        defer { ExtensionHost.close(view, coordinator: coordinator) }
        try await settle(view)

        // The page drew, which it cannot have done without its stylesheet,
        // its script and its picture — each of which is a separate load that
        // could not have carried a header of its own.
        #expect(try await string(view, "return document.getElementById('title').textContent;") == "One")
        #expect(try await bool(view, "return window.stubRan === true;"))

        for path in ["/one", "/look.css", "/page.js", "/deeper/picture.svg"] {
            let hits = server.hits(forPath: path)
            #expect(!hits.isEmpty, "nothing asked for \(path)")
            #expect(hits.allSatisfy { $0.key == server.key }, "\(path) went without the key")
        }
        // The key is in the request and nowhere the page can see it.
        #expect(try await bool(view, """
        return document.documentElement.outerHTML.indexOf('a-test-key') === -1
            && !('key' in window) && typeof window.XStudioKey === 'undefined';
        """))
    }

    @Test("the injected look is on the page, and follows the app into Dark Mode while it is open")
    func theLookFollowsTheApp() async throws {
        let server = try StubExtensionServer()
        try await server.start()
        defer { server.stop() }

        let (view, coordinator) = host(server, page: "one")
        defer { ExtensionHost.close(view, coordinator: coordinator) }
        view.appearance = NSAppearance(named: .aqua)
        try await settle(view)

        func variable(_ name: String) async throws -> String {
            try await string(view, """
            return getComputedStyle(document.documentElement).getPropertyValue('\(name)').trim();
            """)
        }
        let lightText = try await variable("--pp-text")
        #expect(!lightText.isEmpty)
        #expect(try await variable("--pp-appearance") == "light")
        #expect(try await variable("--pp-font") != "")
        // The page's own rule reads the host's variable, so its heading takes
        // the app's text colour rather than a colour of its own.
        let titleColour = try await string(view, """
        return getComputedStyle(document.getElementById('title')).color;
        """)
        #expect(!titleColour.isEmpty)

        view.appearance = NSAppearance(named: .darkAqua)
        try await waitUntilJS(view, "return document.documentElement.dataset.appearance === 'dark';")
        #expect(try await variable("--pp-appearance") == "dark")
        #expect(try await variable("--pp-text") != lightText)
    }

    @Test("the three bridges answer the page")
    func theBridgesAnswer() async throws {
        let server = try StubExtensionServer()
        try await server.start()
        defer { server.stop() }

        let model = ExtStepModel(state: ExtStateStore(defaults: scratchDefaults()))
        let (view, coordinator) = host(server, page: "one", bridge: model.bridge)
        defer { ExtensionHost.close(view, coordinator: coordinator) }
        try await settle(view)

        // state: what a page keeps comes back to it.
        _ = try await run(view, "await window.pipeline.state.set('sort', 'by time'); return true;")
        #expect(try await string(view, "return await window.pipeline.state.get('sort');") == "by time")
        _ = try await run(view, "await window.pipeline.state.remove('sort'); return true;")
        #expect(try await bool(view, "return (await window.pipeline.state.get('sort')) === null;"))

        // viewFrames: the app's own viewer opens on the frames it named, with
        // the marks the page offers, and answers when he closes it with
        // where he stopped and what he marked.
        _ = try await run(view, """
        window.looked = null;
        window.pipeline.viewFrames(['TSC04313', 'TSC04314'], 1, {
            actions: [{id: 'yes', label: 'Yes', key: 'y'}, {label: 'no id'}],
            marks: {TSC04313: 'yes', ELSEWHERE: 'yes'}
        }).then(function (r) { window.looked = r; });
        return true;
        """)
        try await waitUntil { model.viewing != nil }
        let look = try #require(model.viewing)
        #expect(look.stems == ["TSC04313", "TSC04314"])
        #expect(look.startAt == 1)
        #expect(look.actions.map(\.id) == ["yes"] && look.actions.first?.key == "y")
        #expect(look.marks == ["TSC04313": "yes"])
        #expect(try await bool(view, "return window.looked === null;"))      // still open
        model.lookEnded(look.id, ExtViewerResult(index: 0, stem: "TSC04313", marks: ["TSC04314": "yes"]))
        try await waitUntilJS(view, "return window.looked !== null;")
        #expect(try await string(view, "return window.looked.stem;") == "TSC04313")
        #expect(try await bool(view, "return window.looked.index === 0 && window.looked.marks.TSC04314 === 'yes';"))
        #expect(model.viewing == nil)

        // confirmDestructive: a promise that resolves with what he said.
        let asked = Task { @MainActor () -> Bool in
            (try? await self.bool(view, """
            return await window.pipeline.confirmDestructive(
                'Let go of it?', 'It cannot be undone.', 'Let Go');
            """)) ?? false
        }
        try await waitUntil { model.question != nil }
        #expect(model.question?.title == "Let go of it?")
        #expect(model.question?.confirmLabel == "Let Go")
        model.answer(true)
        #expect(await asked.value == true)

        // The page cannot replace the bridge with one of its own.
        #expect(try await string(view, """
        try { window.pipeline = {}; } catch (e) {}
        return typeof window.pipeline.state.get;
        """) == "function")
    }

    @Test("a page's own alert asks for nothing, and its confirm is the app's sheet and not the dangerous one")
    func theDialogsAreTheApps() async throws {
        let server = try StubExtensionServer()
        try await server.start()
        defer { server.stop() }

        let model = ExtStepModel(state: ExtStateStore(defaults: scratchDefaults()))
        let (view, coordinator) = host(server, page: "one", bridge: model.bridge)
        defer { ExtensionHost.close(view, coordinator: coordinator) }
        try await settle(view)

        // `alert()` comes back at once: the line after it runs without
        // anyone pressing anything, and what it said is under the page.
        _ = try await view.evaluateJavaScript(
            "window.__after = false; alert('Six photographs are ready.'); window.__after = true;")
        try await waitUntilJS(view, "return window.__after === true;")
        #expect(model.said == "Six photographs are ready.")
        #expect(model.question == nil)

        // `confirm()` comes back with what he actually said, and it is an
        // ordinary question on the way there.
        let answered = Task { @MainActor () -> Bool in
            (try? await self.bool(view, "return confirm('Start again from the first burst?');")) ?? false
        }
        try await waitUntil(.seconds(10)) { model.question != nil }
        #expect(model.question?.kind == .choice)
        #expect(model.question?.title == "Start again from the first burst?")
        model.answer(true)
        #expect(await answered.value == true)

        // Nothing a page can say to itself reaches the destructive sheet.
        let refused = Task { @MainActor () -> Bool in
            (try? await self.bool(view, "return confirm('Delete everything?');")) ?? true
        }
        try await waitUntil(.seconds(10)) { model.question != nil }
        #expect(model.question?.kind != .destructive)
        model.answer(false)
        #expect(await refused.value == false)
    }

    @Test("a page cannot leave the origin it was served from, and cannot open one in an iframe")
    func nothingLeavesTheOrigin() async throws {
        let server = try StubExtensionServer()
        try await server.start()
        defer { server.stop() }

        let refused = Refusals()
        let (view, coordinator) = host(server, page: "one", onRefusal: { refused.add($0) })
        defer { ExtensionHost.close(view, coordinator: coordinator) }
        try await settle(view)

        _ = try await run(view, "location.href = 'https://example.invalid/'; return true;")
        try await waitUntil { refused.wentOutside }
        // It did not go: the page is still the one that was served.
        #expect(try await string(view, "return document.getElementById('title').textContent;") == "One")

        // No page is ever loaded in an iframe — not even one of its own.
        refused.clear()
        _ = try await run(view, """
        var f = document.createElement('iframe');
        f.src = 'pipeline-ext://page/two';
        document.body.appendChild(f);
        return true;
        """)
        try await waitUntil { refused.notServed }
        #expect(server.hits(forPath: "/two").isEmpty)
    }

    @Test("a link he clicks to the web opens in his browser, and a script still cannot leave on its own")
    func hisLinksOpenInHisBrowser() async throws {
        let server = try StubExtensionServer()
        try await server.start()
        defer { server.stop() }

        let refused = Refusals()
        let opened = Opened()
        let (view, coordinator) = host(server, page: "one", onRefusal: { refused.add($0) },
                                       openOutside: { opened.add($0) })
        defer { ExtensionHost.close(view, coordinator: coordinator) }
        try await settle(view)
        func follow(_ href: String, blank: Bool = false) async throws {
            _ = try await run(view, """
            var a = document.createElement('a');
            a.href = '\(href)'; \(blank ? "a.target = '_blank';" : "")
            document.body.appendChild(a); a.click(); return true;
            """)
        }

        // Followed by the page with no press of his: refused, as before.
        try await follow("https://example.invalid/post")
        try await waitUntil { refused.wentOutside }
        #expect(opened.all.isEmpty)

        // His click on it: his browser, the link's own address and nothing
        // else, and the page stays where it was with no red line.
        refused.clear()
        view.notePress()
        try await follow("https://example.invalid/post?id=7")
        try await waitUntil { !opened.all.isEmpty }
        #expect(opened.all == [URL(string: "https://example.invalid/post?id=7")!])
        #expect(!refused.wentOutside)
        #expect(try await string(view, "return document.getElementById('title').textContent;") == "One")

        // A link that opens a window of its own goes the same way.
        view.notePress()
        try await follow("https://example.invalid/profile", blank: true)
        try await waitUntil { opened.all.count == 2 }
        #expect(opened.all.last == URL(string: "https://example.invalid/profile")!)

        // A script moving the page is not a link he clicked, press or not.
        view.notePress()
        _ = try await run(view, "location.href = 'https://example.invalid/elsewhere'; return true;")
        try await waitUntil { refused.wentOutside }
        #expect(opened.all.count == 2)
    }

    @Test("a space typed in the page's field is not his press on a link, and a press is his for a second")
    func typingIsNotAPress() async throws {
        let server = try StubExtensionServer()
        try await server.start()
        defer { server.stop() }

        let refused = Refusals()
        let opened = Opened()
        let (view, coordinator) = host(server, page: "one", onRefusal: { refused.add($0) },
                                       openOutside: { opened.add($0) })
        defer { ExtensionHost.close(view, coordinator: coordinator) }
        try await settle(view)
        func follow(_ href: String) async throws {
            _ = try await run(view, "var a = document.createElement('a'); a.href = '\(href)'; "
                                  + "document.body.appendChild(a); a.click(); return true;")
        }
        func key(_ code: UInt16, _ characters: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false,
                                          keyCode: code))
        }

        // In a caption: a space, and then the page's own a.click().
        view.isTyping = true
        view.keyDown(with: try key(49, " "))
        view.keyDown(with: try key(36, "\r"))
        try await follow("https://example.invalid/typed")
        try await waitUntil { refused.wentOutside }
        #expect(opened.all.isEmpty, "a space in a field let a script open his browser")

        // On the link itself, not typing: his.
        refused.clear()
        view.isTyping = false
        view.keyDown(with: try key(49, " "))
        try await follow("https://example.invalid/pressed")
        try await waitUntil { !opened.all.isEmpty }
        #expect(opened.all == [URL(string: "https://example.invalid/pressed")!])

        // A second after his press, a link the page follows is the page's.
        view.notePress()
        try await Task.sleep(for: .seconds(ExtWebView.pressCounts + 0.2))
        try await follow("https://example.invalid/later")
        try await waitUntil { refused.wentOutside }
        #expect(opened.all.count == 1)
    }

    @Test("what counts as a link to his browser: his, to the web, and not to this Mac")
    func whatGoesToHisBrowser() {
        let web = URL(string: "https://www.instagram.com/p/abc/")!
        #expect(ExtensionHost.goesToHisBrowser(web, type: .linkActivated, byHisHand: true))
        #expect(!ExtensionHost.goesToHisBrowser(web, type: .linkActivated, byHisHand: false))
        #expect(!ExtensionHost.goesToHisBrowser(web, type: .other, byHisHand: true))
        #expect(!ExtensionHost.goesToHisBrowser(web, type: .formSubmitted, byHisHand: true))
        for local in ["http://127.0.0.1:9931/pages/grid", "http://localhost:9931/x", "http://[::1]:9931/x",
                      "file:///Users/someone/photos", "mailto:someone@example.invalid", "pipeline-ext://page/two",
                      // The rest of this Mac: all of loopback, the any-address,
                      // IPv4 written as IPv6, a trailing dot, and .local names.
                      "http://127.0.0.2:9931/x", "http://127.255.255.254/x", "http://0.0.0.0:9931/x",
                      "http://[::]:9931/x", "http://[::ffff:127.0.0.1]:9931/x", "http://localhost.:9931/x",
                      "http://LOCALHOST/x", "http://a.localhost/x", "http://Someones-MacBook.local:9931/x"] {
            #expect(!ExtensionHost.goesToHisBrowser(URL(string: local)!, type: .linkActivated, byHisHand: true), "\(local)")
        }
        // An address that merely starts like one of them is the web.
        for web in ["https://127.example.invalid/x", "https://localhost.example.invalid/x",
                    "https://10.0.0.127/x", "https://local.example.invalid/x"] {
            #expect(ExtensionHost.goesToHisBrowser(URL(string: web)!, type: .linkActivated, byHisHand: true), "\(web)")
        }
    }

    @Test("the context menu is the app's, and every item on it has a key")
    func theMenuIsTheApps() async throws {
        let server = try StubExtensionServer()
        try await server.start()
        defer { server.stop() }

        let (view, coordinator) = host(server, page: "one")
        defer { ExtensionHost.close(view, coordinator: coordinator) }
        try await settle(view)

        // WebKit's own items are in this menu before the host has its say.
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Services", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Inspect Element", action: nil, keyEquivalent: ""))
        view.willOpenMenu(menu, with: NSEvent())

        let items = menu.items.filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == [Strings.Extensions.copy, Strings.Extensions.selectAll,
                                       Strings.Extensions.reload])
        #expect(items.allSatisfy { !$0.keyEquivalent.isEmpty })
        #expect(!items.contains { $0.title == "Inspect Element" })
        // Off unless Settings ▸ Advanced turns it on.
        #expect(view.isInspectable == false)

        // In a field, WebKit's guesses, Cut and Paste stay; the rest still go.
        // The menu as WebKit builds it for a misspelt word it has selected:
        // it names Copy, Paste, Look Up and its submenus, and names neither
        // Cut nor a guess nor Ignore and Learn Spelling (the full list of its
        // names has no Cut and no guess).
        func named(_ title: String, _ id: String, submenu: Bool = false) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.identifier = NSUserInterfaceItemIdentifier(id)
            if submenu { i.submenu = NSMenu(title: title) }
            return i
        }
        func unnamed(_ title: String) -> NSMenuItem { NSMenuItem(title: title, action: nil, keyEquivalent: "") }
        let misspelt: [NSMenuItem] = [
            unnamed("colour"), unnamed("color"), .separator(),
            unnamed("Ignore Spelling"), unnamed("Learn Spelling"), .separator(),
            named("Look Up “colr”", "WKMenuItemIdentifierLookUp"),
            named("Search with Google", "WKMenuItemIdentifierSearchWeb"), .separator(),
            unnamed("Cut"), named("Copy", "WKMenuItemIdentifierCopy"), named("Paste", "WKMenuItemIdentifierPaste"),
            .separator(),
            named("Spelling and Grammar", "WKMenuItemIdentifierSpellingMenu", submenu: true),
            named("Substitutions", "WKMenuItemIdentifierSubstitutionsMenu", submenu: true),
            unnamed("Transformations"),
            named("Speech", "WKMenuItemIdentifierSpeechMenu", submenu: true),
            named("Inspect Element", "WKMenuItemIdentifierInspectElement"),
        ]
        let field = NSMenu()
        misspelt.forEach(field.addItem)
        view.willOpenMenu(field, with: NSEvent())
        #expect(field.items.filter { !$0.isSeparatorItem }.map(\.title)
                == ["colour", "color", "Ignore Spelling", "Learn Spelling", "Cut", Strings.Extensions.copy, "Paste",
                    Strings.Extensions.selectAll, Strings.Extensions.reload])
        #expect(field.items.first { $0.title == "Cut" }?.keyEquivalent == "x")
        #expect(field.items.first { $0.title == "Paste" }?.keyEquivalent == "v")

        // A word spelt right: Cut, Copy and Paste open the menu, and nothing
        // of theirs is taken for a guess or kept twice.
        let spelt = NSMenu()
        for i in [unnamed("Cut"), named("Copy", "WKMenuItemIdentifierCopy"), named("Paste", "WKMenuItemIdentifierPaste"),
                  .separator(), named("Spelling and Grammar", "WKMenuItemIdentifierSpellingMenu", submenu: true)] {
            spelt.addItem(i)
        }
        view.willOpenMenu(spelt, with: NSEvent())
        #expect(spelt.items.filter { !$0.isSeparatorItem }.map(\.title)
                == ["Cut", Strings.Extensions.copy, "Paste", Strings.Extensions.selectAll, Strings.Extensions.reload])

        // Outside a field WebKit offers no Paste, and none of its items stay,
        // named or not.
        let text = NSMenu()
        for i in [unnamed("Something unnamed"), .separator(), named("Copy", "WKMenuItemIdentifierCopy"),
                  named("Look Up", "WKMenuItemIdentifierLookUp")] {
            text.addItem(i)
        }
        view.willOpenMenu(text, with: NSEvent())
        #expect(text.items.filter { !$0.isSeparatorItem }.map(\.title)
                == [Strings.Extensions.copy, Strings.Extensions.selectAll, Strings.Extensions.reload])
    }

    @Test("⌘R is Shoot ▸ Cull's, never the page's; the page reloads on ⇧⌘R, and only while it has the keyboard")
    func reloadIsNotCull() throws {
        func key(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: 0, context: nil, characters: "r",
                                          charactersIgnoringModifiers: flags.contains(.shift) ? "R" : "r",
                                          isARepeat: false, keyCode: 15))
        }
        #expect(!ExtWebView.isReload(try key(.command)))
        #expect(ExtWebView.isReload(try key([.command, .shift])))
        #expect(!ExtWebView.isReload(try key([.command, .shift, .option])))
        // Not first responder anywhere: the key goes on to the menu.
        let view = ExtWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var reloaded = false
        view.onReload = { reloaded = true }
        _ = view.performKeyEquivalent(with: try key([.command, .shift]))
        #expect(!reloaded)
    }

    @Test("the page has the keyboard once it has loaded, unless he is typing in a field")
    func thePageTakesTheKeyboard() async throws {
        let server = try StubExtensionServer()
        try await server.start()
        defer { server.stop() }

        // A window that is never put on screen.
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        defer { w.close() }
        let other = NSButton(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        w.contentView?.addSubview(other)
        w.makeFirstResponder(other)

        let (view, coordinator) = host(server, page: "one")
        defer { ExtensionHost.close(view, coordinator: coordinator) }
        w.contentView?.addSubview(view)
        try await settle(view)
        try await waitUntil { w.firstResponder === view || (w.firstResponder as? NSView)?.isDescendant(of: view) == true }

        // A field he is typing in keeps it.
        let field = NSTextField(frame: NSRect(x: 0, y: 20, width: 100, height: 20))
        w.contentView?.addSubview(field)
        w.makeFirstResponder(field)
        #expect(MenuValidation.isTextEditing(in: w))
        view.takeKeyboard()
        #expect(MenuValidation.isTextEditing(in: w))
    }

    @Test("a field on the page is a field to the menu's bare-letter keys, and a button on it is not")
    func aFieldOnThePageIsAField() async throws {
        let server = try StubExtensionServer()
        try await server.start()
        defer { server.stop() }

        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        defer { w.close() }
        let (view, coordinator) = host(server, page: "one")
        defer { ExtensionHost.close(view, coordinator: coordinator) }
        w.contentView?.addSubview(view)
        try await settle(view)
        w.makeFirstResponder(view)
        #expect(!MenuValidation.isTextEditing(in: w))

        // The events the page sees when he clicks into a caption and out to
        // a button. Sent by hand: a window never on screen gives the page no
        // focus of its own to move.
        _ = try await run(view, """
        var f = document.createElement('textarea'); f.id = 'caption';
        var b = document.createElement('button'); b.id = 'send';
        document.body.appendChild(f); document.body.appendChild(b);
        f.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
        return true;
        """)
        try await waitUntil { view.isTyping }
        #expect(MenuValidation.isTextEditing(in: w))
        #expect(!MenuValidation.allows(Shortcut(Character("h")), textEditing: MenuValidation.isTextEditing(in: w)))

        _ = try await run(view, """
        var f = document.getElementById('caption'), b = document.getElementById('send');
        f.dispatchEvent(new FocusEvent('focusout', { bubbles: true, relatedTarget: b }));
        b.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
        return true;
        """)
        try await waitUntil { !view.isTyping }
        #expect(!MenuValidation.isTextEditing(in: w))

        // Back into the field, then the page loads again: the field went with it.
        _ = try await run(view, """
        document.getElementById('caption').dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
        return true;
        """)
        try await waitUntil { view.isTyping }
        view.reload()
        try await waitUntil { !view.isTyping }
    }

    @Test("the page comes back where he left it, once it is tall enough, and says where he scrolls to")
    func thePageComesBackWhereHeWas() async throws {
        let server = try StubExtensionServer()
        try await server.start()
        defer { server.stop() }

        let noted = Scrolls()
        let bridge = ExtBridge(delegate: noted)
        let host = ExtensionHost(page: server.base.appendingPathComponent("tall"),
                                 upstream: ExtHTTPUpstream(key: server.key), bridge: bridge,
                                 label: "A Step", scrolledTo: CGPoint(x: 0, y: 1200))
        let (view, coordinator) = host.hosted()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        defer { ExtensionHost.close(view, coordinator: coordinator) }
        try await settle(view)
        try await waitUntilJS(view, "return window.scrollY === 1200;")

        _ = try await run(view, "window.scrollTo(0, 700); return true;")
        try await waitUntil { noted.last?.y == 700 }
    }

    @Test("a picture its server says will not change is fetched once a visit and not again the next")
    func picturesAreKept() async throws {
        let server = try StubExtensionServer()
        try await server.start()
        defer { server.stop() }
        let up = ExtHTTPUpstream(key: server.key)
        for path in ["cached.svg", "cached.svg", "deeper/picture.svg", "deeper/picture.svg"] {
            let r = try await up.load(ExtRequest(url: server.base.appendingPathComponent(path), method: "GET"))
            #expect(r.status == 200)
        }
        #expect(server.hits(forPath: "/cached.svg").count == 1)
        // One it says nothing about is asked for each time, as before.
        #expect(server.hits(forPath: "/deeper/picture.svg").count == 2)
    }

    // MARK: -

    private func host(_ server: StubExtensionServer, page: String,
                      bridge: ExtBridge? = nil,
                      onRefusal: @escaping @MainActor (ExtHostError) -> Void = { _ in },
                      openOutside: @escaping @MainActor (URL) -> Void = { _ in })
        -> (ExtWebView, ExtensionHost.Coordinator) {
        let host = ExtensionHost(page: server.base.appendingPathComponent(page),
                                 upstream: ExtHTTPUpstream(key: server.key),
                                 bridge: bridge ?? ExtBridge(),
                                 label: "A Step",
                                 inspectable: false,
                                 onRefusal: onRefusal,
                                 openOutside: openOutside)
        let hosted = host.hosted()
        hosted.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return (hosted.view, hosted.coordinator)
    }

    private func settle(_ view: WKWebView) async throws {
        try await waitUntil(.seconds(20)) { !view.isLoading && view.url != nil }
        try await waitUntilJS(view, "return document.readyState === 'complete' && !!window.pipeline;")
    }

    /// `await` works here and the result is a real value, which
    /// `evaluateJavaScript` cannot give for a promise.
    @discardableResult
    private func run(_ view: WKWebView, _ body: String) async throws -> Any? {
        try await view.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    private func string(_ view: WKWebView, _ body: String) async throws -> String {
        (try await run(view, body)) as? String ?? ""
    }

    private func bool(_ view: WKWebView, _ body: String) async throws -> Bool {
        ((try await run(view, body)) as? NSNumber)?.boolValue ?? false
    }

    private func waitUntilJS(_ view: WKWebView, _ body: String,
                             timeout: Duration = .seconds(10)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(try await bool(view, body)) {
            if clock.now > deadline { throw WaitedTooLong() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// What the pane was told, from a callback that is not a test's own local.
@MainActor
final class Refusals {
    private(set) var all: [ExtHostError] = []
    func add(_ e: ExtHostError) { all.append(e) }
    func clear() { all.removeAll() }
    var wentOutside: Bool { all.contains { if case .wentOutside = $0 { return true } else { return false } } }
    var notServed: Bool { all.contains { if case .notServed = $0 { return true } else { return false } } }
}

/// What went to his browser.
@MainActor
final class Opened {
    private(set) var all: [URL] = []
    func add(_ u: URL) { all.append(u) }
}

/// Where a page said it was scrolled to.
@MainActor
final class Scrolls: ExtBridgeDelegate {
    private(set) var last: CGPoint?
    func scrolled(x: Double, y: Double) { last = CGPoint(x: x, y: y) }
    func viewFrames(_ stems: [String], startAt: Int, actions: [ExtViewerAction],
                    marks: [String: String]) async -> ExtViewerResult {
        ExtViewerResult(index: startAt, stem: stems[startAt], marks: marks)
    }
    func confirmDestructive(title: String, body: String, confirmLabel: String) async -> Bool { false }
    func state(get key: String) -> String? { nil }
    func state(set key: String, _ value: String?) {}
}
