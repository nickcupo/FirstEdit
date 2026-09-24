import Foundation
import Testing
@testable import PipelineKit

/// The review behind "See the 48" is sorted by what would change, the change
/// said once over each group, the costly one first.
@Suite("The review is grouped by what would change")
struct ReviewGridTests {

    private func frames(_ id: String) throws -> [LearnerFrame] {
        let l = try StorageFixture.decode(Learned.self, "learned-in-use-beside-held")
        return try #require(l.learners.first { $0.id == id }?.check?.frames)
    }

    @Test("the frames that would go out of sight come first, then the ones moved lower, then the ones shown more")
    func costlyFirst() throws {
        let all = try frames("drop-reasons")
        let g = ReviewGroups(all)
        #expect(g.frames.count == all.count, "every frame is in exactly one group")
        #expect(Set(g.frames.map(\.id)) == Set(all.map(\.id)))
        let heads = g.groups.map { "\($0.now)→\($0.new)" }
        // Read off the frames' own moves, not a list of the engine's words:
        // "out of sight" is below "folded away", which is below "shown".
        #expect(heads.first == "shown→out of sight", "\(heads)")
        #expect(heads.firstIndex(of: "folded away→out of sight")! < heads.firstIndex(of: "shown→folded away")!)
        #expect(g.groups.prefix { $0.down }.count == 3 && g.groups.suffix(2).allSatisfy { !$0.down },
                "every move down before any move up: \(heads)")
        // 16 out of sight (14 from shown, 2 from folded away), 20 moved
        // lower, 12 shown more.
        #expect(Array(g.groups.map(\.count).prefix(3)) == [14, 2, 20])
        #expect(g.groups.dropFirst(3).map(\.count).reduce(0, +) == 12)
    }

    @Test("frames from more than one shoot are named by shoot inside each group")
    func byShoot() throws {
        let g = ReviewGroups(try frames("drop-reasons"))
        #expect(g.namesShoots)
        for group in g.groups {
            #expect(Set(group.shoots.map(\.shoot)).count == group.shoots.count, "one run per shoot")
            #expect(group.shoots.allSatisfy { part in part.frames.allSatisfy { $0.shoot == part.shoot } })
        }
        let one = ReviewGroups(try frames("drop-reasons").filter { $0.shoot == "2026-09-16" })
        #expect(!one.namesShoots, "one shoot needs no line of its own")
    }

    @Test("the burst order: 81 moved later, then 35 earlier")
    func burstOrder() throws {
        let g = ReviewGroups(try frames("tier-order"))
        #expect(g.groups.map(\.count) == [81, 35])
        #expect(g.groups.map(\.down) == [true, false])
    }

    @Test("the arrow keys move a row by the columns the grid lays out")
    func columns() {
        #expect(ReviewGrid.columns(in: 900) == 3)
        #expect(ReviewGrid.columns(in: 300) == 1)
    }
}

@Suite("The button under the sentence says what it counts")
struct SeeThemTests {
    @Test("48 under a sentence about 16 says it is all 48 the version would change")
    func saysWhatItCounts() {
        #expect(Strings.Learning.seeThem(48) == "See All 48 It Would Change")
        #expect(Strings.Learning.seeThem(1) == "See the 1 It Would Change")
    }
}

@Suite("A date in the engine's sentence reads like the footer's")
struct LearnerDateTests {
    @Test("only the date the engine sent as data is re-read, and only when it reads")
    @MainActor
    func sinceIsLocal() {
        let s = LearnerRow.dated("In use since 2026-09-22. Learned from 2026-09-21.", "2026-09-22")
        #expect(!s.contains("2026-09-22") && s.contains("Sep"), "\(s)")
        #expect(s.contains("2026-09-21"), "another date in the sentence is the engine's to say")
        #expect(LearnerRow.dated("In use since whenever.", "whenever") == "In use since whenever.")
        #expect(LearnerRow.dated("In use.", nil) == "In use.")
    }
}

/// What a learner is short of: a fact to a line, and a button for each shoot
/// a line asks him to act on — not a paragraph ending in a command.
@Suite("A needs line carries what he can press")
struct NeedsLinesTests {

    @Test("the engine's lines and the shoots to act on are read")
    func decoded() throws {
        let l = try StorageFixture.decode(Learned.self, "learned-in-use-beside-held")
        let byID = Dictionary(uniqueKeysWithValues: l.learners.map { ($0.id, $0) })
        let edit = try #require(byID["edit"])
        #expect(edit.needs_lines.first == "Waiting on you:")
        #expect(edit.needs_do == [LearnerNeed(shoot: "2026-09-05-the-gals", act: .pull)])
        #expect(!edit.needs_lines.joined().contains("./pl"), "no command on the page")
        #expect(edit.candidate_sentence.hasSuffix("Bringing photographs back does not settle this."),
                "the caveat is on the line it is about")
        #expect(try #require(byID["tier-order"]).needs_do == [LearnerNeed(shoot: "2026-09-13-dog", act: .finish)])
        #expect(try #require(byID["drop-reasons"]).needs_lines.count == 4)
    }

    @Test("the buttons name the shoot they act on")
    func buttons() {
        #expect(Strings.Learning.needButton(.init(shoot: "2026-09-05-the-gals", act: .pull))
                == "Bring 2026-09-05-the-gals Back…")
        #expect(Strings.Learning.needButton(.init(shoot: "2026-09-13-dog", act: .finish)) == "Open 2026-09-13-dog")
    }

    @Test("the footer names the shoots waiting to be learned from")
    func footer() {
        #expect(Strings.Learning.readyToLearnFrom(["2026-09-19"]) == "Ready to learn from 2026-09-19")
        #expect(Strings.Learning.readyToLearnFrom(["a", "b", "c"]) == "Ready to learn from a and 2 more")
        #expect(Strings.Learning.readyToLearnFrom([]) == Strings.Learning.nothingNew)
    }
}

@Suite("A learner's row reads in the order he asks")
struct LearnerRowOrderTests {
    @Test("what it changes first and as a sentence, the store's reassurance last, one way of drawing the pause")
    func order() throws {
        let row = try #require(SafetyTests.sources.first { $0.name == "LearnerRow.swift" }?.text)
        let body = String(row[try #require(row.range(of: "private var detail")).lowerBound...])
        let changes = try #require(body.range(of: "learner.changes.capitalizedFirst"))
        let sentence = try #require(body.range(of: "Text(sentence)"))
        let metric = try #require(body.range(of: "learner.plain_metric.capitalizedFirst"))
        #expect(changes.lowerBound < sentence.lowerBound && sentence.lowerBound < metric.lowerBound)
        #expect(row.components(separatedBy: ".symbolRenderingMode(.hierarchical)").count - 1 == 2,
                "the title's symbol and the held line's are drawn alike")
    }
}
