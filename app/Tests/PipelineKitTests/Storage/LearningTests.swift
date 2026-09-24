import Foundation
import AppKit
import SwiftUI
import Testing
@testable import PipelineKit

/// §2.9 — what the learning screen says, and the one override.
@Suite("What the cull has learned")
struct LearningTests {

    @Test("the engine crew's own shape decodes, field for field")
    func theEnginesShape() throws {
        let l = try StorageFixture.decode(Learned.self, "learned-engine-shape")
        #expect(l.keepers == 773 && l.shoots == 6)
        #expect(l.learners.count == 3)
        #expect(l.due)
        #expect(l.new_shoots == 2)
        #expect(!l.unreadable)

        let reasons = l.learners[0]
        #expect(reasons.id == "drop-reasons")
        // `held` on the wire is "not in use" here, and the sentence is the
        // engine's own, byte for byte.
        #expect(reasons.status == .not_in_use)
        #expect(reasons.detail.hasPrefix("Not in use. The new version would stop putting forward 10"))
        #expect(reasons.candidate_version == "2026-09-22T14-08-31")
        #expect(reasons.can_use_anyway)
        #expect(!reasons.can_go_back)
        // What it read is the version IN USE's, and nothing is in use here:
        // the held candidate's source is not put over the row.
        #expect(reasons.learned_from.isEmpty)

        let check = try #require(reasons.check)
        #expect(check.hidden == 10)
        #expect(check.moved_down == 18)
        #expect(check.moved_up == 1, "the engine calls a keeper that moved up 'lifted'")
        #expect(check.costsHim)
        #expect(check.frames.count == 4)
        #expect(check.frames.first?.stem == "TSC07363")
        #expect(check.frames.first?.candidate == "set aside", "the engine calls it `new`")

        let order = l.learners[1]
        #expect(order.status == .not_in_use)
        #expect(order.check?.couldnt_check.first?.shoot == "2026-09-05-the-gals",
                "a shoot the check could not measure is named, never skipped")
        #expect(order.check?.frames.count == 2,
                "the frames of every shoot in the check are one list to show him")

        let edit = l.learners[2]
        #expect(edit.status == .in_use)
        #expect(edit.live_since == "2026-09-22")
        #expect(edit.can_go_back && edit.can_stop)
        #expect(!edit.can_use_anyway, "nothing to use anyway: it is already in use")
        #expect(l.fixed.count == 2)
    }

    @Test("what is in use, what waits beside it and what it is short of are three lines")
    func inUseBesideHeld() throws {
        // His library, 23 September, from the engine: the starting edit in
        // use is In use while a newer one is held beside it. The page used to
        // say "Not in use" over it, because the held candidate's state won.
        let l = try StorageFixture.decode(Learned.self, "learned-in-use-beside-held")
        let edit = try #require(l.learners.first { $0.id == "edit" })
        #expect(edit.status == .in_use)
        #expect(edit.detail.hasPrefix("In use since 2026-09-22. Learned from 527 finished frames"))
        #expect(edit.candidate_status == .not_in_use, "held on the wire")
        #expect(edit.candidate_sentence.hasPrefix("Held back: a newer version"))
        // The command that actually copies (without --apply a pull is a dry
        // run), and no promise a pull cannot keep for a version held for its
        // white balance.
        #expect(edit.needs_sentence.contains("./pl archive pull 2026-09-05-the-gals --apply"))
        // The promise a pull cannot keep is now withheld on the held line
        // itself, not two paragraphs down in the one about the download.
        #expect(edit.candidate_sentence.contains("Bringing photographs back does not settle this"))

        // Held for harm, and short of evidence: two lines, never one.
        let reasons = try #require(l.learners.first { $0.id == "drop-reasons" })
        #expect(reasons.status == .not_in_use)
        #expect(reasons.detail.hasPrefix("Not in use: "))
        #expect(reasons.candidate_sentence.hasPrefix("Held back:"))
        #expect(reasons.needs_sentence.hasPrefix("Not enough yet to learn your own:"))
        #expect(reasons.needs_sentence.contains("6 more frames dropped for blur"))
        #expect(reasons.hasFramesToShow, "See the N belongs to the held version's frames")
        // Every frame the engine sent, not a trimmed sample: the button reads
        // "See the 48" (36 moved down, 16 of them hidden, and 12 lifted)
        // under a sentence about the 16, as DESIGN §2.9 says.
        #expect(reasons.check?.frames.count == 48)
        let order = try #require(l.learners.first { $0.id == "tier-order" })
        #expect(order.check?.frames.count == 116)

        // An engine that sends none of the three new fields still decodes.
        let old = try StorageFixture.decode(Learned.self, "learned-engine-shape")
        #expect(old.learners[0].candidate_sentence.isEmpty && old.learners[0].candidate_status == nil)
        #expect(old.learners[0].needs_sentence.isEmpty)
    }

    @Test("the shape DESIGN.md wrote decodes into the same model")
    func theDesignsShape() throws {
        let l = try Fixture.decode(Learned.self, "learned-not-yet-on-the-server")
        #expect(l.keepers == 773 && l.shoots == 6)
        #expect(l.learners[0].status == .not_in_use)
        #expect(l.learners[0].detail.hasPrefix("Not in use."))
        #expect(l.learners[0].check?.hidden == 10)
        #expect(l.learners[0].check?.frames.first?.candidate == "set aside")
        #expect(l.learners[1].status == .in_use)
        #expect(l.learners[1].live_since == "2026-09-22")
        #expect(l.learners[2].status == .fixed)
        #expect(l.last_checked == "2026-09-22T14:10:00")
    }

    @Test("every state has a symbol of its own and a word of its own")
    func everyStateIsSayable() {
        var symbols = Set<String>()
        for state in LearnerStatus.allCases {
            #expect(!state.word.isEmpty, "\(state) has no word")
            #expect(Symbols.all.contains(state.symbol) || state.symbol == Symbols.cullForward,
                    "\(state)'s symbol is not one the design fixed")
            symbols.insert(state.symbol)
        }
        // in_use and not_in_use must never look alike; the two that share a
        // symbol (stopped with not_in_use, none with not_enough) also differ
        // by their word, which is always on the row.
        #expect(LearnerStatus.in_use.symbol != LearnerStatus.not_in_use.symbol)
        #expect(LearnerStatus.could_not_check.symbol != LearnerStatus.not_enough.symbol)
        #expect(symbols.count >= 4)
    }

    @Test("an empty record, and one that will not read, are two different screens")
    func emptyAndUnreadable() throws {
        let empty = try StorageFixture.decode(Learned.self, "learned-empty")
        #expect(empty.learners.isEmpty)
        #expect(!empty.unreadable, "nothing finished yet is not the same as nothing readable")
        #expect(empty.keepers == 0)

        // The engine's own answer for a broken record: three blank rows, as
        // it always sends, and the flag. "No rows" was all this used to read,
        // so the real thing showed as "Nothing learned yet" with Learn Now.
        let broken = try StorageFixture.decode(Learned.self, "learned-unreadable")
        #expect(broken.learners.count == 3)
        #expect(broken.unreadable)
        #expect(broken.error?.hasPrefix("The record of what the cull has learned will not read") == true)
        #expect(broken.error?.contains("/") == false, "no path in the sentence; it is beside it")
        #expect(broken.record?.hasSuffix("/manifest.json") == true)
        #expect(broken.unreadable_why?.isEmpty == false)
    }

    @Test("a path on the page is shown in Finder by the nearest part of it that exists, and nothing is made")
    func pathRevealsWhatExists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathrow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let notYet = dir.appendingPathComponent("not/made/yet")
        #expect(PathRow.Coordinator.nearestThatExists(notYet).path == dir.standardizedFileURL.path)
        #expect(!FileManager.default.fileExists(atPath: notYet.path))
        #expect(PathRow.Coordinator.nearestThatExists(dir).path == dir.standardizedFileURL.path)
    }

    @Test("a path row shows its part in Finder on a double-click, and a single click does nothing")
    @MainActor
    func pathRevealsOnADoubleClickOnly() throws {
        // Hosted with no window: nothing appears anywhere.
        let host = NSHostingView(rootView: PathRow(URL(fileURLWithPath: "/tmp")).frame(width: 300, height: 22))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 22)
        host.layoutSubtreeIfNeeded()
        func find(_ v: NSView) -> NSPathControl? {
            if let p = v as? NSPathControl { return p }
            return v.subviews.lazy.compactMap(find).first
        }
        let control = try #require(find(host))
        #expect(control.action == nil,
                "Settings, the first-run sheet and every step carry this row: a stray click stays in the app")
        #expect(control.doubleAction == #selector(PathRow.Coordinator.clicked(_:)))
        #expect(control.target is PathRow.Coordinator)
    }

    @Test("while it runs, the row says what it is doing and the rest stays usable")
    func running() throws {
        let l = try StorageFixture.decode(Learned.self, "learned-running")
        #expect(l.running)
        let job = try #require(l.job)
        // Which shoot it is learning from, and what it is doing right now —
        // both the engine's own words, from the fixture the engine wrote.
        #expect(job.title == "Learning from 2026-09-21")
        #expect(job.label == "reading the edits you exported: 144 of 288 frames")
        #expect(job.fraction == 0.53)
        #expect(job.remaining == 188)
        #expect(job.whereItHasGot
                == "reading the edits you exported: 144 of 288 frames · about 3 minutes left")
        // And why he can stop it without thinking about it, said before he
        // decides rather than after — only the half the headline above the
        // row does not already say ("Nothing new is used until it has been
        // checked against every photograph you kept").
        #expect(job.safe_to_stop == "Stopping it loses only the time it has spent.")
        #expect(!job.safe_to_stop.contains("checked against every photograph you kept"))
    }

    @Test("the row says nothing about what is left when the engine will not guess")
    func noFalsePrecisionOnTheRow() throws {
        // Early in a run the engine sends no estimate at all. The row shows
        // the stage and the bar and stops there: a made-up "about 4 hours
        // left" on a six-minute job is worse than a silence.
        let job = LearningJob(fields: Fields([
            "title": .string("Learning from 2026-09-21"),
            "label": .string("reading what you kept: 2 of 2 steps"),
            "fraction": .number(0.02)]))
        #expect(job.remaining == nil)
        #expect(job.remaining_text.isEmpty)
        #expect(job.whereItHasGot == "reading what you kept: 2 of 2 steps")
    }

    @Test("the row's sentence is the engine's, and the seam that could change it has two sides")
    @MainActor
    func theSentenceIsTheEngines() throws {
        let l = try StorageFixture.decode(Learned.self, "learned-engine-shape")
        let model = LearnedModel(preview: l)
        let held = l.learners[0]
        #expect(model.sentence(for: held) == held.detail)

        // The other implementation only ever fills a silence.
        let composed = ComposedCopy()
        #expect(composed.sentence(held) == held.detail, "an engine sentence is never rewritten")

        // With nothing from the engine, it says the state rather than nothing.
        let silent = try JSONDecoder().decode(Learner.self, from: Data("""
            {"id": "x", "title": "X", "state": "held", "can_use_anyway": true,
             "check": {"hidden": 3, "shoot": "2026-09-19", "frames": []}}
            """.utf8))
        #expect(silent.detail.isEmpty)
        #expect(EngineWrittenCopy().sentence(silent).isEmpty)
        #expect(composed.sentence(silent).contains("3"))
        #expect(composed.sentence(silent).contains("2026-09-19"))
    }

    @Test("Use It Anyway refuses unless the frames were on screen")
    @MainActor
    func useAnywayNeedsTheFrames() async throws {
        let l = try StorageFixture.decode(Learned.self, "learned-engine-shape")
        let model = LearnedModel(preview: l)          // no client: nothing can be sent
        let held = l.learners[0]
        #expect(held.can_use_anyway)

        let withoutLooking = await model.useAnyway(held, sawFrames: false)
        #expect(!withoutLooking)
        #expect(model.refusals[.learner(held.id)] == Strings.Learning.readOnly,
                "and it says why, on that learner's own row")

        // A learner the engine will not honour it for is refused the same way,
        // even from the review screen.
        let inUse = l.learners[2]
        #expect(!inUse.can_use_anyway)
        #expect(!(await model.useAnyway(inUse, sawFrames: true)))
    }

    @Test("a learner with no frames behind it offers no way to see them")
    func noFramesNoButton() throws {
        let l = try StorageFixture.decode(Learned.self, "learned-engine-shape")
        #expect(l.learners[0].hasFramesToShow)
        #expect(!l.learners[2].hasFramesToShow, "a check with no frames has nothing to show")
    }

    @Test("a refusal about one learner lands on that learner and nowhere else")
    @MainActor
    func refusalsAreOwned() throws {
        let board = RefusalBoard()
        board.set(.learner("drop-reasons"), "no")
        #expect(board[.learner("drop-reasons")] == "no")
        #expect(board[.learner("tier-order")] == nil)
        #expect(board[.learning] == nil)
        board.clear(.learning)
        #expect(board[.learner("drop-reasons")] == "no", "cleared only by its own owner")
    }

    @Test("a time the engine wrote is shown as a time he reads")
    @MainActor
    func theClock() {
        #expect(LearnedView.when("") == nil)
        let full = try! #require(LearnedView.when("2026-09-22T14:10:00"))
        #expect(full.contains("Sep") && full.contains("22"))
        #expect(full.contains("14:10") || full.contains("2:10"))
        #expect(LearnedView.when("2026-09-22")?.contains("Sep") == true)
        // Unreadable: printed as it arrived rather than guessed at.
        #expect(LearnedView.when("whenever") == "whenever")
    }
}

