import Foundation
import Testing
@testable import PipelineKit

/// "It should go to the last step I was on. I shouldn't need to expand the
/// sidebar and traverse." The app opens on the shoot and the step he quit
/// from, and every case where that place no longer holds lands on All Shoots
/// and says nothing (DESIGN.md §2.1, "Where the window opens").
@Suite("The window opens where he left off", .serialized)
@MainActor
struct LastPlaceTests {

    static let folder = "/Users/someone/photos"

    /// A store of its own, thrown away after.
    static func store() -> (SettingsStore, () -> Void) {
        let name = "last-place-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (SettingsStore(defaults: d), { d.removePersistentDomain(forName: name) })
    }

    static func shoots(_ fixture: String = "shoots", edit: (inout [[String: Any]]) -> Void = { _ in }) throws -> ShootsResponse {
        var top = try #require(JSONSerialization.jsonObject(with: Fixture.data(fixture)) as? [String: Any])
        var rows = try #require(top["shoots"] as? [[String: Any]])
        edit(&rows)
        top["shoots"] = rows
        return try JSONDecoder().decode(ShootsResponse.self, from: JSONSerialization.data(withJSONObject: top))
    }

    /// The app as it is at launch: engine running, library read, window on
    /// All Shoots.
    static func app(_ r: ShootsResponse, _ settings: SettingsStore) -> AppModel {
        let app = AppModel(preview: Library(preview: r), state: .stopped, navigation: Navigation(selection: .allShoots))
        app.memory = settings
        app.libraryFolder = { folder }
        return app
    }

    @Test("the shoot and the step he quit from, with the shoot expanded and selected")
    func opensOnTheStep() throws {
        let (s, done) = Self.store(); defer { done() }
        s.lastPlace = LastPlace(library: Self.folder, shoot: "2026-09-13-dog", step: "presets")
        let app = Self.app(try Self.shoots(), s)
        app.restorePlace()
        #expect(app.navigation.selection == .step(shoot: "2026-09-13-dog", step: "presets"))
        #expect(app.navigation.step == "presets")
        #expect(app.navigation.expandedShoot == "2026-09-13-dog")
        #expect(app.navigation.revealed == "2026-09-13-dog")
        #expect(app.navigation.finishedExpanded == false)
    }

    @Test("the sidebar scrolls to the reopened shoot once, not every time it comes back")
    func revealedOnce() throws {
        let (s, done) = Self.store(); defer { done() }
        s.lastPlace = LastPlace(library: Self.folder, shoot: "2026-09-13-dog", step: "presets")
        let app = Self.app(try Self.shoots(), s)
        app.restorePlace()
        #expect(app.navigation.revealed == "2026-09-13-dog")
        app.navigation.didReveal()
        #expect(app.navigation.revealed == nil)
        // He moves on; the sidebar is hidden and shown by the light table.
        app.navigation.selection = .step(shoot: "2026-09-21", step: "keepers")
        #expect(app.navigation.revealed == nil)
    }

    @Test("the place is saved against the folder the engine reads: PHOTOS_ROOT first, as the engine is given it")
    func folderIsTheEngines() {
        let (s, done) = Self.store(); defer { done() }
        s.libraryFolder = URL(fileURLWithPath: "/Users/someone/photos", isDirectory: true)
        let clone = AppPaths.engineLibrary(settings: s, environment: ["PHOTOS_ROOT": "/tmp/scratch/photos"])
        #expect(clone.path == "/tmp/scratch/photos")
        #expect(AppPaths.engineLibrary(settings: s, environment: [:]).path == "/Users/someone/photos")
        // And the child is handed the same one.
        let launch = EngineLaunch(origin: .bundled, python: URL(fileURLWithPath: "/R/python/bin/python3.12"),
                                  script: URL(fileURLWithPath: "/R/pipeline/studio.py"),
                                  resources: URL(fileURLWithPath: "/R"))
        let env = EngineHost.environment(for: launch, base: ["PHOTOS_ROOT": "/tmp/scratch/photos"],
                                         support: URL(fileURLWithPath: "/scratch/support"), bundle: .main,
                                         settings: s, key: "k")
        #expect(env["PHOTOS_ROOT"] == clone.path)
    }

