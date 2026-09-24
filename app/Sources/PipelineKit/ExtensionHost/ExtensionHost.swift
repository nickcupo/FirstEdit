import AppKit
import SwiftUI
import WebKit

/// An extension's whole page, filling the detail pane.
///
/// **No iframe anywhere** (DESIGN.md §2.16-1). The page is loaded over
/// `pipeline-ext://` through a scheme handler that adds `X-Studio-Key` to the
/// page and to every subresource it asks for — which an iframe or a plain URL
/// load cannot do, because a page loading its own picture cannot put a header
/// on that load. Nothing inside the page can read the key, and no other
/// process on the machine can reach these pages.
///
/// One `WKWebView` is kept on 15 and on 26 alike: the scheme handler, the
/// answering bridge and the app's own context menu all live on it, and a
/// second path would be a second set of behaviours to keep identical for no
/// visible gain.
public struct ExtensionHost: NSViewRepresentable {

    public let page: URL
    public let origin: URL
    public let upstream: any ExtUpstream
    public let bridge: ExtBridge
    public let inspectable: Bool
    /// The step's label, for VoiceOver — the extension's own word, read at
    /// runtime and never written down here.
    public let label: String
    /// Where the page was when he last left it, to be put back there once it
    /// has grown tall enough to be.
    public let scrolledTo: CGPoint?
    public let onRefusal: @MainActor (ExtHostError) -> Void
    /// Opens a link he clicked on the page in his own browser (§2.16).
    /// Replaced by tests.
    public let openOutside: @MainActor (URL) -> Void

    /// DESIGN.md §3.7, with the engine's address as well as its key: the host
    /// has to know where the extension's pages are before it can put the key
    /// on a request to them.
    public init(step: String, shoot: String, config: ExtConfig, key: String, engine: URL,
                bridge: ExtBridge, label: String = "",
                inspectable: Bool = SettingsStore.shared.webInspector,
                onRefusal: @escaping @MainActor (ExtHostError) -> Void = { _ in }) {
        let target = ExtPages.upstream(step: step, shoot: shoot, config: config, engine: engine) ?? engine
        self.init(page: target, upstream: ExtHTTPUpstream(key: key), bridge: bridge,
                  label: label.isEmpty ? (config.labels[step] ?? step) : label,
                  inspectable: inspectable, onRefusal: onRefusal)
    }

    /// The same host against pages that do not come off a socket — a rendered
    /// scene, a test. One protocol, two implementations, and nothing above it
    /// knows which it has.
    public init(page: URL, upstream: any ExtUpstream, bridge: ExtBridge, label: String = "",
                inspectable: Bool = false, scrolledTo: CGPoint? = nil,
                onRefusal: @escaping @MainActor (ExtHostError) -> Void = { _ in },
                openOutside: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.page = page
        self.origin = ExtPages.origin(of: page)
        self.upstream = upstream
        self.bridge = bridge
        self.label = label
        self.inspectable = inspectable
        self.scrolledTo = scrolledTo
        self.onRefusal = onRefusal
        self.openOutside = openOutside
    }

    /// Whether a navigation is a link he clicked to somewhere on the web,
    /// which his browser opens (§2.16): a link, activated within a moment of
    /// his own press on the page, to an `http` or `https` address that is not
    /// this Mac's. Everything else a page does to leave its origin is still
    /// refused — a script moving `location`, a window it opens by itself, an
    /// iframe — and a link to this Mac is an extension page that belongs in
    /// the app, where it has its key, not in a browser that has not.
    public static func goesToHisBrowser(_ url: URL, type: WKNavigationType, byHisHand: Bool) -> Bool {
        guard type == .linkActivated, byHisHand,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return !isThisMac(host)
    }

