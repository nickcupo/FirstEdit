import Foundation
import Testing
@testable import PipelineKit

/// Decision 4: Compare marks its sharpest frame (DESIGN.md §2.5.12), and the
/// inspector says where a frame's focus figure sits in its burst.
@Suite("Compare names its sharpest frame")
struct SharpnessTests {

    static func rows(_ focus: [String: Double?]) -> [String: Row] {
        var out: [String: Row] = [:]
        for (stem, f) in focus {
            var fields: [String: JSONValue] = ["file": .string("\(stem).ARW"), "stem": .string(stem),
                                               "rating": .string("3")]
            if let f { fields["focus"] = .number(f) }
            out[stem] = try! Row(fields: Fields(fields))
        }
        return out
    }

    @Test("the one the cull measures sharpest is named, and the rest say how far under it they are")
    func standings() throws {
        // His burst 265's stack, as the cull measured it.
        let rows = Self.rows(["07179": 161, "07180": 156, "07181": 152, "07182": 61])
        let s = Sharpness.standings(["07179", "07180", "07181", "07182"], rows: rows)
        #expect(s["07179"]?.sharpest == true)
        #expect(s.values.filter(\.sharpest).count == 1)
        #expect(s["07180"]?.under == 3)
        #expect(s["07181"]?.under == 6)
        #expect(s["07182"]?.under == 62)
        #expect(s.values.allSatisfy { $0.of == 4 && $0.bestStem == "07179" && $0.best == 161 })
        #expect(Strings.LightTable.compareSharpest(of: 4) == "sharpest of 4")
        #expect(Strings.LightTable.compareSofter(62) == "62% softer")
        #expect(Strings.LightTable.compareSofter(0) == "as sharp")
    }

    @Test("equal figures name the first shown, and a frame with no figure stands nowhere")
    func tiesAndGaps() {
        let rows = Self.rows(["a": 100, "b": 100, "c": nil, "d": 99.8])
        let s = Sharpness.standings(["b", "a", "c", "d"], rows: rows)
        #expect(s["b"]?.sharpest == true && s["a"]?.sharpest == false)
        #expect(s["a"]?.under == 0)
        #expect(s["d"]?.under == 0, "a fifth of a percent is not softer")
        #expect(s["c"] == nil)
        #expect(s["b"]?.of == 3)
        // One figure has nothing to stand against.
        #expect(Sharpness.standings(["a", "c"], rows: rows).isEmpty)
    }

    @Test("the inspector's typical figure is the middle of the burst's, not the next cull's setting")
    func typical() {
        let rows = Self.rows(["a": 161, "b": 156, "c": 152, "d": 61, "e": nil])
        #expect(Sharpness.typical(["a", "b", "c", "d", "e"], rows: rows) == 154)
        #expect(Sharpness.typical(["a", "b", "c"], rows: rows) == 156)
        #expect(Sharpness.typical(["a", "e"], rows: rows) == nil)
        #expect(Strings.LightTable.focusAgainstTypical(161, 154) == "161 · most in this burst near 154")
    }
}
