import Testing
import Foundation
@testable import PipelineKit

/// Each page's main button appears once, at its bottom right (DESIGN.md §2.3,
/// §2.6). Copy, Cull It, Write the Presets, Open and Finish This Shoot were
/// each drawn in the toolbar as well: two things to read for one action, and a
/// greyed Finish This Shoot stayed up there after finishing. The toolbar holds
/// a second action only — Cull Again…, Write Them Again… — and never Return.
@Suite("One main button per page") @MainActor
struct OnePrimaryTests {

    static let pages = ["ImportStep.swift", "CullStep.swift", "PresetsStep.swift", "EditStep.swift", "FinishStep.swift",
                        "ReelsStep.swift"]
    static let seconds = ["Strings.Cull.again", "Strings.Presets.again"]

    @Test("a step's toolbar holds only its second action, never a copy of the primary")
    func toolbarHoldsOnlyASecondAction() throws {
        var items = 0
        for page in Self.pages {
            let text = try #require(StepShortcutTests.sources.first { $0.name == page }?.text, "\(page) not found")
            for item in text.components(separatedBy: "ToolbarItem(").dropFirst() {
                // The item's own contents: up to the trailing closure pair
                // every toolbar button here ends with.
                let body = String(item.prefix(600))
                items += 1
                #expect(Self.seconds.contains { body.contains($0) }, "\(page) puts something else in its toolbar")
                #expect(!body.contains(".defaultAction"), "\(page)'s toolbar button takes Return")
            }
        }
        #expect(items == 2, "Cull Again… and Write Them Again…, and nothing else")
    }

    /// Reels drew Cut It in the toolbar and in its bottom box, and the
    /// learning page had Learn Now only in the toolbar's far corner. Each is
    /// its page's main button, bottom right, once.
    @Test("Reels and the learning page draw their main button once, at the bottom right")
    func reelsAndLearning() throws {
        let reels = try #require(StepShortcutTests.sources.first { $0.name == "ReelsStep.swift" }?.text)
        #expect(!reels.contains(".toolbar {"), "Cut It is drawn in the toolbar as well")
        #expect(reels.contains("StepActionBar {"))
        #expect(reels.contains(".answersMenu([CommandTable.ID.cutAReel]"), "Shoot ▸ Cut a Reel still answers")

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/PipelineKit/Learning/LearnedView.swift")
        let learned = try String(contentsOf: url, encoding: .utf8)
        #expect(!learned.contains(".toolbar {"), "Learn Now is in the toolbar")
        #expect(learned.components(separatedBy: "Button(action: learnNow)").count == 2, "one Learn Now")
        #expect(!learned.contains("Button(Strings.Learning.learnNow"), "a second Learn Now in the page")
        #expect(learned.contains("StepActionBar {"))
    }

    @Test("the second actions are only offered once there is something to do again")
    func onlyOnceDone() throws {
        let cull = try #require(StepShortcutTests.sources.first { $0.name == "CullStep.swift" }?.text)
        let presets = try #require(StepShortcutTests.sources.first { $0.name == "PresetsStep.swift" }?.text)
        #expect(cull.contains("if session.info.culled {\n                ToolbarItem("))
        #expect(presets.contains("if written {\n                ToolbarItem("))
    }
}
