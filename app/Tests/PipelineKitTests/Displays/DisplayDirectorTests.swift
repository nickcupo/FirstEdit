import Foundation
import CoreGraphics
import Testing
@testable import PipelineKit

@Suite("The second screen, and what it can never cost him", .serialized)
@MainActor
struct DisplayDirectorTests {

    // MARK: - opening on the right screen

    @Test("it opens on the big screen when there is one, and never by itself")
    func opensOnTheExternal() {
        let (d, _) = Fake.director()
        #expect(d.presence == .closed)
        // Opening is always his action.
        d.toggleWindow()
        #expect(d.presence == .open(Fake.externalKey))
        #expect(d.fills)
        d.toggleWindow()
        #expect(d.presence == .closed)
    }

    @Test("with one display it opens a floating window rather than lying about the other screen")
    func oneDisplay() {
        let (d, _) = Fake.director(Fake.undocked)
        d.open(on: nil)
        #expect(d.presence == .open(Fake.laptopKey))
        // Not filling: the light table underneath has to stay reachable.
        #expect(!d.fills)
    }

    @Test("a screen it has never been used on never gets a window thrown at it")
    func neverAutoOpensOnANewScreen() {
        let settings = Fake.settings()
        let watcher = ScreenWatcher(fixed: Fake.undocked)
        let (d, _) = Fake.director(Fake.undocked, settings: settings, watcher: watcher)
        watcher.simulate(ScreenSet(screens: [Fake.laptop, Fake.projector]))
        #expect(d.presence == .closed)
        #expect(d.note == nil)
    }

    // MARK: - unplugging it mid-burst (§3.7)

    @Test("the screen goes away mid-burst and nothing of his moves")
    func disconnect() throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        let watcher = ScreenWatcher(fixed: Fake.docked)
        let (d, _) = Fake.director(Fake.docked, watcher: watcher)
        d.attach(table, session: session)
        d.open(on: nil)
        d.setMode(.wholeBurst)
        d.toggleHold()

        let cursorBefore = session.cursor
        let undoBefore = session.undo.steps.count
        let seenBefore = session.bursts.map(\.seen)

        watcher.simulate(Fake.undocked)