    @Test("a finished shoot opens the Finished section, which is collapsed by default")
    func finishedShoot() throws {
        let (s, done) = Self.store(); defer { done() }
        s.lastPlace = LastPlace(library: Self.folder, shoot: "2026-09-16", step: "done")
        let app = Self.app(try Self.shoots(), s)
        app.restorePlace()
        #expect(app.navigation.selection == .step(shoot: "2026-09-16", step: "done"))
        #expect(app.navigation.finishedExpanded)
    }

    @Test("the shoot's own page is a place too")
    func shootPage() throws {
        let (s, done) = Self.store(); defer { done() }
        s.lastPlace = LastPlace(library: Self.folder, shoot: "2026-09-21", step: nil)
        let app = Self.app(try Self.shoots(), s)
        app.restorePlace()
        #expect(app.navigation.selection == .shoot("2026-09-21"))
        #expect(app.navigation.step == nil)
    }

    @Test("a fresh install, a shoot that is gone or renamed, another library folder, a broken shoot: All Shoots")
    func nowhere() throws {
        let cases: [(LastPlace?, String)] = [
            (nil, "shoots"),
            (LastPlace(library: Self.folder, shoot: "2026-09-13-dogs", step: "keepers"), "shoots"),
            (LastPlace(library: "/Volumes/Other/photos", shoot: "2026-09-13-dog", step: "keepers"), "shoots"),
            (LastPlace(library: Self.folder, shoot: "a-broken-shoot", step: "keepers"), "shoots-broken"),
        ]
        for (place, fixture) in cases {
            let (s, done) = Self.store(); defer { done() }
            s.lastPlace = place
            let app = Self.app(try Self.shoots(fixture), s)
            app.restorePlace()
            #expect(app.navigation.selection == .allShoots, "\(String(describing: place))")
            #expect(app.navigation.finishedExpanded == false)
        }
    }

    @Test("a step the shoot no longer has lands on the shoot, not on a page that cannot be")
    func stepGone() throws {
        let (s, done) = Self.store(); defer { done() }
        let r = try Self.shoots { rows in
            for i in rows.indices where rows[i]["name"] as? String == "2026-09-13-dog" {
                rows[i]["can_cut_reels"] = false
            }
        }
        s.lastPlace = LastPlace(library: Self.folder, shoot: "2026-09-13-dog", step: "reels")
        let app = Self.app(r, s)
        app.restorePlace()
        #expect(app.navigation.selection == .shoot("2026-09-13-dog"))

        // An extension's step, with no extension there any more.
        let (s2, done2) = Self.store(); defer { done2() }
        s2.lastPlace = LastPlace(library: Self.folder, shoot: "2026-09-13-dog", step: "someone-elses-step")
        let app2 = Self.app(try Self.shoots(), s2)
        app2.restorePlace()
        #expect(app2.navigation.selection == .shoot("2026-09-13-dog"))
    }

    @Test("a click he made while the engine was starting wins, and the restore happens once")
    func hisClickWins() throws {
        let (s, done) = Self.store(); defer { done() }
        s.lastPlace = LastPlace(library: Self.folder, shoot: "2026-09-13-dog", step: "keepers")
        let app = Self.app(try Self.shoots(), s)
        app.navigation.selection = .learned
        app.restorePlace()
        #expect(app.navigation.selection == .learned)
        app.navigation.selection = .allShoots
        app.restorePlace()
        #expect(app.navigation.selection == .allShoots)
    }

    @Test("before the library has been read nothing is decided")
    func waitsForTheLibrary() throws {
        let (s, done) = Self.store(); defer { done() }
        s.lastPlace = LastPlace(library: Self.folder, shoot: "2026-09-13-dog", step: "keepers")
        let app = AppModel(preview: Library(), state: .stopped, navigation: Navigation(selection: .allShoots))
        app.memory = s
        app.libraryFolder = { Self.folder }
        app.restorePlace()
        #expect(app.navigation.selection == .allShoots)
    }

    @Test("arriving at a shoot or a step is remembered; a library page never overwrites it")
    func remembers() throws {
        let (s, done) = Self.store(); defer { done() }
        let app = Self.app(try Self.shoots(), s)
        app.navigation.selection = .step(shoot: "2026-09-21", step: "cull")
        #expect(s.lastPlace == LastPlace(library: Self.folder, shoot: "2026-09-21", step: "cull"))
        app.navigation.selection = .learned
        app.navigation.selection = .storage
        app.navigation.selection = .allShoots
        #expect(s.lastPlace == LastPlace(library: Self.folder, shoot: "2026-09-21", step: "cull"))
        app.navigation.selection = .shoot("2026-09-19")
        #expect(s.lastPlace == LastPlace(library: Self.folder, shoot: "2026-09-19", step: nil))
    }

