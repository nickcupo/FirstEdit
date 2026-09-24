import AppKit

// Edit ▸ Find Burst… (⌘F): a burst number and Return, and the light table is
// there (DESIGN.md §2.12).
//
// A sheet on the window, the way Preview asks for a page number: ⌘F, the
// digits, Return — three presses from anywhere in a 288-burst shoot, where the
// scrubber's 8 pt segments take a steady hand and N takes a hundred presses.
// The jump is the scrubber's own (`ViewerModel.goToBurst`), so it records
// nothing: only leaving a burst forward marks it as looked through (§7.4).
//
// The row used to have nothing behind it: greyed on every page while the
// Keyboard Shortcuts window promised ⌘F.

@MainActor
public enum FindBurst {

    /// The burst a typed number names, as an index, or nil when it names none.
    /// "41" is burst 41, which is index 40; spaces around it are forgiven.
    public static func index(from text: String, bursts: Int) -> Int? {
        guard let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), n >= 1, n <= bursts
        else { return nil }
        return n - 1
    }

    /// The sheet, with the number he is on filled in and selected, so typing
    /// replaces it and Return on its own changes nothing. Go is greyed until
    /// the field names a burst there is.
    public static func alert(current: Int, bursts: Int) -> (NSAlert, NSTextField) {
        let a = NSAlert()
        a.messageText = Words.FindBurst.title
        a.informativeText = Words.FindBurst.range(bursts)
        let go = a.addButton(withTitle: Words.FindBurst.go)
        a.addButton(withTitle: Words.FindBurst.cancel)
        let field = NSTextField(string: "\(current + 1)")
        field.placeholderString = Words.FindBurst.placeholder
        field.setAccessibilityLabel(Words.FindBurst.placeholder)
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 22)
        a.accessoryView = field
        let watcher = Watcher(go: go, bursts: bursts)
        field.delegate = watcher
        // The alert keeps its accessory; the accessory keeps its watcher.
        objc_setAssociatedObject(field, &Watcher.key, watcher, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        a.window.initialFirstResponder = field
        return (a, field)
    }

    /// Where Return takes him: the burst the field names, or nowhere when it
    /// names the burst he is already in. A jump lands on a burst's first
    /// frame, so Return on the number the sheet opened with took him from
    /// frame 12 of a 30-frame burst back to frame 1 of the same burst — a
    /// press that was meant to change nothing lost his place.
    public static func destination(_ text: String, current: Int, bursts: Int) -> Int? {
        guard let i = index(from: text, bursts: bursts), i != current else { return nil }
        return i
    }

    /// What Go does with what he typed.
    public static func go(_ text: String, viewer: ViewerModel) {
        guard let i = destination(text, current: viewer.burstIndex, bursts: viewer.bursts.count)
        else { return }
        viewer.goToBurst(i)
    }

    /// Asks, on `window`, and goes there on Return.
    public static func ask(on window: NSWindow, viewer: ViewerModel) {
        let (a, field) = alert(current: viewer.burstIndex, bursts: viewer.bursts.count)
        a.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            go(field.stringValue, viewer: viewer)
        }
        field.selectText(nil)
    }

    /// Greys Go while the field names no burst, so Return can never be a
    /// press that does nothing.
    final class Watcher: NSObject, NSTextFieldDelegate {
        nonisolated(unsafe) static var key = 0
        let go: NSButton
        let bursts: Int

        init(go: NSButton, bursts: Int) {
            self.go = go
            self.bursts = bursts
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            go.isEnabled = FindBurst.index(from: field.stringValue, bursts: bursts) != nil
        }
    }
}
