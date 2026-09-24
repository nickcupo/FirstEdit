import Foundation
import SwiftUI
import Testing
@testable import PipelineKit

/// The inspector pin was window-wide, so a column pinned open on the light
/// table — or opened there by a portrait burst — came with him to Presets,
/// Reels and All Shoots as 280 pt of "Nothing to show here yet." It is drawn,
/// and offered, only on a page that has one; the pin waits for the light table.
@Suite("The inspector shows only where it has something in it", .serialized)
@MainActor
struct InspectorPagesTests {

    @Test("pinned open on Choose Keepers, not drawn on a page without an inspector, back on return")
    func followsThePage() {
        InspectorRegistry.register("keepers") { _ in AnyView(EmptyView()) }
        let nav = Navigation(selection: .step(shoot: "2026-09-19", step: "keepers"))
        nav.toggleInspector()
        #expect(nav.hasInspector && nav.inspectorOnScreen)
        nav.selection = .step(shoot: "2026-09-19", step: "presets")
        #expect(!nav.hasInspector)
        #expect(!nav.inspectorOnScreen)
        nav.selection = .allShoots
        #expect(!nav.inspectorOnScreen)
        // The pin itself is untouched, and is there again on the light table.
        #expect(nav.inspectorShown)
        nav.selection = .step(shoot: "2026-09-19", step: "keepers")
        #expect(nav.inspectorOnScreen)
    }
}
