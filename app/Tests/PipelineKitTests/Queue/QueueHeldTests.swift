import Testing
import Foundation
@testable import PipelineKit

// He pressed Stop on a cull the list had started, because he needed the
// machine or wanted to cull again with another focus, and the presets behind
// it started at once. Stop holds the rest of Up Next now, and the list says
// it was his Stop that held it rather than a Hold he does not remember.

@Suite("What held the list")
struct QueueHeldTests {

    static let stopped = """
    {"queue": [{"id": 8, "kind": "presets", "title": "presets for 2026-09-19", "shoot": "2026-09-19", \
    "does": "", "why": "", "kept": true, "ready": true, "why_not": ""}], \
    "held": true, "held_after": {"why": "stopped", "kind": "cull", "title": "culling 2026-09-19", \
    "shoot": "2026-09-19"}, "waiting": 1, "listed": 2, "fraction": 0.0, "pass": 2, "done": [], \
    "skipped": [], "running": false, "from_list": false, "id": 7, "kind": "cull", "title": "", \
    "shoot": "", "label": "", "remaining_text": "", "job_fraction": 0.0, "background": false}
    """

    @Test("a list his Stop held says so, naming the work as Up Next names it")
    func stopHeldIt() throws {
        let q = try Fixture.decodeJSON(QueueState.self, Self.stopped)
        #expect(q.held)
        let after = try #require(q.heldAfter)
        #expect(after.why == .stopped)
        #expect(after.named == "Cull · 2026-09-19")
        #expect(Strings.Queue.heldLine(after)
                == "Held because you stopped Cull · 2026-09-19. Nothing new starts until you continue.")
    }

    @Test("a list he held himself says only that it is held")
    func heldByHand() throws {
        let q = try Fixture.decodeJSON(QueueState.self,
                                       Self.stopped.replacingOccurrences(of: "\"why\": \"stopped\"",
                                                                         with: "\"why\": \"\"")
                                           .replacingOccurrences(of: "\"held_after\": {", with: "\"x\": {"))
        #expect(q.held)
        #expect(q.heldAfter == nil)
        #expect(Strings.Queue.heldLine(q.heldAfter) == Strings.Queue.heldNote)
    }

    @Test("a reason is never carried by a list that is not held")
    func notHeldNoReason() throws {
        let q = try Fixture.decodeJSON(QueueState.self,
                                       Self.stopped.replacingOccurrences(of: "\"held\": true", with: "\"held\": false"))
        #expect(!q.held)
        #expect(q.heldAfter == nil)
        #expect(QueueState(held: false, heldAfter: HeldAfter(why: .stopped, kind: "cull")).heldAfter == nil)
    }

    static let crashed = """
    {"queue": [{"id": 12, "kind": "cull", "title": "culling 2026-09-19", "shoot": "2026-09-19", \
    "does": "Look at 1,558 frames and put the ones worth keeping forward.", "why": "", "kept": true, \
    "ready": true, "why_not": "", "interrupted": true}, \
    {"id": 9, "kind": "presets", "title": "presets for 2026-09-19", "shoot": "2026-09-19", \
    "does": "", "why": "", "kept": true, "ready": true, "why_not": "", "interrupted": false}], \
    "held": true, "held_after": {"why": "crashed", "kind": "cull", "title": "culling 2026-09-19", \
    "shoot": "2026-09-19"}, "cut_off": {"why": "crashed", "kind": "cull", "title": "culling 2026-09-19", \
    "shoot": "2026-09-19"}, "waiting": 2, "listed": 2, "fraction": 0.0, "pass": 1, "done": [], \
    "skipped": [], "running": false, "from_list": false, "id": 0, "kind": "", "title": "", \
    "shoot": "", "label": "", "remaining_text": "", "job_fraction": 0.0, "background": false}
    """

    @Test("the work a crash cut off is back at the top, marked, and the list says why it is held")
    func crashCutItOff() throws {
        let q = try Fixture.decodeJSON(QueueState.self, Self.crashed)
        #expect(q.waiting.map(\.interrupted) == [true, false])
        #expect(q.heldAfter?.why == .crashed)
        #expect(Strings.Queue.heldLine(q.heldAfter).contains("the engine stopped while Cull · 2026-09-19 ran"))
        // The restart line names it, rather than only saying nothing was lost.
        let cut = try #require(q.cutOff)
        let line = AppModel.cutOffLine(cut)
        #expect(line.contains("Cull · 2026-09-19"))
        #expect(line.contains("back at the top of Up Next, held"))
        #expect(line != Strings.Engine.restarted)
    }

    /// A card copy the crash cut off is back at the top as the copy that
    /// finishes into the same shoot, and every line says how far it got and
    /// that continuing, with the card in, finishes it.
    @Test("a card copy a crash cut off is back at the top to finish, and says where it stopped")
    func copyPutBack() throws {
        let json = Self.crashed
            .replacingOccurrences(of: "\"held_after\": {\"why\": \"crashed\", \"kind\": \"cull\"",
                                  with: "\"held_after\": {\"why\": \"crashed\", \"files\": 412, \"of\": 1558, \"kind\": \"ingest\"")
            .replacingOccurrences(of: "\"cut_off\": {\"why\": \"crashed\", \"kind\": \"cull\"",
                                  with: "\"cut_off\": {\"why\": \"crashed\", \"files\": 412, \"of\": 1558, \"kind\": \"ingest\"")
        let q = try Fixture.decodeJSON(QueueState.self, json)
        let after = try #require(q.heldAfter)
        #expect(after.putBack && after.files == 412 && after.of == 1558)
        let held = Strings.Queue.heldLine(after)
        #expect(held.contains("at 412 of 1558 frames") || held.contains("at 412 of 1,558 frames"))
        #expect(held.contains("back at the top") && held.contains("finish the copy"))
        let line = AppModel.cutOffLine(try #require(q.cutOff))
        #expect(line.contains("412 of 1"))
        #expect(line.contains("back at the top of Up Next, held") && line.contains("finishes the copy"))
        #expect(line.contains("Nothing you decided is lost."))
        // Without the copy's count, the lines still read.
        #expect(!Strings.Queue.heldAfterCopyBack("Copy the Card · 2026-09-19", files: 0, of: 0).contains("0 of 0"))
        #expect(!Strings.Queue.restartedDuringCopyBack("Copy the Card · 2026-09-19", files: 0, of: 0).contains("0 of 0"))
    }

    /// An engine from before a copy could be finished into its shoot did not
    /// put one back, and said so: a list it held still says how far the copy
    /// got instead of "back at the top".
    @Test("a card copy an earlier engine did not put back is said where it stopped")
    func copyCutOff() throws {
        let json = Self.crashed
            .replacingOccurrences(of: "\"held_after\": {\"why\": \"crashed\", \"kind\": \"cull\"",
                                  with: "\"held_after\": {\"why\": \"crashed\", \"put_back\": false, \"files\": 412, \"of\": 1558, \"kind\": \"ingest\"")
            .replacingOccurrences(of: "\"cut_off\": {\"why\": \"crashed\", \"kind\": \"cull\"",
                                  with: "\"cut_off\": {\"why\": \"crashed\", \"put_back\": false, \"files\": 412, \"of\": 1558, \"kind\": \"ingest\"")
        let q = try Fixture.decodeJSON(QueueState.self, json)
        let after = try #require(q.heldAfter)
        #expect(!after.putBack && after.files == 412 && after.of == 1558)
        let held = Strings.Queue.heldLine(after)
        #expect(held.contains("at 412 of 1558 frames") || held.contains("at 412 of 1,558 frames"))
        #expect(!held.contains("back at the top"))
        let line = AppModel.cutOffLine(try #require(q.cutOff))
        #expect(line.contains("412 of 1"))
        #expect(!line.contains("back at the top"))
        #expect(line.contains("Nothing you decided is lost."))
        // A list the engine did not say that about is put back, as before.
        #expect(try #require(Fixture.decodeJSON(QueueState.self, Self.crashed).heldAfter).putBack)
        // And without the copy's count, the line still reads.
        #expect(!Strings.Queue.heldAfterCopyCut("Copy · 2026-09-19", files: 0, of: 0).contains("0 of 0"))
    }

    @Test("the reasons are in his words, not ours")
    func words() {
        for line in [Strings.Queue.heldAfterStop("Cull · 2026-09-19"),
                     Strings.Queue.heldAfterCrash("Cull · 2026-09-19"),
                     Strings.Queue.restartedWhile("Cull · 2026-09-19"),
                     Strings.Queue.heldAfterCopyCut("Cull · 2026-09-19", files: 412, of: 1558),
                     Strings.Queue.restartedDuringCopy("Cull · 2026-09-19", files: 412, of: 1558),
                     Strings.Queue.heldAfterCopyBack("Cull · 2026-09-19", files: 412, of: 1558),
                     Strings.Queue.restartedDuringCopyBack("Cull · 2026-09-19", files: 412, of: 1558)] {
            let lower = line.lowercased()
            #expect(!lower.contains("job"), "\(line)")
            #expect(!lower.contains("queue"), "\(line)")
            #expect(line.contains("Cull · 2026-09-19"))
        }
        #expect(!Strings.Queue.interruptedNote.lowercased().contains("job"))
        // A kind the app has no word for is the engine's title, first letter up.
        #expect(HeldAfter(why: .stopped, kind: "ext-upload", title: "uploading the set").named == "Uploading the set")
    }
}