    @Test("with nowhere to keep it — the smoke run, the harness — nothing is written")
    func smokeWritesNothing() throws {
        let (s, done) = Self.store(); defer { done() }
        let app = Self.app(try Self.shoots(), s)
        app.memory = nil
        app.navigation.selection = .step(shoot: "2026-09-21", step: "cull")
        #expect(s.lastPlace == nil)
    }

    @Test("after a restart onto a library without the shoot on screen, All Shoots")
    func restartKeepsTheSelectionHonest() throws {
        let (s, done) = Self.store(); defer { done() }
        let app = Self.app(try Self.shoots(), s)
        app.navigation.selection = .step(shoot: "2026-09-21", step: "cull")
        app.keepSelectionInLibrary()
        #expect(app.navigation.selection == .step(shoot: "2026-09-21", step: "cull"))

        let gone = AppModel(preview: Library(preview: try Self.shoots { $0.removeAll { $0["name"] as? String == "2026-09-21" } }),
                            state: .stopped, navigation: Navigation(selection: .step(shoot: "2026-09-21", step: "cull")))
        gone.keepSelectionInLibrary()
        #expect(gone.navigation.selection == .allShoots)
    }

    @Test("the same folder, however it was spelled, is the same library")
    func folderSpelling() {
        let a = LastPlace.folder(URL(fileURLWithPath: "/tmp/x/../photos/", isDirectory: true))
        let b = LastPlace.folder(URL(fileURLWithPath: "/tmp/photos"))
        #expect(a == b)
    }

    @Test("the step follows the selection, so a shoot's own page is never titled with the last shoot's step")
    func stepFollowsSelection() {
        let nav = Navigation(selection: .step(shoot: "a", step: "keepers"))
        #expect(nav.step == "keepers")
        nav.selection = .shoot("b")
        #expect(nav.step == nil)
        // ⌘] from a shoot's own page goes to its first step, not the one after
        // the step he was on in the last shoot.
        let steps = Fallbacks.listSteps(canCutReels: true, ext: nil)
        nav.moveStep(by: 1, in: steps)
        #expect(nav.selection == .step(shoot: "b", step: "ingest"))
        nav.selection = .learned
        #expect(nav.step == nil)
    }

    // MARK: - the inspector pin

    @Test("⌥⌘I pins the inspector across launches; before he presses it nothing is kept")
    func inspectorPin() {
        let (s, done) = Self.store(); defer { done() }
        func launch() -> AppModel {
            AppModel(engine: EngineHost(bundle: .main, support: URL(fileURLWithPath: "/tmp/nowhere"), settings: s),
                     memory: s)
        }
        let first = launch()
        #expect(s.inspectorPinned == nil)
        // The portrait default still moves it while he has not chosen.
        first.navigation.setInspectorByDefault(true)
        #expect(first.navigation.inspectorShown)
        #expect(s.inspectorPinned == nil)
        first.navigation.toggleInspector()
        #expect(s.inspectorPinned == false)

        let second = launch()
        #expect(second.navigation.inspectorShown == false)
        second.navigation.setInspectorByDefault(true)
        #expect(second.navigation.inspectorShown == false, "a default does not override a person")
        #expect(second.navigation.inspectorIsHisChoice)
    }

    @Test("a pin to show it opens it in the light table, not beside All Shoots at launch")
    func inspectorPinIsTheLightTables() {
        let (s, done) = Self.store(); defer { done() }
        s.inspectorPinned = true
        let app = AppModel(engine: EngineHost(bundle: .main, support: URL(fileURLWithPath: "/tmp/nowhere"), settings: s),
                           memory: s)
        // All Shoots, the overview: nothing to show, so no column.
        #expect(app.navigation.inspectorShown == false)
        // The light table, whose default for a landscape burst is shut.
        app.navigation.setInspectorByDefault(false)
        #expect(app.navigation.inspectorShown)
        // And from then on it is his, as a press this launch would be.
        app.navigation.setInspectorByDefault(false)
        #expect(app.navigation.inspectorShown)
    }
}
