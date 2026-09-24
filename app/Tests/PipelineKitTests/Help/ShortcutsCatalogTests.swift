import Foundation
import Testing
@testable import PipelineKit

/// §2.12 — what the Keyboard Shortcuts window lists, in what order, and what
/// a one-letter search answers.
@Suite("The Keyboard Shortcuts window's list")
@MainActor
struct ShortcutsCatalogTests {

    @Test("the one scheme comes first, E and D at its top, then Deciding with Keep and Drop in it")
    func decidingFirst() throws {
        let groups = ShortcutsCatalog.grouped()
        let first = try #require(groups.first)
        #expect(first.0 == .everywhere)
        #expect(first.1.prefix(2).map(\.keys) == ["E", "D"])
        #expect(first.1.allSatisfy { $0.menu == Strings.Help.everyPage })
        let second = try #require(groups.dropFirst().first)
        #expect(second.0 == .deciding)
        #expect(second.1.map(\.title).prefix(2) == [Words.Frame.keep, Words.Frame.drop])
    }

    @Test("the one scheme's rows are read from the menu rows that carry the keys, the left hand's first")
    func theSchemeRows() throws {
        let rows = ShortcutsCatalog.schemeRows
        func row(_ id: String) -> ShortcutRow? { rows.first { $0.id.rawValue == "help.every.\(id)" } }
        #expect(row("include")?.keys == "E" && row("include")?.alternate == Words.Shortcuts.orPlain("K"))
        #expect(row("clear")?.keys == "X" && row("clear")?.alternate == Words.Shortcuts.orPlain("0"))
        #expect(row("undo")?.keys == "Q" && row("undo")?.alternate == Words.Shortcuts.orPlain("⌘Z, U"))
        #expect(row("move")?.keys == "S F" && row("move")?.alternate == Words.Shortcuts.orPlain("← →"))
        #expect(row("bursts")?.keys == "W R" && row("bursts")?.alternate == Words.Shortcuts.orPlain("P N"))
        #expect(row("large")?.keys == "Space")
        #expect(row("oneToOne")?.keys == "Z" && row("oneToOne")?.alternate == Words.Shortcuts.orPlain("⌘0"))
        #expect(row("back")?.keys == "⎋" && row("primary")?.keys == "↩")
        // Reels' own keys are listed by where they work, as the Instagram
        // editor's are.
        let all = ShortcutsCatalog.rows(steps: [])
        #expect(all.contains { $0.id.rawValue == "help.reels.startHere" && $0.keys == "I" })
        #expect(all.contains { $0.id.rawValue == "help.reels.endHere" && $0.keys == "O" })
    }

    /// The Edit menu comes before Frame, so Undo — the Mac's row, or the
    /// app's own once it undoes verdicts by name — would stand above Keep.
    @Test("Undo comes after the decisions it undoes, whichever kind of row it is")
    func undoGoesLast() {
        #expect(ShortcutsCatalog.goesLast(Command("edit.undo", "Undo", group: .deciding)))
        #expect(ShortcutsCatalog.goesLast(Command("edit.undo", "Undo", group: .deciding, role: .system("undo:"))))
        #expect(ShortcutsCatalog.goesLast(Command("edit.redo", "Redo", group: .deciding)))
        #expect(!ShortcutsCatalog.goesLast(Command(CommandTable.ID.keep, "Keep", group: .deciding)))
    }

    @Test("a submenu's rows carry its name, so Black and Shadow say what they are")
    func submenusKeepTheirContext() {
        let titles = ShortcutsCatalog.rows.map(\.title)
        #expect(titles.contains("\(Words.Frame.whyItIsOut): \(DropReason.allCases[0].word.capitalizedFirst)"))
        #expect(titles.contains("\(Words.View.viewerBackground): \(Words.View.black)"))
        #expect(!titles.contains(Words.View.black))
    }

