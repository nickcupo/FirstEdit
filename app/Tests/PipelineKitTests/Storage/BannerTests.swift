import Foundation
import Testing
@testable import PipelineKit

/// When a run lands, the page says what it changed (§2.9). Nothing ever set
/// the banner: the running row disappeared after six minutes and the page
/// re-rendered without a word.
@Suite("A run that lands says what it changed")
@MainActor
struct BannerTests {

    /// The fixture as the engine wrote it, edited the way a run would leave
    /// the panel different.
    private func panel(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Learned {
        var json = try JSONSerialization.jsonObject(
            with: StorageFixture.data("learned-in-use-beside-held")) as! [String: Any]
        edit(&json)
        return try JSONDecoder().decode(Learned.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func learner(_ json: inout [String: Any], _ id: String, _ change: (inout [String: Any]) -> Void) {
        var rows = json["learners"] as! [[String: Any]]
        let i = rows.firstIndex { $0["id"] as? String == id }!
        change(&rows[i])
        json["learners"] = rows
    }

    @Test("a run that changed nothing says so, and names the shoot it learned from")
    func nothing() throws {
        let before = try panel { $0["new_to_learn_from"] = ["2026-09-19"] }
        let said = LearnedModel.landed(before: before, after: try panel(), stoppedByHim: false)
        #expect(said.text == "The cull learned from 2026-09-19. " + Strings.Learning.bannerNothing)
        #expect(said.first == nil)
    }

    @Test("a new version in use is named, and the button goes to its row")
    func inUse() throws {
        let before = try panel { j in
            learner(&j, "edit") { l in
                var live = l["live"] as! [String: Any]
                live["version"] = "20260901-000000"
                l["live"] = live
            }
        }
        let said = LearnedModel.landed(before: before, after: try panel(), stoppedByHim: false)
        // The starting edit is a preset: it hides no keeper, so the banner
        // does not say none is hidden by it. It says where it is used.
        #expect(said.text.contains(Strings.Learning.bannerInUseEdit("Your starting edit")))
        #expect(!said.text.contains("hidden"))
        #expect(said.first == "edit")
    }

    @Test("a version the run learned and the check held is said as held")
    func held() throws {
        let before = try panel { j in
            learner(&j, "tier-order") { l in l["candidate"] = NSNull() }
        }
        let said = LearnedModel.landed(before: before, after: try panel(), stoppedByHim: false)
        #expect(said.text.contains(Strings.Learning.bannerHeld("Which frames of a burst you keep")))
        #expect(said.first == "tier-order")
    }

    @Test("stood down for his own work, or stopped by him: said as that, not as a result")
    func pausedOrStopped() throws {
        let queued = try panel { $0["queued"] = true }
        #expect(LearnedModel.landed(before: try panel(), after: queued, stoppedByHim: false).text
                == Strings.Learning.pausedForYou)
        #expect(LearnedModel.landed(before: try panel(), after: try panel(), stoppedByHim: true).text
                == Strings.Learning.stoppedBanner)
    }
}

/// The engine always sends its three learners, so the first page he meets is
/// the engine's real first answer, not an empty list.
@Suite("The first run names the shoot waiting")
@MainActor
struct FirstRunLearningTests {
    @Test("three learners with nothing learned are one short section, and the shoot just finished is named")
    func realFirstAnswer() throws {
        let l = try StorageFixture.decode(Learned.self, "learned-first-run")
        #expect(l.learners.count == 3)
        #expect(LearnedView.nothingLearned(l))
        #expect(l.new_shoot_names == ["2026-09-19"])
        #expect(LearnedView.waiting(l) == "Ready to learn from 2026-09-19")
        let held = try StorageFixture.decode(Learned.self, "learned-in-use-beside-held")
        #expect(!LearnedView.nothingLearned(held))
        let none = try StorageFixture.decode(Learned.self, "learned-empty")
        #expect(!LearnedView.nothingLearned(none), "no learners at all keeps the designed empty state")
    }
}
