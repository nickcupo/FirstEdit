import Foundation
import Testing
@testable import PipelineKit

/// The Go menu's own rows, run the way the menu runs them.
@Suite("The Go and File menus", .serialized)
@MainActor
struct GoMenuTests {

    static func host(selection: SidebarSelection, cards: [String] = []) throws -> (CommandHost, AppModel) {
        var top = try #require(JSONSerialization.jsonObject(with: Fixture.data("shoots")) as? [String: Any])
        top["cards"] = cards
        let r = try JSONDecoder().decode(ShootsResponse.self, from: JSONSerialization.data(withJSONObject: top))
        let app = AppModel(preview: Library(preview: r), state: .stopped, navigation: Navigation(selection: selection))
        let host = CommandHost(model: app, center: CommandCenter())
        host.registerEverything()
        return (host, app)
    }

    @Test("⌘J from a shoot whose session has not arrived yet still goes to Choose Keepers")
    func resumeBeforeTheSession() throws {
        let (host, app) = try Self.host(selection: .shoot("2026-09-21"))
        #expect(app.library.cachedSession(for: "2026-09-21") == nil)
        #expect(host.center.run(CommandTable.ID.resume))
        #expect(app.navigation.selection == .step(shoot: "2026-09-21", step: "keepers"))
    }

    @Test("⌘J from another step goes back to the burst and frame he left, not where the shoot opened")
    func resumeKeepsHisPlace() throws {
        let (host, app) = try Self.host(selection: .step(shoot: "2026-09-13-dog", step: "keepers"))
        let c = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"))
        let session = ShootSession(response: try Fixture.decode(ShootResponse.self, "shoot-bursts"),
                                   ext: nil, client: c, pump: ImagePump(client: c))
        app.library.adopt(session)
        // The light table opens where the engine says, and he moves on from there.
        let viewer = ViewerModel.shared(for: session, navigation: app.navigation)
        defer { ViewerModel.forget(session) }
        #expect(session.resume.burst_id == session.bursts.first?.id)
        viewer.goToBurst(7)
        viewer.goToFrame(1)
        app.navigation.selection = .step(shoot: "2026-09-13-dog", step: "presets")

        #expect(host.center.run(CommandTable.ID.resume))
        #expect(app.navigation.selection == .step(shoot: "2026-09-13-dog", step: "keepers"))
        #expect(session.cursor.burst == 7)
        #expect(session.cursor.frame == 1)
    }

    @Test("Go ▸ Storage, ⇧⌘S, is the library's third page, from anywhere, as All Shoots and the learning page are")
    func storageHasAKey() throws {
        let (host, app) = try Self.host(selection: .step(shoot: "2026-09-13-dog", step: "presets"))
        #expect(CommandTable.command(CommandTable.ID.storagePage)?.shortcut == Shortcut("s", [.command, .shift]))
        #expect(host.center.run(CommandTable.ID.storagePage))
        #expect(app.navigation.selection == .storage)
        // A side trip, and ⌘J is the way back.
        #expect(host.center.run(CommandTable.ID.resume))
        #expect(app.navigation.selection == .step(shoot: "2026-09-13-dog", step: "presets"))
    }

    @Test("⌘J with no shoot to go back to is greyed, not a press that does nothing")
    func resumeWithNoShoot() throws {
        let (host, _) = try Self.host(selection: .allShoots)
        #expect(!host.center.canRun(CommandTable.ID.resume))
    }

    @Test("⌘J from All Shoots, Storage, the learning page or a card goes back to his shoot, on the step he was on")
    func resumeFromALibraryPage() throws {
        for side in [SidebarSelection.allShoots, .storage, .learned, .card("/Volumes/EOS_DIGITAL")] {
            let (host, app) = try Self.host(selection: .step(shoot: "2026-09-13-dog", step: "presets"))
            app.navigation.selection = side
            #expect(host.center.canRun(CommandTable.ID.resume), "greyed on \(side)")
            #expect(host.center.run(CommandTable.ID.resume))
            #expect(app.navigation.selection == .step(shoot: "2026-09-13-dog", step: "presets"))
        }
        // Remembered from the last launch, before he has been anywhere in this one.
        let (host, app) = try Self.host(selection: .allShoots)
        app.navigation.recall(["2026-09-21": "edit"], lastShoot: "2026-09-21")
        #expect(host.center.run(CommandTable.ID.resume))
        #expect(app.navigation.selection == .step(shoot: "2026-09-21", step: "edit"))
    }

    @Test("⌘J from a library page is greyed when his shoot is not in the library any more")
    func resumeToAShootThatWent() throws {
        let (host, app) = try Self.host(selection: .allShoots)
        app.navigation.recall(["a-shoot-he-deleted": "keepers"], lastShoot: "a-shoot-he-deleted")
        #expect(!host.center.canRun(CommandTable.ID.resume))
    }

