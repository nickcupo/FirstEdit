import Testing
import Foundation
import SwiftUI
@testable import PipelineKit

/// A focused button inside the window beats a menu command, so a key written
/// on a toolbar button is a key taken off the menu item that owns it — without
/// the menu item changing, or dimming, or saying anything at all.
///
/// ⌘R was hard-wired into `StepPrimaryToolbarButton`. The command table gives
/// ⌘R to Shoot ▸ Cull, and the Cull step's old button carried it, so Cull was
/// right by accident. The Presets step's old button had no key, so when both
/// steps moved to the shared button, ⌘R on the Presets step wrote the presets
/// while the menu it came from said it culled.
@Suite("A step's toolbar button and the keys the menus own")
@MainActor
struct StepShortcutTests {

    // MARK: - the key is the table's, or there is none

    @Test("the only key a step's button carries is the table's own, for that same action")
    func derivedFromTheTable() {
        // Cull: the table gives it ⌘R, so the button carries ⌘R.
        #expect(CommandTable.shortcut(CommandTable.ID.cull)?.display == "⌘R")
        #expect(StepPrimaryWords.toolbarKey(for: CommandTable.ID.cull) == "r")
        // Presets: the table gives it no key, so the button carries none.
        #expect(CommandTable.shortcut(CommandTable.ID.writePresets) == nil)
        #expect(StepPrimaryWords.toolbarKey(for: CommandTable.ID.writePresets) == nil)
    }

    /// The derivation is only safe while a plain ⌘-letter means one thing in
    /// the whole bar. If two commands ever shared one, a button derived from
    /// either would shadow the other.
    @Test("no two commands in the bar share a plain command-and-a-letter")
    func noTwoCommandsShareAKey() {
        var seen: [String: CommandID] = [:]
        for command in CommandTable.allCommands {
            guard let s = command.shortcut, s.modifiers == .command,
                  case .character = s.key else { continue }
            if let other = seen[s.display] {
                Issue.record("\(s.display) is both \(other.rawValue) and \(command.id.rawValue)")
            }
            seen[s.display] = command.id
        }
        #expect(seen["⌘R"] == CommandTable.ID.cull)
    }

    /// Anything the table spells with ⌥, ⇧ or ⌃ belongs to a menu item with
    /// its own wording. A toolbar button is one press of one action and is not
    /// the place to shadow it.
    @Test("a button never takes a key the table spells with another modifier")
    func onlyPlainCommandKeys() {
        for command in CommandTable.allCommands {
            guard let s = command.shortcut, s.modifiers != .command else { continue }
            #expect(StepPrimaryWords.toolbarKey(for: command.id) == nil,
                    "\(command.id.rawValue) carries \(s.display)")
        }
    }

    // MARK: - and nobody writes one down instead

    /// The defect was a key spelled out in a view rather than read from the
    /// table. Read the sources: every toolbar button either says nothing about
    /// a key or asks `toolbarKey(for:)` for it.
    @Test("no step writes a key into its toolbar button by hand")
    func nothingIsHardWired() throws {
        var checked = 0
        for (name, text) in Self.sources {
            for call in text.components(separatedBy: "StepPrimaryToolbarButton(").dropFirst() {
                // The call's own arguments: up to the closing brace of its
                // trailing closure pair, which `addToTheList:` always ends.
                let arguments = String(call.prefix(while: { $0 != "}" }))
                checked += 1
                if let r = arguments.range(of: "shortcut:") {
                    let value = String(arguments[r.upperBound...])
                        .prefix(while: { $0 != "," })
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    #expect(value.hasPrefix("StepPrimaryWords.toolbarKey(for:"),
                            "\(name) writes \(value) instead of reading the table")
                }
            }
        }
        #expect(checked >= 2, "found \(checked) toolbar buttons to check")
        // And the shared button itself names no key of its own.
        let shared = try #require(Self.sources.first { $0.name == "StepPrimary.swift" }?.text)
        #expect(!shared.contains("keyboardShortcut(\"r\""),
                "StepPrimary.swift hard-wires a letter")
        #expect(shared.contains("shortcut.map { KeyboardShortcut($0, modifiers: .command) }"),
                "the button takes its key from its caller, and nil means none")
    }

    /// Every step's own source, read off the disk the way `SafetyTests` reads
    /// the storage crew's.
    static let sources: [(name: String, text: String)] = {
        let steps = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Steps
            .deletingLastPathComponent()      // PipelineKitTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // app
            .appendingPathComponent("Sources/PipelineKit/Steps")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: steps.path)) ?? []
        return names.filter { $0.hasSuffix(".swift") }.sorted().compactMap { name in
            (try? String(contentsOf: steps.appendingPathComponent(name), encoding: .utf8))
                .map { (name, $0) }
        }
    }()

    @Test("the step sources were actually found")
    func theSourcesAreThere() {
        #expect(Self.sources.count >= 5, "found \(Self.sources.map(\.name))")
    }
}
