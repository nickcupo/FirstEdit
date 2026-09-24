import Foundation
import Testing
@testable import PipelineKit

/// The Shoot menu, run the way the menu runs it: each row goes to its page and
/// asks the page to press its own button (DESIGN.md §2.12).
@Suite("The Shoot menu", .serialized)
@MainActor
struct ShootMenuTests {

    typealias ID = CommandTable.ID

    init() { PagePresses.shared.reset() }

    static let storageRows = [ID.copyUp, ID.bringBack, ID.checkEvery, ID.takeBackCache,
                              ID.removeLocal, ID.letGo]

    @Test("from Choose Keepers, every row of a culled shoot is live but Cull It, which it has had")
    func liveFromTheLightTable() throws {
        let (host, _) = try GoMenuTests.host(selection: .step(shoot: "2026-09-19", step: "keepers"))
        #expect(!host.center.canRun(ID.cull), "a culled shoot is culled again, and that asks first")
        for id in [ID.cullAgain, ID.writePresets, ID.openInEditor, ID.cutAReel, ID.finished] + Self.storageRows {
            #expect(host.center.canRun(id), "\(id.rawValue) is greyed on Choose Keepers")
        }
    }

    @Test("a shoot that has not been culled offers Cull It and nothing that needs a cull")
    func notCulled() throws {
        let (host, _) = try GoMenuTests.host(selection: .shoot("ducksAndDeadlifts"))
        #expect(host.center.canRun(ID.cull))
        #expect(!host.center.canRun(ID.cullAgain))
        #expect(!host.center.canRun(ID.writePresets), "nothing would get a preset")
        #expect(!host.center.canRun(ID.openInEditor), "nothing to open")
    }

    @Test("Cull It is grey while that shoot's own cull runs or waits on the list, so ⌘R cannot queue a second")
    func noSecondCull() throws {
        let (host, app) = try GoMenuTests.host(selection: .shoot("ducksAndDeadlifts"))
        #expect(host.center.canRun(ID.cull))
        app.jobs.take(Job(running: true, stopped: false, id: 4, kind: "cull", shoot: "ducksAndDeadlifts"))
        #expect(!host.center.canRun(ID.cull), "its own cull is running")
        #expect(!host.center.run(ID.cull))
        #expect(PagePresses.shared.pending == nil, "nothing asked of the page")

        // Another shoot's cull is no reason: this one's goes on the list.
        app.jobs.take(Job(running: true, stopped: false, id: 5, kind: "cull", shoot: "2026-09-19"))
        #expect(host.center.canRun(ID.cull))

        // Already waiting on the list is the same work a second time.
        host.queue.take(QueueState(waiting: [QueueItem(id: 6, kind: "cull", shoot: "ducksAndDeadlifts")],
                                   running: true, kind: "cull", shoot: "2026-09-19"))
        #expect(!host.center.canRun(ID.cull), "its cull is already on the list")
    }

    @Test("Cull Again… and Write the Presets are grey while that work of the shoot's is in hand, and only that work")
    func noSecondPresets() throws {
        let (host, app) = try GoMenuTests.host(selection: .step(shoot: "2026-09-19", step: "keepers"))
        app.jobs.take(Job(running: true, stopped: false, id: 4, kind: "presets", shoot: "2026-09-19"))
        #expect(!host.center.canRun(ID.writePresets))
        #expect(host.center.canRun(ID.cullAgain), "the presets being written is no reason to grey the cull")
        app.jobs.take(Job(running: true, stopped: false, id: 5, kind: "cull", shoot: "2026-09-19"))
        #expect(!host.center.canRun(ID.cullAgain))
        #expect(host.center.canRun(ID.writePresets), "the presets ended; the cull is what runs now")
    }

    @Test("what a shoot has in hand is what runs for it and what waits for it, never another shoot's")
    func inHand() {
        let list = QueueState(waiting: [QueueItem(id: 2, kind: "presets", shoot: "a"),
                                        QueueItem(id: 3, kind: "reel", shoot: "b")],
                              running: true, kind: "stor-push", shoot: "a")
        let job = Job(running: true, stopped: false, id: 1, kind: "stor-push", shoot: "a")
        #expect(PagePresses.inHand(shoot: "a", job: job, list: list) == ["stor-push", "presets"])
        #expect(PagePresses.inHand(shoot: "b", job: job, list: list) == ["reel"])
        let ended = Job(running: false, stopped: false, id: 1, kind: "cull", shoot: "c", code: 0)
        #expect(PagePresses.inHand(shoot: "c", job: ended, list: .empty).isEmpty, "a cull that ended is not in hand")
    }

