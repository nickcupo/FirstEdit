import Foundation
import Testing
@testable import PipelineKit

/// One test per route, against what the real engine sent. Each asserts real
/// values, not just "it decoded": a lenient decoder that silently zeroed a
/// field that went missing would pass a weaker test.
@Suite("Decoding the engine's real answers")
struct DecodingTests {

    @Test("every captured fixture is one this suite knows about")
    func everyFixtureIsCovered() {
        let covered: Set<String> = [
            "shoots", "shoots-broken", "cards", "update", "job", "job-finished", "storage-library",
            "shoot", "shoot-full", "shoot-light", "shoot-decided", "shoot-not-culled", "shoot-bursts", "storage",
            "storage-not-culled", "storage-frames", "storage-plan-undrawn", "storage-plan-reclaim",
            "storage-plan-drop", "reel-options", "reel-watch", "rating", "label", "review", "kind",
            "error-no-such-shoot", "error-bad-plan", "learned-not-yet-on-the-server", "learned",
            // The list of work: empty, filled with something running, and
            // finished. Decoded in `QueueDecodingTests`.
            "queue", "queue-empty", "queue-running",
            // One burst's frames, asked of the reel lister. Decoded in
            // `ReelsTests`.
            "reel-options-burst", "reel-watch-burst",
            // The Instagram step's routes and the job that works its cuts
            // out. Decoded in `InstagramDecodingTests`.
            "instagram", "instagram-empty", "instagram-planning", "instagram-plan", "instagram-plan-waiting",
            "instagram-crop", "instagram-shape", "job-instagram-plan",
        ]
        let unknown = Fixture.names.filter { !covered.contains($0) }
        #expect(unknown.isEmpty, "fixtures with no decoding test: \(unknown)")
    }

    @Test("GET /api/shoots")
    func shoots() throws {
        let r = try Fixture.decode(ShootsResponse.self, "shoots")
        #expect(r.shoots.count == 7)
        #expect(r.broken.isEmpty)
        #expect(r.ext == nil)
        #expect(r.app)
        let dog = try #require(r.ok.first { $0.name == "2026-09-13-dog" })
        #expect(dog.frames == 54)
        #expect(dog.culled)
        #expect(dog.cull_picks == 23)
        #expect(dog.storage?.cells == [.full, .none])
        #expect(dog.sidecar_kinds[".dop"] == 23)
        let big = try #require(r.ok.first { $0.name == "2026-09-21" })
        #expect(big.kept == 200)
        guard case .done(let files, let proof) = big.ingest else {
            Issue.record("2026-09-21 copied with a proof and the note should say so"); return
        }
        #expect(files == 857)
        #expect(proof == "not hashed; sizes match")
        #expect(r.ok.filter { $0.finished }.count == 2)
        // Not on this engine yet; absent means the Reels step stays.
        #expect(r.ok.allSatisfy { $0.can_cut_reels })
        // Today's engine sends `update` as a bare {"error": …}; nothing else.
        #expect(r.update.current == "")
        #expect(r.update.error != nil)
    }

    @Test("a shoot whose decisions file will not read is one row, with the engine's sentence")
    func brokenShoot() throws {
        let r = try Fixture.decode(ShootsResponse.self, "shoots-broken")
        #expect(r.ok.isEmpty)
        let b = try #require(r.broken.first)
        #expect(b.name == "a-broken-shoot")
        #expect(b.broken.hasPrefix("organize.json will not read"))
        #expect(b.broken_where == "decisions")
        #expect(b.broken_file?.hasSuffix("cull/organize.json") == true)
        #expect(r.update.current == "")          // `update: {}` decodes too
    }

