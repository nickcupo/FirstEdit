import Foundation
import Testing
@testable import PipelineKit

/// Rule 5 with two windows: which screen counts as "displayed".
///
/// **The main window's stage remains the sole authority.** Not the picture
/// window, not "either", not "both".
///
/// - Not the picture window: its screen can be asleep, occluded by PhotoLab,
///   disconnected, or showing a contact sheet, so gating his verdicts on it
///   would make a verdict impossible to record for reasons he cannot see.
/// - Not "both": the picture window asks for a larger asset than the laptop and
///   lands later, so every verdict would slow to the slower screen and the gate
///   would depend on which display he happens to own.
/// - Not "either": that is a hole. A frame up on the external but not yet on
///   the laptop would pass while the control bar's label still read the
///   previous frame — a verdict taken against a caption naming a different
///   photograph.
@Suite("The display gate, with two windows", .serialized)
@MainActor
struct DisplayGateTwoWindowsTests {

    @Test("the picture window's report can never satisfy the gate")
    func pictureCannotSatisfyTheGate() async throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        let (d, _) = Fake.director()
        d.attach(table, session: session)
        d.open(on: nil)

        // The stage has drawn the first frame; he moves on.
        let first = session.currentStem!
        session.didDisplay(stem: first, generation: session.cursor.generation)
        let stale = session.cursor.generation
        session.nextFrame()
        let second = session.currentStem!

        // The big screen has caught up to the new frame. The laptop has not
        // drawn it at all.
        d.pictureDidDisplay(stem: second, generation: session.cursor.generation)
        #expect(d.pictureDisplayed?.stem == second)
        #expect(await session.keep() == .refused(Strings.Verdict.stillOpening))
        #expect(session.rows[second]?.override == nil)
        #expect(session.undo.steps.isEmpty)

        // Now the laptop's own picture lands, but late — for the frame he had
        // already left. The big screen is still showing the current one.
        session.didDisplay(stem: second, generation: stale)
        d.pictureDidDisplay(stem: second, generation: session.cursor.generation)
        #expect(await session.keep() == .refused(Strings.Verdict.notOnScreen))
        #expect(session.rows[second]?.override == nil)
        #expect(session.undo.steps.isEmpty)
        #expect(session.refusals[.verdict] == Strings.Verdict.notOnScreen)

        // And once the laptop has drawn it, the same press lands.
        session.didDisplay(stem: second, generation: session.cursor.generation)
        #expect(await session.keep() == .applied)
    }

    @Test("the picture window's report goes to the HUD and to measurement, and nowhere else")
    func reportIsForTheHUDOnly() throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        let (d, _) = Fake.director()
        d.attach(table, session: session)
        d.open(on: nil)

        let before = session.displayed?.stem
        d.pictureDidDisplay(stem: "TSC99999", generation: 12_345)
        // The session's own idea of what is on screen is untouched by a report
        // from a window on another desk.
        #expect(session.displayed?.stem == before)
        #expect(d.pictureDisplayed?.stem == "TSC99999")
    }

    @Test("a verdict is refused while a deck is running, before the gate is even consulted")
    func presentationRefusesFirst() async throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        let (d, _) = Fake.director()
        d.attach(table, session: session)
        // The frame is on screen and the gate would pass.
        session.didDisplay(stem: session.currentStem!, generation: session.cursor.generation)
        d.beginPresentation(.thisBurst)

        #expect(!d.allows(.keep))
        // The light table asks first, so nothing reaches the session at all.
        #expect(session.undo.steps.isEmpty)
        #expect(session.rows.values.allSatisfy { $0.override == nil })

        d.endPresentation()
        #expect(d.allows(.keep))
        #expect(await session.keep() == .applied)
    }

    @Test("the picture window never writes a verdict of its own, whatever happens to it")
    func windowWritesNothing() throws {
        let session = try Fake.shootSession()
        let table = FakeLightTable(shoot: session.name, stem: session.currentStem)
        let watcher = ScreenWatcher(fixed: Fake.docked)
        let (d, _) = Fake.director(Fake.docked, watcher: watcher)
        d.attach(table, session: session)

        d.open(on: nil)
        d.setMode(.wholeBurst)
        d.toggleHold()
        d.pictureDidDisplay(stem: session.currentStem!, generation: session.cursor.generation)
        d.beginPresentation(.thisBurst)
        d.presentationKey(.right)
        d.presentationKey(.escape)
        watcher.simulate(Fake.undocked)
        watcher.simulate(Fake.docked)
        d.close()

        #expect(session.undo.steps.isEmpty)
        #expect(session.rows.values.allSatisfy { $0.override == nil })
        #expect(session.bursts.allSatisfy { !$0.seen })
    }
}
