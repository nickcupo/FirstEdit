import Foundation
import Testing
@testable import PipelineKit

/// The app is First Edit everywhere he reads its name: the menu bar, the
/// window, the About panel, the Dock, the card-reader prompt, the help menu,
/// every sentence that names it, and the report he files.
///
/// The catalog wins over the Swift default in a built app, and the bundle's
/// own plist names the menu bar and the Dock, so a name changed in the code
/// alone is a name a checkout shows and his app does not.
@Suite("The app's name")
@MainActor
struct AppNameTests {

    static let app = StringCatalogTests.app
    static let old = "Photo Pipeline"

    static func infoPlist() throws -> [String: Any] {
        let url = app.appendingPathComponent("Resources/Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: Any])
    }

    @Test("the bundle names the app First Edit: menu bar, Dock, executable, identifier and the card-reader prompt")
    func bundle() throws {
        let info = try Self.infoPlist()
        #expect(info["CFBundleName"] as? String == "First Edit")
        #expect(info["CFBundleDisplayName"] as? String == "First Edit")
        // app/build.sh copies the binary to Contents/MacOS/$EXE, and macOS
        // opens whatever this key names: the two have to agree.
        #expect(info["CFBundleExecutable"] as? String == "First Edit")
        // Its settings, its notifications and its permissions are filed
        // under this; the first launch copies the old app's settings across.
        #expect(info["CFBundleIdentifier"] as? String == "com.nickcupo.firstedit")
        #expect(info["CFBundleIdentifier"] as? String == FirstLaunch.New.bundleID)
        let prompt = try #require(info["NSRemovableVolumesUsageDescription"] as? String)
        #expect(prompt.hasPrefix("First Edit "))
    }

    @Test("no sentence in the catalog says the old name")
    func catalog() throws {
        for (key, value) in try StringCatalogTests.catalog() {
            #expect(!value.contains(Self.old), "\(key) still says \"\(value)\"")
        }
        #expect(Strings.App.name == "First Edit")
    }

    @Test("no Swift source says the old name, except where it finds the old app's things")
    func sources() throws {
        let root = Self.app.appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var said: [String] = []
        for case let url as URL in walker where ["swift", "md"].contains(url.pathExtension) {
            // Where the first launch finds the old app's folder and settings,
            // and tells him when the old app is still open: those are the
            // old name on purpose.
            if Self.allowed.contains(url.lastPathComponent) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated() where line.contains(Self.old) {
                said.append("\(url.lastPathComponent):\(n + 1)")
            }
        }
        #expect(said.isEmpty, "the old name is still said at \(said.joined(separator: ", "))")
    }

    /// Where the first launch finds the old app's folder and settings, and
    /// the alert that names it while it is still open.
    static let allowed: Set<String> = ["FirstLaunch.swift", "FirstLaunchStrings.swift"]

    @Test("a report goes to First Edit's own issues, and says which app it is about")
    func report() throws {
        let url = try #require(HelpBook.reportURL(version: "0.2.0"))
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(c.host == "github.com")
        #expect(c.path == "/nickcupo/first-edit/issues/new")
        let body = c.queryItems?.first { $0.name == "body" }?.value ?? ""
        #expect(body.contains("First Edit 0.2.0"))
    }
}