    @Test("the Mac's standard rows are left out, and no row says 'no key'")
    func noStandardRows() {
        let ids = Set(ShortcutsCatalog.rows.map(\.id.rawValue))
        for standard in ["edit.cut", "edit.copy", "edit.paste", "edit.selectAll", "edit.emoji",
                         "app.hide", "app.hideOthers", "app.quit", "window.minimize",
                         CommandTable.ID.fill.rawValue, CommandTable.ID.centre.rawValue] {
            #expect(!ids.contains(standard), "\(standard) is a standard Mac key")
        }
        #expect(ids.contains("edit.undo"), "Undo decides things here, and is kept")
        #expect(ShortcutsCatalog.rows.allSatisfy {
            $0.note == nil || $0.note == Strings.Help.noneOnPurpose
                || ($0.id == CommandTable.ID.single && $0.note == Strings.Help.singleInAllBursts)
        })
    }

    @Test("the keys the light table reads with no menu row of their own are listed")
    func extraKeys() {
        let rows = ShortcutsCatalog.rows
        #expect(rows.contains { $0.title == Strings.Help.pan && $0.keys == "⇧←→↑↓" })
        #expect(rows.contains { $0.title == Strings.Help.leave && $0.keys == "⎋" })
        #expect(rows.contains { $0.title == Strings.Help.openBurst && $0.keys == "↩" })
        #expect(rows.first { $0.id.rawValue == "edit.undo" }?.alternate == Words.Shortcuts.orPlain("Q, U"))
        #expect(rows.first { $0.id == CommandTable.ID.actualSize }?.alternate == Words.Shortcuts.orPlain("Z"))
    }

    @Test("one letter asks what that key does, the left hand's or the one he learned first")
    func oneLetter() {
        let k = ShortcutsCatalog.grouped(matching: "k").flatMap(\.1).map(\.title)
        #expect(k == [Strings.Help.keepOrInclude, Words.Frame.keep], "k is Keep, not every title with a k in it")
        let e = ShortcutsCatalog.grouped(matching: "e").flatMap(\.1).map(\.title)
        #expect(e == [Strings.Help.keepOrInclude, Words.Frame.keep], "e is Keep")
        let u = ShortcutsCatalog.grouped(matching: "u").flatMap(\.1).map(\.id.rawValue)
        #expect(u == ["help.every.undo", "edit.undo"])
        let q = ShortcutsCatalog.grouped(matching: "q").flatMap(\.1).map(\.id.rawValue)
        #expect(q == ["help.every.undo", "edit.undo"])
        // S is the previous frame in every view, All Bursts' covers
        // included: Single Frame is Esc, or Return on a cover.
        let s = ShortcutsCatalog.grouped(matching: "s").flatMap(\.1).map(\.id)
        #expect(s == [CommandID("help.every.move"), CommandTable.ID.previousFrame])
        let r = ShortcutsCatalog.grouped(matching: "n").flatMap(\.1).map(\.id)
        #expect(r == [CommandID("help.every.bursts"), CommandTable.ID.finishBurst], "N is still Next Burst")
        // Longer text is searched as text, as before.
        #expect(ShortcutsCatalog.grouped(matching: "keep").flatMap(\.1).count > 1)
    }

    @Test("the Go rows are the open shoot's own steps, with its labels and its numbers")
    func liveSteps() {
        let steps = CommandTable.stepCommands([
            StepState(id: "ingest", label: "Copy the card", done: true, enabled: true, why_disabled: nil, source: .base),
            StepState(id: "keepers", label: "Choose keepers", done: false, enabled: true, why_disabled: nil, source: .base),
            StepState(id: "done", label: "Done", done: false, enabled: true, why_disabled: nil, source: .base),
        ])
        let rows = ShortcutsCatalog.rows(steps: steps)
        let go = rows.filter { $0.menu == CommandTable.go.title && $0.id.rawValue.hasPrefix("go.step") }
        // The Go menu's own titles for them, however the table cases them.
        #expect(go.map(\.title) == steps.map(\.title))
        #expect(go.last?.title == "Done", "the open shoot's last step, not the base list's Finish")
        #expect(go.last?.keys == "⌘3")
    }
}
