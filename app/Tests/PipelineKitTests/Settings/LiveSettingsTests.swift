import Foundation
import Observation
import Testing
@testable import PipelineKit

/// §2.11 — a surround chosen anywhere repaints everywhere.
@Suite("The viewer background, as views read it")
@MainActor
struct LiveSettingsTests {

    static func scratch(_ name: String = #function) -> SettingsStore {
        let d = UserDefaults(suiteName: "photopipeline.tests.live.\(name)")!
        for k in SettingsStore.Key.allCases { d.removeObject(forKey: k.rawValue) }
        return SettingsStore(defaults: d)
    }

    @Test("a write from the menu, straight to the defaults, reaches every view that draws the surround")
    func followsAWriteItDidNotMake() async throws {
        let store = Self.scratch()
        let live = LiveSettings(store: store)
        #expect(live.viewerBackground == .neutralGrey)

        // What View ▸ Viewer Background does: it writes the defaults and
        // nothing else. A view that read the value is told.
        let told = Told()
        withObservationTracking { _ = live.viewerBackground } onChange: { told.yes = true }
        store.viewerBackground = .black
        for _ in 0..<100 where !told.yes { try await Task.sleep(for: .milliseconds(10)) }
        #expect(told.yes)
        #expect(live.viewerBackground == .black)
    }

    @Test("Settings' own picker writes through it and is read back at once")
    func settingsWritesThrough() {
        let store = Self.scratch()
        let live = LiveSettings(store: store)
        live.setViewerBackground(.matchSystem)
        #expect(live.viewerBackground == .matchSystem)
        #expect(store.viewerBackground == .matchSystem)
    }

    final class Told: @unchecked Sendable { var yes = false }
}