    /// An address that reaches this Mac, or the network it is on by name:
    /// `localhost` and anything under it, the loopback block (all of
    /// 127.0.0.0/8, not only 127.0.0.1), `0.0.0.0`, which reaches the Mac's
    /// own servers too, IPv6's own `::1` and `::`, the IPv4 ones written as
    /// IPv6, and a `.local` name — the Mac's own among them.
    static func isThisMac(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        if h.isEmpty || h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
        if h == "::1" || h == "::" || h == "0:0:0:0:0:0:0:1" || h == "0:0:0:0:0:0:0:0" { return true }
        if h.hasPrefix("::ffff:") { return isThisMac(String(h.dropFirst(7))) }
        let four = h.split(separator: ".", omittingEmptySubsequences: false)
        if four.count == 4, four.allSatisfy({ UInt8($0) != nil }) { return four[0] == "127" || four[0] == "0" }
        return false
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> ExtHostView {
        ExtHostView(makeWebView(coordinator: context.coordinator))
    }

    /// The same web view, outside SwiftUI — which is how a test drives the
    /// real thing rather than a second one built to resemble it.
    public func hosted() -> (view: ExtWebView, coordinator: Coordinator) {
        let c = makeCoordinator()
        return (makeWebView(coordinator: c), c)
    }

    private func makeWebView(coordinator: Coordinator) -> ExtWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing the page stores outlives the pane: what it wants to keep
        // goes through `pipeline.state`, which is the app's and is per shoot.
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(ExtSchemeHandler(upstream: upstream, origin: origin),
                                          forURLScheme: ExtSchemeHandler.scheme)
        configuration.userContentController.addUserScript(ExtBridge.userScript)
        configuration.userContentController.addScriptMessageHandler(
            bridge, contentWorld: .page, name: ExtBridge.name)

        let view = ExtWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        // A pinch here used to magnify the pane, and it STAYED magnified: every
        // movement of his hand then covered a different distance on that page
        // than anywhere else in the app, with nothing on screen saying why and
        // no way back except quitting. He reported it as his mouse changing
        // sensitivity as he used the app. A page of ours is a screen of the
        // app, and the app's screens do not zoom under a pinch; the whole
        // window's zoom is his to set in View, and it applies here too.
        view.allowsMagnification = false
        view.magnification = 1
        view.allowsBackForwardNavigationGestures = false
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.isInspectable = inspectable
        view.setAccessibilityLabel(label.isEmpty ? Strings.Extensions.page : label)
        view.setAccessibilityRole(.group)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        coordinator.attach(view)
        coordinator.load(page)
        return view
    }

    public func updateNSView(_ container: ExtHostView, context: Context) {
        context.coordinator.host = self
        let view = container.webView
        view.isInspectable = inspectable
        if !label.isEmpty { view.setAccessibilityLabel(label) }
        context.coordinator.load(page)
    }

    public static func dismantleNSView(_ container: ExtHostView, coordinator: Coordinator) {
        coordinator.tearDown(container.webView)
    }

    /// For a web view taken with `hosted()`: the same teardown SwiftUI does.
    public static func close(_ view: ExtWebView, coordinator: Coordinator) {
        coordinator.tearDown(view)
    }

    // MARK: -

    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var host: ExtensionHost
        private weak var view: ExtWebView?
        private var appearanceObserver: NSKeyValueObservation?
        private var loaded: URL?
        private var applied: ExtAppearance?
        private var scrollBack: WKUserScript?

        init(_ host: ExtensionHost) { self.host = host }