    @Test("GET /api/shoot: the cull's rating is text on the wire and a number here")
    func shoot() throws {
        let r = try Fixture.decode(ShootResponse.self, "shoot")
        #expect(r.info.name == "2026-09-13-dog")
        #expect(r.rows.count == 54)
        let first = try #require(r.rows.first)
        #expect(first.stem == "TSC04313")
        #expect(first.rating == 3)
        #expect(first.override == nil)
        #expect(first.focus == 53.7)
        #expect(first.borderline == nil)          // "" is "not measured", not zero
        #expect(first.tw == 640 && first.dw == 6024 && first.dh == 4024)
        #expect(first.hasAnyRendering)
        #expect(first.legacyBurstKey == "3/0")
        #expect(r.presets.count == 2)
        #expect(r.presets[0].frames.count == 13)
        #expect(r.presets[0].notes?.isEmpty == false)
        #expect(r.review.at == "")
        // The server does not group or list steps yet: empty, and the session
        // falls back.
        #expect(r.bursts.isEmpty)
        #expect(r.steps.isEmpty)
        #expect(r.resume.kind == .fresh)
        // Not in the stack columns yet.
        #expect(r.rows.allSatisfy { $0.stack == nil && $0.stack_top == nil })
        #expect(r.info.will_be_edited == nil)
    }

    @Test("his override is an Int beside a rating that is a String, and never merged")
    func decided() throws {
        let r = try Fixture.decode(ShootResponse.self, "shoot-decided")
        let first = try #require(r.rows.first)
        #expect(first.override == 5)
        #expect(first.rating == 3)
        #expect(first.label == "blur")
        #expect(VerdictValue.his(first) == .kept)
        #expect(r.review.at == "3/0")
        #expect(r.review.bursts["3/0"]?.from == "your overrides")
        #expect(r.info.kept == 1)
    }

    @Test("?full=1 carries columns this app never names, and they survive in `extra`")
    func fullRows() throws {
        let r = try Fixture.decode(ShootResponse.self, "shoot-full")
        let first = try #require(r.rows.first)
        #expect(first.extra["eyes_open"] != nil)
        #expect(first.extra["rating"] == nil)
        #expect(first.rating == 3)
    }

    @Test("?light=1")
    func light() throws {
        let r = try Fixture.decode(ShootLightResponse.self, "shoot-light")
        #expect(r.info.frames == 54)
        #expect(r.info.exported == 14)
        #expect(r.info.bursts == 19)
    }

    @Test("an un-culled shoot has no rows and no bursts")
    func notCulled() throws {
        let r = try Fixture.decode(ShootResponse.self, "shoot-not-culled")
        #expect(r.rows.isEmpty)
        #expect(!r.info.culled)
        #expect(r.info.kind == nil)
        #expect(r.info.frames == 98)
        guard case .none = r.info.ingest else { Issue.record("an empty ingest note is .none"); return }
    }

    @Test("GET /api/job, idle and after a plan that refused")
    func job() throws {
        let idle = try Fixture.decode(Job.self, "job")
        #expect(!idle.running)
        #expect(idle.code == nil)
        #expect(idle.outcome == .idle)
        #expect(idle.id == 0 && !idle.queued)       // not numbered on this engine yet

        let done = try Fixture.decode(Job.self, "job-finished")
        #expect(done.kind == "plan-drop")
        #expect(done.code == 1)
        // A plan that refuses on purpose is Refused, not Failed.
        #expect(done.outcome == .refused)
        #expect(done.refusalSentence == "2026-09-13-dog has no archive manifest: nothing was ever pushed.")
    }

    @Test("GET /api/storage uses only the engine's own words and order")
    func storage() throws {
        let s = try Fixture.decode(Storage.self, "storage")
        #expect(s.name == "2026-09-13-dog")
        #expect(s.archive.frames == 54 && s.archive.here == 54)
        #expect(s.order.first == "both")
        #expect(s.glyphs["missing"] == [.none, .gone])
        #expect(s.words["here_only"]?.hasPrefix("on this Mac only") == true)
        #expect(s.cache.files == 164)
        // DESIGN.md calls it `with`; the engine sends `where`.
        #expect(s.cache.last_copy.with == ["cull/previews", "cull/thumbs"])
        #expect(s.retain.days == 365)
        #expect(!s.retain.finished)                  // "" is not a yes
        #expect(s.retain.age_days == nil)
        #expect(s.retain.keepers == 14)
        _ = try Fixture.decode(Storage.self, "storage-not-culled")
    }

    @Test("GET /api/storage/frames")
    func storageFrames() throws {
        let f = try Fixture.decode(StorageFrames.self, "storage-frames")
        #expect(f.rows.count == 54)
        #expect(f.rows[0].name == "TSC04313.ARW")
        #expect(f.rows[0].cells == [.full, .none])
    }

