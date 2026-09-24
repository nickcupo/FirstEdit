import Foundation
import Testing
@testable import PipelineKit

/// "Nothing tells him which shoots still need keepers chosen or presets
/// written. That is the question he opens All Shoots to answer." Each row
/// says where its shoot is up to, from the steps the engine sends on the row
/// (DESIGN.md §2.1).
@Suite("All Shoots says where each shoot is up to")
@MainActor
struct UpToTests {

    /// The engine's steps as it sends them, done up to `doneThrough`.
    static func steps(doneThrough last: String?, disabled: Set<String> = []) -> [[String: Any]] {
        let ids = Fallbacks.baseStepIDs
        let through = last.flatMap { ids.firstIndex(of: $0) } ?? -1
        return ids.enumerated().map { i, id in
            ["id": id, "label": Fallbacks.baseLabel(id), "done": i <= through,
             "enabled": !disabled.contains(id), "why_disabled": disabled.contains(id) ? "Cull the shoot first." : NSNull(),
             "source": "base"]
        }
    }

    static func rows(_ edit: (inout [[String: Any]]) -> Void) throws -> ShootsResponse {
        try LastPlaceTests.shoots(edit: edit)
    }

    @Test("the first step not done that can be started, by the sidebar's name for it")
    func firstUndone() throws {
        let r = try Self.rows { rows in
            rows[1]["steps"] = Self.steps(doneThrough: "keepers")
            rows[1]["finished"] = false
        }
        let row = try #require(r.ok.first { $0.name == "2026-09-21" })
        #expect(row.upTo?.id == "presets")
        #expect(UpToCell.words(row, bursts: (3, 19), ext: nil) == "Presets", "only Choose Keepers counts bursts")
    }

    @Test("on Choose Keepers it counts the bursts been through, as the sidebar does")
    func keepersCounts() throws {
        let r = try Self.rows { rows in rows[1]["steps"] = Self.steps(doneThrough: "cull") }
        let row = try #require(r.ok.first { $0.name == "2026-09-21" })
        #expect(row.upTo?.id == "keepers")
        #expect(UpToCell.parts(row, bursts: (140, 288), ext: nil)?.count == "140/288")
        #expect(UpToCell.words(row, bursts: (140, 288), ext: nil) == "Choose Keepers · 140 of 288 bursts")
        #expect(UpToCell.words(row, bursts: nil, ext: nil) == "Choose Keepers")
    }

    @Test("a step that cannot be started yet is passed over, not named")
    func disabledPassedOver() throws {
        let r = try Self.rows { rows in
            rows[1]["steps"] = Self.steps(doneThrough: "cull", disabled: ["keepers"])
        }
        let row = try #require(r.ok.first { $0.name == "2026-09-21" })
        #expect(row.upTo?.id == "presets")
    }

    @Test("a finished shoot is up to nothing, and an engine that sent no steps says nothing")
    func finishedAndSilent() throws {
        let r = try Self.rows { rows in
            rows[3]["steps"] = Self.steps(doneThrough: "cull")     // 2026-09-16, finished
        }
        let finished = try #require(r.ok.first { $0.name == "2026-09-16" })
        #expect(finished.finished && finished.upTo == nil)
        let silent = try #require(r.ok.first { $0.name == "2026-09-19" })
        #expect(silent.steps == nil && silent.upTo == nil)
        #expect(UpToCell.words(silent, bursts: (3, 19), ext: nil) == nil,
                "done-ness is the engine's: nothing is worked out here")
    }

    @Test("the steps are the row's own and are not taken for something the extension added")
    func stepsAreKnown() throws {
        let r = try Self.rows { rows in rows[1]["steps"] = Self.steps(doneThrough: nil) }
        let row = try #require(r.ok.first { $0.name == "2026-09-21" })
        #expect(row.steps?.count == Fallbacks.baseStepIDs.count)
        #expect(row.extra["steps"] == nil)
    }
}