        func attach(_ view: ExtWebView) {
            self.view = view
            view.onReload = { [weak view] in view?.reload() }
            host.bridge.onTyping = { [weak view] on in view?.isTyping = on }
            view.onPressed = { [weak self] in self?.host.bridge.onPressed?() }
            // The page follows the app into Dark Mode while it is open, not
            // only when it is next opened (EXT-02).
            appearanceObserver = view.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.applyAppearance(to: v) }
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(accessibilityChanged),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }

        func tearDown(_ view: ExtWebView) {
            appearanceObserver?.invalidate()
            appearanceObserver = nil
            NotificationCenter.default.removeObserver(self)
            view.configuration.userContentController.removeAllUserScripts()
            view.configuration.userContentController
                .removeScriptMessageHandler(forName: ExtBridge.name, contentWorld: .page)
            view.navigationDelegate = nil
            view.uiDelegate = nil
            view.stopLoading()
        }

        @objc private func accessibilityChanged() {
            guard let view else { return }
            applyAppearance(to: view)
        }

        func load(_ url: URL) {
            guard loaded != url, let view else { return }
            guard let address = ExtSchemeHandler.schemeURL(for: url) else {
                host.onRefusal(.notServed(url.absoluteString))
                return
            }
            loaded = url
            scrollBack = host.scrolledTo.map {
                WKUserScript(source: Self.scrollBack($0), injectionTime: .atDocumentStart, forMainFrameOnly: true)
            }
            installScripts(on: view)
            view.load(URLRequest(url: address))
        }

        /// The bridge, the look, and — for the first load of a visit — the
        /// way back to where he was. Set again whenever one changes, because
        /// WebKit has no way to take out one script of several.
        private func installScripts(on view: WKWebView) {
            let controller = view.configuration.userContentController
            controller.removeAllUserScripts()
            controller.addUserScript(ExtBridge.userScript)
            if let applied {
                controller.addUserScript(WKUserScript(source: applied.script, injectionTime: .atDocumentStart,
                                                      forMainFrameOnly: true))
            }
            if let scrollBack { controller.addUserScript(scrollBack) }
        }

        /// Puts the page back where he left it, once it is tall enough to be
        /// there — most pages draw their cards after they have loaded — and
        /// gives up the moment he scrolls or presses a key himself, or after
        /// five seconds.
        static func scrollBack(_ p: CGPoint) -> String {
            let x = Int(p.x.rounded()), y = Int(p.y.rounded())
            return """
            (function () {
              var done = false, start = Date.now();
              function stop() { done = true; }
              window.addEventListener("wheel", stop, { once: true, passive: true });
              window.addEventListener("keydown", stop, { once: true });
              window.addEventListener("mousedown", stop, { once: true });
              function tryIt() {
                if (done) { return true; }
                if (Date.now() - start > 5000) { done = true; return true; }
                var d = document.documentElement;
                if (d && d.scrollHeight >= \(y) + window.innerHeight - 1) {
                  window.scrollTo(\(x), \(y));
                  done = true;
                }
                return done;
              }
              function watch() {
                if (tryIt() || !window.ResizeObserver) { return; }
                var ro = new ResizeObserver(function () { if (tryIt()) { ro.disconnect(); } });
                ro.observe(document.documentElement);
              }
              if (document.readyState === "loading") {
                document.addEventListener("DOMContentLoaded", watch, { once: true });
              } else { watch(); }
              window.addEventListener("load", tryIt, { once: true });
            })();
            """
        }

        /// Set at document start and again on every change, by setting the
        /// properties rather than swapping a stylesheet — a page that has
        /// already laid itself out re-colours without reflowing.
        private func applyAppearance(to view: WKWebView) {
            let now = ExtAppearance.current(view.effectiveAppearance)
            guard now != applied else { return }
            applied = now
            installScripts(on: view)
            view.evaluateJavaScript(now.script) { _, _ in }
        }

        // MARK: navigation

        public func webView(_ webView: WKWebView,
                            decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            // A link he clicked to the web — "View on Instagram" — opens in
            // his browser, in this frame or a new window alike, and the page
            // stays where it is. It was refused with the red line, and he
            // copied the address by hand. Only the link's own address goes:
            // no key, no shoot name.
            if linkOut(url, action, webView) { return .cancel }
            // A new window is not a thing an added step has.
            guard let frame = action.targetFrame else {
                host.onRefusal(.wentOutside(url.absoluteString))
                return .cancel
            }
            // No page is ever loaded in an iframe — including by itself.
            guard frame.isMainFrame || url.absoluteString == "about:blank" else {
                host.onRefusal(.notServed(url.absoluteString))
                return .cancel
            }
            if url.scheme == ExtSchemeHandler.scheme || url.absoluteString == "about:blank" {
                return .allow
            }
            host.onRefusal(.wentOutside(url.absoluteString))
            return .cancel
        }

        public func webView(_ webView: WKWebView, didStartProvisionalNavigation: WKNavigation!) {
            // A page going away takes its field with it.
            (webView as? ExtWebView)?.isTyping = false
            host.bridge.onNavigation?()
        }

        public func webView(_ webView: WKWebView, didFinish: WKNavigation!) {
            (webView as? ExtWebView)?.takeKeyboard()
            // Put back once: a reload later is a fresh start at the top.
            if scrollBack != nil {
                scrollBack = nil
                installScripts(on: webView)
            }
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation: WKNavigation!,
                            withError error: any Error) {
            report(error)
        }

        public func webView(_ webView: WKWebView, didFail: WKNavigation!, withError error: any Error) {
            report(error)
        }

        private func report(_ error: any Error) {
            if let e = error as? ExtHostError { host.onRefusal(e); return }
            let ns = error as NSError
            guard ns.code != NSURLErrorCancelled else { return }
            host.onRefusal(.notServed(ns.localizedDescription))
        }

        // MARK: the page's own dialogs, drawn as the app's

        public func webView(_ webView: WKWebView, createWebViewWith: WKWebViewConfiguration,
                            for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, !linkOut(url, action, webView) {
                host.onRefusal(.wentOutside(url.absoluteString))
            }
            return nil
        }

        /// A link to the web he clicked: opened in his browser. Whether it was.
        private func linkOut(_ url: URL, _ action: WKNavigationAction, _ webView: WKWebView) -> Bool {
            let his = (webView as? ExtWebView)?.pressedJustNow ?? false
            guard ExtensionHost.goesToHisBrowser(url, type: action.navigationType, byHisHand: his) else { return false }
            host.openOutside(url)
            return true
        }

        /// A page's `alert()` and `confirm()` are drawn as the app rather
        /// than as WebKit — and as the app's *ordinary* ones. They go to
        /// ``ExtPageDialogs`` and never to `confirmDestructive`: a page
        /// saying "Saved" must not come out red with a Cancel beside it, or
        /// the colour the app keeps for what cannot be taken back stops
        /// meaning anything.
        /// `alert()` is a line under the page and returns at once
        /// (`ExtSaidBar`); `confirm()` is the app's ordinary sheet.
        public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                            initiatedByFrame: WKFrameInfo) async {
            await host.bridge.dialogs?.pageSaid(message)
        }

        public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                            initiatedByFrame: WKFrameInfo) async -> Bool {
            await host.bridge.dialogs?.pageAsked(message) ?? false
        }
    }
}