    @Test("a plan: drawn, refused, and not drawn yet")
    func plans() throws {
        let reclaim = try Fixture.decode(Plan.self, "storage-plan-reclaim")
        #expect(reclaim.what == "reclaim")
        #expect(reclaim.counts["files"] == 164)
        #expect(reclaim.label == "Take back 140.8 MB")
        #expect(reclaim.ready)
        #expect(reclaim.token?.count == 64)
        // The command line's footer ("nothing was removed. Add --apply …") is
        // not in what the engine sends the app: the button is the apply.
        #expect(reclaim.lines.last?.contains("above and are not in the list") == true)
        #expect(!reclaim.lines.contains { $0.contains("--apply") })

        let drop = try Fixture.decode(Plan.self, "storage-plan-drop")
        #expect(!drop.ready)
        #expect(drop.lines == ["  2026-09-13-dog has no archive manifest: nothing was ever pushed."])

        // A 200 whose whole body is a refusal: Plan has room for it.
        let undrawn = try Fixture.decode(Plan.self, "storage-plan-undrawn")
        #expect(undrawn.error == "that list was drawn for something else. Ask for it again.")
        #expect(!undrawn.ready)
    }

    @Test("GET /api/storage/library")
    func library() throws {
        let l = try Fixture.decode(LibraryLine.self, "storage-library")
        #expect(l.root == "/scratch/photos")
        #expect(l.files > 0)            // grows with every plan log a capture writes
        #expect(l.free_text.hasSuffix("B"))
        #expect(l.strays.isEmpty)
    }

    @Test("GET /api/reel/options and /api/reel/watch")
    func reels() throws {
        let o = try Fixture.decode(ReelOptions.self, "reel-options")
        #expect(o.sequences.count == 11 && o.cuts.count == 11)
        #expect(o.cuts[0].lands_on == "TSC04344")
        #expect(o.sequences[0].kept == 3)
        #expect(o.exports_found == 14)
        #expect(o.source == "raw")
        #expect(!o.exports_dir.contains("/Users/"))
        let w = try Fixture.decode(ReelWatch.self, "reel-watch")
        #expect(w.burst == "1")
    }

    @Test("the POST answers")
    func posts() throws {
        let rating = try Fixture.decode(RatingResult.self, "rating")
        #expect(rating.ok && rating.key_note.isEmpty)
        #expect(try Fixture.decode(OK.self, "label").ok)
        let review = try Fixture.decode(ReviewResult.self, "review")
        #expect(review.seen == 1 && review.at == "3/0")
        let kind = try Fixture.decode(KindResult.self, "kind")
        #expect(kind.ok && kind.error == nil)
        #expect(try Fixture.decode(CardsResponse.self, "cards").cards.isEmpty)
    }

    @Test("GET /api/learned, in the shape DESIGN.md §3.9-11 gives it")
    func learned() throws {
        // Captured once the engine has the route; the hand-shaped file until then.
        let name = Fixture.names.contains("learned") ? "learned" : "learned-not-yet-on-the-server"
        let l = try Fixture.decode(Learned.self, name)
        #expect(!l.learners.isEmpty)
        if name != "learned" {
            #expect(l.keepers == 773)
            #expect(l.learners[0].status == .not_in_use)
            #expect(l.learners[0].check?.hidden == 10)
            #expect(l.learners[0].check?.frames.first?.stem == "TSC07363")
            #expect(l.learners[2].status == .fixed)
        }
    }

    @Test("an {\"error\": …} body is a refusal, and its sentence is kept byte for byte")
    func refusal() throws {
        let data = try Fixture.data("error-no-such-shoot")
        #expect(StudioClient.refusal(in: data) == "no such shoot")
        let sentence = "that list was drawn for something else. Ask for it again."
        let odd = Data("{\"error\": \"\(sentence)\"}".utf8)
        #expect(StudioClient.refusal(in: odd) == sentence)
        #expect(StudioError.refused(sentence).sentence == sentence)
        // Deeper than the top level is not a refusal.
        #expect(StudioClient.refusal(in: Data(#"{"storage": {"error": "x"}}"#.utf8)) == nil)
        #expect(StudioClient.refusal(in: Data(#"{"error": null}"#.utf8)) == nil)
    }

