import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// The Frame and View menus act on the light table that is on screen, and a
/// key press still goes where it always went.
@Suite("The light table's menu rows", .serialized)
@MainActor
struct LightTableCommandsTests {

    static func keyDown(_ chars: String, _ flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    }

    static func click() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test("every Frame and View row the light table can do is behind it while it is on screen")
    func everyRowIsLive() throws {
        let center = CommandCenter()
        let m = try ViewerTests.model()
        LightTableCommands.attach(m, center: center)
        defer { LightTableCommands.detach(m, center: center) }

        // What the light table has no way to do yet, or what someone else owns.
        let notOurs: Set<CommandID> = [
            CommandTable.ID.filmstrip, CommandTable.ID.burstMap, CommandTable.ID.whyItIsOut,
            CommandTable.ID.sidebar, CommandTable.ID.inspector, CommandTable.ID.viewerBackground,
            CommandTable.ID.appearance, "view.fullScreen",
        ]
        for menu in [CommandTable.frame, CommandTable.view] {
            for c in menu.commands.flatMap(\.flattened) where !c.isSubmenu {
                if notOurs.contains(c.id) || c.id.rawValue.hasPrefix("displays.")
                    || c.id.rawValue.hasPrefix("view.viewerBackground") || c.id.rawValue.hasPrefix("view.appearance") {
                    continue
                }
                #expect(center.isRegistered(c.id), "\(c.id.rawValue) has nothing behind it")
            }
        }
        #expect(center.canRun(CommandTable.ID.keep))
        #expect(center.canRun(CommandTable.ID.copyFrameNumber))
        // Compare has a stack under it in this burst, and Keep Only waits for
        // Compare.
        #expect(center.canRun(CommandTable.ID.compare))
        #expect(!center.canRun(CommandTable.ID.keepOnly))
    }

    @Test("a clicked row is the same press as its key, through the same gate")
    func clickIsAPress() async throws {
        let log = WriteLog()
        let center = CommandCenter()
        let m = try ViewerTests.model(log: log)
        LightTableCommands.attach(m, center: center)
        defer { LightTableCommands.detach(m, center: center) }

        center.run(CommandTable.ID.keep)
        await ViewerTests.press(m, .single)      // wait for the queue
        #expect(await log.writes.isEmpty, "nothing was on screen, so nothing was written")

        ViewerTests.show(m)
        center.run(CommandTable.ID.keep)
        await ViewerTests.press(m, .single)
        #expect(await log.writes.count == 1)
    }

    @Test("a light table that has gone does not take its successor's rows with it")
    func detachIsItsOwn() throws {
        let center = CommandCenter()
        let a = try ViewerTests.model()
        let b = try ViewerTests.model()
        LightTableCommands.attach(a, center: center)
        LightTableCommands.attach(b, center: center)
        LightTableCommands.detach(a, center: center)
        #expect(center.isRegistered(CommandTable.ID.keep))
        LightTableCommands.detach(b, center: center)
        #expect(!center.isRegistered(CommandTable.ID.keep))
    }

    @Test("the frame number is copied as he reads it")
    func copyNumber() throws {
        let center = CommandCenter()
        let m = try ViewerTests.model()
        LightTableCommands.attach(m, center: center)
        defer { LightTableCommands.detach(m, center: center) }
        let board = NSPasteboard(name: .init("light-table-test-\(UUID().uuidString)"))
        LightTableCommands.pasteboard = board
        defer { LightTableCommands.pasteboard = .general; board.releaseGlobally() }
        center.run(CommandTable.ID.copyFrameNumber)
        let stem = try #require(m.currentStem)
        #expect(board.string(forType: .string) == ShootSession.shortStem(stem))
    }

    @Test("a key the light table reads is never taken by its menu row; a click is")
    func keysStayWhereTheyWere() {
        let k = CommandTable.shortcut(CommandTable.ID.keep)
        #expect(MenuValidation.declinesKeyPress(k, event: Self.keyDown("e")))
        #expect(!MenuValidation.declinesKeyPress(k, event: Self.click()))
        #expect(!MenuValidation.declinesKeyPress(k, event: nil))
        // ⇧E is not "unmodified", and would otherwise keep a frame while he
        // typed a capital E into a search field.
        #expect(MenuValidation.declinesKeyPress(CommandTable.shortcut(CommandTable.ID.keepOnly),
                                                event: Self.keyDown("e", .shift)))
        // The rest of the left hand's rows leave their keys to the light
        // table too, where a held key is one press.
        for (id, c) in [(CommandTable.ID.nextFrame, "f"), (CommandTable.ID.previousFrame, "s"),
                        (CommandTable.ID.finishBurst, "r"), (CommandTable.ID.previousBurst, "w"),
                        (CommandTable.ID.clearMark, "x"), (CommandTable.ID.drop, "d")] {
            #expect(MenuValidation.declinesKeyPress(CommandTable.shortcut(id), event: Self.keyDown(c)),
                    "\(id.rawValue) took \(c) from the light table")
        }
        #expect(MenuValidation.declinesKeyPress(CommandTable.shortcut(CommandTable.ID.fullImage),
                                                event: Self.keyDown(" ", keyCode: 49)))
        // A key with ⌘ is the menu's, as it always was.
        #expect(!MenuValidation.declinesKeyPress(CommandTable.shortcut(CommandTable.ID.actualSize),
                                                 event: Self.keyDown("0", .command)))
        // H has no reader but its row, and keeps it.
        #expect(!MenuValidation.declinesKeyPress(Shortcut("h"), event: Self.keyDown("h")))
        // A different key is not this row's business.
        #expect(!MenuValidation.declinesKeyPress(k, event: Self.keyDown("d")))
    }
}
