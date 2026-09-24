import AppKit
import Foundation
import Testing
@testable import PipelineKit

/// Taking frames out of a reel (DESIGN.md §2.6): a run in one shift-click,
/// the peak of a burst in two keys, all out or all back in one press, and
/// what he took out survives looking at other bursts.
@Suite("Reels trimming", .serialized)
@MainActor
struct ReelsTrimTests {

    @Test("the frames he took out of a burst are still out when he looks at another and comes back")
    func trimSurvivesBrowsing() async throws {
        let m = ReelsScaffold.model()
        let answers = ["93": try ReelsScaffold.options(about: "93"), "94": try ReelsScaffold.options(about: "94")]
        m.fetchOptions = { _, b, _ in answers[b ?? "93"]! }
        m.burst = "93"
        m.load()
        for _ in 0..<200 where m.framesBurst != "93" { try await Task.sleep(for: .milliseconds(5)) }
        for s in ["B93F0", "B93F1", "B93F2"] { m.toggle(s) }
        #expect(m.chosen.count == 10)

        m.choose(burst: "94")
        for _ in 0..<200 where m.framesBurst != "94" { try await Task.sleep(for: .milliseconds(5)) }
        #expect(m.chosen.count == 13)                   // 94 is whole
        m.toggle("B94F5")
        m.putAllBack()                                  // 94's frames, and only 94's
        #expect(m.chosen.count == 13)

        m.choose(burst: "93")
        for _ in 0..<200 where m.framesBurst != "93" { try await Task.sleep(for: .milliseconds(5)) }
        #expect(m.chosen.count == 10 && !m.isIn("B93F0"))
        #expect(m.request["frames"] == .array((3..<13).map { .string("B93F\($0)") }))
    }

