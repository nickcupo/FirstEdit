import Foundation
import Testing
@testable import PipelineKit

/// §2.12 — the Help menu says each thing once.
@Suite("The Help menu")
@MainActor
struct HelpMenuTests {

    @Test("without a help book there is no First Edit Help: it opened the item below it")
    func noHelpBookNoHelpItem() {
        #expect(!HelpBook.hasHelpBook, "a checkout has no compiled help book")
        let ids = CommandTable.help.commands.map(\.id)
        #expect(!ids.contains(CommandTable.ID.appHelp))
        #expect(ids.first == CommandTable.ID.shortcuts, "Keyboard Shortcuts is the menu's first item")
    }

    @Test("a report is never filed against an empty version")
    func reportVersion() throws {
        // A checkout's bundle has no version of its own, so the updater's is used.
        let v = HelpBook.version(fallback: "0.1.3")
        #expect(!v.isEmpty)
        let url = try #require(HelpBook.reportURL(version: v))
        #expect(url.absoluteString.contains("issues/new"))
    }
}
