import Foundation
import Testing
@testable import PipelineKit

/// The two items of a shoot's context menu that act are judged by the shoot
/// that was right-clicked, not by the one on screen, and by the rule of the
/// step whose button they are.
@Suite("A shoot's context menu is about that shoot")
@MainActor
struct ShootContextMenuTests {

    static func row(culled: Bool, finished: Bool = false, keepers: Int = 0, willBeEdited: Int? = nil, presets: Int = 1, sidecars: Int = 12) throws -> ShootRowOK {
        var f: [String: JSONValue] = [
            "name": .string("lounge"), "path": .string("/photos/shoots/lounge"),
            "presets": .number(Double(presets)), "sidecars": .number(Double(sidecars)),
            "culled": .bool(culled), "finished": .bool(finished), "keepers": .number(Double(keepers)),
        ]
        if let w = willBeEdited { f["will_be_edited"] = .number(Double(w)) }
        return try ShootRowOK(fields: Fields(f))
    }

    @Test("Open My Keepers in PhotoLab: culled, with something that would open")
    func openInEditor() throws {
        #expect(!ShootContextMenu.canOpenInEditor(try Self.row(culled: false, keepers: 12)))
        #expect(!ShootContextMenu.canOpenInEditor(try Self.row(culled: true, keepers: 0)))
        #expect(ShootContextMenu.canOpenInEditor(try Self.row(culled: true, keepers: 12)))
        #expect(!ShootContextMenu.canOpenInEditor(try Self.row(culled: true, keepers: 12, presets: 0)))
        #expect(!ShootContextMenu.canOpenInEditor(try Self.row(culled: true, keepers: 12, sidecars: 0)))
        #expect(ShootContextMenu.canOpenInEditor(try Self.row(culled: true, keepers: 12, presets: 0),
                                               presetsInHand: true))
        #expect(!ShootContextMenu.canOpenInEditor(try Self.row(culled: true, keepers: 0), presetsInHand: true))
        // What gets a sidecar decides, where the engine says it.
        #expect(ShootContextMenu.canOpenInEditor(try Self.row(culled: true, keepers: 0, willBeEdited: 23)))
        #expect(!ShootContextMenu.canOpenInEditor(try Self.row(culled: true, keepers: 12, willBeEdited: 0)))
    }

    @Test("This Shoot Is Finished: culled and not yet finished")
    func finish() throws {
        #expect(!ShootContextMenu.canFinish(try Self.row(culled: false)))
        #expect(ShootContextMenu.canFinish(try Self.row(culled: true)))
        #expect(!ShootContextMenu.canFinish(try Self.row(culled: true, finished: true)))
    }
}
