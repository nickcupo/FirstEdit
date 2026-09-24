import Foundation
import Testing
@testable import PipelineKit

/// What Reels remembers across a relaunch (DESIGN.md §2.6): his habits for
/// every shoot, and where he was in each.
@Suite("Reels remembers", .serialized)
@MainActor
struct ReelsMemoryTests {

    @Test("a relaunch opens Reels on the burst, format and frames he left, at his speed, crop, size and order")
    func relaunchKeepsHisPlace() async throws {
        let defaults = scratchDefaults()
        let jobs = JobModel()
        let first = ReelsModelStore(memory: ReelsMemory(defaults: defaults))
        let m = first.model(for: try session("shoot-decided"), jobs: jobs)
        m.preview(try ReelsScaffold.burst93(), burst: "93")
        m.choose(format: .loop)
        m.speed = 10
        m.follow = ReelFollowBase.none
        m.size = .w1440
        m.order = .best
        m.toggle("TSC06264")
        m.choose(format: .timelapse)
        m.speed = 6                                         // the timelapse's own
        m.choose(format: .loop)
        try await Task.sleep(for: .milliseconds(20))        // the write follows the change
        first.reset()

        let relaunched = ReelsModelStore(memory: ReelsMemory(defaults: defaults))
        let again = relaunched.model(for: try session("shoot-decided"), jobs: jobs)
        #expect(again.format == .loop && again.burst == "93")
        #expect(again.leftOut == ["TSC06264"])
        #expect(again.burstSpeed == 10 && again.timelapseSpeed == 6)
        #expect(again.burstFollow == ReelFollowBase.none && again.size == .w1440 && again.order == .best)

        // Another shoot has its own place and his same habits.
        let other = relaunched.model(for: try session("shoot-not-culled"), jobs: jobs)
        #expect(other.burst == nil && other.leftOut.isEmpty && other.format == .cut)
        #expect(other.burstSpeed == 10 && other.size == .w1440)
        relaunched.reset()
    }

    @Test("a remembered burst the lister no longer offers is let go for the one it ranks first")
    func aGoneBurstIsLetGo() async throws {
        let m = ReelsScaffold.model()
        let answer = try ReelsScaffold.burst93()
        var asked: [String?] = []
        m.fetchOptions = { _, b, _ in asked.append(b); return answer }
        m.burst = "99999"
        m.load()
        for _ in 0..<200 where m.burst == "99999" || m.framesBurst != m.burst {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(m.burst == answer.cuts.first?.burst)
        #expect(asked.first == "99999")
    }

    @Test("a model made outside the store, and the harness's, remember nothing")
    func nothingOutsideTheStore() throws {
        #expect(!ReelsMemory.none.remembers)
        let store = ReelsModelStore(memory: .none)
        let m = store.model(for: try session("shoot-decided"), jobs: JobModel())
        m.order = .best
        #expect(ReelsMemory.none.habits() == nil)
        store.reset()
    }

    func session(_ fixture: String) throws -> ShootSession {
        let c = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "t"))
        let r = try Fixture.decode(ShootResponse.self, fixture)
        return ShootSession(response: r, ext: nil, client: c, pump: ImagePump(client: c))
    }
}