/// The one override dialog says what the version would do, in the engine's
/// words, and never "0 photographs".
@Suite("Use It Anyway says what it would do")
@MainActor
struct UseItAnywayBody {

    @Test("the burst-order learner, which hides nothing, is not described as hiding 0")
    func burstOrderIsNotZero() throws {
        let l = try StorageFixture.decode(Learned.self, "learned-in-use-beside-held")
        let order = try #require(l.learners.first { $0.id == "tier-order" })
        #expect(order.check?.hidden == 0)
        let body = ReviewModeHost.confirmBody(for: order)
        #expect(!body.contains(" 0 "), "the bug: 'would stop putting forward 0 photographs'")
        #expect(body.hasPrefix("It would show 81 of the photos you kept later in their burst and 35 earlier"),
                "the engine's own sentence, byte for byte")
        #expect(body.hasSuffix(Strings.Learning.useItAnywayTailOrder),
                "it moves his keepers within their burst; it does not show them less")
    }

    @Test("the starting edit's dialog says what a preset does, not that the cull shows keepers less")
    func theEditSaysWhatAPresetDoes() throws {
        let l = try StorageFixture.decode(Learned.self, "learned-in-use-beside-held")
        let edit = try #require(l.learners.first { $0.id == "edit" })
        #expect(edit.can_use_anyway, "the dialog is reachable for it")
        let body = ReviewModeHost.confirmBody(for: edit)
        #expect(body.hasPrefix("On \"2026-09-21\" it would set the white balance"))
        #expect(!body.contains("shows them less") && !body.contains("keepers stay kept"),
                "the bug: \(body)")
        #expect(body.hasSuffix(Strings.Learning.useItAnywayTailEdit))
    }

    @Test("VoiceOver reads what a learner is short of as the lines on the screen, not the sentence they replaced")
    func voiceOverReadsTheLines() throws {
        let row = try Fixture.decodeJSON(Learner.self, """
            {"id": "edit", "title": "Your starting edit", "state": "in_use",
             "needs_sentence": "Waiting on you: (./pl archive pull 2026-09-05-the-gals --apply brings them back from iCloud; then learn again)",
             "needs_lines": ["2026-09-05-the-gals: its RAWs are in iCloud.", "Bring them back, then learn again."]}
            """)
        #expect(row.needsText == "2026-09-05-the-gals: its RAWs are in iCloud. Bring them back, then learn again.")
        #expect(!row.needsText.contains("./pl"))
        let old = try Fixture.decodeJSON(Learner.self, """
            {"id": "edit", "title": "Your starting edit", "state": "in_use", "needs_sentence": "Not enough yet."}
            """)
        #expect(old.needsText == "Not enough yet.", "an engine that sends only the sentence is still read")
    }

    @Test("a version that hides keepers says how many, in the engine's words")
    func hidingSaysHowMany() throws {
        let l = try StorageFixture.decode(Learned.self, "learned-in-use-beside-held")
        let reasons = try #require(l.learners.first { $0.id == "drop-reasons" })
        #expect(ReviewModeHost.confirmBody(for: reasons)
            .hasPrefix("The new version would stop putting forward 16 of the photos you kept"))
    }
}
