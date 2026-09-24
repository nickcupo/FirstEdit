import Foundation
import Testing
@testable import PipelineKit

/// "On the light table on burst 93 he thinks 'reel this' and presses ⌘6.
/// Reels opens on burst 231, the lister's top pick, after two lister round
/// trips." Reels opens on the burst he was on in Choose Keepers, in one
/// answer (DESIGN.md §2.6).
@Suite("Reels opens on the burst he was on in Choose Keepers", .serialized)
@MainActor
struct ReelsFromLightTableTests {

    /// A page whose lister counts what it is asked, and a light table on
    /// `on` (nil: not opened this launch).
    @MainActor final class Page {
        let model = ReelsScaffold.model()
        var asked: [String?] = []
        var on: String?
        init(on: String?) {
            self.on = on
            model.fetchOptions = { [unowned self] _, b, _ in
                self.asked.append(b)
                return try ReelsScaffold.options(about: b ?? "93")
            }
            model.lightTableBurst = { [unowned self] in self.on }
        }
        func arrive() async throws {
            model.appeared()
            for _ in 0..<400 where model.loading || model.options == nil || model.framesBurst != model.burst {
                try await Task.sleep(for: .milliseconds(5))
            }
            model.stopObserving()
        }
    }

    @Test("arriving from burst 93 opens on 93, and the lister is asked once, about 93")
    func opensOnHisBurst() async throws {
        let p = Page(on: "93")
        try await p.arrive()
        #expect(p.model.burst == "93" && p.model.framesBurst == "93")
        #expect(p.asked == ["93"], "one answer, not the top pick's and then his")
        #expect(p.model.frames.first?.stem == "B93F0")
    }

    @Test("coming back without moving on the light table keeps the burst he chose on Reels")
    func keepsHisReelsChoice() async throws {
        let p = Page(on: "93")
        try await p.arrive()
        p.model.choose(burst: "134")
        try await p.arrive()
        #expect(p.model.burst == "134")
        // Moving on the light table and coming back follows it again.
        p.on = "43"
        try await p.arrive()
        #expect(p.model.burst == "43")
    }

    @Test("a burst the lister does not offer is let go for its first pick")
    func notOffered() async throws {
        let p = Page(on: "999")
        try await p.arrive()
        try await p.arrive()
        #expect(p.model.burst == "231")
        #expect(p.asked.first == "999")
    }

    @Test("before the light table has been opened this launch, the burst remembered on Reels stays")
    func notOpenedYet() async throws {
        let p = Page(on: nil)
        p.model.burst = "195"
        try await p.arrive()
        #expect(p.model.burst == "195" && p.asked == ["195"])
    }

    @Test("the light table's place is the session's cursor, and only once it has moved")
    func theLightTablesPlace() throws {
        let m = ReelsScaffold.model()
        #expect(ReelsModel.lightTablePlace(m.session) == nil, "burst 0 of a shoot nobody opened is nobody's place")
        m.session.go(burst: 2)
        #expect(ReelsModel.lightTablePlace(m.session) == m.session.bursts[2].id)
        #expect(m.lightTableBurst() == m.session.bursts[2].id)
    }
}
