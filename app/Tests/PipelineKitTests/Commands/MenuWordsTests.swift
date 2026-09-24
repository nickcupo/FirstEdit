import AppKit
import Foundation
import Testing
@testable import PipelineKit

/// What the rows say, and the rows that are not there (DESIGN.md §2.12).
@Suite("The menus' words", .serialized)
@MainActor
struct MenuWordsTests {

    @Test("words that arrive in sentence case are drawn in a menu's title case")
    func titleCase() {
        #expect(CommandTable.titleCase("cut off") == "Cut Off")
        #expect(CommandTable.titleCase("Copy the card") == "Copy the Card")
        #expect(CommandTable.titleCase("Choose keepers") == "Choose Keepers")
        #expect(CommandTable.titleCase("Edit in PhotoLab") == "Edit in PhotoLab")
        #expect(CommandTable.titleCase("Copy the RAWs to iCloud") == "Copy the RAWs to iCloud")
        #expect(CommandTable.titleCase("Done") == "Done")
        let why = CommandTable.command(CommandTable.ID.whyItIsOut)?.children.map(\.title) ?? []
        #expect(why.allSatisfy { $0 == CommandTable.titleCase($0) }, "\(why)")
        let steps = CommandTable.stepCommands([
            StepState(id: "ingest", label: "Copy the card", done: false, enabled: true, why_disabled: nil,
                      source: .base),
            StepState(id: "keepers", label: "Choose keepers", done: false, enabled: true, why_disabled: nil,
                      source: .base),
        ])
        #expect(steps.map(\.title) == ["Copy the Card", "Choose Keepers"])
    }

    @Test("N has the button's name, and says in its help tag that it records been through")
    func nextBurst() {
        let n = CommandTable.command(CommandTable.ID.finishBurst)
        #expect(n?.title == "Next Burst")
        #expect(n?.help == Words.Frame.finishBurstHelp)
        #expect(CommandTable.command(CommandTable.ID.nextForward)?.title == "Next Frame the Cull Put Forward")
    }

    @Test("no row that could never be chosen: Add a Folder, and Help without a help book")
    func noDeadRows() {
        #expect(CommandTable.command(CommandTable.ID.addFolder) == nil)
        #expect(!HelpBook.hasHelpBook)
        #expect(CommandTable.command(CommandTable.ID.appHelp) == nil,
                "without a help book it opened the Keyboard Shortcuts window, one row above that one")
        #expect(CommandTable.command(CommandTable.ID.shortcuts) != nil)
    }

    @Test("the picture window's right-click menu says what the Frame menu says")
    func pictureMenuWords() throws {
        let (director, _) = Fake.director()
        let state = PictureViewState()
        let caption = FrameCaption(shoot: "2026-09-19", shortStem: "04330", indexInBurst: 1, framesInBurst: 7,
                                   burstNumber: 3, burstsInShoot: 19, his: .unmarked)
        state.content = .frame(stem: "DSC04330", caption: caption, zoom: .fit)
        let view = PictureContentView(state: state, director: director)
        let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        let titles = try #require(view.contextMenu(for: click)).items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == [Words.Frame.keep, Words.Frame.drop, Words.Frame.clearMark, Words.Frame.compare,
                           DisplayStrings.Menu.hold, Words.Frame.showInFinder, Words.Frame.copyNumber],
                "it said Compare Similar beside the menu bar's Compare Similar Frames")
    }

    @Test("a submenu with nothing live in it is grey, and live once one of its rows is")
    func submenuFollowsItsRows() throws {
        let center = CommandCenter()
        let target = MenuTarget(center: center)
        let why = try #require(CommandTable.command(CommandTable.ID.whyItIsOut))
        let item = MenuBar.item(for: why, target: target)
        #expect(item.submenu != nil)
        #expect(!target.validateMenuItem(item), "six grey reasons behind a live arrow")
        center.register(CommandTable.ID.reason(.blur)) {}
        #expect(target.validateMenuItem(item))
    }
}