/// A plain box the page is drawn in.
///
/// It exists for one measured reason. A `WKWebView` reports a fitting size —
/// the height it happens to have — and SwiftUI asks the view it hosts for
/// exactly that when it works out how tall the pane wants to be. Put a row
/// under the page and the pane asks for the page's height plus the row, the
/// window grows to that, the page grows with the window, and the two chase
/// each other until the top of the app is off the screen. A box with no
/// constraints in it has no fitting size to leak, so the pane decides how big
/// the page is and the page never decides how big the pane is.
public final class ExtHostView: NSView {
    public let webView: ExtWebView

    init(_ webView: ExtWebView) {
        self.webView = webView
        super.init(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    public override var acceptsFirstResponder: Bool { false }

    /// The page takes the keyboard, not the box around it.
    public override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(webView) ?? false
    }

    /// A page that had loaded before the box was in a window takes the
    /// keyboard once it is.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !webView.isLoading, webView.url != nil { webView.takeKeyboard() }
    }
}

/// The web view, with the app's own context menu on it.
///
/// WebKit's menu offers Reload, Back, Services, Look Up, Share and a Web
/// Inspector item that is not the app's to offer (NAT-09). This one offers
/// what the app means, and every item the app puts on it has a key. Inside a
/// field it keeps WebKit's spelling guesses, Cut and Paste, which a caption
/// being typed needs.
public final class ExtWebView: WKWebView, TypingResponder {
    var onReload: (() -> Void)?
    /// Told at each press of the mouse on the page, before the page sees it.
    var onPressed: (@MainActor () -> Void)?
    /// He is in one of the page's fields, as the page last said. With the
    /// picture on the other screen, H — Hold — took the letter from a
    /// caption being typed here, because to the menu a web view is not a
    /// text field.
    public internal(set) var isTyping = false

    public override var acceptsFirstResponder: Bool { true }

    public override func mouseDown(with event: NSEvent) {
        notePress()
        onPressed?()
        super.mouseDown(with: event)
    }

    /// A link is followed when the button comes up, so a press held on it
    /// counts from there.
    public override func mouseUp(with event: NSEvent) {
        notePress()
        super.mouseUp(with: event)
    }

    /// Return, Enter or Space on a link the keyboard is on is his press too
    /// — but not typed into one of the page's fields, where it is a space in
    /// a caption, and a script's `a.click()` straight after it is not his.
    public override func keyDown(with event: NSEvent) {
        if [36, 76, 49].contains(event.keyCode), !isTyping { notePress() }
        super.keyDown(with: event)
    }

    /// When he last pressed on the page, for telling a link he clicked from
    /// one a script followed by itself.
    private var lastPress: TimeInterval?
    func notePress() { lastPress = ProcessInfo.processInfo.systemUptime }

    /// A link followed now was followed by his hand: his press is under a
    /// second old. It was three, long enough for a page to follow a link of
    /// its own choosing after a fetch set off by his click on something else.
    var pressedJustNow: Bool {
        guard let at = lastPress else { return false }
        return ProcessInfo.processInfo.systemUptime - at < Self.pressCounts
    }
    static let pressCounts: TimeInterval = 1

    /// The page has the keyboard once it has loaded, so its own keys and
    /// the arrows work on arrival rather than after a click inside it that
    /// did nothing else. Not while he is typing in a field somewhere else in
    /// the window, and not when something inside the page already has it.
    func takeKeyboard() {
        guard let window, !MenuValidation.isTextEditing(in: window) else { return }
        if let r = window.firstResponder as? NSView, r === self || r.isDescendant(of: self) { return }
        window.makeFirstResponder(self)
    }

