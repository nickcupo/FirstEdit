import Foundation
import WebKit

/// The three things a page can ask the app for (DESIGN.md §2.16-3/4/5).
///
/// Every one of them exists so a page does not have to build something the app
/// already has and does better: a full-size look at a frame, a confirmation
/// that reads like every other confirmation in the app, and somewhere to keep
/// a per-shoot choice that survives the page being closed.
@MainActor
public protocol ExtBridgeDelegate: AnyObject {
    /// Open the app's own viewer over the page, at `stems[startAt]`, with
    /// the marks the page offers, and answer when he closes it: the frame he
    /// was on and every mark as it then stood.
    func viewFrames(_ stems: [String], startAt: Int, actions: [ExtViewerAction],
                    marks: [String: String]) async -> ExtViewerResult
    /// Draw the app's own sheet and answer when he has. Cancel is the default
    /// button and the answer is `false`.
    func confirmDestructive(title: String, body: String, confirmLabel: String) async -> Bool
    func state(get key: String) -> String?
    func state(set key: String, _ value: String?)
    /// Where the page is scrolled to, as he scrolls it: the host's own note,
    /// not a call a page makes.
    func scrolled(x: Double, y: Double)
}

extension ExtBridgeDelegate {
    public func scrolled(x: Double, y: Double) {}
}

/// A page's own `alert()` and `confirm()`, answered by the app.
///
/// These are deliberately **not** on ``ExtBridgeDelegate``. `pipeline`'s three
/// calls are what a page asks the app to *do*; these two are what the browser
/// would have drawn, drawn as the app instead. Keeping them apart is what
/// stops an ordinary `alert("Saved")` from arriving at the sheet that is
/// reserved for something that cannot be taken back.
@MainActor
public protocol ExtPageDialogs: AnyObject {
    /// The page said something. Show it; nothing waits for him to have seen it.
    func pageSaid(_ message: String) async
    /// The page asked something ordinary. `false` is the safe answer.
    func pageAsked(_ question: String) async -> Bool
}

/// What a page calls, and the one place the names are written down.
///
/// A message is answered rather than fired and forgotten: `postMessage` with a
/// reply handler is a promise on the page's side, so `confirmDestructive`
/// resolves with his actual answer instead of the page guessing.
public final class ExtBridge: NSObject, WKScriptMessageHandlerWithReply {
    public static let name = "pipeline"

    public weak var delegate: (any ExtBridgeDelegate)?
    /// Who draws the page's own `alert()` and `confirm()`. Nothing is drawn
    /// if nobody does, and a `confirm()` is then `false`.
    public weak var dialogs: (any ExtPageDialogs)?
    /// What the host itself refused, put where the action was taken. It is
    /// never an alert.
    public var onRefusal: (@MainActor (String) -> Void)?
    /// The page has begun to load afresh — a reload, or a navigation of its
    /// own within its origin. A refusal about the last load goes.
    public var onNavigation: (@MainActor () -> Void)?
    /// He has gone into, or out of, a field on the page he can type in. The
    /// web view keeps it, because a field inside the page is not an
    /// `NSTextView` and the menu's bare-letter keys cannot see it otherwise
    /// (`TypingResponder`).
    public var onTyping: (@MainActor (Bool) -> Void)?
    /// He has pressed the mouse on the page (`ExtWebView.mouseDown`).
    public var onPressed: (@MainActor () -> Void)?

    public init(delegate: (any ExtBridgeDelegate)? = nil) {
        self.delegate = delegate
    }

