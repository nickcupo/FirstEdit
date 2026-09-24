import Foundation
import Testing
@testable import PipelineKit

/// The Frame, View and Edit rows Choose Keepers answers are answered by the
/// Instagram step while it is on screen, each naming what it does here
/// (DESIGN.md §2.12, §2.17).
@Suite("The Instagram step's menu rows", .serialized)
@MainActor
struct InstagramCommandsTests {

    static let frameRows: [CommandID] = [
        CommandTable.ID.keep, CommandTable.ID.drop, CommandTable.ID.clearMark,
        CommandTable.ID.nextFrame, CommandTable.ID.previousFrame,
        CommandTable.ID.fullImage, CommandTable.ID.actualSize, CommandTable.ID.zoomToFit,
    ]

    @Test("every row it answers is behind it, and names what it does here")
    func rowsAnswered() throws {
        let center = CommandCenter()
        let m = try InstagramScaffold.model()
        InstagramCommands.attach(m, center: center)
        defer { InstagramCommands.detach(m) }
        for id in Self.frameRows + [CommandTable.ID.undo, CommandTable.ID.redo] {
            #expect(center.isRegistered(id), "\(id.rawValue) has nothing behind it")
        }
        let first = ShootSession.shortStem(m.order[0])
        #expect(center.title(CommandTable.ID.keep) == "Include \(first)")
        #expect(center.title(CommandTable.ID.drop) == "Leave Out \(first)")
        #expect(center.title(CommandTable.ID.fullImage) == "Adjust the Cut")
        #expect(center.title(CommandTable.ID.nextFrame) == "Next Photograph")
        #expect(!center.canRun(CommandTable.ID.actualSize))       // the editor's only
        #expect(!center.canRun(CommandTable.ID.undo))
        // A clicked row is the same meaning as its key.
        #expect(center.run(CommandTable.ID.keep))
        #expect(m.mark(m.order[0]) == .include)
        #expect(center.title(CommandTable.ID.undo) == "Undo Include \(first)")
        #expect(center.run(CommandTable.ID.undo))
        #expect(m.mark(m.order[0]) == nil)
        #expect(center.run(CommandTable.ID.fullImage))
        #expect(m.editor != nil)
        #expect(center.state(CommandTable.ID.fullImage) == true)
        #expect(center.title(CommandTable.ID.fullImage) == "Back to the Photographs")
        #expect(center.canRun(CommandTable.ID.actualSize))
        #expect(center.run(CommandTable.ID.actualSize))
        #expect(m.editor?.view == .oneToOne)
        #expect(center.run(CommandTable.ID.fullImage))
        #expect(m.editor == nil)
    }

    @Test("the app's own Undo and Redo go back to their owner when the step goes")
    func ownersRestored() throws {
        let center = CommandCenter()
        var ran = 0
        center.register(CommandTable.ID.undo, isEnabled: { true }, title: { "Undo Keep 04330" }) { ran += 1 }
        center.register(CommandTable.ID.redo, isEnabled: { false }) {}
        let m = try InstagramScaffold.model()
        InstagramCommands.attach(m, center: center)
        m.set(m.order[1], .leaveOut)
        #expect(center.title(CommandTable.ID.undo)?.hasPrefix("Undo Leave Out") == true)
        InstagramCommands.detach(m)
        #expect(center.title(CommandTable.ID.undo) == "Undo Keep 04330")
        #expect(center.run(CommandTable.ID.undo))
        #expect(ran == 1)
        #expect(!center.canRun(CommandTable.ID.redo))
        // The light table's rows are its own to put back when it comes on
        // screen: here they grey rather than act on a page that has gone.
        for id in Self.frameRows { #expect(!center.canRun(id), "\(id.rawValue) still acts") }
    }

    @Test("coming straight from Choose Keepers, its detach after this attach does not take the rows away")
    func lightTableDetachAfterAttach() throws {
        let center = CommandCenter()
        let viewer = try ViewerTests.model()
        LightTableCommands.attach(viewer, center: center)
        let m = try InstagramScaffold.model()
        InstagramCommands.attach(m, center: center)
        // The light table's own detach arrives after this step's appear.
        LightTableCommands.detach(viewer, center: center)
        #expect(!center.isRegistered(CommandTable.ID.keep))
        // The second attach, on the next turn of the main queue.
        InstagramCommands.attach(m, center: center)
        defer { InstagramCommands.detach(m) }
        for id in Self.frameRows { #expect(center.isRegistered(id)) }
        #expect(center.title(CommandTable.ID.keep)?.hasPrefix("Include") == true)
        #expect(center.run(CommandTable.ID.keep))
        #expect(m.mark(m.order[0]) == .include)
    }

    @Test("a second step attached takes the rows, and the first's detach leaves them alone")
    func newerWins() throws {
        let center = CommandCenter()
        let a = try InstagramScaffold.model()
        let b = try InstagramScaffold.model()
        InstagramCommands.attach(a, center: center)
        InstagramCommands.attach(b, center: center)
        InstagramCommands.detach(a)
        #expect(center.run(CommandTable.ID.keep))
        #expect(b.mark(b.order[0]) == .include)
        #expect(a.mark(a.order[0]) == nil)
        InstagramCommands.detach(b)
    }
}
