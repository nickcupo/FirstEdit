import Foundation
import Testing
@testable import PipelineKit

/// §2.9: a check that could not reach a shoot for want of picture vectors
/// said "./pl learned vectors 2026-09-16 measures them" - a command to type,
/// on a page in an app. The row carries a Measure button now.
@Suite("Measure, beside a check that could not reach a shoot")
@MainActor
struct MeasureVectorsTests {

    static let row = #"""
    {"id": "drop-reasons", "title": "Why you drop frames", "state": "couldnt_check",
     "candidate_state": "couldnt_check",
     "candidate_sentence": "Waiting: a version has not been checked yet. Not checked yet, so nothing has changed: 2026-09-16 has no picture vectors kept; measured off its previews, it can be checked.",
     "check_do": [{"shoot": "2026-09-16", "do": "vectors"}, {"shoot": "", "do": "vectors"},
                  {"shoot": "2026-09-19", "do": "something-new"}]}
    """#

    @Test("the row carries the shoot to measure, and nothing it cannot act on")
    func decodes() throws {
        let l = try Fixture.decodeJSON(Learner.self, Self.row)
        #expect(l.check_do == [LearnerNeed(shoot: "2026-09-16", act: .vectors)])
        #expect(!l.candidate_sentence.contains("./pl"))
        // An engine that does not say has nothing to measure.
        let old = try Fixture.decodeJSON(Learner.self, #"{"id": "edit"}"#)
        #expect(old.check_do.isEmpty)
    }

    @Test("the button says what it does and to which shoot, and its help what comes after")
    func words() {
        let need = LearnerNeed(shoot: "2026-09-16", act: .vectors)
        #expect(Strings.Learning.needButton(need) == "Measure 2026-09-16")
        let help = Strings.Learning.needHelp(need)
        #expect(help.contains("Learn Now"))
        #expect(help.contains("Nothing in the shoot changes"))
        #expect(!help.contains("./pl"))
    }

    @Test("it asks the engine for the job the command was")
    func route() {
        #expect(LearnedModel.measureVectors.path == "/api/learned/vectors")
    }
}
