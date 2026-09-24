import Foundation
import Testing
@testable import PipelineKit

/// "Choosing among 203 bursts, each row says only '1 of 4 exported'. He
/// can't see which bursts run long enough to be worth a reel, or which ones
/// he kept a frame from." Each row says how long the burst lasted, from its
/// frames' capture times, and has a dot when he kept a frame (DESIGN.md §2.6).
@Suite("Each burst in Reels says how long it lasted and whether he kept a frame")
@MainActor
struct ReelsBurstFactsTests {

    static func model(_ fixture: String = "shoot-bursts") throws -> ReelsModel {
        let c = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "t"))
        let r = try Fixture.decode(ShootResponse.self, fixture)
        return ReelsModel(session: ShootSession(response: r, ext: nil, client: c, pump: ImagePump(client: c)),
                          jobs: JobModel())
    }

    @Test("a capture time is read as the cull writes it, to the second or finer, across midnight")
    func captureTimes() throws {
        let a = try #require(CaptureTime.read("2026:09:13 16:32:28"))
        let b = try #require(CaptureTime.read("2026:09:13 16:32:31"))
        #expect(b.at - a.at == 3 && !a.fractional)
        let fine = try #require(CaptureTime.read("2026:09:13 16:32:28.45"))
        #expect(abs(fine.at - a.at - 0.45) < 0.0001 && fine.fractional)
        let zoned = try #require(CaptureTime.read("2026:09:13 16:32:28+02:00"))
        #expect(zoned.at == a.at)
        let late = try #require(CaptureTime.read("2026:09:13 23:59:59"))
        let early = try #require(CaptureTime.read("2026:09:14 00:00:01"))
        #expect(early.at - late.at == 2)
        for junk in [nil, "", "yesterday", "2026:09:13", "2026-09-13T16:32:28"] as [String?] {
            #expect(CaptureTime.read(junk) == nil, "\(junk ?? "nil")")
        }
    }

    @Test("a burst lasts from its first frame's capture to its last's, and needs two of them")
    func lengths() {
        #expect(BurstLength.of(["2026:09:13 16:32:28", "2026:09:13 16:32:28", "2026:09:13 16:32:29"])
                == BurstLength(seconds: 1, exact: false))
        #expect(BurstLength.of(["2026:09:13 16:32:29", nil, "2026:09:13 16:32:26"]) == BurstLength(seconds: 3, exact: false))
        #expect(BurstLength.of(["2026:09:13 16:32:28", nil, ""]) == nil)
        #expect(BurstLength.of(["2026:09:13 16:32:28.1", "2026:09:13 16:32:29.3"])?.exact == true)
    }

    @Test("said to the second the times are written to, and plainly to VoiceOver")
    func words() {
        #expect(Strings.Reels.lastedShort(BurstLength(seconds: 0, exact: false)) == "<1 s")
        #expect(Strings.Reels.lastedShort(BurstLength(seconds: 3, exact: false)) == "3 s")
        #expect(Strings.Reels.lasted(BurstLength(seconds: 0, exact: false)) == "under 1 s")
        #expect(Strings.Reels.lasted(BurstLength(seconds: 3, exact: false)) == "about 3 s")
        #expect(Strings.Reels.lastedShort(BurstLength(seconds: 1.24, exact: true)) == "1.2 s")
    }

    @Test("the page reads each burst's length off the shoot's own frames, not the lister's running time")
    func fromTheShoot() throws {
        let m = try Self.model()
        #expect(m.length(of: "0") == BurstLength(seconds: 1, exact: false))
        #expect(m.length(of: "2") == BurstLength(seconds: 2, exact: false))
        #expect(m.length(of: "no-such-burst") == nil)
        // The lister's `seconds` is the reel maker's arithmetic, and is not it.
        let listed = try ReelsScaffold.burst93().sequences.first { $0.seconds != nil }
        #expect(listed?.seconds != nil)
        #expect(m.length(of: listed?.burst ?? "") == nil, "nothing is taken from it")
    }

    @Test("the dot is his: the engine's count for the burst, a frame he kept since, or the lister's where the shoot has no such burst")
    func keptDot() throws {
        let m = try Self.model()
        func option(_ burst: String, kept: Int) throws -> BurstOption {
            try BurstOption(fields: Fields(["burst": .string(burst), "frames": .integer(4), "kept": .integer(kept)]))
        }
        let zero = try option("0", kept: 0), two = try option("2", kept: 5)
        let listedKept = try option("elsewhere", kept: 1), listedNot = try option("elsewhere", kept: 0)
        #expect(m.keptOne(zero), "the engine counts one kept in burst 0")
        #expect(!m.keptOne(two), "the shoot's own count wins over the lister's")
        #expect(m.keptOne(listedKept))
        #expect(!m.keptOne(listedNot))
    }

    /// "The kept dot stays after he un-keeps his only kept frame of a burst":
    /// the engine's count was read when the shoot was opened, and no press
    /// moves it.
    @Test("the dot follows what he does on the light table, without the shoot being read again")
    func keptDotFollowsHim() async throws {
        // Burst 2 as the engine sends it after an earlier launch: its first
        // frame kept by him, and counted.
        var top = try #require(JSONSerialization.jsonObject(with: Fixture.data("shoot-bursts")) as? [String: Any])
        var rows = try #require(top["rows"] as? [[String: Any]])
        var bursts = try #require(top["bursts"] as? [[String: Any]])
        let two = try #require(bursts.firstIndex { $0["id"] as? String == "2" })
        let first = Burst.stem(try #require((bursts[two]["frames"] as? [String])?.first))
        for i in rows.indices where rows[i]["stem"] as? String == first { rows[i]["override"] = 5 }
        bursts[two]["kept"] = 1
        top["rows"] = rows
        top["bursts"] = bursts
        let response = try JSONDecoder().decode(ShootResponse.self, from: JSONSerialization.data(withJSONObject: top))
        let session = ShootSession(response: response, ext: nil, client: LiveCountsTests.client(),
                                   pump: ImagePump(budget: .base, loader: { _ in Data() }),
                                   queue: VerdictQueue(sender: { _ in .success(RatingResult(ok: true, key_note: "")) }))
        let m = ReelsModel(session: session, jobs: JobModel())
        func dot(_ burst: String) throws -> Bool {
            m.keptOne(try BurstOption(fields: Fields(["burst": .string(burst), "frames": .integer(4)])))
        }
        func onScreen(_ burst: String, frame: Int = 0) throws {
            session.go(burst: try #require(session.bursts.firstIndex { $0.id == burst }), frame: frame)
            session.didDisplay(stem: try #require(session.currentStem), generation: session.cursor.generation)
        }
        #expect(try dot("2"))

        // D on the one frame he had kept: no dot, where it stayed.
        try onScreen("2")
        #expect(await session.drop(advance: false) == .applied)
        #expect(try !dot("2"))
        // K on it again, and then its mark cleared.
        #expect(await session.keep(advance: false) == .applied)
        #expect(try dot("2"))
        #expect(await session.clear() == .applied)
        #expect(try !dot("2"), "not been through, and the cull rated none of it in")

        // N on a burst the cull rated two frames of in: the picks he left
        // standing are his, as they are in "you kept" everywhere else.
        #expect(try !dot("3"))
        try onScreen("3")
        #expect(await session.finishBurst() == .applied)
        #expect(try dot("3"))
        #expect(await session.unmarkBurst("3") == .applied)
        #expect(try !dot("3"))

        // A burst he has not touched keeps the engine's own count.
        #expect(try dot("0"))
    }
}