    /// The pane decides how big the page is, not the page. Without this the
    /// web view reports the height it happens to have, the window grows to
    /// fit it, the web view grows with the window, and the two chase each
    /// other until the pane is taller than the screen — which is exactly what
    /// a refusal row under the page made happen.
    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        // What WebKit offers for a field he is typing in stays: its guesses
        // at the word under the pointer, Cut and Paste. Everything else of
        // WebKit's goes.
        let field = Self.fieldItems(menu.items)
        menu.removeAllItems()
        if !field.spelling.isEmpty {
            field.spelling.forEach(menu.addItem)
            menu.addItem(.separator())
        }

        if let cut = field.cut {
            cut.keyEquivalent = "x"
            cut.keyEquivalentModifierMask = [.command]
            menu.addItem(cut)
        }

        let copy = NSMenuItem(title: Strings.Extensions.copy, action: #selector(NSText.copy(_:)),
                              keyEquivalent: "c")
        copy.keyEquivalentModifierMask = [.command]
        menu.addItem(copy)

        if let paste = field.paste {
            paste.keyEquivalent = "v"
            paste.keyEquivalentModifierMask = [.command]
            menu.addItem(paste)
        }

        let all = NSMenuItem(title: Strings.Extensions.selectAll, action: #selector(NSText.selectAll(_:)),
                             keyEquivalent: "a")
        all.keyEquivalentModifierMask = [.command]
        menu.addItem(all)

        menu.addItem(.separator())

        let reload = NSMenuItem(title: Strings.Extensions.reload, action: #selector(reloadPage(_:)),
                                keyEquivalent: Self.reloadKey)
        reload.keyEquivalentModifierMask = Self.reloadModifiers
        reload.target = self
        menu.addItem(reload)
    }

    /// The items of WebKit's own menu that the app's keeps inside a field.
    ///
    /// WebKit names only some of its items (`WKMenuItemIdentifier…`), and
    /// neither Cut nor a guess at a misspelt word is among them, so they are
    /// found by where WebKit puts them. Paste is named and WebKit offers it
    /// only where he can type, so it says the menu is a field's. Cut is the
    /// unnamed item just before Copy — WebKit adds Cut, Copy and Paste in
    /// that order. The guesses, "No Guesses Found", Ignore Spelling and Learn
    /// Spelling are the groups above those three in which WebKit names
    /// nothing and nothing opens a submenu; a group with a named item in it
    /// (Look Up, Search the Web) is WebKit's and goes. Outside a field there
    /// is no Paste, and nothing is kept.
    static func fieldItems(_ items: [NSMenuItem]) -> (spelling: [NSMenuItem], cut: NSMenuItem?, paste: NSMenuItem?) {
        func named(_ i: NSMenuItem, _ id: String) -> Bool { i.identifier?.rawValue == id }
        guard let pasteAt = items.firstIndex(where: { named($0, pasteID) }) else { return ([], nil, nil) }
        let anchor = items.firstIndex { named($0, copyID) } ?? pasteAt
        var clipboardStart = anchor
        var cut: NSMenuItem?
        if anchor > 0, Self.isUnnamed(items[anchor - 1]) {
            cut = items[anchor - 1]
            clipboardStart = anchor - 1
        }
        var spelling: [NSMenuItem] = []
        var group: [NSMenuItem] = []
        for item in items[..<clipboardStart] + [NSMenuItem.separator()] {
            guard item.isSeparatorItem else { group.append(item); continue }
            if !group.isEmpty, group.allSatisfy(Self.isUnnamed) { spelling += group }
            group = []
        }
        return (spelling, cut, items[pasteAt])
    }

    static let pasteID = "WKMenuItemIdentifierPaste"
    static let copyID = "WKMenuItemIdentifierCopy"

    /// An item WebKit gave no name and no submenu: an action on the text.
    private static func isUnnamed(_ item: NSMenuItem) -> Bool {
        !item.isSeparatorItem && item.identifier == nil && !item.hasSubmenu
    }

    /// ⇧⌘R, not ⌘R: ⌘R is Shoot ▸ Cull, and a key equivalent here reached
    /// the page before the menu wherever the keyboard was, so ⌘R on an added
    /// step threw away what he had half done on its page.
    static let reloadKey = "r"
    static let reloadModifiers: NSEvent.ModifierFlags = [.command, .shift]

    @objc func reloadPage(_ sender: Any?) {
        onReload?()
    }

    /// ⇧⌘R is the key path to the one thing the menu offers that WebKit does
    /// not already bind — and only while the page has the keyboard.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isReload(event), hasKeyboard {
            reloadPage(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    static func isReload(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .shift, .option, .control]) == reloadModifiers
            && event.charactersIgnoringModifiers?.lowercased() == reloadKey
    }

    private var hasKeyboard: Bool {
        guard let r = window?.firstResponder as? NSView else { return false }
        return r === self || r.isDescendant(of: self)
    }
}
