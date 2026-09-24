import Testing
import Foundation
@testable import PipelineKit

/// From the card to the cull on the night of a shoot (DESIGN.md §2.6): the cull's
/// settings come from his last shoot, the cull starts by itself after a good
/// copy, a copy that stopped finishes into the same shoot, and a second card
/// can join a shoot that has not been culled.
@Suite("Card to cull")
struct CardToCullTests {

    @MainActor func session(patchInfo: [String: Any]) throws -> ShootSession {
        ShootSession(response: try PatchedFixture.shoot("shoot-not-culled", patchInfo: patchInfo),
                     ext: nil, client: StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k")),
                     pump: ImagePump(budget: .base, loader: { _ in Data() }),
                     queue: VerdictQueue(sender: { _ in .failure(.offline) }))
    }

    /// Every new shoot opened on 1.9 and off, and he set both back every
    /// evening. The engine now answers with his last shoot's, and says
    /// which shoot; the page starts there and says so.
    @Test("a new shoot's cull page starts as his last shoot was culled, and says so")
    @MainActor func startsFromTheLastShoot() throws {
        let s = try session(patchInfo: ["style": "action", "focus": 1.6, "cull_from": "2026-09-19"])
        #expect(s.info.cull_from == "2026-09-19")
        let model = StepsModel(session: s, jobs: JobModel())
        #expect(model.focusSetting == 1.6 && model.peopleMove)
        #expect(Strings.Cull.asLastTime("2026-09-19") == "Both start as you culled 2026-09-19.")
        // A shoot's own settings are said as nothing borrowed.
        let own = try session(patchInfo: ["style": "normal", "focus": 2.2])
        #expect(own.info.cull_from.isEmpty)
    }

