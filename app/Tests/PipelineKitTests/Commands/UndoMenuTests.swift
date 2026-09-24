import AppKit
import Foundation
import Testing
@testable import PipelineKit

/// Edit ▸ Undo over the light table: his newest verdict, named, and the same
/// press ⌘Z and U make (DESIGN.md §2.12).
@Suite("Edit ▸ Undo", .serialized)
@MainActor
struct UndoMenuTests {

    static func onTheLightTable() throws -> (CommandHost, AppModel, ShootSession) {
        let (host, app) = try GoMenuTests.host(selection: .step(shoot: "2026-09-13-dog", step: "keepers"))
        let c = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"))
        let session = ShootSession(response: try Fixture.decode(ShootResponse.self, "shoot-bursts"),
                                   ext: nil, client: c, pump: ImagePump(client: c))
        app.library.adopt(session)
        return (host, app, session)
    }

    @Test("with a verdict to take back it is live and says which one")
    func namesTheStep() throws {
        let (host, _, session) = try Self.onTheLightTable()
        #expect(!host.center.canRun(CommandTable.ID.undo), "nothing to take back yet")
        session.undo.push(VerdictStep(kind: .keep, stem: "04330", file: "04330.CR3", before: nil, after: 5,
                                      burstIndex: 0, name: Strings.Verdict.undoKeep("04330")))
        #expect(host.center.canRun(CommandTable.ID.undo))

        let target = MenuTarget(center: host.center)
        let item = MenuBar.item(for: try #require(CommandTable.command(CommandTable.ID.undo)), target: target)
        #expect(target.validateMenuItem(item))
        #expect(item.title == "Undo Keep 04330")
    }

    @Test("a held ⌘Z takes back one verdict, and still repeats in a text field, whose undo it is")
    func heldKey() throws {
        let (host, _, session) = try Self.onTheLightTable()
        let target = MenuTarget(center: host.center)
        let undo = try #require(CommandTable.command(CommandTable.ID.undo))
        let item = MenuBar.item(for: undo, target: target)
        let held = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "z",
                                    charactersIgnoringModifiers: "z", isARepeat: true, keyCode: 6)
        target.currentEvent = { held }

        // Nothing of his to take back: the row is the responder chain's, and
        // the chain decides — a field's undo repeats as the system's always
        // did. It used to be refused as a repeat before the chain was asked.
        item.title = "not asked"
        _ = target.validateMenuItem(item)
        #expect(item.title == Words.Edit.undo, "the chain was asked, repeat or not")

        // A verdict: one press however long ⌘Z is held.
        session.undo.push(VerdictStep(kind: .keep, stem: "04330", file: "04330.CR3", before: nil, after: 5,
                                      burstIndex: 0, name: Strings.Verdict.undoKeep("04330")))
        #expect(!target.validateMenuItem(item))
        target.currentEvent = { nil }
        #expect(target.validateMenuItem(item))
    }

    @Test("away from the light table the row is the responder chain's, not his verdicts'")
    func onlyOverTheLightTable() throws {
        let (host, app, session) = try Self.onTheLightTable()
        session.undo.push(VerdictStep(kind: .drop, stem: "04331", file: "04331.CR3", before: nil, after: 0,
                                      burstIndex: 0, name: Strings.Verdict.undoDrop("04331")))
        app.navigation.selection = .step(shoot: "2026-09-13-dog", step: "presets")
        #expect(!host.center.canRun(CommandTable.ID.undo))
        let target = MenuTarget(center: host.center)
        let item = MenuBar.item(for: try #require(CommandTable.command(CommandTable.ID.undo)), target: target)
        _ = target.validateMenuItem(item)
        #expect(item.title == Words.Edit.undo)
    }

    @Test("Edit ▸ Redo is live over the light table with what ⌘Z took back, named, and the chain's elsewhere")
    func redoNamesTheStep() throws {
        let (host, app, session) = try Self.onTheLightTable()
        #expect(!host.center.canRun(CommandTable.ID.redo), "nothing taken back yet")
        session.undo.keepUndone(VerdictStep(kind: .keep, stem: "04330", file: "04330.CR3", before: nil, after: 5,
                                            burstIndex: 0, name: Strings.Verdict.undoKeep("04330")))
        #expect(host.center.canRun(CommandTable.ID.redo))
        let target = MenuTarget(center: host.center)
        let item = MenuBar.item(for: try #require(CommandTable.command(CommandTable.ID.redo)), target: target)
        #expect(target.validateMenuItem(item))
        #expect(item.title == "Redo Keep 04330")

        app.navigation.selection = .step(shoot: "2026-09-13-dog", step: "presets")
        #expect(!host.center.canRun(CommandTable.ID.redo))
        _ = target.validateMenuItem(item)
        #expect(item.title == Words.Edit.redo)
    }
}
