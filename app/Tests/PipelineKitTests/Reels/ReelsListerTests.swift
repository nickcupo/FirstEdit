import Foundation
import Testing
@testable import PipelineKit

/// How often Reels asks the lister (DESIGN.md §2.6): each ask is a process
/// that walks every export folder.
@Suite("Reels asks the lister", .serialized)
@MainActor
struct ReelsListerTests {

    /// A model on burst 93 whose lister counts what it is asked.
    func counted() async throws -> (ReelsModel, () -> [String?]) {
        let m = ReelsScaffold.model()
        var asked: [String?] = []
        m.fetchOptions = { _, b, _ in
            asked.append(b)
            return try ReelsScaffold.options(about: b ?? "93")
        }
        m.burst = "93"
        m.load()
        for _ in 0..<200 where m.framesBurst != "93" { try await Task.sleep(for: .milliseconds(5)) }
        return (m, { asked })
    }

    @Test("walking the bursts with N asks about the one he stops on, not every one he passes")
    func keysAskOnce() async throws {
        let (m, asked) = try await counted()
        for _ in 0..<5 { #expect(m.chooseNeighbour(1)) }
        let stop = try #require(m.burst)
        #expect(m.framesComing > 0)                     // the grid keeps the burst's places
        for _ in 0..<200 where m.framesBurst != stop { try await Task.sleep(for: .milliseconds(5)) }
        #expect(asked() == ["93", stop])
        #expect(m.framesComing == 0 && m.frames.first?.stem == "B\(stop)F0")
    }

    @Test("a burst looked at again this visit is not asked about again, until the page comes back")
    func answersAreKept() async throws {
        let (m, asked) = try await counted()
        m.choose(burst: "94")
        for _ in 0..<200 where m.framesBurst != "94" { try await Task.sleep(for: .milliseconds(5)) }
        m.choose(burst: "93")
        #expect(m.framesBurst == "93" && m.frames.first?.stem == "B93F0")     // at once
        #expect(asked() == ["93", "94"])
        m.appeared()                                    // exports may have come meanwhile
        for _ in 0..<200 where asked().count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(asked() == ["93", "94", "93"])
        m.stopObserving()
    }
}