    @Test("I and O keep the peak of a burst: frames 4 to 9 of 13 in two presses")
    func inAndOut() throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.options(about: "93"), burst: "93")
        m.cursor = "B93F3"
        #expect(m.startHere())
        #expect(m.chosen == (3..<13).map { "B93F\($0)" })
        m.moveCursor(by: 5)
        #expect(m.endHere())
        #expect(m.chosen == (3...8).map { "B93F\($0)" })
        // Moving the start later keeps the end where it was.
        #expect(m.startHere("B93F5"))
        #expect(m.chosen == (5...8).map { "B93F\($0)" } && m.cursor == "B93F5")
        // An end after everything that is in reaches back to the start.
        #expect(m.endHere("B93F11"))
        #expect(m.chosen == (5...11).map { "B93F\($0)" })
        // A start after everything that is in runs to the end of the burst.
        m.leaveAllOut()
        #expect(m.startHere("B93F10"))
        #expect(m.chosen == (10..<13).map { "B93F\($0)" })
        let empty = ReelsScaffold.model()
        #expect(!empty.startHere() && !empty.endHere())
    }

    @Test("I and O leave a soft frame he took out by hand inside the reel out, and bring in only what they add")
    func inAndOutKeepHisOuts() throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.options(about: "93"), burst: "93")
        m.toggle("B93F5")                               // soft, taken out by hand
        #expect(m.endHere("B93F8"))
        #expect(m.chosen == [0, 1, 2, 3, 4, 6, 7, 8].map { "B93F\($0)" })
        #expect(m.startHere("B93F2"))
        #expect(m.chosen == [2, 3, 4, 6, 7, 8].map { "B93F\($0)" })
        // Reaching out again brings in the frames past the old ends, and
        // not the one he took out.
        #expect(m.endHere("B93F10") && m.startHere("B93F1"))
        #expect(m.chosen == [1, 2, 3, 4, 6, 7, 8, 9, 10].map { "B93F\($0)" })
        // The frame the reel is made to start or end on is in, even if he
        // had taken it out.
        #expect(m.startHere("B93F5"))
        #expect(m.chosen == (5...10).map { "B93F\($0)" })
    }

    @Test("a shift-click gives every frame from the last one clicked the clicked one's new state")
    func shiftClickRuns() throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.options(about: "93"), burst: "93")
        m.toggle("B93F0")                       // out, and the keys are on it
        m.toggleRun(to: "B93F2")                // 0 to 2 out: two presses, not three
        #expect(m.chosen == (3..<13).map { "B93F\($0)" })
        m.toggle("B93F12")
        m.toggleRun(to: "B93F9")                // backwards works the same
        #expect(m.chosen == (3...8).map { "B93F\($0)" })
        m.toggleRun(to: "B93F1")                // an out frame: the run, 9 back to 1, goes in
        #expect(m.chosen == (1...9).map { "B93F\($0)" })
    }

    @Test("Leave Them All Out, then a few clicks, keeps three of twenty-one")
    func leaveAllOut() throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.options(about: "7", frames: 21), burst: "7")
        m.leaveAllOut()
        #expect(m.chosen.isEmpty && !m.canCut)
        for s in ["B7F9", "B7F10", "B7F11"] { m.toggle(s) }
        #expect(m.chosen.count == 3 && m.canCut)
        m.putAllBack()
        #expect(m.chosen.count == 21)
    }

    @Test("a shift-click runs once, and never opens the frame or undoes itself")
    func shiftClickIsOneRun() throws {
        var runs = 0, toggles = 0, opens = 0
        let v = TileClicks.ClickView()
        v.toggle = { toggles += 1 }
        v.run = { runs += 1 }
        v.open = { opens += 1 }
        v.mouseDown(with: try click(1, shift: true))
        v.mouseDown(with: try click(2, shift: true))
        #expect(runs == 1 && toggles == 0 && opens == 0)
        v.mouseDown(with: try click(1))
        #expect(toggles == 1)
    }

    @Test("D in the frame seen large takes it out there and then, E and X put it back, and closing it leaves the keys on that frame")
    func dInTheViewer() throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.options(about: "93"), burst: "93")
        m.toggle("B93F0")
        m.openLarge("B93F4")
        let marking = m.lookMarking
        // No letter of its own: the scheme's E, D and X reach it.
        #expect(marking.actions.map(\.key) == [""])
        #expect(marking.verdicts == ExtViewerVerdicts(include: ReelsModel.inReelMark, leaveOut: nil,
                                                      clear: ReelsModel.inReelMark))
        #expect(ExtViewerKeys.action(.init("d"), marking: marking) == .leaveOut)
        #expect(ExtViewerKeys.action(.init("e"), marking: marking) == .include)
        #expect(ExtViewerKeys.action(.init("x"), marking: marking) == .clear)
        #expect(ExtViewerKeys.action(.init("f"), marking: marking) == .next)
        #expect(ExtViewerKeys.action(.init("s"), marking: marking) == .previous)
        #expect(marking.marks["B93F0"] == nil && marking.marks["B93F4"] == ReelsModel.inReelMark)
        marking.onMark?("B93F6", nil)                  // D on a soft frame
        #expect(!m.isIn("B93F6"))
        marking.onMark?("B93F0", ReelsModel.inReelMark)
        #expect(m.isIn("B93F0"))
        m.lookEnded(ExtViewerResult(index: 7, stem: "B93F7", marks: [:]))
        #expect(m.look == nil && m.cursor == "B93F7")
    }

    @Test("Q in the frame seen large takes its mark back off the page's own undo, so the grid's Q after it goes to the change before")
    func undoInTheViewerIsThePagesUndo() throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.options(about: "93"), burst: "93")
        // A change on the grid first, which the viewer's Q must not reach.
        #expect(m.key(.init("d")))
        #expect(!m.isIn("B93F0"))
        m.openLarge("B93F4")
        let marking = m.lookMarking
        marking.onMark?("B93F4", nil)                          // D in the viewer
        #expect(!m.isIn("B93F4"))
        #expect(m.undoName == Words.Edit.undoNamed(Strings.Reels.leaveOutNamed(ShootSession.shortStem("B93F4"))))
        marking.takeBack("B93F4", to: ReelsModel.inReelMark)   // Q in the viewer
        #expect(m.isIn("B93F4"))
        m.lookEnded(ExtViewerResult(index: 4, stem: "B93F4", marks: [:]))
        // Edit ▸ Undo names the grid's D, not an "Include" the viewer's Q
        // would have pushed.
        #expect(m.undoName == Words.Edit.undoNamed(Strings.Reels.leaveOutNamed(ShootSession.shortStem("B93F0"))))
        #expect(m.key(.init("q")))                              // Q in the grid
        #expect(m.isIn("B93F4"), "the D he took back in the viewer came back")
        #expect(m.isIn("B93F0"))
        #expect(!m.canUndo)
        // ⇧⌘Z does both again, in order.
        #expect(m.key(.init("z", command: true, shift: true)))
        #expect(!m.isIn("B93F0") && m.isIn("B93F4"))
        #expect(m.key(.init("z", command: true, shift: true)))
        #expect(!m.isIn("B93F4"))
    }

    @Test("a page's viewer, with no undo of its own to reach, hears Q as the mark it puts back")
    func aPagesViewerHearsQAsAMark() {
        var heard: [(String, String?)] = []
        let marking = ExtViewerMarking(actions: ExtViewerAction.parse([["id": "yes", "label": "Yes", "key": "k"]]),
                                       onMark: { stem, mark in heard.append((stem, mark)) })
        marking.takeBack("A1", to: "yes")
        #expect(heard.count == 1 && heard.first?.0 == "A1" && heard.first?.1 == "yes")
    }

    func click(_ n: Int, shift: Bool = false) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: n, pressure: 1))
    }
}