    /// The copy asks the engine to follow it with the cull, whichever way it
    /// is sent - now, or on the list - and the result page says where that
    /// cull is.
    @Test("a copy asks for the cull after it, and the result page says where the cull is")
    @MainActor func cullFollowsTheCopy() throws {
        for body in [IngestBody(card: "/Volumes/Untitled", name: "2026-09-26", verify: "in-flight"),
                     IngestBody(card: "/Volumes/Untitled", name: "2026-09-26", verify: "in-flight", queue: true)] {
            let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
            #expect(json["then_cull"] as? Bool == true)
        }
        let running = Job(running: true, stopped: false, kind: "cull", shoot: "2026-09-26")
        #expect(CardPage.cullLine("2026-09-26", job: running, list: QueueState()) == Strings.Import.cullRunning)
        let waiting = QueueState(waiting: [QueueItem(id: 4, kind: "cull", shoot: "2026-09-26")], running: true,
                                 kind: "ingest", shoot: "2026-09-26-b")
        #expect(CardPage.cullLine("2026-09-26", job: nil, list: waiting) == Strings.Import.cullWaiting)
        #expect(CardPage.cullLine("2026-09-26", job: nil, list: QueueState()) == nil)
        #expect(CardPage.cullLine("2026-09-26", job: Job(running: true, stopped: false, kind: "cull", shoot: "other"),
                                  list: QueueState()) == nil)
    }

    /// Rows of /api/shoots, as the engine sends them: name, day, and whether
    /// the cull has run.
    func rows(_ list: [(String, Bool)]) throws -> [ShootRowOK] {
        let object: [String: Any] = ["shoots": list.map { ["name": $0.0, "path": "/x/\($0.0)", "culled": $0.1] },
                                     "cards": []]
        let r = try JSONDecoder().decode(ShootsResponse.self, from: JSONSerialization.data(withJSONObject: object))
        return r.shoots.compactMap { if case .ok(let row) = $0 { return row } else { return nil } }
    }

    func contents(_ copiedAs: String, held: Int, of n: Int, copying: Bool = false) throws -> CardContents {
        try CardContents(fields: Fields(["path": .string("/Volumes/Untitled"), "photographs": .integer(n),
                                         "copied_as": .string(copiedAs), "held": .integer(held),
                                         "stopped": .bool(!copying), "copying": .bool(copying)]))
    }

    /// A card put back after its copy stopped finishes into the shoot it
    /// stopped in; a second card can join the day's shoots not culled yet.
    @Test("the card page offers the copy to finish, then the day's shoots not culled, and nothing culled")
    @MainActor func whereACardCanGo() throws {
        let shoots = try rows([("2026-09-23-night", false), ("2026-09-23-lounge", true), ("2026-09-19", true)])
        let row = { (n: String) in shoots.first { $0.name == n } }
        let stopped = try contents("2026-09-23-night", held: 412, of: 1_558)
        #expect(CardPage.resumeTarget(stopped, row: row) == "2026-09-23-night")
        // Not while a copy into it is going, not once it holds all of the
        // card, not once it has been culled.
        #expect(CardPage.resumeTarget(try contents("2026-09-23-night", held: 412, of: 1_558, copying: true), row: row) == nil)
        #expect(CardPage.resumeTarget(try contents("2026-09-23-night", held: 1_558, of: 1_558), row: row) == nil)
        #expect(CardPage.resumeTarget(try contents("2026-09-23-lounge", held: 12, of: 40), row: row) == nil)

        #expect(CardPage.joinable(resume: "2026-09-23-night", day: "2026-09-23", shoots: shoots) == ["2026-09-23-night"])
        #expect(CardPage.joinable(resume: nil, day: "2026-09-23", shoots: shoots) == ["2026-09-23-night"])
        #expect(CardPage.joinable(resume: nil, day: "2026-09-20", shoots: shoots).isEmpty)

        // Sent as a copy into it, and said as what it copies.
        let body = IngestBody(card: "/Volumes/Untitled", name: "2026-09-23-night", verify: "end", into: true)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        #expect(json["into"] as? Bool == true)
        #expect(Strings.Import.finishCopying(1_146) == "Finish Copying 1,146 Frames")
        #expect(Strings.Import.addCount(986) == "Add 986 Frames")
    }

    /// The first card's copy keeps its own proof, and the page says it.
    @Test("an earlier card's copy is read off the note and said under the last one's")
    func earlierCards() throws {
        let object: [String: Any] = ["name": "2026-09-23-night", "path": "/x", "ingest": [
            "state": "done", "files": 986, "proof": "hashed on the way in and read back",
            "earlier": [["files": 1_558, "proof": "verified byte for byte, both sides"]]]]
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object))
        let info = try ShootInfo(fields: Fields(try #require(value.objectValue)))
        #expect(info.earlier_copies == [EarlierCopy(files: 1_558, proof: "verified byte for byte, both sides")])
        #expect(Strings.Import.earlierCard(1_558, proof: "verified byte for byte, both sides")
            == "Before it, another card: 1,558 frames copied, verified byte for byte, both sides.")
    }

    /// Rows whose copy notes are given, as the engine sends them.
    func rows(notes: [(String, [String: Any])]) throws -> [ShootRowOK] {
        let object: [String: Any] = ["shoots": notes.map { ["name": $0.0, "path": "/x/\($0.0)", "culled": false,
                                                            "ingest": $0.1] },
                                     "cards": []]
        let r = try JSONDecoder().decode(ShootsResponse.self, from: JSONSerialization.data(withJSONObject: object))
        return r.shoots.compactMap { if case .ok(let row) = $0 { return row } else { return nil } }
    }

    /// Card A was pulled at 412 of 1,558. Adding a second camera's card to
    /// that shoot wrote over A's record and started the cull on half the
    /// night, so a shoot a copy into which did not finish is offered only to
    /// the card that can finish it, and says so in red wherever it is shown.
    @Test("a shoot whose copy did not finish is offered only to the card that can finish it")
    @MainActor func unfinishedShootsTakeOnlyTheirOwnCard() throws {
        let shoots = try rows(notes: [
            ("2026-09-23-night", ["state": "stopped", "files": 412, "of": 1_558]),
            ("2026-09-23-b", ["state": "failed", "detail": "TSC00002.ARW"]),
            ("2026-09-23-c", ["state": "done", "files": 40, "proof": "hashed",
                              "earlier": [["state": "stopped", "files": 2, "of": 5]]]),
            ("2026-09-23-d", ["state": "done", "files": 40, "proof": "hashed",
                              "earlier": [["state": "done", "files": 12, "proof": "hashed"]]]),
            ("2026-09-23-e", [:]),
        ])
        #expect(shoots.map(\.copyUnfinished) == [true, true, true, false, false])
        // Another card: only the shoots whose every copy finished.
        #expect(CardPage.joinable(resume: nil, day: "2026-09-23", shoots: shoots) == ["2026-09-23-d", "2026-09-23-e"])
        // The card whose copy stopped: that shoot first, to finish it.
        #expect(CardPage.joinable(resume: "2026-09-23-night", day: "2026-09-23", shoots: shoots)
                == ["2026-09-23-night", "2026-09-23-d", "2026-09-23-e"])
        // Not the shoot that already holds all of this card.
        #expect(CardPage.joinable(resume: nil, day: "2026-09-23", shoots: shoots, whole: "2026-09-23-d") == ["2026-09-23-e"])

        // Every file arrived and the copy stopped in its check: still the
        // copy to finish, and the button says so without "0 Frames".
        let row = { (n: String) in shoots.first { $0.name == n } }
        let all = try contents("2026-09-23-night", held: 1_558, of: 1_558)
        #expect(CardPage.resumeTarget(all, row: row) == "2026-09-23-night")
        #expect(CardPage.resumeTarget(try contents("2026-09-23-d", held: 40, of: 40), row: row) == nil)
        // Card B held whole in a shoot where card A's earlier copy stopped:
        // not B's copy to finish.
        #expect(CardPage.resumeTarget(try contents("2026-09-23-c", held: 40, of: 40), row: row) == nil)
        #expect(CardPage.resumeTarget(try contents("2026-09-23-c", held: 2, of: 5), row: row) == "2026-09-23-c")
        #expect(Strings.Import.finishTheCopy == "Finish the Copy")

        // An earlier card's copy that did not finish is said, in its own words.
        let c = try #require(shoots.first { $0.name == "2026-09-23-c" }?.earlier_copies.first)
        #expect(!c.finished)
        #expect(Strings.Import.earlier(c)
                == "Before it, another card's copy stopped after 2 of 5 frames. Put that card back to finish it.")
        let d = try #require(shoots.first { $0.name == "2026-09-23-d" }?.earlier_copies.first)
        #expect(d.finished && Strings.Import.earlier(d) == "Before it, another card: 12 frames copied, hashed.")
    }

    /// The card's report does not carry him on to the cull with Return while
    /// any card of the shoot is half there.
    @Test("the card's report withholds Return while an earlier card's copy did not finish")
    @MainActor func reportWithholdsReturn() throws {
        func info(_ ingest: [String: Any]) throws -> ShootInfo {
            let object: [String: Any] = ["name": "2026-09-23-night", "path": "/x", "frames": 40, "ingest": ingest]
            let value = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object))
            return try ShootInfo(fields: Fields(try #require(value.objectValue)))
        }
        #expect(!ImportReport.unproved(try info(["state": "done", "files": 40, "proof": "hashed"])))
        #expect(ImportReport.unproved(try info(["state": "done", "files": 40, "proof": "hashed",
                                                "earlier": [["state": "failed", "detail": ""]]])))
        #expect(ImportReport.unproved(try info(["state": "stopped", "files": 2, "of": 5])))
    }

    /// A shoot whose cull is running takes no card until that cull is
    /// stopped: the picker says so rather than offering "adding this card".
    @Test("a shoot being culled is named as such in the picker")
    @MainActor func beingCulled() throws {
        let running = Job(running: true, stopped: false, kind: "cull", shoot: "2026-09-23-night")
        #expect(CardPage.beingCulled("2026-09-23-night", job: running, list: QueueState()))
        #expect(!CardPage.beingCulled("2026-09-23-b", job: running, list: QueueState()))
        // Waiting on the list is not being culled: a card added now goes
        // ahead of that cull, and it is one cull over both.
        let waiting = QueueState(waiting: [QueueItem(id: 4, kind: "cull", shoot: "2026-09-23-night")])
        #expect(!CardPage.beingCulled("2026-09-23-night", job: nil, list: waiting))
        #expect(Strings.Import.addToBeingCulled("2026-09-23-night") == "2026-09-23-night, being culled now")
        // "As your last shoot was culled" only when there is one.
        #expect(Strings.Import.cullFollows(asLast: false) == "When the copy is done, the cull starts by itself.")
        #expect(Strings.Import.cullFollows(asLast: true).hasSuffix("set as your last shoot was culled."))
    }
}
