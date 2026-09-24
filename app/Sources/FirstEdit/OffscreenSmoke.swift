import AppKit
import SwiftUI
import PipelineKit

/// Explicit opt-in before any settings, engine or migration code is reached.
/// Both halves of smoke.sh use this same preflight, including --check.
@MainActor
enum OffscreenSmoke {
    static let marker = "SMOKE_OFFSCREEN_V1"

    static func prepare() throws {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        func refuse(_ reason: String) throws -> Never {
            throw NSError(domain: "OffscreenSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: reason])
        }
        func directory(_ key: String) throws -> URL {
            guard let path = env[key], path.hasPrefix("/") else { try refuse("missing absolute \(key)") }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.resolvingSymlinksInPath().path == url.path,
                  (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            else { try refuse("\(key) must be a real directory without symlinks") }
            return url
        }
        func within(_ path: URL, _ root: URL) -> Bool { path.path.hasPrefix(root.path + "/") }
        let root = try directory("PIPELINE_SMOKE_ROOT")
        guard root.lastPathComponent.hasPrefix("first-edit-smoke."),
              within(root, URL(fileURLWithPath: "/private/tmp").standardizedFileURL)
        else { try refuse("smoke state must be a dedicated temporary directory") }
        let home = try directory("CFFIXED_USER_HOME")
        guard home.path == root.appendingPathComponent("home").path else { try refuse("preferences must stay in scratch") }
        for (key, child) in [("PIPELINE_SUPPORT", "support"), ("PIPELINE_ICLOUD", "icloud"),
                             ("PIPELINE_LEARNED", "learned"), ("PIPELINE_EXT", "no-extension"),
                             ("XDG_CACHE_HOME", "cache"), ("TMPDIR", "tmp")] {
            guard try directory(key).path == root.appendingPathComponent(child).path else { try refuse("unsafe \(key)") }
        }
        let rawSite = URL(fileURLWithPath: env["PIPELINE_SITE"] ?? "").standardizedFileURL
        let site = rawSite.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(rawSite.lastPathComponent)
        let expectedSite = root.appendingPathComponent("no-site").path
        guard site.path == expectedSite else {
            try refuse("smoke site is outside scratch state: \(site.path) != \(expectedSite)")
        }
        guard !fm.fileExists(atPath: site.path) else {
            try refuse("smoke cannot publish a site")
        }
        guard try fm.contentsOfDirectory(atPath: env["PIPELINE_EXT"]!).isEmpty else {
            try refuse("smoke cannot load an extension")
        }
        let library = try directory("PHOTOS_ROOT")
        // A release check consumes an explicit clone under temporary storage,
        // never the originals or a differently named link back to them.
        guard within(library, URL(fileURLWithPath: "/private/tmp").standardizedFileURL),
              fm.fileExists(atPath: library.appendingPathComponent("shoots").path)
        else { try refuse("library must be a temporary scratch clone with a shoots folder") }
        var enumerationError: Error?
        guard let entries = fm.enumerator(at: library, includingPropertiesForKeys: nil,
                                           errorHandler: { _, error in enumerationError = error; return false })
        else { try refuse("cannot inspect scratch library") }
        for case let file as URL in entries {
            let attributes = try fm.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                  attributes[.type] as? FileAttributeType != .typeRegular
                    || ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) <= 1
            else { try refuse("scratch library contains a symbolic or hard link: \(file.lastPathComponent)") }
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0
            else { try refuse("scratch library contains an unavailable file: \(file.lastPathComponent)") }
        }
        if let enumerationError { throw enumerationError }
        WindowFrameMemory.remembers = false
        SettingsStore.shared.checkForUpdates = false
        SettingsStore.shared.learnAutomatically = false
        SettingsStore.shared.firstRunDone = true
        setvbuf(stdout, nil, _IOLBF, 0)
        print("\(marker) isolated")
    }

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        AppDelegate.smoke = true
        AppDelegate.offscreenSmoke = true
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    static func window(model: AppModel) -> NSWindow {
        let size = Tokens.Metric.defaultWindow
        let frame = NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size)
        // No window is ordered before its final offscreen geometry is checked.
        precondition(!NSScreen.screens.contains { $0.frame.intersects(frame) })
        let window = OffscreenWindow(contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.ignoresMouseEvents = true
        window.sharingType = .none
        window.isExcludedFromWindowsMenu = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        window.contentViewController = NSHostingController(rootView: RootView(app: model).onAppear {
            PictureModel.shared.attach(model)
            EngineRestart.shared.attach(.real(model))
        })
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        window.setFrame(frame, display: false)
        window.orderBack(nil)
        return window
    }

    static func isolated(_ window: NSWindow) -> Bool {
        NSApp.activationPolicy() == .prohibited && !window.canBecomeKey && !window.canBecomeMain
            && !NSScreen.screens.contains { $0.frame.intersects(window.frame) }
            && NSApp.windows.filter(\.isVisible).allSatisfy { $0 === window }
    }
}

/// Same offscreen technique as SnapshotHarness: no screen constraining, no
/// key/main eligibility. Geometry is pinned even if SwiftUI resizes the host.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: frameRect.size), display: flag)
    }
}