    @Test("a finished shoot cannot be finished again")
    func finishedOnce() throws {
        let (host, _) = try GoMenuTests.host(selection: .shoot("2026-09-16"))
        #expect(!host.center.canRun(ID.finished))
    }

    @Test("with no shoot open the whole menu is grey but Stop the Job's rule")
    func noShoot() throws {
        let (host, _) = try GoMenuTests.host(selection: .allShoots)
        for id in [ID.cull, ID.cullAgain, ID.writePresets, ID.openInEditor, ID.cutAReel, ID.finished]
            + Self.storageRows {
            #expect(!host.center.canRun(id), "\(id.rawValue) with no shoot")
        }
    }

    @Test("⇧⌘E from the light table goes to Edit and asks it to open PhotoLab; nothing starts here")
    func openFromAnywhere() throws {
        let (host, app) = try GoMenuTests.host(selection: .step(shoot: "2026-09-19", step: "keepers"))
        #expect(host.center.run(ID.openInEditor))
        #expect(app.navigation.selection == .step(shoot: "2026-09-19", step: "edit"))
        #expect(PagePresses.shared.pending?.command == ID.openInEditor)
        #expect(PagePresses.shared.pending?.shoot == "2026-09-19")
        #expect(app.jobs.job == nil)
    }

    @Test("each row goes to the page whose button it is")
    func eachRowItsPage() throws {
        let pages: [(CommandID, String, String)] = [
            (ID.cullAgain, "2026-09-19", "cull"), (ID.cull, "ducksAndDeadlifts", "cull"),
            (ID.writePresets, "2026-09-19", "presets"), (ID.finished, "2026-09-19", "done"),
        ] + Self.storageRows.map { ($0, "2026-09-19", "done") }
        for (id, shoot, step) in pages {
            let (host, app) = try GoMenuTests.host(selection: .shoot(shoot))
            #expect(host.center.run(id))
            #expect(app.navigation.selection == .step(shoot: shoot, step: step), "\(id.rawValue)")
            #expect(PagePresses.shared.take([id], shoot: shoot) != nil, "\(id.rawValue) asked nothing")
        }
    }

    @Test("Cut a Reel from anywhere but Reels goes there and cuts nothing: the burst is chosen on the page")
    func cutAReelChoosesNothing() throws {
        let (host, app) = try GoMenuTests.host(selection: .step(shoot: "2026-09-19", step: "keepers"))
        #expect(host.center.run(ID.cutAReel))
        #expect(app.navigation.selection == .step(shoot: "2026-09-19", step: "reels"))
        #expect(PagePresses.shared.pending == nil)
    }

    @Test("a row whose page the engine has greyed is grey, not a trip to a button that cannot be pressed")
    func greyedPageGreyRow() throws {
        let (host, app) = try GoMenuTests.host(selection: .step(shoot: "2026-09-13-dog", step: "keepers"))
        // Reels kept for the reels already in the folder, on a Mac that
        // cannot cut one: the engine lists the step and greys it.
        var top = try #require(JSONSerialization.jsonObject(with: Fixture.data("shoot-bursts")) as? [String: Any])
        var steps = try #require(top["steps"] as? [[String: Any]])
        for i in steps.indices where steps[i]["id"] as? String == "reels" {
            steps[i]["enabled"] = false
            steps[i]["why_disabled"] = "reels are not part of this build"
        }
        top["steps"] = steps
        let response = try JSONDecoder().decode(ShootResponse.self,
                                                from: JSONSerialization.data(withJSONObject: top))
        let c = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"))
        app.library.adopt(ShootSession(response: response, ext: nil, client: c, pump: ImagePump(client: c)))

        #expect(!host.center.canRun(ID.cutAReel))
        #expect(host.center.canRun(ID.openInEditor), "the other pages are still live")
    }

