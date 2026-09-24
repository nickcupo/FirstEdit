import AppKit
import SwiftUI
import ObjectiveC
import PipelineKit

// MARK: - what a crew writes

/// One screen, rendered with fixture data. DESIGN.md §4.3.
public struct SnapshotScene: Sendable {
    public let name: String
    public let size: CGSize
    public let make: @MainActor @Sendable (Fixtures) -> Snapshotted

    public init(name: String, size: CGSize, make: @escaping @MainActor @Sendable (Fixtures) -> Snapshotted) {
        self.name = name
        self.size = size
        self.make = make
    }
}

/// What a scene hands back. Whichever it is, the caller gets a PNG.
public enum Snapshotted {
    /// A SwiftUI view, hosted in an offscreen `NSWindow` and captured with
    /// `cacheDisplay`, so an `NSViewRepresentable` inside it — the viewer, the
    /// filmstrip, a path control — draws for real. The default.
    case window(AnyView)
    /// An AppKit view, captured the same way.
    case appKit(NSView)
    /// SwiftUI only, through `ImageRenderer` at scale 2. Enough for a screen
    /// with no AppKit inside it; `ImageRenderer` draws an
    /// `NSViewRepresentable` as a blank box.
    case rendered(AnyView)
}

/// Scenes registered by hand, for a crew that prefers it.
@MainActor
public enum SnapshotRegistry {
    static var scenes: [SnapshotScene] = []
    public static func register(_ s: SnapshotScene) { scenes.append(s) }
}

/// Subclass this under `Scenes/<Crew>/` and the harness finds it: nothing
/// shared needs editing to add a scene. The harness walks the Objective-C
/// class list for subclasses, the way XCTest finds test cases.
@MainActor
open class SceneProvider: NSObject {
    open class var scenes: [SnapshotScene] { [] }
}

// MARK: - fixtures

/// The captured server answers, decoded, and the objects a scene is built
/// from. Read from `Tests/PipelineKitTests/Fixtures/` unless `--fixtures`
/// says otherwise.
@MainActor
public final class Fixtures {
    public let directory: URL
    /// A scratch library to draw real pictures from, when `--library` is given.
    public let library: URL?

    public init(directory: URL, library: URL?) {
        self.directory = directory
        self.library = library
    }

    public func data(_ name: String) -> Data {
        (try? Data(contentsOf: directory.appendingPathComponent("\(name).json"))) ?? Data("{}".utf8)
    }

