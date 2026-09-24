import Foundation
import Testing
@testable import PipelineKit

/// Copy the Card, as he meets it on a real evening (DESIGN.md §2.6).
@Suite("Copying the card", .serialized)
@MainActor
struct ImportStepTests {

    /// The library as the engine answered it, with these cards in.
    static func app(selection: SidebarSelection = .allShoots, cards: [String] = [],
                    patch: (inout [String: Any]) -> Void = { _ in }) throws -> AppModel {
        var top = try #require(JSONSerialization.jsonObject(with: Fixture.data("shoots")) as? [String: Any])
        top["cards"] = cards
        patch(&top)
        let r = try JSONDecoder().decode(ShootsResponse.self, from: JSONSerialization.data(withJSONObject: top))
        return AppModel(preview: Library(preview: r), state: .stopped, navigation: Navigation(selection: selection))
    }

    // MARK: - noticing the card

    @Test("the card watcher belongs to the app, not to the page that only a card can open")
    func watcherIsTheApps() throws {
        let app = try Self.app()
        #expect(app.importModel.app === app)
        // The harness and previews never watch the Mac they run on.
        #expect(!app.importModel.isWatching)
        app.importModel.watch()
        app.importModel.watch()
        #expect(app.importModel.isWatching)
    }

    @Test("a card that goes in while the light table has hidden the sidebar is said over the top of the window")
    func noticeWhenTheSidebarIsHidden() async throws {
        let app = try Self.app(selection: .step(shoot: "2026-09-19", step: "keepers"), cards: ["/Volumes/Untitled"])
        app.navigation.sidebarShown = false
        await app.importModel.cardsChanged(.mounted("/Volumes/Untitled"))
        #expect(app.importModel.notice == .init(line: Strings.Import.cardIsIn("Untitled"), card: "/Volumes/Untitled"))
        #expect(Strings.Import.cardIsIn("Untitled") == "Untitled is in. ⌘N to copy it.")
        // Never the window's banner, whose band pushes the light table down.
        #expect(app.banner == nil)
        #expect(app.navigation.selection == .step(shoot: "2026-09-19", step: "keepers"), "nothing moved him")
        // The card comes out: the line about it goes with it.
        await app.importModel.cardsChanged(.unmounted("/Volumes/Untitled"))
        #expect(app.importModel.notice == nil)
    }

    @Test("with the sidebar showing, its Memory Card row is the news and nothing else is said")
    func noNoticeWithTheSidebar() async throws {
        let app = try Self.app(cards: ["/Volumes/Untitled"])
        await app.importModel.cardsChanged(.mounted("/Volumes/Untitled"))
        #expect(app.importModel.notice == nil)
        #expect(app.banner == nil)
    }

    @Test("the line goes by itself, when he goes anywhere, or when he clicks it, which opens the card")
    func noticeGoes() async throws {
        let app = try Self.app(cards: ["/Volumes/Untitled"])
        let m = app.importModel
        m.noticeLasts = .milliseconds(20)
        app.navigation.sidebarShown = false
        await m.cardsChanged(.mounted("/Volumes/Untitled"))
        #expect(m.notice != nil)
        // However long a busy run takes to wake the line's timer.
        for _ in 0..<100 where m.notice != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(m.notice == nil, "it went by itself")

        m.noticeLasts = .seconds(60)
        await m.cardsChanged(.mounted("/Volumes/Untitled"))
        m.navigated()
        #expect(m.notice == nil, "he went somewhere")

        await m.cardsChanged(.mounted("/Volumes/Untitled"))
        m.openNotice()
        #expect(m.notice == nil)
        #expect(app.navigation.selection == .card("/Volumes/Untitled"))

        // Arriving at the card page spends it; the engine's own line is not
        // the card's to take back.
        app.navigation.selection = .allShoots
        await m.cardsChanged(.mounted("/Volumes/Untitled"))
        app.banner = Strings.Engine.restarted
        m.arrived()
        #expect(m.notice == nil)
        #expect(app.banner == Strings.Engine.restarted)
    }

    // MARK: - one card's page

    static let a = "/Volumes/Untitled"
    static let b = "/Volumes/Untitled 1"