    @Test("a page takes only its own press, for its own shoot, once")
    func takeOnce() {
        let p = PagePresses.shared
        p.ask(ID.openInEditor, shoot: "a", optionHeld: false)
        #expect(p.take([ID.cull, ID.cullAgain], shoot: "a") == nil)
        #expect(p.take([ID.openInEditor], shoot: "b") == nil)
        let taken = p.take([ID.openInEditor], shoot: "a")
        #expect(taken?.command == ID.openInEditor)
        #expect(taken?.optionHeld == false)
        #expect(p.take([ID.openInEditor], shoot: "a") == nil)
    }

    @Test("a press is dropped when he goes somewhere else before its page comes up")
    func droppedWhenHeLeaves() {
        let p = PagePresses.shared
        p.ask(ID.cull, shoot: "a", optionHeld: true)
        p.forget(unlessOn: .step(shoot: "a", step: "cull"))
        #expect(p.pending?.optionHeld == true, "on its way to its page, kept")
        p.forget(unlessOn: .allShoots)
        #expect(p.pending == nil, "never saved up for his next visit")
    }

    /// Every row in the bar is either something the app registers — app-wide
    /// at launch, the light table's while it is up, the other screen's — or
    /// one of the few that are meant to be grey. The harness used to register
    /// stand-ins for the rest, so the pictures of the menus hid this.
    @Test("every ordinary row in the menu bar has something behind it in the app")
    func nothingDead() throws {
        let (host, _) = try GoMenuTests.host(selection: .step(shoot: "2026-09-13-dog", step: "keepers"))
        let c = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"))
        let session = ShootSession(response: try Fixture.decode(ShootResponse.self, "shoot-bursts"),
                                   ext: nil, client: c, pump: ImagePump(client: c))
        LightTableCommands.attach(ViewerModel(session: session, navigation: Navigation()), center: host.center)
        DisplayRegistration.register(director: Fake.director().0, center: host.center)

        let rows = CommandTable.allCommands.filter { !$0.isSubmenu && !$0.isSystemSubmenu }
            .filter { if case .system = $0.role { return false }; return true }
        let dead = Set(rows.map(\.id).filter { !host.center.isRegistered($0) })
        #expect(dead.isEmpty,
                "rows with nothing behind them: \(dead.map(\.rawValue).sorted())")
    }

    @Test("while his work runs a row that would add says so, as its page's button does")
    func rowsSayTheyAdd() throws {
        // It still asks when it adds, so the ellipsis ends the sentence.
        #expect(CommandHost.rowTitle("Cull Again…", adds: true) == Strings.Queue.addInsteadSpoken("Cull Again") + "…")
        #expect(CommandHost.rowTitle("Cull Again…", adds: false) == "Cull Again…")
        #expect(CommandHost.rowTitle("Cull It", adds: true) == Strings.Queue.addInsteadSpoken("Cull It"))
        let (host, _) = try GoMenuTests.host(selection: .step(shoot: "2026-09-19", step: "keepers"))
        #expect(host.center.title(ID.cullAgain) == Words.Shoot.cullAgain, "nothing of his runs")
        #expect(host.center.title(ID.cutAReel) == Words.Shoot.cutAReel, "off Reels it goes there and adds nothing")
        #expect(host.center.title(ID.writePresets) == Words.Shoot.writePresetsAgain,
                "written already, the press asks first, as Write Them Again… does")
        let (fresh, _) = try GoMenuTests.host(selection: .step(shoot: "2026-09-12-lounge", step: "keepers"))
        #expect(fresh.center.title(ID.writePresets) == Words.Shoot.writePresets, "none written: it just writes them")
    }

    @Test("the question a row that adds asks first names its button for what it does, as the page's button does")
    func againSheetsSayTheyAdd() {
        #expect(Strings.Cull.againConfirm(adds: false) == "Cull Again")
        #expect(Strings.Cull.againConfirm(adds: true) == StepPrimaryWords.label(Strings.Cull.again, adds: true),
                "it read Cull Again and put the re-cull in Up Next")
        #expect(Strings.Presets.againConfirm(adds: false) == Strings.Presets.againConfirm)
        #expect(Strings.Presets.againConfirm(adds: true) == StepPrimaryWords.label(Strings.Presets.again, adds: true))
    }
}
