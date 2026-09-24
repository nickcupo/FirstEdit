import AppKit
import WebKit

// The one rule that makes single-letter menu keys safe.
//
// E, D, X, 1–6, S, F, R, W, C, G and Space are real menu key equivalents with an
// empty modifier mask, which is what makes them show in the menus, work with
// Full Keyboard Access and be re-bindable in System Settings. The price is
// that AppKit would fire them while he is typing into a search field, and the
// first press of "e" in Find Burst… would keep a photograph instead of typing
// a letter. `validateMenuItem` returns false for every bare-letter row while
// a text field has the keyboard, so the keystroke falls through to the field.

@MainActor
public enum MenuValidation {

    /// Whether the keyboard belongs to something a person is typing into.
    ///
    /// The field editor is the honest test: a `NSTextField` hands its keyboard
    /// to a shared `NSTextView` when it is being edited, and that text view is
    /// the first responder. A `NSTextView` that is not a field editor — a log,
    /// a licence — is editing too when it takes text.
    ///
    /// An extension's page counts as typing too, wherever the keyboard is in
    /// it: its single letters are its own (DESIGN.md §2.16-6), and the app
    /// cannot see which of its fields has the caret. Hold This One (bare H)
    /// used to fire from a caption field there while the other screen was
    /// open — every "h" held a picture and never reached the text.
    public static func isTextEditing(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let typing = responder as? any TypingResponder { return typing.isTyping }
        if let text = responder as? NSTextView { return text.isFieldEditor || text.isEditable }
        if responder is NSTextField { return true }
        if let view = responder as? NSView, view.isKind(of: NSTextField.self) { return true }
        if let view = responder as? NSView, isInAPage(view) { return true }
        return false
    }

    /// A held key's repeat, on a row that is one press however long the key
    /// is held. Asked only once the row is running the app's own action.
    static func refusesRepeat(_ c: Command, event: @autoclosure () -> NSEvent?) -> Bool {
        guard !c.allowsRepeat, let e = event(), e.type == .keyDown else { return false }
        return e.isARepeat
    }

    /// The view, or something it sits in, is a web page.
    static func isInAPage(_ view: NSView) -> Bool {
        var v: NSView? = view
        while let current = v {
            if current is WKWebView { return true }
            v = current.superview
        }
        return false
    }

    /// Anywhere: the key window if there is one, otherwise the main window.
    public static var isTextEditing: Bool {
        isTextEditing(in: NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow)
    }

    /// Whether a row may fire at all right now, before anything is asked about
    /// what it does.
    public static func allows(_ shortcut: Shortcut?, textEditing: Bool) -> Bool {
        guard let shortcut, shortcut.isUnmodified else { return true }
        // Space and the arrows belong to the focused view as much as the
        // letters do: Space in a text field is a space.
        return !textEditing
    }

    /// Whether a row turns down its own key when the key is what is being
    /// matched — a key press, not a click in the open menu.
    ///
    /// A key with no ⌘, ⌃ or ⌥ — K, D, N, the digits, the arrows, Space, ⇧K —
    /// belongs to whatever has the keyboard: the stage, which drops a held
    /// verdict key and coalesces a held arrow; the light table's own buttons;
    /// a text field. The menu shows the key and does the action when the row
    /// is clicked, but never takes the press itself. Taking it would bypass
    /// the repeat rule (a held K would keep every frame it passed) and, for ⇧K,
    /// the text-field rule too, since a shifted key is not "unmodified".
    ///
    /// Only for a key the light table reads for itself (`KeyMap`). H, which
    /// holds the picture on the other screen, has no reader but its menu row,
    /// and keeps it.
    public static func declinesKeyPress(_ shortcut: Shortcut?, event: NSEvent?) -> Bool {
        guard let shortcut, shortcut.modifiers.isSubset(of: [.shift]),
              let event, event.type == .keyDown,
              Modifiers(event.modifierFlags) == shortcut.modifiers,
              shortcut.matches(event.charactersIgnoringModifiers ?? "")
        else { return false }
        return KeyMap.action(for: KeyMap.Press(event: event), mode: .single) != nil
    }
}

