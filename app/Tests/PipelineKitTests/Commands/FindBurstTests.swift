import AppKit
import Foundation
import Testing
@testable import PipelineKit

/// Edit ▸ Find Burst… (⌘F): a number, Return, and the light table is there
/// (DESIGN.md §2.12).
@Suite("Find Burst", .serialized)
@MainActor
struct FindBurstTests {

    @Test("the number he types is the burst he sees: 41 is the 41st, and nothing outside the shoot")
    func numbers() {
        #expect(FindBurst.index(from: "41", bursts: 288) == 40)
        #expect(FindBurst.index(from: " 1 ", bursts: 288) == 0)
        #expect(FindBurst.index(from: "288", bursts: 288) == 287)
        #expect(FindBurst.index(from: "289", bursts: 288) == nil)
        #expect(FindBurst.index(from: "0", bursts: 288) == nil)
        #expect(FindBurst.index(from: "", bursts: 288) == nil)
        #expect(FindBurst.index(from: "4a", bursts: 288) == nil)
    }

    @Test("the sheet opens on the burst he is in, and Go is greyed while the field names no burst")
    func sheet() {
        let (alert, field) = FindBurst.alert(current: 6, bursts: 20)
        #expect(field.stringValue == "7")
        #expect(alert.buttons.first?.title == Words.FindBurst.go)
        let go = alert.buttons[0]
        field.stringValue = "21"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(!go.isEnabled)
        field.stringValue = "12"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(go.isEnabled)
    }

    @Test("Return on the number it opened with keeps him on his frame; another number goes to that burst")
    func returnOnItsOwnChangesNothing() throws {
        let c = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"))
        let session = ShootSession(response: try Fixture.decode(ShootResponse.self, "shoot-bursts"),
                                   ext: nil, client: c, pump: ImagePump(client: c))
        let viewer = ViewerModel.shared(for: session, navigation: Navigation())
        defer { ViewerModel.forget(session) }
        viewer.goToBurst(6)
        viewer.goToFrame(1)
        #expect(FindBurst.destination("7", current: 6, bursts: viewer.bursts.count) == nil)
        FindBurst.go("7", viewer: viewer)
        #expect(session.cursor.burst == 6)
        #expect(session.cursor.frame == 1, "the burst he is in, untouched: his frame stays")
        FindBurst.go("2", viewer: viewer)
        #expect(session.cursor.burst == 1)
        #expect(session.cursor.frame == 0)
    }

    @Test("⌘F is live on Choose Keepers of a shoot with more than one burst")
    func liveOnTheLightTable() throws {
        let (host, app) = try GoMenuTests.host(selection: .step(shoot: "2026-09-13-dog", step: "keepers"))
        #expect(!host.center.canRun(CommandTable.ID.findBurst), "no bursts read yet: nothing to find")
        let c = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"))
        let session = ShootSession(response: try Fixture.decode(ShootResponse.self, "shoot-bursts"),
                                   ext: nil, client: c, pump: ImagePump(client: c))
        app.library.adopt(session)
        #expect(session.bursts.count > 1)
        #expect(host.center.canRun(CommandTable.ID.findBurst))
    }

    @Test("⌘F is greyed away from Choose Keepers")
    func onlyOnTheLightTable() throws {
        let (host, _) = try GoMenuTests.host(selection: .step(shoot: "2026-09-19", step: "presets"))
        #expect(!host.center.canRun(CommandTable.ID.findBurst))
        let (none, _) = try GoMenuTests.host(selection: .allShoots)
        #expect(!none.center.canRun(CommandTable.ID.findBurst))
    }
}
