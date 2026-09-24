import Foundation
import Testing
@testable import PipelineKit

/// The folder picker, against the mistake it is here to make impossible.
///
/// He opened Settings, pressed Choose…, and picked the folder his shoots are
/// visibly in — `~/photos/shoots`. That was saved as `PHOTOS_ROOT` verbatim,
/// the engine appended `shoots` to it, made `~/photos/shoots/shoots` because
/// nothing was there, and served an empty library. Nothing in the app said a
/// word: the control showed the path he had picked, and the sidebar showed
/// nothing at all.
@Suite("Which folder is the library")
struct LibraryFolderTests {

    /// A library on disk, laid out his way.
    static func make(shoots: [String: String?], under name: String = "photos") throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photopipeline-lib-\(UUID().uuidString)")
            .appendingPathComponent(name)
        let shelf = tmp.appendingPathComponent("shoots")
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        for (shoot, inside) in shoots {
            let at = shelf.appendingPathComponent(shoot)
            if let inside {
                try FileManager.default.createDirectory(at: at.appendingPathComponent(inside),
                                                        withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
            }
        }
        return tmp
    }

    static func remove(_ u: URL) {
        try? FileManager.default.removeItem(at: u.deletingLastPathComponent())
    }

    @Test("the library root resolves to itself")
    func theRoot() throws {
        let lib = try Self.make(shoots: ["2026-09-16": "raw", "2026-09-19": "cull"])
        defer { Self.remove(lib) }
        let r = try #require(LibraryFolder.resolve(lib))
        #expect(r.root.path == lib.standardizedFileURL.path)
        #expect(r.shelf.path == lib.appendingPathComponent("shoots").standardizedFileURL.path)
        #expect(r.shoots == ["2026-09-16", "2026-09-19"])
    }

    /// The one he actually picked.
    @Test("the shoots folder itself resolves to the library above it")
    func theShootsFolder() throws {
        let lib = try Self.make(shoots: ["2026-09-16": "raw", "2026-09-19": "cull"])
        defer { Self.remove(lib) }
        let r = try #require(LibraryFolder.resolve(lib.appendingPathComponent("shoots")))
        #expect(r.root.path == lib.standardizedFileURL.path,
                "picking the folder his shoots are in must not send the engine one level deeper")
        #expect(r.shoots.count == 2)
    }

    @Test("a folder that plainly holds shoots resolves, whatever it is called")
    func aShelfByAnotherName() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photopipeline-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("a-wedding/raw"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = try #require(LibraryFolder.resolve(tmp))
        #expect(r.root.path == tmp.standardizedFileURL.path)
        #expect(r.shelf.path == tmp.standardizedFileURL.path)
        #expect(r.shoots == ["a-wedding"])
    }

    /// The ducks shoot: 98 ARW lying loose, no raw/ and no cull/.
    @Test("a folder of loose frames is a shoot")
    func looseFrames() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photopipeline-lib-\(UUID().uuidString)")
        let ducks = tmp.appendingPathComponent("shoots/ducksAndDeadlifts")
        try FileManager.default.createDirectory(at: ducks, withIntermediateDirectories: true)
        try Data().write(to: ducks.appendingPathComponent("TSC05691.ARW"))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = try #require(LibraryFolder.resolve(tmp))
        #expect(r.shoots == ["ducksAndDeadlifts"])
    }

    @Test("a folder with no shoot under it resolves to nothing, and is not guessed at")
    func nothingThere() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photopipeline-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("shoots/shoots"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(LibraryFolder.resolve(tmp) == nil, "an empty folder in shoots/ is not a shoot")
        #expect(LibraryFolder.resolve(tmp.appendingPathComponent("nowhere")) == nil)
        // And the refusal names what was looked for rather than only failing.
        #expect(Strings.Settings.noShootsHere("/x").contains("raw/"))
        #expect(Strings.Settings.noShootsHere("/x").contains("cull/"))
    }

    /// The whole point of normalising on the way out: his setting is already
    /// wrong on his Mac, and no one should have to go and rewrite it.
    @Test("a setting written by an older build fixes itself when it is read")
    func aStoredSettingFixesItself() throws {
        let lib = try Self.make(shoots: ["2026-09-21": "cull"])
        defer { Self.remove(lib) }
        let d = UserDefaults(suiteName: "photopipeline.tests.libraryfolder")!
        for k in SettingsStore.Key.allCases { d.removeObject(forKey: k.rawValue) }
        let store = SettingsStore(defaults: d)

        // Exactly what `defaults read com.nickcupo.photo-pipeline` held.
        d.set(lib.appendingPathComponent("shoots").path, forKey: SettingsStore.Key.libraryFolder.rawValue)
        #expect(store.libraryFolder?.standardizedFileURL.path == lib.standardizedFileURL.path)
        #expect(store.libraryFolderAsChosen?.lastPathComponent == "shoots",
                "what he picked is still on record; only what the engine is told has changed")

        // And on the way in.
        store.libraryFolder = lib.appendingPathComponent("shoots")
        #expect(d.string(forKey: SettingsStore.Key.libraryFolder.rawValue) == lib.standardizedFileURL.path)
    }

    /// A folder that is not there — an unmounted volume, a typo — is his
    /// answer and stays his answer. The app never quietly points the engine
    /// somewhere else.
    @Test("a folder that cannot be resolved is left exactly as it was given")
    func anUnresolvableFolderIsLeftAlone() {
        let nowhere = URL(fileURLWithPath: "/Volumes/NotMounted/photos")
        #expect(LibraryFolder.normalised(nowhere).path == nowhere.path)
        let d = UserDefaults(suiteName: "photopipeline.tests.libraryfolder.missing")!
        for k in SettingsStore.Key.allCases { d.removeObject(forKey: k.rawValue) }
        let store = SettingsStore(defaults: d)
        store.libraryFolder = nowhere
        #expect(store.libraryFolder?.path == nowhere.path)
    }

    @Test("the folder the engine will look in is the folder the empty sidebar names")
    func whereItLooked() throws {
        let lib = try Self.make(shoots: ["2026-09-16": "raw"])
        defer { Self.remove(lib) }
        #expect(LibraryFolder.shelf(under: lib).path == lib.appendingPathComponent("shoots").standardizedFileURL.path)
        // Nothing there: the folder to name is still the one it would look in.
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photopipeline-empty-\(UUID().uuidString)")
        #expect(LibraryFolder.shelf(under: empty).lastPathComponent == "shoots")
    }

    @Test("the resolved line says the count, and not the folder the control above it already shows")
    func theLine() throws {
        let lib = try Self.make(shoots: ["2026-09-16": "raw", "2026-09-19": "cull"])
        defer { Self.remove(lib) }
        let r = try #require(LibraryFolder.resolve(lib))
        let line = Strings.Settings.resolvedLine(r)
        #expect(!line.contains(lib.lastPathComponent))
        #expect(line == "2 shoots")
        let one = try #require(LibraryFolder.resolve(try {
            let l = try Self.make(shoots: ["2026-09-16": "raw"]); return l
        }()))
        #expect(Strings.Settings.resolvedLine(one).contains("1 shoot"))
    }
}