    @Test("⌘N goes to the card that is in, and with no card to the page that says so; the copy is still his press there")
    func newShoot() throws {
        let (none, noCard) = try Self.host(selection: .allShoots)
        #expect(none.center.run(CommandTable.ID.newShoot), "never greyed: it is how he finds out there is no card")
        #expect(noCard.navigation.selection == .card(""))
        #expect(!none.center.canRun(CommandTable.ID.eject))

        let (host, app) = try Self.host(selection: .allShoots, cards: ["/Volumes/EOS_DIGITAL"])
        #expect(host.center.run(CommandTable.ID.newShoot))
        #expect(app.navigation.selection == .card("/Volumes/EOS_DIGITAL"))
        #expect(app.jobs.job == nil, "nothing was started")
    }

    @Test("⌘E is never available while a copy is running off the card")
    func noEjectMidCopy() throws {
        let (host, app) = try Self.host(selection: .allShoots, cards: ["/Volumes/EOS_DIGITAL"])
        #expect(host.center.canRun(CommandTable.ID.eject))
        app.jobs.take(Job(running: true, stopped: false, id: 3, kind: "ingest", shoot: "2026-09-23"))
        #expect(!host.center.canRun(CommandTable.ID.eject))
        app.jobs.take(Job(running: true, stopped: false, id: 4, kind: "cull", shoot: "2026-09-21"))
        #expect(host.center.canRun(CommandTable.ID.eject), "another shoot's cull does not read the card")
    }

    @Test("⌘E on the card's page straight after a copy of that card goes on to the new shoot's Cull")
    func ejectAfterACopy() throws {
        let card = "/Volumes/EOS_DIGITAL"
        // The engine records the card each shoot was copied from.
        var top = try #require(JSONSerialization.jsonObject(with: Fixture.data("shoots")) as? [String: Any])
        var shoots = try #require(top["shoots"] as? [[String: Any]])
        for i in shoots.indices where shoots[i]["name"] as? String == "ducksAndDeadlifts" { shoots[i]["card"] = card }
        top["shoots"] = shoots
        top["cards"] = [card, "/Volumes/SECOND"]
        let r = try JSONDecoder().decode(ShootsResponse.self, from: JSONSerialization.data(withJSONObject: top))
        let app = AppModel(preview: Library(preview: r), state: .stopped, navigation: Navigation(selection: .card(card)))

        #expect(CommandHost.afterEject(app, card: card) == .allShoots, "nothing copied, nothing to go on to")
        app.jobs.take(Job(running: false, stopped: false, id: 3, kind: "ingest", shoot: "ducksAndDeadlifts",
                          code: 0))
        #expect(CommandHost.afterEject(app, card: card) == .step(shoot: "ducksAndDeadlifts", step: "cull"))
        #expect(CommandHost.afterEject(app, card: "/Volumes/SECOND") == .allShoots,
                "ejecting the second card, never copied, is not a way to the first card's shoot")
        app.jobs.take(Job(running: false, stopped: false, id: 4, kind: "ingest", shoot: "ducksAndDeadlifts",
                          log: "Traceback (most recent call last):", code: 1))
        #expect(CommandHost.afterEject(app, card: card) == .allShoots, "a copy that failed made no shoot to go to")
        app.jobs.take(Job(running: false, stopped: false, id: 5, kind: "ingest", shoot: "2026-09-19", code: 0))
        #expect(CommandHost.afterEject(app, card: "/Volumes/Untitled") == .allShoots,
                "a shoot already culled was not just copied")
    }

    @Test("the empty library does not send him to a menu row that is greyed")
    func emptyLibraryPointsSomewhereReal() throws {
        let (host, _) = try Self.host(selection: .allShoots)
        #expect(!host.center.canRun(CommandTable.ID.addFolder))
        #expect(!Strings.Library.emptyWhy.contains(Words.File.addFolder))
    }

    @Test("nor while a copy is waiting its turn on the list")
    func noEjectWithACopyWaiting() {
        let copy = QueueItem(id: 7, kind: "ingest", shoot: "2026-09-23")
        let cull = QueueItem(id: 8, kind: "cull", shoot: "2026-09-21")
        #expect(CardWatcher.copyNeedsTheCard(job: nil, running: false, waiting: [cull, copy]))
        #expect(!CardWatcher.copyNeedsTheCard(job: nil, running: false, waiting: [cull]))
        let running = Job(running: true, stopped: false, id: 3, kind: "ingest", shoot: "2026-09-23")
        #expect(CardWatcher.copyNeedsTheCard(job: running, running: true, waiting: []))
        #expect(!CardWatcher.copyNeedsTheCard(job: running, running: false, waiting: []), "a copy that has ended")
    }

    @Test("an eject run off the main thread still answers with the system's sentence when it cannot happen")
    func ejectOffMain() async {
        // A path that is no volume: refused, with the system's sentence, and
        // not on the main thread while it waits.
        let why = await CardWatcher.ejectOffTheMainThread("/nonexistent-card-\(UUID().uuidString)")
        #expect(why != nil)
    }
}
