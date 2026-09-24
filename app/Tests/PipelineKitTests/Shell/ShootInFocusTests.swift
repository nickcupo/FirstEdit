import Testing
@testable import PipelineKit

/// A shoot selected in All Shoots is the shoot the File menu's Show the Shoot
/// in Finder means; the table's selection was private to it, and the item
/// stayed grey.
@Suite("A shoot selected in All Shoots is the one the shoot commands mean")
@MainActor
struct ShootInFocusTests {

    @Test("All Shoots: the selected row; a shoot's page: that shoot; another library page: none")
    func focus() {
        let nav = Navigation(selection: .allShoots)
        #expect(nav.shootForCommands == nil)
        nav.shootInFocus = "2026-09-19"
        #expect(nav.shootForCommands == "2026-09-19")
        nav.selection = .step(shoot: "2026-09-13-dog", step: "presets")
        #expect(nav.shootForCommands == "2026-09-13-dog")
        nav.selection = .storage
        #expect(nav.shootForCommands == nil)
    }
}