    @Test("an extension's own field survives on the row and breaks nothing")
    func extensionFieldsSurvive() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: Fixture.data("shoots")) as? [String: Any])
        var rows = try #require(obj["shoots"] as? [[String: Any]])
        rows[0]["an_extension_count"] = 3
        rows[0]["an_extension_flag"] = ["nested": [1, 2]]
        obj["shoots"] = rows
        let r = try JSONDecoder().decode(ShootsResponse.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(r.ok[0].extra["an_extension_count"] == .integer(3))
        #expect(r.ok[0].extra["an_extension_flag"]?.objectValue?["nested"] == .array([.integer(1), .integer(2)]))
        #expect(r.ok[0].extra["frames"] == nil)
    }

    @Test("the new server's fields decode when they land")
    func newServerShape() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: Fixture.data("shoot")) as? [String: Any])
        var rows = try #require(obj["rows"] as? [[String: Any]])
        rows[0]["stack"] = "s1"; rows[0]["stack_top"] = "1"
        rows[0]["face_x"] = "0.42"; rows[0]["face_y"] = 0.31
        rows[0]["subject"] = [0.1, 0.2, 0.3, 0.4]
        obj["rows"] = rows
        var info = try #require(obj["info"] as? [String: Any])
        info["will_be_edited"] = 23; info["agreed"] = 9; info["can_cut_reels"] = false
        obj["info"] = info
        obj["bursts"] = [["id": "b0", "index": 0, "frames": ["TSC04313"], "seen": true,
                          "kept": 1, "out": 0, "cull_picks": 1, "undecided": 0]]
        obj["steps"] = [["id": "cull", "label": "Cull", "done": true, "enabled": true,
                         "why_disabled": NSNull(), "source": "base"],
                        ["id": "x", "label": "An extension step", "done": false, "enabled": false,
                         "why_disabled": "Cull first.", "source": "extension"]]
        obj["resume"] = ["burst_id": "b0", "kind": "left_off", "note": "Back where you left off."]
        let r = try JSONDecoder().decode(ShootResponse.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(r.rows[0].stack == "s1" && r.rows[0].stack_top == 1)
        #expect(r.rows[0].face_x == 0.42 && r.rows[0].face_y == 0.31)
        #expect(r.rows[0].subject == [0.1, 0.2, 0.3, 0.4])
        #expect(r.info.will_be_edited == 23 && r.info.agreed == 9)
        #expect(!r.info.can_cut_reels)
        #expect(r.bursts.first?.seen == true)
        #expect(r.steps[1].source == .extensionProvided && r.steps[1].why_disabled == "Cull first.")
        #expect(r.resume.kind == .left_off && r.resume.burst_id == "b0")
    }

    @Test("a missing identity field throws rather than becoming an empty string")
    func identityIsRequired() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Row.self, from: Data(#"{"stem": "x", "rating": "3"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ShootInfo.self, from: Data(#"{"frames": 3}"#.utf8))
        }
    }
}

@Suite("A burst names frames the way a picture route does")
struct BurstStemTests {
    @Test("a file name from the engine becomes the stem the routes answer to")
    func fileNamesBecomeStems() {
        #expect(Burst.stem("TSC07363.ARW") == "TSC07363")
        #expect(Burst.stem("TSC07363.arw") == "TSC07363")
        #expect(Burst.stem("DSC_0001.NEF") == "DSC_0001")
        #expect(Burst.stem("frame.001.jpg") == "frame.001")
        #expect(Burst.stem("TSC07363") == "TSC07363")           // already a stem
        #expect(Burst.stem("2026-09-21.a.name") == "2026-09-21.a.name")   // not a picture suffix
    }

    @Test("a burst decoded from an engine that sends file names still draws")
    func burstDecodesToStems() throws {
        let json = """
        {"id":"7","index":0,"scene":"0","started_at":null,
         "frames":["TSC07363.ARW","TSC07364.ARW"],"cover":"TSC07363.ARW",
         "seen":false,"kept":0,"out":0,"cull_picks":1,"undecided":2}
        """
        let burst = try JSONDecoder().decode(Burst.self, from: Data(json.utf8))
        #expect(burst.frames == ["TSC07363", "TSC07364"])
        #expect(burst.cover == "TSC07363")
    }
}
