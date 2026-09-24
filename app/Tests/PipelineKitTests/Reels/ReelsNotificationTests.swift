import Foundation
import Testing
import UserNotifications
@testable import PipelineKit

/// A reel cut while he is in PhotoLab ends with a notification, and clicking
/// it lands on Reels, where the reel is (DESIGN.md §2.7).
@Suite("A reel's notification", .serialized)
@MainActor
struct ReelsNotificationTests {

    @Test("a reel opens Reels; the presets written for one open PhotoLab, which is the answer; a cull opens Choose Keepers")
    func landsOnReels() throws {
        let n = Notifications()
        n.isAvailable = true
        n.allowed = true
        n.isFrontmost = { false }
        nonisolated(unsafe) var steps: [String] = []
        n.post = { content, _ in steps.append(content.userInfo["step"] as? String ?? "") }

        for (i, kind) in ["reel", "spread", "cull"].enumerated() {
            n.jobChanged(try Fixture.decodeJob(running: false, fraction: 1, kind: kind,
                                               title: "job \(i)", code: 0))
        }
        // The presets for a burst end with PhotoLab opening in front of him,
        // and a banner over that is a second answer (§2.7); were one posted,
        // `Notifications.step(for:)` sends that work to Reels as well.
        #expect(steps == ["reels", "keepers"])
        #expect(Notifications.step(for: try Fixture.decodeJob(running: false, fraction: 1, kind: "spread", code: 0)) == "reels")
    }
}