    /// An app with a scratch store for his habits and nothing that can reach
    /// an engine or unmount a volume.
    static func quiet(selection: SidebarSelection = .allShoots, cards: [String] = [a, b],
                      ejected: Box<[String]> = Box([])) throws -> AppModel {
        let app = try Self.app(selection: selection, cards: cards)
        let m = app.importModel
        // One scratch domain, emptied each time: the suite runs one test at
        // a time, and a domain per test would leave a file behind for each.
        let scratch = "photopipeline.tests.import"
        let defaults = UserDefaults(suiteName: scratch)!
        defaults.removePersistentDomain(forName: scratch)
        m.settings = SettingsStore(defaults: defaults)
        m.ejectCard = { path in ejected.value.append(path); return nil }
        m.startNow = { _ in 41 }
        m.putOnTheList = { _ in 42 }
        return app
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// Lets the tasks a job's ending starts run to their end.
    static func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    static func ended(id: Int, shoot: String, code: Int?, stopped: Bool = false, log: String = "") -> Job {
        Job(running: false, stopped: stopped, id: id, kind: "ingest", shoot: shoot,
            title: "copying the card into \(shoot)", log: log, code: code)
    }

    @Test("the page is the card chosen in the sidebar, and with none chosen the first that is in")
    func pageFollowsTheSidebar() throws {
        let app = try Self.quiet()
        let m = app.importModel
        #expect(m.volume(for: .card(Self.b), cards: [Self.a, Self.b]) == Self.b)
        #expect(m.volume(for: .card(""), cards: [Self.a, Self.b]) == Self.a, "⌘N with no card chosen")
        #expect(m.volume(for: .card("/Volumes/Gone"), cards: [Self.a]) == Self.a)
        #expect(m.volume(for: .card(""), cards: []) == "")
    }

    @Test("pressing Copy while his cull runs puts the copy on the list rather than waiting inside the page")
    func copyGoesOnTheList() async throws {
        let app = try Self.quiet(selection: .card(Self.a))
        let m = app.importModel
        let sent = Box<IngestBody?>(nil)
        var started = false
        m.putOnTheList = { body in sent.value = body; return 42 }
        m.startNow = { _ in started = true; return 41 }

        await m.start(card: Self.a, name: "2026-09-23-night", verify: "end", kind: "theirs", addToTheList: true)
        #expect(!started)
        #expect(m.copies[Self.a] == .init(card: Self.a, shoot: "2026-09-23-night", verify: "end", kind: "theirs",
                                          id: 42, listed: true))
        // The copy's own route, told to list it, so the extension's kind goes
        // with it rather than being read as the kind of work.
        let body = try #require(sent.value)
        #expect(body.queue == true)
        #expect(body.card == Self.a && body.name == "2026-09-23-night")
        #expect(body.verify == "end" && body.kind == "theirs")
        #expect(m.listedNote != nil)
        // Pressing again on the same card is not a second copy of it.
        await m.start(card: Self.a, name: "2026-09-23-other", verify: "end", kind: nil, addToTheList: true)
        #expect(m.copies[Self.a]?.shoot == "2026-09-23-night")
    }

    @Test("a copy the engine refused at the press leaves the form as it was")
    func refusedAtThePress() async throws {
        let app = try Self.quiet(selection: .card(Self.a))
        app.importModel.startNow = { _ in nil }
        await app.importModel.start(card: Self.a, name: "2026-09-23", verify: "in-flight", kind: nil, addToTheList: false)
        #expect(app.importModel.copies.isEmpty)
        #expect(app.importModel.endings.isEmpty)
    }

    @Test("the card that was copied is the one ejected when the copy ends, on whatever page he is")
    func ejectsTheCardCopied() async throws {
        let ejected = Box<[String]>([])
        let app = try Self.quiet(selection: .card(Self.a), ejected: ejected)
        let m = app.importModel
        m.ejectAfter = true
        await m.start(card: Self.a, name: "2026-09-23-night", verify: "in-flight", kind: nil, addToTheList: false)
        #expect(m.copies[Self.a]?.id == 41)

        // He picks the other card, then goes off to his keepers.
        app.navigation.selection = .card(Self.b)
        app.navigation.selection = .step(shoot: "2026-09-19", step: "keepers")
        m.jobEnded(Self.ended(id: 41, shoot: "2026-09-23-night", code: 0))
        await Self.settle()

        #expect(ejected.value == [Self.a], "the card copied, never the one on screen")
        #expect(m.copies.isEmpty)
        #expect(m.endings[Self.a]?.outcome == .done)
        #expect(m.endings[Self.a]?.eject == .done)
        // He is told at the top of the window, with the copy's own sentence.
        let notice = try #require(m.notice)
        #expect(notice.line.contains("2026-09-23-night"))
        #expect(notice.line.contains(Strings.Import.ejected))
        #expect(notice.card == Self.a)
        #expect(app.banner == nil)
        // And the card page, when he gets there, is the result: the line is spent.
        m.arrived()
        #expect(m.notice == nil)
        #expect(m.volume(for: .card(""), cards: [Self.b]) == Self.b)
    }

    @Test("Eject after copying is read when the copy ends, so turning it off while it runs counts")
    func ejectIsReadAtTheEnd() async throws {
        let ejected = Box<[String]>([])
        let app = try Self.quiet(selection: .card(Self.a), ejected: ejected)
        let m = app.importModel
        m.ejectAfter = true
        await m.start(card: Self.a, name: "2026-09-23-night", verify: "in-flight", kind: nil, addToTheList: false)
        m.ejectAfter = false
        m.jobEnded(Self.ended(id: 41, shoot: "2026-09-23-night", code: 0))
        await Self.settle()
        #expect(ejected.value.isEmpty)
        #expect(m.endings[Self.a]?.eject == .notAsked)
        // On the card's own page, nothing is said at the top of the window.
        #expect(app.importModel.notice == nil)
    }

    @Test("a copy that fails part way ends with its own words, ejects nothing, and frees the page")
    func failedCopy() async throws {
        let ejected = Box<[String]>([])
        let app = try Self.quiet(selection: .allShoots, ejected: ejected)
        let m = app.importModel
        m.ejectAfter = true
        await m.start(card: Self.a, name: "2026-09-23-night", verify: "in-flight", kind: nil, addToTheList: false)
        // The card comes out while it copies.
        await m.cardsChanged(.unmounted(Self.a))
        #expect(m.copies[Self.a]?.cardCameOut == true)
        let log = "$ ingest.py\ncopying 1558 files\n@@ copy 410 1558\nTraceback (most recent call last):\n"
            + "FileNotFoundError: [Errno 2] No such file or directory: '/Volumes/Untitled/DCIM/100MSDCF/DSC0124.ARW'"
        m.jobEnded(Self.ended(id: 41, shoot: "2026-09-23-night", code: 1, log: log))
        await Self.settle()

        let e = try #require(m.endings[Self.a])
        #expect(e.outcome == .failed)
        #expect(e.cardCameOut)
        #expect(e.sentence == nil, "an exception is never the sentence")
        #expect(ejected.value.isEmpty)
        #expect(m.notice?.line == Strings.Import.didNotFinish("2026-09-23-night"))
        #expect(m.copy(for: Self.a) == nil)
        // With no card in, the card page is still about that copy.
        #expect(m.volume(for: .card(""), cards: []) == Self.a)
    }

    @Test("a copy he stopped, and one the engine refused with a sentence, say which")
    func stoppedAndRefused() async throws {
        let app = try Self.quiet(selection: .card(Self.a))
        let m = app.importModel
        await m.start(card: Self.a, name: "one", verify: "in-flight", kind: nil, addToTheList: false)
        m.jobEnded(Self.ended(id: 41, shoot: "one", code: nil, stopped: true))
        await Self.settle()
        #expect(m.endings[Self.a]?.outcome == .stopped)
        #expect(CardPage.why(try #require(m.endings[Self.a])) == Strings.Import.youStopped)

        m.startNow = { _ in 43 }
        await m.start(card: Self.a, name: "two", verify: "in-flight", kind: nil, addToTheList: false)
        #expect(m.endings[Self.a] == nil, "a new copy of the card clears the last one's ending")
        let room = "not enough room on Macintosh HD for the copy of 1558 files: 31.0 GB free, 40.2 GB needed"
        m.jobEnded(Self.ended(id: 43, shoot: "two", code: 1, log: "$ ingest.py\n\n" + room))
        await Self.settle()
        #expect(m.endings[Self.a]?.outcome == .refused)
        #expect(CardPage.why(try #require(m.endings[Self.a])) == room)
    }

    @Test("a copy left on the list that the engine skipped, because its card was out, ends with the engine's words")
    func skippedOnTheList() async throws {
        let app = try Self.quiet(selection: .card(Self.a))
        let m = app.importModel
        await m.start(card: Self.a, name: "2026-09-23-night", verify: "in-flight", kind: nil, addToTheList: true)
        let why = "Untitled is not in this Mac any more"
        m.listChanged(QueueState(waiting: [], skipped: [QueueSkipped(id: 42, kind: "ingest", shoot: "2026-09-23-night",
                                                                     whyNot: why)]))
        #expect(m.copies.isEmpty)
        #expect(m.endings[Self.a]?.sentence == why)
        #expect(m.listedNote == nil)
    }

    @Test("another card going in where the last one was is a new page: the last card's result goes with it")
    func newCardAtTheSamePlace() async throws {
        let app = try Self.quiet(selection: .card(Self.a), cards: [Self.a])
        let m = app.importModel
        m.preview(ending: .done, card: Self.a, shoot: "2026-09-19")
        m.preview(scan: CardScan(photographs: 1_558, day: "2026-09-19"), for: Self.a)
        let before = m.generation[Self.a, default: 0]
        await m.cardsChanged(.mounted(Self.a))
        #expect(m.endings[Self.a] == nil)
        #expect(m.scans[Self.a] == nil, "tonight's card is read afresh")
        #expect(m.generation[Self.a, default: 0] == before + 1)
        #expect(app.navigation.selection == .card(Self.a))
    }

    @Test("a card put back in after a copy it left early still shows that copy, so the same name is not a surprise")
    func cardPutBack() async throws {
        let app = try Self.quiet(selection: .card(Self.a), cards: [Self.a])
        let m = app.importModel
        m.preview(ending: .failed, card: Self.a, shoot: "2026-09-23-night", cardCameOut: true)
        await m.cardsChanged(.mounted(Self.a))
        #expect(m.endings[Self.a]?.shoot == "2026-09-23-night", "what reached the shoot, and that it needs a new name")
        // A copy of it that starts is the end of that.
        await m.start(card: Self.a, name: "2026-09-23-night-2", verify: "in-flight", kind: nil, addToTheList: false)
        #expect(m.endings[Self.a] == nil)
    }

    @Test("a card is read the moment it goes in, once, and the page waits for that read rather than starting another")
    func readOnMount() async throws {
        let app = try Self.quiet(selection: .allShoots, cards: [Self.a])
        let m = app.importModel
        let reads = Box(0)
        m.readCard = { _ in reads.value += 1; return CardScan(photographs: 1_558, day: "2026-09-19") }
        #expect(!m.hasRead(Self.a))
        await m.cardsChanged(.mounted(Self.a))
        // The page arrives while the read may still be out.
        await m.scan(Self.a)
        await m.scan(Self.a)
        #expect(m.scans[Self.a]?.day == "2026-09-19")
        #expect(m.hasRead(Self.a))
        #expect(reads.value == 1)

        // A card with nothing the copy would take is read, and found empty.
        await m.cardsChanged(.unmounted(Self.a))
        m.readCard = { _ in reads.value += 1; return nil }
        await m.cardsChanged(.mounted(Self.a))
        await m.scan(Self.a)
        #expect(m.scans[Self.a] == nil)
        #expect(m.hasRead(Self.a), "so the page falls back to the Mac's date")
        #expect(reads.value == 2)
    }

    @Test("a card going in while the card page is up becomes the page, unless that page is watching a copy")
    func newCardIsChosen() async throws {
        let app = try Self.quiet(selection: .card(Self.a))
        await app.importModel.cardsChanged(.mounted(Self.b))
        #expect(app.navigation.selection == .card(Self.b))

        let busy = try Self.quiet(selection: .card(Self.a))
        busy.importModel.preview(copy: .init(card: Self.a, shoot: "2026-09-23-night", verify: "in-flight", id: 41))
        await busy.importModel.cardsChanged(.mounted(Self.b))
        #expect(busy.navigation.selection == .card(Self.a), "the copy he is watching stays in front of him")
    }

    @Test("the line at the top of the window names the shoot and the copy's own sentence")
    func headline() throws {
        let app = try Self.quiet()
        let row = try #require(app.library.row(named: "2026-09-19"))
        app.importModel.preview(ending: .done, card: Self.a, shoot: "2026-09-19", eject: .failed("it is busy"))
        let e = try #require(app.importModel.endings[Self.a])
        let line = ImportModel.headline(e, row: row)
        #expect(line.hasPrefix("2026-09-19: "))
        #expect(line.contains("verified byte for byte, both sides"))
        #expect(line.hasSuffix(Strings.Import.ejectFailed("it is busy")))
    }

    @Test("the extension's kind question starts on the kind of his newest shoot, not on no")
    func kindStartsOnHisNewest() throws {
        let app = try Self.app()
        let shoots = app.library.shoots
        // Newest by the day the name starts with: 2026-09-21 is "other", and
        // an undated name at the top of the list does not count.
        #expect(CardPage.newestIsTheExtensions(ext: ExtConfig(kind: "other"), shoots: shoots))
        #expect(!CardPage.newestIsTheExtensions(ext: ExtConfig(kind: "redacted"), shoots: shoots))
        let his = shoots.filter { $0.name != "2026-09-21" }
        #expect(CardPage.newestIsTheExtensions(ext: ExtConfig(kind: "redacted"), shoots: his))
        #expect(!CardPage.newestIsTheExtensions(ext: nil, shoots: his))
        #expect(!CardPage.newestIsTheExtensions(ext: ExtConfig(kind: ""), shoots: his))
    }

    @Test("a copy off his list is running once its turn comes, and ends like any other")
    func listedCopyRuns() async throws {
        let app = try Self.quiet(selection: .card(Self.a))
        let m = app.importModel
        await m.start(card: Self.a, name: "2026-09-23-night", verify: "in-flight", kind: nil, addToTheList: true)
        #expect(m.job(for: Self.a) == nil)
        let running = Job(running: true, stopped: false, id: 42, kind: "ingest", shoot: "2026-09-23-night",
                          title: "copying the card into 2026-09-23-night", fraction: 0.1, elapsed: 9)
        app.jobs.take(running)
        #expect(m.job(for: Self.a) == running)
        m.jobEnded(Self.ended(id: 42, shoot: "2026-09-23-night", code: 0))
        await Self.settle()
        #expect(m.endings[Self.a]?.copied == true)
        #expect(m.listedNote == nil)
    }

    // MARK: - a copy the app lost sight of

    @Test("a copy the engine restarted under ends, rather than saying Copying for the rest of the evening")
    func engineRestartedUnderACopy() async throws {
        let app = try Self.quiet(selection: .card(Self.a))
        let m = app.importModel
        await m.start(card: Self.a, name: "2026-09-23-night", verify: "in-flight", kind: nil, addToTheList: false)
        #expect(m.copies[Self.a]?.id == 41)
        m.engineRestarted()
        await Self.settle()
        #expect(m.copies.isEmpty)
        let e = try #require(m.endings[Self.a])
        #expect(e.unseen && e.engineRestarted)
        #expect(e.outcome == .failed)
        #expect(CardPage.why(e) == Strings.Import.engineStopped)
        // The card is still in: the form is back, and pressing Copy is a copy.
        await m.start(card: Self.a, name: "2026-09-23-night-2", verify: "in-flight", kind: nil, addToTheList: false)
        #expect(m.copies[Self.a]?.shoot == "2026-09-23-night-2")
    }

    @Test("a fresh engine's empty answer about the slot ends a copy it is not running")
    func idleAnswerEndsACopy() async throws {
        let app = try Self.quiet(selection: .card(Self.a))
        let m = app.importModel
        await m.start(card: Self.a, name: "2026-09-23-night", verify: "in-flight", kind: nil, addToTheList: false)
        app.jobs.take(Job(running: false, stopped: false))
        await Self.settle()
        #expect(m.copies.isEmpty)
        let e = try #require(m.endings[Self.a])
        #expect(e.unseen && !e.engineRestarted)
        #expect(!e.copied(row: app.library.row(named: e.shoot)))
    }

    @Test("a copy that ended between two reads while other work took the slot ends by its shoot's own note")
    func missedEndReadsTheNote() async throws {
        let ejected = Box<[String]>([])
        let app = try Self.quiet(selection: .allShoots, ejected: ejected)
        let m = app.importModel
        m.ejectAfter = true
        // A shoot whose own log says the copy finished.
        await m.start(card: Self.a, name: "2026-09-19", verify: "end", kind: nil, addToTheList: false)
        app.jobs.take(Job(running: true, stopped: false, id: 41, kind: "ingest", shoot: "2026-09-19",
                          title: "copying the card into 2026-09-19", fraction: 0.9, elapsed: 300))
        #expect(m.copies[Self.a]?.began == true)
        app.jobs.take(Job(running: true, stopped: false, id: 43, kind: "cull", shoot: "2026-09-18",
                          title: "culling 2026-09-18", fraction: 0.01, elapsed: 1))
        await Self.settle()
        let e = try #require(m.endings[Self.a])
        #expect(e.outcome == .done)
        #expect(e.unseen)
        #expect(ejected.value == [Self.a], "a copy its own log says finished is ejected as he asked")
    }

    @Test("a copy waiting on the list is left alone by other work, and by a restart, because the list is kept")
    func listedCopyIsLeftAlone() async throws {
        let app = try Self.quiet(selection: .card(Self.a))
        let m = app.importModel
        await m.start(card: Self.a, name: "2026-09-23-night", verify: "in-flight", kind: nil, addToTheList: true)
        app.jobs.take(Job(running: true, stopped: false, id: 6, kind: "cull", shoot: "2026-09-19",
                          title: "culling 2026-09-19", fraction: 0.3, elapsed: 90))
        m.engineRestarted()
        await Self.settle()
        #expect(m.copies[Self.a]?.id == 42)
        #expect(m.endings.isEmpty)
    }

    @Test("Stop on the card page stops that copy by its number, and nothing when the engine is not running it")
    func stopIsTheCopys() async throws {
        let app = try Self.quiet(selection: .card(Self.a))
        let m = app.importModel
        let stopped = Box<[Int?]>([])
        m.stopJob = { id in stopped.value.append(id) }
        await m.start(card: Self.a, name: "2026-09-23-night", verify: "in-flight", kind: nil, addToTheList: false)
        // Before the engine has said anything about it: nothing to stop.
        await m.stop(Self.a)
        #expect(stopped.value.isEmpty)
        app.jobs.take(Job(running: true, stopped: false, id: 41, kind: "ingest", shoot: "2026-09-23-night",
                          title: "copying the card into 2026-09-23-night", fraction: 0.2, elapsed: 60))
        await m.stop(Self.a)
        #expect(stopped.value == [41])
        // His cull runs where the copy was: the copy's Stop does not reach it.
        app.jobs.take(Job(running: true, stopped: false, id: 44, kind: "cull", shoot: "2026-09-19",
                          title: "culling 2026-09-19", fraction: 0.1, elapsed: 5))
        await m.stop(Self.a)
        #expect(stopped.value == [41])
    }

    @Test("the kind a copy was sent with is its own, shown while it runs")
    func copyKeepsItsKind() async throws {
        let app = try Self.quiet(selection: .card(Self.a))
        await app.importModel.start(card: Self.a, name: "one", verify: "end", kind: nil, addToTheList: false)
        #expect(app.importModel.copies[Self.a]?.kind == nil)
        await app.importModel.start(card: Self.b, name: "two", verify: "end", kind: "theirs", addToTheList: false)
        #expect(app.importModel.copies[Self.b]?.kind == "theirs")
    }

    @Test("a shoot's own Copy the Card step makes Cull the Return key only when its copy was not cut short")
    func reportPrimary() throws {
        func info(_ ingest: String) throws -> ShootInfo {
            try JSONDecoder().decode(ShootInfo.self, from: Data(
                #"{"name": "2026-09-23-night", "path": "/s", "frames": 412, "ingest": \#(ingest)}"#.utf8))
        }
        #expect(!ImportReport.unproved(try info(#"{"state": "done", "files": 1558, "proof": "verified"}"#)))
        #expect(ImportReport.unproved(try info(#"{"state": "stopped", "files": 412, "of": 1558}"#)))
        #expect(ImportReport.unproved(try info(#"{"state": "failed", "detail": "DSC0124.ARW"}"#)))
        #expect(ImportReport.unproved(try info(#"{"state": "unclear", "log": "ingest.log"}"#)))
        // Copied before copies kept a log: not one of the three.
        #expect(!ImportReport.unproved(try info("{}")))
    }
}
