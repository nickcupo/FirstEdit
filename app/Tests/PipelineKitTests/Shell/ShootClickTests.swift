import Foundation
import Testing
@testable import PipelineKit

/// "He clicks yesterday's shoot and gets a form with five numbers and a
/// folder path." A click on a shoot, in the sidebar or All Shoots, opens the
/// step he was last on in it, or the step it is up to (DESIGN.md §2.1,
/// "Clicking a shoot").
@Suite("Clicking a shoot opens where he was in it", .serialized)
@MainActor
struct ShootClickTests {

    /// The fixture library, with the engine's steps on two of its rows: the
    /// dog up to Choose Keepers, 2026-09-21 up to Presets.
    static func library() throws -> ShootsResponse {
        try LastPlaceTests.shoots { rows in
            for i in rows.indices {
                switch rows[i]["name"] as? String {
                case "2026-09-13-dog": rows[i]["steps"] = UpToTests.steps(doneThrough: "cull")
                case "2026-09-21": rows[i]["steps"] = UpToTests.steps(doneThrough: "keepers")
                default: break
                }
            }
        }
    }

    static func app(_ selection: SidebarSelection = .allShoots) throws -> AppModel {
        AppModel(preview: Library(preview: try library()), state: .stopped,
                 navigation: Navigation(selection: selection))
    }

    @Test("a shoot he has not been in opens on the step it is up to, not on its page of numbers")
    func opensOnTheNextStep() throws {
        let app = try Self.app()
        app.open(shoot: "2026-09-13-dog")
        #expect(app.navigation.selection == .step(shoot: "2026-09-13-dog", step: "keepers"))
        app.open(shoot: "2026-09-21")
        #expect(app.navigation.selection == .step(shoot: "2026-09-21", step: "presets"))
    }

    @Test("going back to a shoot opens the step he was last on in it, whichever shoot he was in between")
    func opensWhereHeWas() throws {
        let app = try Self.app()
        app.navigation.selection = .step(shoot: "2026-09-13-dog", step: "reels")
        app.navigation.selection = .step(shoot: "2026-09-21", step: "edit")
        app.navigation.selection = .storage
        app.open(shoot: "2026-09-13-dog")
        #expect(app.navigation.selection == .step(shoot: "2026-09-13-dog", step: "reels"))
        app.open(shoot: "2026-09-21")
        #expect(app.navigation.selection == .step(shoot: "2026-09-21", step: "edit"))
    }

    @Test("the row of the shoot he is already in is its own page, which is how the summary is reached")
    func sameShootIsItsPage() throws {
        let app = try Self.app(.step(shoot: "2026-09-13-dog", step: "keepers"))
        app.open(shoot: "2026-09-13-dog")
        #expect(app.navigation.selection == .shoot("2026-09-13-dog"))
        // Its own page is not a step, and is not remembered as one.
        app.navigation.selection = .allShoots
        app.open(shoot: "2026-09-13-dog")
        #expect(app.navigation.selection == .step(shoot: "2026-09-13-dog", step: "keepers"))
    }

    @Test("keys moving through the sidebar rest on each shoot's own row, and Return there opens where he was")
    func keysThroughTheSidebar() throws {
        let app = try Self.app(.step(shoot: "2026-09-21", step: "presets"))
        // ↓ onto another shoot's row: its own row, not its step page — which
        // could be Reels, Edit or the light table, each doing work of its own.
        SidebarView.choose(.shoot("2026-09-13-dog"), in: app, byKey: true)
        #expect(app.navigation.selection == .shoot("2026-09-13-dog"))
        // Return on it: the step it is up to, as in All Shoots.
        #expect(SidebarView.openChosenShoot(in: app))
        #expect(app.navigation.selection == .step(shoot: "2026-09-13-dog", step: "keepers"))
        // On a step's row, Return is not the sidebar's.
        #expect(!SidebarView.openChosenShoot(in: app))
        SidebarView.choose(.step(shoot: "2026-09-13-dog", step: "cull"), in: app, byKey: true)
        #expect(app.navigation.selection == .step(shoot: "2026-09-13-dog", step: "cull"))
        // A click on a shoot's row still opens where he was in it.
        SidebarView.choose(.shoot("2026-09-21"), in: app, byKey: false)
        #expect(app.navigation.selection == .step(shoot: "2026-09-21", step: "presets"))
        SidebarView.choose(.allShoots, in: app, byKey: false)
        #expect(app.navigation.selection == .allShoots)
    }

    @Test("with no step remembered and none the engine says, it is the shoot's page, as before")
    func nothingKnown() throws {
        let app = try Self.app()
        app.open(shoot: "2026-09-19")
        #expect(app.navigation.selection == .shoot("2026-09-19"))
    }

    @Test("a remembered step the shoot no longer has counts as none")
    func stepGone() throws {
        let app = try Self.app()
        app.navigation.recall(["2026-09-13-dog": "someone-elses-step"], lastShoot: nil)
        app.open(shoot: "2026-09-13-dog")
        #expect(app.navigation.selection == .step(shoot: "2026-09-13-dog", step: "keepers"))
    }

    @Test("a broken shoot's row still opens its own page, its one way in")
    func brokenShoot() throws {
        let r = try LastPlaceTests.shoots("shoots-broken")
        let app = AppModel(preview: Library(preview: r), state: .stopped, navigation: Navigation(selection: .allShoots))
        let broken = try #require(r.broken.first?.name)
        app.navigation.recall([broken: "keepers"], lastShoot: nil)
        app.open(shoot: broken)
        #expect(app.navigation.selection == .shoot(broken))
    }

    @Test("the step in each shoot is kept across launches, for this library only")
    func acrossLaunches() throws {
        let (s, done) = LastPlaceTests.store(); defer { done() }
        let first = LastPlaceTests.app(try Self.library(), s)
        first.restorePlace()
        first.navigation.selection = .step(shoot: "2026-09-13-dog", step: "reels")
        first.navigation.selection = .step(shoot: "2026-09-21", step: "presets")
        #expect(s.shootSteps == ShootSteps(library: LastPlaceTests.folder,
                                           steps: ["2026-09-13-dog": "reels", "2026-09-21": "presets"]))

        let next = LastPlaceTests.app(try Self.library(), s)
        next.restorePlace()
        #expect(next.navigation.selection == .step(shoot: "2026-09-21", step: "presets"))
        next.navigation.selection = .allShoots
        next.open(shoot: "2026-09-13-dog")
        #expect(next.navigation.selection == .step(shoot: "2026-09-13-dog", step: "reels"))

        // Another library folder's steps are nothing in this one.
        s.shootSteps = ShootSteps(library: "/Volumes/Other/photos", steps: ["2026-09-13-dog": "edit"])
        s.lastPlace = nil
        let other = LastPlaceTests.app(try Self.library(), s)
        other.restorePlace()
        other.open(shoot: "2026-09-13-dog")
        #expect(other.navigation.selection == .step(shoot: "2026-09-13-dog", step: "keepers"))
    }

    @Test("only the shoots the library holds are written down")
    func bounded() throws {
        let (s, done) = LastPlaceTests.store(); defer { done() }
        let app = LastPlaceTests.app(try Self.library(), s)
        app.restorePlace()
        app.navigation.recall(["a-shoot-he-deleted": "keepers"], lastShoot: nil)
        app.navigation.selection = .step(shoot: "2026-09-13-dog", step: "presets")
        #expect(s.shootSteps?.steps == ["2026-09-13-dog": "presets"])
    }
}