/// A view that is sometimes a field and sometimes not, and says which: an
/// added step's web page, whose fields are not `NSTextView`s.
@MainActor
public protocol TypingResponder: AnyObject {
    var isTyping: Bool { get }
}

/// What every ordinary menu row is wired to.
@MainActor
final class MenuTarget: NSObject, NSMenuItemValidation {
    let center: CommandCenter
    /// The key press being matched, injected so a test can hold a key down.
    /// `NSApp` is nil until something makes the application, which a test
    /// may not have done yet.
    var currentEvent: () -> NSEvent? = { NSApp?.currentEvent }

    init(center: CommandCenter) {
        self.center = center
        super.init()
    }

    @objc func performCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let id = CommandID(raw)
        if let c = CommandTable.command(id), let sel = handedOn(c) {
            NSApp.sendAction(NSSelectorFromString(sel), to: nil, from: sender)
            return
        }
        center.run(id)
    }

    /// The selector a row goes to instead of its own action right now: its
    /// fallback, while a field has the keyboard or nothing of the app's can
    /// run it.
    func handedOn(_ c: Command) -> String? {
        guard let sel = c.fallback else { return nil }
        return MenuValidation.isTextEditing || !center.canRun(c.id) ? sel : nil
    }

    /// What the responder chain says about a selector, asked with a stand-in
    /// row that carries it: whether it can run, and the title it gives it
    /// ("Undo Typing").
    func askTheChain(_ sel: String, title: String) -> (Bool, String) {
        let probe = NSMenuItem(title: title, action: NSSelectorFromString(sel), keyEquivalent: "")
        guard let target = NSApp.target(forAction: probe.action!, to: nil, from: probe) else {
            return (false, title)
        }
        if let v = target as? NSMenuItemValidation { return (v.validateMenuItem(probe), probe.title) }
        if let v = target as? NSUserInterfaceValidations { return (v.validateUserInterfaceItem(probe), probe.title) }
        return (true, title)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let raw = item.representedObject as? String else { return true }
        let id = CommandID(raw)
        guard let c = CommandTable.command(id) ?? center.stepCommands.first(where: { $0.id == id })
        else { return center.canRun(id) }

        // A submenu is live while anything in it is. Why It Is Out was
        // enabled with all six reasons grey inside it.
        if c.isSubmenu, !c.isSystemSubmenu {
            return c.children.contains { child in
                if case .system = child.role { return true }
                return child.isSubmenu || center.canRun(child.id)
            }
        }

        // Handed on to a text field's own undo, the row repeats the way the
        // system's Undo always did: the rule below is for the app's own
        // action, and a held ⌘Z in a field undid once and then beeped.
        if let sel = handedOn(c) {
            let (ok, title) = askTheChain(sel, title: c.title)
            item.title = title
            return ok
        }

        // A held key is one press unless the row says otherwise — the same
        // rule the stage keeps, for a ⌘ key the menu takes first. A held ⌘Z
        // undoes one verdict, not every one it can reach.
        if MenuValidation.refusesRepeat(c, event: currentEvent()) { return false }
        // A row that says what a press does now: Undo naming his verdict, or
        // a Shoot row saying it adds to Up Next while his work runs.
        if let title = center.title(id) { item.title = title } else if c.fallback != nil { item.title = c.title }
        // And its tag, where the page answering it says what it does there.
        item.toolTip = center.help(id) ?? c.help

        // "Show the Filmstrip" and "Hide the Filmstrip" are one row that says
        // which way it goes, the way every Mac app says it.
        let on = center.state(id)
        if let on, let when = c.titleWhenOn {
            item.title = on ? when : c.title
        }
        item.state = (on == true && c.titleWhenOn == nil) ? .on : .off

        if !MenuValidation.allows(c.shortcut, textEditing: MenuValidation.isTextEditing) {
            return false
        }
        if MenuValidation.declinesKeyPress(c.shortcut, event: NSApp.currentEvent) { return false }
        return center.canRun(id)
    }
}