/// What a tile says about itself (DESIGN.md §2.6).
@Suite("Reels tiles", .serialized)
@MainActor
struct ReelsTileTests {
    @Test("\"Not exported\" is a badge only on a burst partly exported, and not while the wait counts it")
    func exportBadgeOnlyWhereItHelps() throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.burst93(), burst: "93")        // 3 of 13
        #expect(m.badgesExports)
        m.pollInterval = .seconds(60)
        m.startWaiting(burst: "93", baseline: 3, target: 13)
        #expect(!m.badgesExports)
        m.stopWaiting()
        m.preview(try ReelsScaffold.options(about: "94"), burst: "94")   // none exported
        #expect(!m.badgesExports)
    }
}

/// The words under the player (DESIGN.md §2.6).
@Suite("Reels player caption")
struct ReelsCaptionTests {
    @Test("when a reel was cut is said as a person would, and a time it cannot read is left as written")
    @MainActor func when() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 12)))
        let thisYear = ReelPreview.when("2026-09-20 15:16", now: now, calendar: cal)
        #expect(!thisYear.contains("2026") && thisYear != "2026-09-20 15:16")
        #expect(ReelPreview.when("2025-09-20 15:16", now: now, calendar: cal).contains("2025"))
        #expect(ReelPreview.when("2026-09-22 15:16", now: now, calendar: cal) != ReelPreview.when("2026-09-19 15:16", now: now, calendar: cal))
        #expect(ReelPreview.when("sometime", now: now, calendar: cal) == "sometime")
    }

    @Test("the reel's name leaves out the shoot's name the page is already in, and keeps the rest whole")
    @MainActor func name() {
        #expect(ReelPreview.shown("2026-09-19-first.mp4", shoot: "2026-09-19") == "first.mp4")
        #expect(ReelPreview.shown("2026-09-19_second.mp4", shoot: "2026-09-19") == "second.mp4")
        #expect(ReelPreview.shown("2026-09-190-third.mp4", shoot: "2026-09-19") == "2026-09-190-third.mp4")
        #expect(ReelPreview.shown("elsewhere.mp4", shoot: "2026-09-19") == "elsewhere.mp4")
        #expect(ReelPreview.shown("2026-09-19-", shoot: "2026-09-19") == "2026-09-19-")
    }
}