    public func decode<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        try? JSONDecoder().decode(T.self, from: data(name))
    }

    public lazy var shoots: ShootsResponse? = decode(ShootsResponse.self, "shoots")
    public lazy var shootsBroken: ShootsResponse? = decode(ShootsResponse.self, "shoots-broken")
    /// The smallest culled shoot the capture found; the dog, on his clone.
    public lazy var shoot: ShootResponse? = decode(ShootResponse.self, "shoot-decided")
        ?? decode(ShootResponse.self, "shoot")
    public lazy var job: Job? = decode(Job.self, "job-finished")
    /// The list of work, as the engine really answered it: a job running off
    /// the list, two more waiting, and one of those with its shoot changed
    /// under it.
    public lazy var queue: QueueState? = decode(QueueState.self, "queue")
    public lazy var queueEmpty: QueueState? = decode(QueueState.self, "queue-empty")
    public lazy var queueFinished: QueueState? = decode(QueueState.self, "queue-running")
    public lazy var storage: Storage? = decode(Storage.self, "storage")

    /// An endpoint nothing listens on. A scene never talks to an engine.
    public let endpoint = EngineHost.Endpoint(base: URL(string: "http://127.0.0.1:9/")!, key: "snapshot")
    public lazy var client = StudioClient(endpoint: endpoint)

    /// Pictures come off the disk of the scratch library, the same files the
    /// engine would serve for thumb, large and full.
    /// With DIAG_STUDIO and DIAG_KEY set, the scenes draw through the REAL
    /// pump against a running engine — the path the app itself uses. Without
    /// them, pictures come off the disk. The stub is why every snapshot was
    /// green while the app showed no photographs: it proved the views, never
    /// the pipeline under them.
    public lazy var pump: ImagePump = {
        let env = ProcessInfo.processInfo.environment
        if let host = env["DIAG_STUDIO"], let key = env["DIAG_KEY"],
           let url = URL(string: "http://\(host)/") {
            FileHandle.standardError.write(Data("harness: drawing through the engine at \(host)\n".utf8))
            return ImagePump(client: StudioClient(endpoint: EngineHost.Endpoint(base: url, key: key)))
        }
        let lib = library
        return ImagePump(loader: { route in
            guard let lib else { throw CocoaError(.fileNoSuchFile) }
            return try Fixtures.file(for: route, in: lib)
        })
    }()

    nonisolated static func file(for route: ImageRoute, in lib: URL) throws -> Data {
        let (shoot, stem, dirs): (String, String, [String])
        switch route {
        case .thumb(let s, let f): (shoot, stem, dirs) = (s, f, ["thumbs", "large", "previews"])
        case .large(let s, let f): (shoot, stem, dirs) = (s, f, ["large", "thumbs", "previews"])
        case .full(let s, let f, _): (shoot, stem, dirs) = (s, f, ["full", "decoded", "large"])
        case .preview(let s, let f): (shoot, stem, dirs) = (s, f, ["previews", "large"])
        default: throw CocoaError(.fileNoSuchFile)
        }
        let cull = lib.appendingPathComponent("shoots/\(shoot)/cull")
        for d in dirs {
            let u = cull.appendingPathComponent("\(d)/\(stem).jpg")
            if let data = try? Data(contentsOf: u) { return data }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// A library that already has the fixture's answer.
    public func makeLibrary(_ response: ShootsResponse? = nil) -> Library {
        let r = response ?? shoots
        let lib = r.map { Library(preview: $0, client: client, pump: pump) } ?? Library(client: client, pump: pump)
        if let s = shoot {
            lib.adopt(ShootSession(response: s, ext: r?.ext, client: client, pump: pump))
        }
        return lib
    }

    /// The whole app model, as if the engine were running.
    public func makeApp(selection: SidebarSelection?, state: EngineHost.State? = nil,
                        response: ShootsResponse? = nil) -> AppModel {
        let nav = Navigation(selection: selection)
        return AppModel(preview: makeLibrary(response), state: state ?? .running(endpoint), navigation: nav)
    }
}

// MARK: - rendering

@MainActor
enum Harness {
    enum Appearance: String, CaseIterable { case light, dark
        var name: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
    }

    static let standardSizes: [CGSize] = [
        CGSize(width: 1100, height: 780), CGSize(width: 1512, height: 945), CGSize(width: 900, height: 620),
    ]

    /// Every scene: the ones registered by hand and every `SceneProvider`
    /// subclass in this executable. `objc_enumerateClasses` filters by
    /// superclass inside the runtime, so no system class is ever touched —
    /// walking the whole class list and casting each one runs arbitrary
    /// `+initialize` methods, and one of CloudKit's traps.
    static func allScenes() -> [SnapshotScene] {
        var out = SnapshotRegistry.scenes
        for cls in objc_enumerateClasses(subclassing: SceneProvider.self) {
            if let provider = cls as? SceneProvider.Type { out += provider.scenes }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.name).inserted }.sorted { $0.name < $1.name }
    }

    /// Render one scene at one size in one appearance to a PNG.
    static func render(_ scene: SnapshotScene, size: CGSize, appearance: Appearance,
                       fixtures: Fixtures, to url: URL) throws {
        let made = scene.make(fixtures)
        let rep: NSBitmapImageRep
        switch made {
        case .window(let view):
            let hosting = NSHostingView(rootView: view)
            // Without this the hosting view hands the window *its* idea of a
            // size — the root's `minWidth`/`minHeight` — and the window obeys.
            // Every scene built on `RootView` was rendered at 900 × 620 no
            // matter what `--size` said, so "the same screen at 1100 and at
            // 1512" was the same 900 pt picture twice. The window's size is
            // the harness's to set.
            hosting.sizingOptions = []
            rep = try capture(hosting, size: size, appearance: appearance, wholeWindow: true)
        case .appKit(let view):
            rep = try capture(view, size: size, appearance: appearance, wholeWindow: false)
        case .rendered(let view):
            let r = ImageRenderer(content: view
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, appearance == .dark ? .dark : .light))
            r.scale = 2
            guard let cg = r.cgImage else { throw HarnessError.renderFailed(scene.name) }
            rep = NSBitmapImageRep(cgImage: cg)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw HarnessError.renderFailed(scene.name)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }

    /// A window AppKit may not drag back onto a display. Every other way of
    /// hiding the render surface either stops SwiftUI laying out (never
    /// ordering it in) or leaves it visible for a frame (alpha, off-level), and
    /// a snapshot run is hundreds of windows: on his Mac they flashed.
    ///
    /// **What this window cannot show you.** It is never key and never main,
    /// which is how it stays off his desktop — and AppKit draws a window that
    /// cannot become key with its *unemphasised* colours. So the accent is
    /// missing from every control in every snapshot this project takes: a
    /// default button is not blue, and a `.tint` or a `.destructive` role is
    /// not red. A view that must read as dangerous has to state its colour on
    /// its own label, and a snapshot is never evidence that an accent-drawn
    /// colour is there.
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// A real window, off the screen, so AppKit lays out and draws everything
    /// it would on screen — toolbar, sidebar, split view, table, path control —
    /// and then its frame view is cached into a bitmap.
    private static func capture(_ content: NSView, size: CGSize, appearance: Appearance,
                                wholeWindow: Bool) throws -> NSBitmapImageRep {
        try autoreleasepool { try captureOnce(content, size: size, appearance: appearance,
                                              wholeWindow: wholeWindow) }
    }

    private static func captureOnce(_ content: NSView, size: CGSize, appearance: Appearance,
                                    wholeWindow: Bool) throws -> NSBitmapImageRep {
        let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance.name)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        content.frame = NSRect(origin: .zero, size: size)
        content.autoresizingMask = [.width, .height]
        window.contentView = content
        // Hold the window at the asked-for size against anything inside it
        // that would rather be another one.
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
        // Well off every display: drawn, composited, never seen. AppKit pulls a
        // titled window back onto a screen whenever it is placed past the edge
        // (constrainFrameRect), so the -20,000 below landed on his desktop and
        // every snapshot flashed a window at him mid-work. OffscreenWindow
        // refuses that correction; the rest keeps it out of the way even if a
        // future macOS ignores it.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        window.isExcludedFromWindowsMenu = true
        window.setFrame(NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size), display: false)
        window.orderBack(nil)

        // Let SwiftUI build its hierarchy, the table populate and the toolbar
        // settle — and then **keep going until the picture stops changing**.
        //
        // A fixed number of turns is a guess, and the guess was wrong: a
        // bordered button two rows down a Form inside a split view drew its
        // chrome and not its title, on roughly one run in three, at twelve
        // turns of 0.06s. A crew looking at that PNG sees a blank button and
        // goes hunting for a bug in a view that is correct. So the capture is
        // taken, the run loop turned again, and the capture retaken until two
        // in a row are identical; that is what is returned. Scenes that
        // settle at once are now *faster* than they were, and one that never
        // settles — a spinner — stops at the cap and returns its last frame.
        let target: NSView = wholeWindow ? (window.contentView?.superview ?? content) : content
        var settled: NSBitmapImageRep?
        var previous: Data?
        var same = 0
        for _ in 0..<20 {
            for _ in 0..<4 {
                window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            window.displayIfNeeded()
            let bounds = target.bounds
            guard let rep = target.bitmapImageRepForCachingDisplay(in: bounds) else {
                throw HarnessError.renderFailed("capture")
            }
            target.cacheDisplay(in: bounds, to: rep)
            settled = rep
            let pixels = rep.tiffRepresentation
            // Three in a row, not two. Inside a split view the control bar
            // came out in a different place on each run, and it was holding
            // still for one pair of turns while the panes were still moving.
            same = (previous == pixels) ? same + 1 : 0
            previous = pixels
            if same >= 2 { break }
        }
        // Ordered out is not gone: every window one of these made stayed
        // alive with its SwiftUI tree and its CATransaction flush observer on
        // it, and rendering the whole set in one process died on an
        // exception inside that flush after about thirty-five scenes. Each
        // one is emptied and closed here, so a batch render is the same work
        // thirty-five times rather than thirty-five windows deep.
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        guard let rep = settled else { throw HarnessError.renderFailed("capture") }
        return rep
    }

    enum HarnessError: Error, CustomStringConvertible {
        case renderFailed(String)
        case noSuchScene(String, [String])
        var description: String {
            switch self {
            case .renderFailed(let n): return "could not render \(n)"
            case .noSuchScene(let n, let all): return "no scene called \(n). There are: \(all.joined(separator: ", "))"
            }
        }
    }
}