    /// Installed at document start, before any of the page's own code runs, so
    /// a page never has to wait for `pipeline` to appear.
    public static var userScript: WKUserScript {
        WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    static let shim = """
    (function () {
      if (window.pipeline) { return; }
      function send(call, payload) {
        var w = window.webkit && window.webkit.messageHandlers;
        var h = w && w["\(name)"];
        if (!h) { return Promise.reject(new Error("this page is not running inside FirstEdit")); }
        return h.postMessage({ name: call, payload: payload || {} });
      }
      var state = {
        get: function (key) { return send("stateGet", { key: String(key) }); },
        set: function (key, value) {
          return send("stateSet", { key: String(key), value: value === null || value === undefined ? null : String(value) });
        },
        remove: function (key) { return send("stateSet", { key: String(key), value: null }); }
      };
      // Where the page is, for the host to put it back there next visit.
      // Not on window.pipeline: nothing a page calls.
      var noted = null;
      window.addEventListener("scroll", function () {
        if (noted) { return; }
        noted = setTimeout(function () {
          noted = null;
          send("scrolled", { x: window.scrollX, y: window.scrollY }).catch(function () {});
        }, 250);
      }, { passive: true });
      // Whether he is typing in one of the page's fields, for the host: a
      // menu key with no modifier, H among them, must not take a letter
      // meant for the field. Not on window.pipeline: nothing a page calls.
      function typable(el) {
        if (!el || el.nodeType !== 1) { return false; }
        if (el.isContentEditable) { return true; }
        if (el.disabled || el.readOnly) { return false; }
        if (el.tagName === "TEXTAREA") { return true; }
        if (el.tagName !== "INPUT") { return false; }
        return ["button", "checkbox", "color", "file", "hidden", "image", "radio", "range", "reset", "submit"]
          .indexOf(String(el.type || "text").toLowerCase()) === -1;
      }
      var typing = false;
      function typingNow(on) {
        if (on === typing) { return; }
        typing = on;
        send("typing", { on: on }).catch(function () {});
      }
      document.addEventListener("focusin", function (e) { typingNow(typable(e.target)); }, true);
      document.addEventListener("focusout", function (e) { typingNow(typable(e.relatedTarget)); }, true);
      Object.defineProperty(window, "pipeline", {
        value: Object.freeze({
          viewFrames: function (stems, startAt, options) {
            var o = options || {};
            return send("viewFrames", { stems: Array.prototype.slice.call(stems || []).map(String),
                                        startAt: Number(startAt) || 0,
                                        actions: Array.prototype.slice.call(o.actions || []),
                                        marks: o.marks || {} });
          },
          confirmDestructive: function (title, body, confirmLabel) {
            return send("confirmDestructive", { title: String(title || ""), body: String(body || ""),
                                                confirmLabel: String(confirmLabel || "") });
          },
          state: Object.freeze(state)
        }),
        writable: false, configurable: false
      });
    })();
    """

    // MARK: - WKScriptMessageHandlerWithReply

    public func userContentController(_ controller: WKUserContentController,
                                      didReceive message: WKScriptMessage,
                                      replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any],
              let name = body["name"] as? String else {
            replyHandler(nil, Strings.Extensions.badCall)
            return
        }
        let payload = body["payload"] as? [String: Any] ?? [:]
        // The host's own note, answered whoever the delegate is.
        if name == "typing" {
            onTyping?((payload["on"] as? Bool) ?? false)
            replyHandler(nil, nil)
            return
        }
        guard let delegate else {
            replyHandler(nil, Strings.Extensions.notRunning)
            return
        }

        switch name {
        case "viewFrames":
            let stems = (payload["stems"] as? [Any] ?? []).compactMap { $0 as? String }
            let startAt = (payload["startAt"] as? NSNumber)?.intValue ?? 0
            guard !stems.isEmpty else {
                replyHandler(nil, Strings.Extensions.noFrames)
                onRefusal?(Strings.Extensions.noFrames)
                return
            }
            // Answered when he closes it, not when it opens: the page learns
            // where he stopped and what he marked, rather than making him
            // find that card again for each frame he decided about.
            let actions = ExtViewerAction.parse(payload["actions"])
            let marks = (payload["marks"] as? [String: Any] ?? [:])
                .compactMapValues { $0 as? String }
                .filter { m in stems.contains(m.key) }
            Task { @MainActor in
                let r = await delegate.viewFrames(stems, startAt: max(0, min(startAt, stems.count - 1)),
                                                  actions: actions, marks: marks)
                replyHandler(r.reply, nil)
            }

        case "confirmDestructive":
            let title = payload["title"] as? String ?? ""
            let text = payload["body"] as? String ?? ""
            let confirm = payload["confirmLabel"] as? String ?? ""
            guard !title.isEmpty, !confirm.isEmpty else {
                replyHandler(nil, Strings.Extensions.confirmNeedsWords)
                return
            }
            Task { @MainActor in
                let said = await delegate.confirmDestructive(title: title, body: text, confirmLabel: confirm)
                replyHandler(said, nil)
            }

        case "scrolled":
            let x = (payload["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (payload["y"] as? NSNumber)?.doubleValue ?? 0
            delegate.scrolled(x: max(0, x), y: max(0, y))
            replyHandler(nil, nil)

        case "stateGet":
            guard let key = payload["key"] as? String, !key.isEmpty else {
                replyHandler(nil, Strings.Extensions.badCall)
                return
            }
            // `null`, never `undefined`: a key that was never set and a key
            // that was cleared are the same answer, and a page should not
            // have to tell two kinds of nothing apart.
            replyHandler(delegate.state(get: key) ?? NSNull(), nil)

        case "stateSet":
            guard let key = payload["key"] as? String, !key.isEmpty else {
                replyHandler(nil, Strings.Extensions.badCall)
                return
            }
            delegate.state(set: key, payload["value"] as? String)
            replyHandler(nil, nil)

        default:
            replyHandler(nil, Strings.Extensions.badCall)
        }
    }
}
