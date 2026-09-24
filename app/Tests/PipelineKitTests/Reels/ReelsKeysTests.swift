import AppKit
import Foundation
import Testing
@testable import PipelineKit

/// The Reels page from the keyboard (DESIGN.md §2.6): Return in the burst
/// field goes to a burst and never cuts one, ⌘F reaches the field, and Shoot ▸
/// Cut a Reel is there while the page is.
@Suite("Reels from the keyboard", .serialized)
@MainActor
struct ReelsKeysTests {

    @Test("Return in the burst field goes to the burst typed, exactly, before one that merely contains it")
    func returnGoesToTheBurst() throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.burst93(), burst: "231")
        m.order = .best                     // 193 is not before 93 by number, so rank them
        #expect(ReelsModel.searched(m.bursts, "93")?.burst == "93")
        #expect(ReelsModel.searched(m.bursts, " 19")?.burst.contains("19") == true)
        #expect(ReelsModel.searched(m.bursts, "nothing") == nil)

        m.search = "93"
        #expect(m.goToSearched())
        #expect(m.burst == "93")
        // The whole list comes back around it.
        #expect(m.search.isEmpty && m.shownBursts.count == m.bursts.count)

        m.search = "no such burst"
        #expect(!m.goToSearched())
        #expect(m.burst == "93" && m.search == "no such burst")
    }

    @Test("Return with nothing typed in the burst field goes nowhere, rather than to the top of the list")
    func returnInAnEmptyField() throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.burst93(), burst: "231")
        #expect(ReelsModel.searched(m.bursts, "") == nil)
        #expect(ReelsModel.searched(m.bursts, "   ") == nil)
        m.search = "  "
        #expect(!m.goToSearched())
        #expect(m.burst == "231")
    }

    @Test("typing down to one burst chooses it without Return, and two or more choose nothing")
    func oneMatchChoosesItself() throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.burst93(), burst: "231")
        m.search = "93"                     // 93 and 193
        m.searchChanged()
        #expect(m.burst == "231")
        m.search = "193"
        m.searchChanged()
        #expect(m.burst == "193")
    }

    @Test("while the burst field has the keyboard, Return is not Cut It's")
    func cutItLetsGoOfReturn() {
        let typing = StepPrimary("Cut It", wouldWait: false, returnKey: false, doItNow: {}, addToTheList: {})
        let elsewhere = StepPrimary("Cut It", wouldWait: false, doItNow: {}, addToTheList: {})
        #expect(!typing.returnKey)
        #expect(elsewhere.returnKey)
    }

    @Test("N and P from the frames walk the list as it is shown, and stop at its ends")
    func nAndPWalkTheList() throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.burst93(), burst: "93")
        let list = m.shownBursts.map(\.burst)
        let i = try #require(list.firstIndex(of: "93"))
        #expect(m.chooseNeighbour(1))
        #expect(m.burst == list[i + 1])
        #expect(m.chooseNeighbour(-1) && m.chooseNeighbour(-1))
        #expect(m.burst == list[i - 1])
        m.choose(burst: list[0])
        #expect(!m.chooseNeighbour(-1) && m.burst == list[0])
        // With the chosen burst filtered out of the list, N goes to the
        // first burst the list shows.
        m.search = "193"
        #expect(m.chooseNeighbour(1))
        #expect(m.burst == "193")
        #expect(!m.chooseNeighbour(1))
    }

    @Test("the keys start on the burst's first frame once its frames are read")
    func theCursorStartsOnTheFirstFrame() async throws {
        let m = ReelsScaffold.model()
        let answer = try ReelsScaffold.burst93()
        m.fetchOptions = { _, _, _ in answer }
        m.burst = "93"
        m.load()
        for _ in 0..<200 where m.framesBurst != "93" { try await Task.sleep(for: .milliseconds(5)) }
        #expect(m.cursor == "TSC06264")
    }

    @Test("⌘F asks for the burst field on a burst format, and a timelapse has none to ask for")
    func findReachesTheField() throws {
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.burst93(), burst: "93")
        m.find()
        #expect(m.findRequests == 1)
        m.choose(format: .timelapse)
        m.find()
        #expect(m.findRequests == 1)
    }

    @Test("Find Burst is live while a Reels page is on screen and greyed once it has gone, and Cut a Reel is not the page's to register")
    func theMenuFollowsThePage() throws {
        let center = CommandCenter()
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.burst93(), burst: "93")
        #expect(!center.canRun(CommandTable.ID.findBurst))
        ReelsCommands.attach(m, center: center)
        #expect(center.canRun(CommandTable.ID.findBurst))
        #expect(center.run(CommandTable.ID.findBurst))
        #expect(m.findRequests == 1)
        // Cut a Reel has one owner, the shell's, which presses the page's
        // button through `.answersMenu` so ⌥ adds to Up Next as it does there.
        #expect(!center.canRun(CommandTable.ID.cutAReel))
        ReelsCommands.detach(m)
        #expect(!center.canRun(CommandTable.ID.findBurst))
    }

    @Test("the Frame rows teach the page's keys while it is up: Keep is Include, Drop is Leave Out, Next Burst records nothing, and Undo names the change")
    func theFrameRowsTeachTheScheme() throws {
        let center = CommandCenter()
        var appsUndo = 0
        center.register(CommandTable.ID.undo) { appsUndo += 1 }
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.burst93(), burst: "93")
        ReelsCommands.attach(m, center: center)
        #expect(center.title(CommandTable.ID.keep) == Strings.Reels.includeNamed("06264"))
        #expect(center.title(CommandTable.ID.drop) == Strings.Reels.leaveOutNamed("06264"))
        #expect(center.help(CommandTable.ID.finishBurst) == Strings.Reels.nextBurstHelp)
        #expect(center.run(CommandTable.ID.drop))
        #expect(!m.isIn("TSC06264") && m.cursor == "TSC06265")
        #expect(center.title(CommandTable.ID.undo) == Words.Edit.undoNamed(Strings.Reels.leaveOutNamed("06264")))
        #expect(center.run(CommandTable.ID.undo))
        #expect(m.isIn("TSC06264") && appsUndo == 0)
        // Greyed while a frame is open large: the viewer in front has the keys.
        m.openLarge("TSC06266")
        #expect(!center.canRun(CommandTable.ID.keep) && !center.canRun(CommandTable.ID.nextFrame))
        m.look = nil
        // The page goes: the Frame rows grey, Undo is the app's again.
        ReelsCommands.detach(m)
        #expect(!center.canRun(CommandTable.ID.keep))
        #expect(center.run(CommandTable.ID.undo) && appsUndo == 1)
    }

    @Test("a row the app answers elsewhere is the Reels page's only while it is on screen, and the app's again after")
    func theAppsOwnerComesBack() throws {
        let center = CommandCenter()
        var lightTableFinds = 0, goneToReels = 0
        center.register(CommandTable.ID.findBurst) { lightTableFinds += 1 }
        center.register(CommandTable.ID.cutAReel) { goneToReels += 1 }
        let m = ReelsScaffold.model()
        m.preview(try ReelsScaffold.burst93(), burst: "93")
        ReelsCommands.attach(m, center: center)
        #expect(center.run(CommandTable.ID.findBurst))
        #expect(m.findRequests == 1 && lightTableFinds == 0)
        // A timelapse has no burst field: greyed on Reels, not handed on.
        m.choose(format: .timelapse)
        #expect(!center.canRun(CommandTable.ID.findBurst))
        m.choose(format: .cut)

        // The next page comes on screen before this one has gone.
        let next = ReelsScaffold.model()
        next.preview(try ReelsScaffold.burst93(), burst: "93")
        ReelsCommands.attach(next, center: center)
        ReelsCommands.detach(m)
        #expect(center.run(CommandTable.ID.findBurst))
        #expect(next.findRequests == 1 && m.findRequests == 1 && lightTableFinds == 0)

        // The last Reels page goes: ⌘F is the light table's again, and Cut a
        // Reel the app's.
        ReelsCommands.detach(next)
        #expect(center.run(CommandTable.ID.findBurst))
        #expect(center.run(CommandTable.ID.cutAReel))
        #expect(lightTableFinds == 1 && goneToReels == 1 && next.findRequests == 1)
    }
}

/// What the Reels suites share: a model on a captured shoot and the lister's
/// real answer about burst 93.
@MainActor
enum ReelsScaffold {
    static func model() -> ReelsModel {
        let c = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "t"))
        let r = try! Fixture.decode(ShootResponse.self, "shoot-decided")
        let s = ShootSession(response: r, ext: nil, client: c, pump: ImagePump(client: c))
        return ReelsModel(session: s, jobs: JobModel())
    }

    static func burst93() throws -> ReelOptions { try Fixture.decode(ReelOptions.self, "reel-options-burst") }

    /// The same answer as the lister would give about another burst: its
    /// frames renamed, so two bursts never share a stem.
    static func options(about burst: String, frames: Int = 13) throws -> ReelOptions {
        var o = try #require(try JSONSerialization.jsonObject(with: Fixture.data("reel-options-burst")) as? [String: Any])
        o["frames"] = (0..<frames).map { i in
            ["stem": "B\(burst)F\(i)", "visible": true, "exported": false] as [String: Any]
        }
        return try JSONDecoder().decode(ReelOptions.self, from: JSONSerialization.data(withJSONObject: o))
    }
}
