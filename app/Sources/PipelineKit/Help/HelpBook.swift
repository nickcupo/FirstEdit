import AppKit

// The Help menu, and the system's own Help search (NATIVE-M02).
//
// Setting `NSApp.helpMenu` is what puts the Search field at the top of the
// menu and lets Spotlight-for-menus find every item in the bar by name — so
// "Where is Cull Again?" is answered by the OS, with the item highlighted in
// place, and the app does not need a search of its own.

@MainActor
public enum HelpBook {

    /// Whether a compiled help book actually ships in this bundle. Running
    /// from a checkout there is none, and `showHelp:` would beep at him.
    public nonisolated static var hasHelpBook: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") != nil
    }

    /// Help ▸ First Edit Help, which is only in the menu when a help book
    /// ships (§2.12). Without one it opened Keyboard Shortcuts, the item
    /// below it, so the menu had two names for one window.
    public static func show() {
        if hasHelpBook {
            NSApplication.shared.showHelp(nil)
        } else {
            ShortcutsWindow.show()
        }
    }

    /// The version a report is filed against: the bundle's own, which a built
    /// app always has, then what the updater said, which it may not have
    /// said yet. A report went out with an empty version whenever the update
    /// check had not answered.
    public static func version(fallback: String?) -> String {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !v.isEmpty { return v }
        return fallback ?? ""
    }

    /// The new-issue page, in his browser, with the version and the system
    /// filled in. Opening a page is not a network write and not an account:
    /// he writes the report and decides whether to file it.
    public static func reportURL(version: String) -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "github.com"
        c.path = "/nickcupo/first-edit/issues/new"
        c.queryItems = [
            URLQueryItem(name: "title", value: ""),
            URLQueryItem(name: "body", value: """


                ---
                First Edit \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
                """),
        ]
        return c.url
    }

    public static func report(version: String) {
        guard let url = reportURL(version: Self.version(fallback: version)) else { return }
        NSWorkspace.shared.open(url)
    }

    public static func showLog(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
