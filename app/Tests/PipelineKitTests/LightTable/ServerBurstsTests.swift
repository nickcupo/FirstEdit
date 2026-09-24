import Foundation
import Testing
@testable import PipelineKit

/// The light table against the bursts the engine sends **itself**.
///
/// Every earlier test and every snapshot ran on `Fallbacks.legacyBursts`,
/// because no captured fixture had a `bursts` array in it: the engine grew one
/// (DESIGN.md §3.9-6) after the fixtures were taken. So the path the app
/// actually uses on his Mac — `TodaysServer.bursts(in:)` returning the
/// server's array — had never been run against a real answer, and the server
/// names a burst's members by `file` where the whole app is keyed on `stem`.
///
/// `shoot-bursts.json` is the real engine's `GET /api/shoot` for the dog
/// shoot, bursts and all.
@Suite("Bursts the engine sends")
@MainActor
struct ServerBurstsTests {

    static func response() throws -> ShootResponse {
        try Fixture.decode(ShootResponse.self, "shoot-bursts")
    }

    static func session(_ r: ShootResponse) -> ShootSession {
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"))
        return ShootSession(response: r, ext: nil, client: client,
                            pump: ImagePump(budget: .base, loader: { _ in Data() }),
                            queue: VerdictQueue(sender: { _ in .failure(.offline) }))
    }

    @Test("the fixture is one the engine really groups: it carries bursts, named by file")
    func theFixtureHasServerBursts() throws {
        let data = try Fixture.data("shoot-bursts")
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let raw = try #require(obj["bursts"] as? [[String: Any]])
        #expect(!raw.isEmpty, "this fixture only tests anything while the engine sends its own bursts")
        let first = try #require(raw.first?["frames"] as? [String])
        #expect(first.first?.contains(".") == true,
                "the engine names a burst's frames by file; if that changed, this test is measuring nothing")
    }

    /// The bug, stated as the thing he saw: a burst of frames, not one of them
    /// with a row, and so not one of them with a picture.
    @Test("every frame of every burst has a row")
    func everyBurstFrameHasARow() throws {
        let s = Self.session(try Self.response())
        #expect(!s.bursts.isEmpty)
        let orphans = s.bursts.flatMap(\.frames).filter { s.rows[$0] == nil }
        #expect(orphans.isEmpty, "\(orphans.count) frames in bursts have no row: \(orphans.prefix(3))")
        let coverless = s.bursts.compactMap(\.cover).filter { s.rows[$0] == nil }
        #expect(coverless.isEmpty, "burst covers with no row: \(coverless.prefix(3))")
    }

    /// And the consequence, at the one place it shows: the stage asks the
    /// engine for a picture by name, and the name has to be one the engine
    /// serves. `/thumb/<shoot>/TSC04313.ARW.jpg` is a 404.
    @Test("the stage asks for a picture by a name the engine serves")
    func theStageAsksForANameTheEngineServes() throws {
        let r = try Self.response()
        let s = Self.session(r)
        let m = ViewerModel(session: s, navigation: Navigation())
        let stem = try #require(m.currentStem)
        #expect(!stem.contains("."), "the stage is pointed at \(stem), which is a file name, not a stem")
        #expect(s.rows[stem] != nil)
        let route = ImageRoute.thumb(shoot: s.name, stem: stem)
        #expect(route.path.hasSuffix("/\(stem).jpg"))
        #expect(!route.path.contains(".ARW"))
    }

    /// A row is what carries the decoded size, and the decoded size is what
    /// the stage lays the photograph out at. With no row it fell back to a
    /// guessed 6024 × 4024 — which is this camera's landscape frame, so the
    /// 16 frames of this shoot he turned the camera for were laid out on their
    /// side. The measurement is taken on one of those.
    @Test("the frame under the cursor is laid out at its own size, not a guess")
    func theFrameIsLaidOutAtItsOwnSize() throws {
        let r = try Self.response()
        let s = Self.session(r)
        let m = ViewerModel(session: s, navigation: Navigation())
        let portrait = try #require(r.rows.first { ($0.dw ?? 0) < ($0.dh ?? 0) },
                                    "this shoot has no upright frame to measure on")
        let where_ = try #require(s.bursts.firstIndex { $0.frames.contains(portrait.stem) })
        m.goToBurst(where_)
        let at = try #require(s.bursts[where_].frames.firstIndex(of: portrait.stem))
        m.goToFrame(at)
        #expect(m.currentStem == portrait.stem)
        let px = m.framePixels
        #expect(Int(px.width) == portrait.dw)
        #expect(Int(px.height) == portrait.dh)
        #expect(px.height > px.width, "an upright frame is being laid out on its side")
    }

    /// Nothing is hidden and nothing is invented: the burst holds exactly the
    /// frames the engine put in it, in the order it put them.
    @Test("the shape of the grouping is the engine's, untouched")
    func theGroupingIsTheEngines() throws {
        let data = try Fixture.data("shoot-bursts")
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let raw = try #require(obj["bursts"] as? [[String: Any]])
        let r = try Self.response()
        #expect(r.bursts.count == raw.count)
        for (decoded, sent) in zip(r.bursts, raw) {
            let sentFrames = sent["frames"] as? [String] ?? []
            #expect(decoded.frames.count == sentFrames.count)
            #expect(decoded.id == sent["id"] as? String)
        }
        #expect(r.bursts.map(\.frames).flatMap { $0 }.count == r.rows.count)
    }

    /// Whichever way the decoder settles a name, these two hold: a frame that
    /// the engine named by `file` ends up under that row's own stem, and a
    /// name that is already a stem is left alone. Written against the decoded
    /// response rather than any one helper, so it guards the behaviour and not
    /// the way it happens to be spelled.
    @Test("a file name becomes its row's stem, and a stem is left alone")
    func namesSettleOnStems() throws {
        let payload: [String: Any] = [
            "info": ["name": "a-shoot", "path": "/nowhere/a-shoot"],
            "rows": [["file": "A.ARW", "stem": "A"], ["file": "B.ARW", "stem": "B"]],
            "bursts": [["id": "0", "index": 0, "frames": ["A.ARW", "B"], "cover": "A.ARW"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let r = try JSONDecoder().decode(ShootResponse.self, from: data)
        let burst = try #require(r.bursts.first)
        #expect(burst.frames == ["A", "B"], "every frame is named the way its row is")
        #expect(burst.cover == "A")
        // Nothing is dropped on the way through.
        #expect(burst.frames.count == 2)
    }
}