        #expect(d.presence == .closed)
        // One sentence, in ordinary words, and no alert of any kind.
        #expect(d.note == DisplayStrings.Note.screenWentAway)
        // Nothing of his moved.
        #expect(session.cursor == cursorBefore)
        #expect(session.undo.steps.count == undoBefore)
        #expect(session.bursts.map(\.seen) == seenBefore)
        // The mode and the fill flag were written before they could be lost.
        #expect(d.mode == .wholeBurst)
    }

    @Test("it comes back on the same screen, in the same mode, showing the frame he is on now")
    func reconnect() throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        let watcher = ScreenWatcher(fixed: Fake.docked)
        let (d, _) = Fake.director(Fake.docked, watcher: watcher)
        d.attach(table, session: session)
        d.open(on: nil)
        d.setMode(.frame)
        watcher.simulate(Fake.undocked)
        #expect(d.presence == .closed)

        // He has moved on while it was gone.
        session.nextFrame()
        table.go(to: session.currentStem!, index: 2, of: 7, burst: 3)

        watcher.simulate(Fake.docked)
        #expect(d.presence == .open(Fake.externalKey))
        #expect(d.mode == .frame)
        #expect(d.note == DisplayStrings.Note.screenIsBack)
        // The frame he is on now, not the one he was on when it vanished.
        #expect(d.content.stem == session.currentStem)
    }

    @Test("fifty unplug-and-plug cycles mid-burst cost him nothing at all")
    func fiftyCycles() throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        let watcher = ScreenWatcher(fixed: Fake.docked)
        let (d, _) = Fake.director(Fake.docked, watcher: watcher)
        d.attach(table, session: session)
        d.open(on: nil)

        let cursorBefore = session.cursor
        let undoBefore = session.undo.steps
        let seenBefore = session.bursts.map(\.seen)
        var notes = 0

        for _ in 0..<50 {
            watcher.simulate(Fake.undocked)
            if d.note != nil { notes += 1 }
            d.clearNote()
            watcher.simulate(Fake.docked)
            d.clearNote()
        }

        #expect(notes == 50)
        #expect(session.cursor == cursorBefore)
        #expect(session.undo.steps.map(\.id) == undoBefore.map(\.id))
        #expect(session.bursts.map(\.seen) == seenBefore)
        #expect(session.rows.values.allSatisfy { $0.override == nil })
    }

    @Test("the setting turns reopening off without turning anything else off")
    func reopenSetting() throws {
        let settings = Fake.settings()
        settings.bringThePictureBack = false
        let watcher = ScreenWatcher(fixed: Fake.docked)
        let (d, _) = Fake.director(Fake.docked, settings: settings, watcher: watcher)
        d.open(on: nil)
        watcher.simulate(Fake.undocked)
        watcher.simulate(Fake.docked)
        #expect(d.presence == .closed)
        // And it still opens when he asks.
        d.toggleWindow()
        #expect(d.presence == .open(Fake.externalKey))
    }

    @Test("the lid closes with the external attached and the picture un-fills so he can reach the light table")
    func clamshell() {
        let watcher = ScreenWatcher(fixed: Fake.docked)
        let (d, _) = Fake.director(Fake.docked, watcher: watcher)
        d.open(on: nil)
        #expect(d.fills)
        // The built-in leaves the list; macOS moves the main window to the
        // external, so both windows are on one screen.
        watcher.simulate(ScreenSet(screens: [Fake.info(Fake.externalKey, "External 5K Panel",
                                                        CGSize(width: 2560, height: 1440),
                                                        builtIn: true)]))
        #expect(!d.fills)
        #expect(d.note == DisplayStrings.Note.oneScreenNow)
        // Nothing was closed.
        #expect(d.isOpen)
    }

    @Test("a sleeping screen is not an event: nothing is announced and nothing is drawn")
    func asleep() {
        let watcher = ScreenWatcher(fixed: Fake.docked)
        let (d, _) = Fake.director(Fake.docked, watcher: watcher)
        d.open(on: nil)
        d.clearNote()
        let sleeping = Fake.info(Fake.externalKey, "External 5K Panel",
                                 CGSize(width: 2560, height: 1440), builtIn: false,
                                 origin: CGPoint(x: 1512, y: 0), asleep: true)
        watcher.simulate(ScreenSet(screens: [Fake.laptop, sleeping]))
        #expect(d.isOpen)
        #expect(d.note == nil)
    }

    // MARK: - Compare (§5.1)

    @Test("Compare goes to the big screen only when it is open and he has not said otherwise")
    func compareTarget() throws {
        let settings = Fake.settings()
        let (d, _) = Fake.director(Fake.docked, settings: settings)
        #expect(d.compareTarget == .mainWindow)
        d.open(on: nil)
        #expect(d.compareTarget == .pictureWindow)
        settings.compareOnTheOtherScreen = false
        #expect(d.compareTarget == .mainWindow)
        settings.compareOnTheOtherScreen = true
        let session = try Fake.shootSession()
        d.attach(FakeLightTable(shoot: session.name, stem: session.currentStem), session: session)
        d.beginPresentation(.thisBurst)
        // While a deck is running the light table is frozen, so Compare has
        // nowhere to go but the main window.
        #expect(d.compareTarget == .mainWindow)
    }

    // MARK: - the modes (§1.3)

    @Test("Follow shows whatever the light table is doing, bigger")
    func follow() throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        table.burstCells = [BurstCell(stem: "a", shortStem: "1", his: .unmarked, cull: .none)]
        table.compareTiles = [CompareTile(stem: "a", caption: table.currentCaption!),
                              CompareTile(stem: "b", caption: table.currentCaption!)]
        let (d, _) = Fake.director()
        d.attach(table, session: session)
        d.open(on: nil)

        #expect(d.content.stem == session.currentStem)
        table.lightTableMode = .compare
        if case .tiles(let tiles, _, _) = d.content { #expect(tiles.count == 2) } else { Issue.record("not tiles") }
        // All Bursts on the laptop is the whole burst here, not the cover grid:
        // covers are for aiming and aiming is on the laptop.
        table.lightTableMode = .allBursts
        if case .burst(_, let cells, _) = d.content { #expect(cells.count == 1) } else { Issue.record("not a burst") }
    }

    @Test("Always the Frame never changes shape, whatever the laptop does")
    func alwaysTheFrame() throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        table.compareTiles = [CompareTile(stem: "a", caption: table.currentCaption!)]
        let (d, _) = Fake.director()
        d.attach(table, session: session)
        d.open(on: nil)
        d.setMode(.frame)
        for mode in LightTableMode.allCases {
            table.lightTableMode = mode
            #expect(d.content.stem == session.currentStem)
        }
    }

    @Test("the mode is remembered per screen, so a projector cannot disturb the one he uses")
    func modePerScreen() {
        let settings = Fake.settings()
        let watcher = ScreenWatcher(fixed: ScreenSet(screens: [Fake.laptop, Fake.external, Fake.projector]))
        let (d, _) = Fake.director(settings: settings, watcher: watcher)
        d.open(on: Fake.externalKey)
        d.setMode(.wholeBurst)
        d.open(on: Fake.projectorKey)
        #expect(d.mode == .follow)
        d.setMode(.frame)
        d.open(on: Fake.externalKey)
        #expect(d.mode == .wholeBurst)
    }

    // MARK: - Hold (§1.3)

    @Test("Hold freezes the frame and the laptop keeps moving")
    func hold() throws {
        let session = try Fake.shootSession()
        let first = session.currentStem!
        let table = FakeLightTable(shoot: session.name, stem: first)
        let (d, _) = Fake.director()
        d.attach(table, session: session)
        d.open(on: nil)

        d.toggleHold()
        #expect(d.heldStem == first)

        session.nextFrame()
        table.go(to: session.currentStem!, index: 2, of: 7, burst: 3)
        d.refresh()
        // The big screen is still on the one he kept.
        #expect(d.content.stem == first)
        // And the laptop has moved on.
        #expect(session.currentStem != first)

        d.toggleHold()
        #expect(d.heldStem == nil)
        #expect(d.content.stem == session.currentStem)
    }

    @Test("Esc releases a hold, and only when there is one")
    func escapeReleasesHold() throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        let (d, _) = Fake.director()
        d.attach(table, session: session)
        d.open(on: nil)
        #expect(!d.escapeReleasesHold())
        d.toggleHold()
        #expect(d.escapeReleasesHold())
        #expect(d.heldStem == nil)
    }

    @Test("closing the window releases the hold and writes nothing")
    func closeReleasesHold() throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        let (d, _) = Fake.director()
        d.attach(table, session: session)
        d.open(on: nil)
        d.toggleHold()
        d.close()
        #expect(d.heldStem == nil)
        #expect(session.undo.steps.isEmpty)
        #expect(session.rows.values.allSatisfy { $0.override == nil })
    }

    // MARK: - Presentation (§5.6)

    @Test("Presentation refuses everything that decides anything, including N and P")
    func presentationRefuses() throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        let (d, _) = Fake.director()
        d.attach(table, session: session)
        d.beginPresentation(.thisBurst)
        #expect(d.isPresenting)

        for action in DisplayAction.allCases {
            #expect(d.allows(action) == !action.decidesSomething, "\(action)")
        }
        // N records "looked through", as leaving any burst forward does. A shoot must never
        // come back from being shown to someone with bursts newly marked as
        // looked through.
        #expect(!d.allows(.nextBurst))
        #expect(!d.allows(.previousBurst))
        #expect(!d.allows(.undo))
        #expect(d.refusalWhilePresenting == DisplayStrings.Refusal.nothingDecidedWhilePresenting)

        d.endPresentation()
        for action in DisplayAction.allCases { #expect(d.allows(action)) }
    }

    @Test("walking his keepers across the shoot moves nothing on the light table")
    func presentationHasItsOwnCursor() async throws {
        let session = try Fake.shootSession()
        // Keepers across several bursts, made the way he makes them: the frame
        // on screen, then K. The deck reads only his own field.
        var kept: [String] = []
        for (i, burst) in session.bursts.enumerated() where i % 2 == 0 {
            guard let stem = burst.frames.first else { continue }
            session.go(burst: i, frame: 0)
            session.didDisplay(stem: stem, generation: session.cursor.generation)
            #expect(await session.keep() == .applied)
            kept.append(stem)
        }
        session.go(burst: 0, frame: 0)

        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        let (d, _) = Fake.director()
        d.attach(table, session: session)

        let cursorBefore = session.cursor
        let reviewBefore = session.review.bursts.mapValues(\.seen)
        let seenBefore = session.bursts.map(\.seen)
        let undoBefore = session.undo.steps.count

        d.beginPresentation(.whatIKept)
        #expect(d.deck?.count == kept.count)
        // Right to the end and back, across every burst in the deck.
        for _ in 0..<(kept.count * 2) { d.presentationKey(.right) }
        for _ in 0..<5 { d.presentationKey(.down) }
        for _ in 0..<5 { d.presentationKey(.up) }
        d.presentationKey(.home)
        d.presentationKey(.end)
        d.presentationKey(.left)

        #expect(session.cursor == cursorBefore)
        #expect(session.review.bursts.mapValues(\.seen) == reviewBefore)
        #expect(session.bursts.map(\.seen) == seenBefore)
        #expect(session.undo.steps.count == undoBefore)

        d.presentationKey(.escape)
        #expect(!d.isPresenting)
        #expect(session.cursor == cursorBefore)
    }

    @Test("Esc ends it even when the app has no key window at all")
    func escapeAlwaysWorks() throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        let (d, _) = Fake.director()
        d.attach(table, session: session)
        d.beginPresentation(.thisBurst)
        // The watch the director installs is app-wide and arrives before
        // dispatch, so a Space switch that leaves no key window cannot strand a
        // guest in a chrome-less window.
        #expect(d.presentationKey(.escape))
        #expect(!d.isPresenting)
        // And once it is over, the watch does nothing.
        #expect(!d.presentationKey(.escape))
    }

    @Test("with nothing kept yet it shows this burst and says so")
    func nothingKeptYet() throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        let (d, _) = Fake.director()
        d.attach(table, session: session)
        d.beginPresentation(.whatIKept)
        #expect(d.note == DisplayStrings.Note.nothingKeptYet)
        #expect(d.deck?.kind == .thisBurst)
        #expect(d.deck?.count == session.currentBurst?.frames.count)
    }

    @Test("the deck stops at its ends rather than wrapping")
    func deckEnds() throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        let (d, _) = Fake.director()
        d.attach(table, session: session)
        d.beginPresentation(.wholeShoot)
        d.presentationKey(.home)
        #expect(d.deck?.index == 0)
        #expect(d.presentationKey(.left))          // handled…
        #expect(d.deck?.index == 0)                // …and it did not move.
        d.presentationKey(.end)
        let last = d.deck?.index
        d.presentationKey(.right)
        #expect(d.deck?.index == last)
    }

    @Test("the screen showing the pictures goes away and verdicts become possible again")
    func presentationScreenLost() throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        let watcher = ScreenWatcher(fixed: Fake.docked)
        let (d, _) = Fake.director(Fake.docked, watcher: watcher)
        d.attach(table, session: session)
        d.beginPresentation(.thisBurst)
        watcher.simulate(Fake.undocked)
        #expect(!d.isPresenting)
        #expect(d.note == DisplayStrings.Note.presentationScreenWentAway)
        #expect(d.allows(.keep))
    }

    // MARK: - what it shows when there is nothing to show (§1.5)

    @Test("the three quiet states")
    func nothingToShow() throws {
        let (d, _) = Fake.director()
        d.open(on: nil)
        #expect(d.content == .nothing(line: DisplayStrings.Picture.noShootOpen))

        let session = try Fake.shootSession()
        d.attach(FakeLightTable(shoot: session.name, stem: session.currentStem), session: session)
        // A shoot is open but he is not on Choose Keepers: the screen names it
        // and then goes quiet.
        d.detach()
        if case .nothing(let line) = d.content {
            #expect(line?.contains(session.name) == true)
        } else {
            Issue.record("expected one quiet line")
        }

        d.engineSentence = Strings.Engine.stopped
        #expect(d.content == .engineDown(sentence: Strings.Engine.stopped))
    }

    // MARK: - the debounce (§3.7)

    @Test("five hundred notifications in one dock event are one rebuild")
    func debounce() async {
        let watcher = ScreenWatcher(reading: { Fake.docked }, debounce: .milliseconds(60))
        let before = watcher.rebuilds
        for _ in 0..<500 { watcher.changed() }
        #expect(watcher.rebuilds == before)
        // However long a busy test run keeps the debounce from firing, then
        // as long again: one rebuild, never a second. A fixed 200 ms failed a
        // full run of a thousand tests with none yet.
        let deadline = ContinuousClock.now + .seconds(10)
        while watcher.rebuilds == before, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(watcher.rebuilds == before + 1)
    }

    // MARK: - memory on disk (§3.5)

    @Test("the mode survives a resolution change; the window frame does not claim to")
    func coarseMemory() {
        var memory = DisplayMemory()
        memory.remember(open: true, on: Fake.externalKey, mode: .wholeBurst, fills: true)
        let at4K = ScreenKey.make(displayID: 3, isBuiltIn: false, vendor: 0x1E6D, model: 0x5B11,
                                  serial: 0, unit: 1, physicalMM: CGSize(width: 597, height: 336),
                                  points: CGSize(width: 3840, height: 2160), scale: 2, name: "x")
        #expect(memory.panel(for: at4K)?.mode == .wholeBurst)
        // It does not claim the window was open in an arrangement it never was.
        #expect(!memory.wasOpen(on: at4K))
        #expect(memory.wasOpen(on: Fake.externalKey))
    }

    @Test("a hotel monitor does not live in his defaults forever")
    func pruning() {
        var memory = DisplayMemory()
        memory.entries["old"] = ScreenMemory(mode: .follow, fills: true, wasOpen: true,
                                             lastSeen: .now.addingTimeInterval(-200 * 24 * 3600))
        memory.entries["recent"] = ScreenMemory(mode: .follow, fills: true, wasOpen: true,
                                                lastSeen: .now)
        memory.prune()
        #expect(memory.entries["old"] == nil)
        #expect(memory.entries["recent"] != nil)
    }

    @Test("it survives a round trip through the defaults")
    func memoryRoundTrip() {
        let settings = Fake.settings()
        var memory = DisplayMemory()
        memory.remember(open: true, on: Fake.externalKey, mode: .frame, fills: false)
        memory.save(to: settings.defaults)
        let back = DisplayMemory.load(from: settings.defaults)
        #expect(back.panel(for: Fake.externalKey)?.mode == .frame)
        #expect(back.panel(for: Fake.externalKey)?.fills == false)
    }

    // MARK: - the menu (§3.10)

    @Test("every key this crew takes is taken once, and none of them lands in the ⌘-number range")
    func shortcuts() {
        let all = DisplayCommands.shortcuts
        #expect(Set(all).count == all.count)
        // Go already uses ⌘9 for an extension step while View uses ⌘9 for Zoom
        // to Fit. Nothing here is allowed to land near that.
        for s in all where s.modifiers == [.command] {
            #expect(Int(s.key) == nil, "\(s.key) is a bare command-number")
        }
        // H is a real menu key equivalent with an empty modifier mask, so it
        // shows in the menu, works with Full Keyboard Access and is rebindable.
        let hold = DisplayCommands.rows.first { $0.identifier == "displays.hold" }
        #expect(hold?.shortcut == .init("h"))
        #expect(hold?.menu == .frame)
    }

    @Test("every row has a title and every action has a row")
    func rowsAreComplete() {
        for row in DisplayCommands.rows {
            #expect(!row.title.isEmpty)
            #expect(!row.identifier.isEmpty)
        }
        let ids = Set(DisplayCommands.rows.map(\.identifier))
        #expect(ids.count == DisplayCommands.rows.count)
        for want in ["displays.toggle", "displays.hold", "displays.mode.follow",
                     "displays.mode.frame", "displays.mode.wholeBurst",
                     "displays.presentation.kept", "displays.theseScreens"] {
            #expect(ids.contains(want), "\(want)")
        }
    }
}
