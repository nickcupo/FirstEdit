import Foundation
import Testing
@testable import PipelineKit

/// The rules of §2.8 and §2.13 that hold over the *source*, not over one
/// view: a rule that can be broken by a line added tomorrow is worth reading
/// the lines for.
@Suite("Nothing destructive is one press away")
struct SafetyTests {

    /// This crew's own folders. Nothing outside them is read.
    static let folders = ["Storage", "Learning", "FirstRun", "SettingsUI"]

    static var sources: [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Storage
            .deletingLastPathComponent()      // PipelineKitTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // app
            .appendingPathComponent("Sources/PipelineKit")
        var out: [(String, String)] = []
        for folder in folders {
            let dir = root.appendingPathComponent(folder)
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    out.append((url.lastPathComponent, text))
                }
            }
        }
        return out
    }

    @Test("this crew's sources exist and are readable, so the rules below mean something")
    func thereIsSomethingToRead() {
        let files = Self.sources
        #expect(files.count >= 12, "found \(files.count) files")
        #expect(files.contains { $0.name == "PlanSheet.swift" })
        #expect(files.contains { $0.name == "LearnedView.swift" })
    }

    @Test("the Delete key is bound to nothing, anywhere in this crew's screens")
    func deleteIsBoundToNothing() {
        for (name, text) in Self.sources {
            #expect(!text.contains(".delete)"), "\(name) binds the Delete key")
            #expect(!text.contains(".deleteForward"), "\(name) binds Delete forward")
            #expect(!text.contains("KeyEquivalent.delete"), "\(name) binds the Delete key")
        }
    }

    /// The only `keyboardShortcut` any of these screens may carry is Cancel
    /// (Escape) and the default button (Return) — and on every sheet of the
    /// ladder the default button is the one that changes nothing.
    @Test("no destructive action has a keyboard shortcut")
    func noShortcutOnAnythingDestructive() {
        for (name, text) in Self.sources {
            for line in text.split(separator: "\n") where line.contains("keyboardShortcut") {
                let l = String(line)
                #expect(l.contains(".cancelAction") || l.contains(".defaultAction"),
                        "\(name) carries a shortcut that is neither Escape nor Return: \(l.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// Return is the default button only where it takes nothing away: Cancel,
    /// or the copy up and the bring back, which are off the ladder
    /// (`rung == nil`). On the two rungs that remove something it presses
    /// nothing, and Escape is what cancels.
    @Test("Return never deletes: on every sheet of the ladder, the default button takes nothing away")
    func returnNeverDeletes() throws {
        let sheets = ["PlanSheet.swift", "ExpireSheet.swift", "ReviewModeHost.swift",
                      "GeneralTab.swift"]
        for name in sheets {
            guard let text = Self.sources.first(where: { $0.name == name })?.text else { continue }
            let lines = Array(text.split(separator: "\n", omittingEmptySubsequences: false))
            for (i, line) in lines.enumerated() where line.contains(".defaultAction") {
                // The line before it, or the line itself, is the one that
                // takes nothing away.
                let window = lines[max(0, i - 1)...i].joined(separator: " ")
                #expect(window.contains("cancel") || window.contains("Cancel")
                        || window.contains("restartLater") || window.contains("role: .cancel")
                        || line.contains("rung == nil ? .defaultAction : nil"),
                        "\(name):\(i + 1) makes something other than Cancel the default button")
            }
        }
    }

    /// Return used to be Cancel on every plan sheet, so on Let Go the number
    /// he had just typed went with the sheet when he pressed the key that
    /// ends typing, and Escape — bound to nothing — closed nothing.
    @Test("Escape cancels every plan sheet, and the number is typed under the list it counts")
    func escapeCancels() throws {
        let sheet = try #require(Self.sources.first { $0.name == "PlanSheet.swift" }?.text)
        let buttons = try #require(sheet.range(of: "private var buttons"))
        let body = String(sheet[buttons.lowerBound...])
        let cancel = try #require(body.range(of: "Button(Strings.Storage.cancel, action: close)"))
        let next = body[cancel.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
        #expect(next.contains(".keyboardShortcut(.cancelAction)"), "Escape is Cancel")
        let list = try #require(sheet.range(of: "PlanLines(plan: p)"))
        let field = try #require(sheet.range(of: "typeTheNumber(p)"))
        #expect(list.lowerBound < field.lowerBound, "the names come before the number")
    }

    @Test("the destructive group is 32 pt clear of anything he presses in a normal shoot")
    func thirtyTwoPointsOfClearSpace() throws {
        #expect(Tokens.Metric.destructiveClearance == 32)
        let panel = try #require(Self.sources.first { $0.name == "StoragePanel.swift" }?.text)
        // The group is below a rule and carries that clearance.
        let group = try #require(panel.range(of: "private var removeAndDelete"))
        let body = String(panel[group.lowerBound...])
        #expect(body.contains("Divider()"), "the group sits below a rule")
        #expect(body.contains("Tokens.Metric.destructiveClearance"))
        // And the frequent actions are a separate section, drawn first.
        let frequent = try #require(panel.range(of: "private var frequentActions"))
        #expect(frequent.lowerBound < group.lowerBound,
                "the frequent actions come first; the group that removes things comes last")
    }

    /// The snapshot harness renders in a window that can never become key, and
    /// AppKit does not give such a window its emphasised colours: a `.tint` and
    /// a `.destructive` role both come out the colour of Cancel. The one
    /// button that destroys photographs therefore states its colour on its own
    /// label, so the red is there in a background window, in a screenshot, and
    /// in every appearance — and dims itself when the button is off.
    @Test("the button that destroys photographs states its own red")
    func theRedIsWrittenOnTheLabel() throws {
        let sheet = try #require(Self.sources.first { $0.name == "PlanSheet.swift" }?.text)
        let buttons = try #require(sheet.range(of: "private var buttons"))
        let body = String(sheet[buttons.lowerBound...])
        #expect(body.contains("Text(confirmLabel).foregroundStyle(red)"),
                "the label carries the colour, not only the role and the tint")
        #expect(body.contains("role: isDestructive ? .destructive : nil"),
                "and the role is still there, for the system's own treatment")
        #expect(sheet.contains("Tokens.Palette.alarm.opacity(canConfirm ?"),
                "a button that is off looks off")
        #expect(sheet.contains("guard isDestructive, gate.isAnAction else { return nil }"),
                "and a button that says the list is empty is not a red button")
    }

    /// Listing a directory is blocking I/O, and a page's body must never do
    /// it: the welcome looks once, off the main actor, and every page after
    /// that reads what the look found.
    @Test("the welcome asks the disk once, and never while it is drawing")
    func theWelcomeLooksOnce() throws {
        let sheet = try #require(Self.sources.first { $0.name == "FirstRunSheet.swift" }?.text)
        let look = try #require(sheet.range(of: "private func look() async"))
        let inLook = String(sheet[look.lowerBound...])
        #expect(inLook.contains("Task.detached"), "the look is not on the main actor")
        for call in ["existingLibrary()", "editors()"] {
            let all = sheet.components(separatedBy: call).count - 1
            let inside = inLook.components(separatedBy: call).count - 1
            #expect(all == inside && all == 1,
                    "\(call) is asked once, inside look(), and never from a body")
        }
    }

    @Test("nothing this crew draws puts a destructive action in a toolbar")
    func noDestructiveToolbarItem() {
        for (name, text) in Self.sources {
            guard let r = text.range(of: ".toolbar {") else { continue }
            let toolbar = String(text[r.lowerBound...].prefix(1200))
            for word in ["Strings.Storage.drop", "Strings.Storage.expire",
                         "Strings.Learning.useItAnyway"] {
                #expect(!toolbar.contains(word), "\(name) has \(word) in a toolbar")
            }
        }
    }

    @Test("the label of anything that opens a plan ends in an ellipsis")
    func theEllipsisIsThePromise() {
        #expect(Strings.Storage.drop.hasSuffix("…"))
        #expect(Strings.Storage.expire.hasSuffix("…"))
        #expect(Strings.Storage.reclaim.hasSuffix("…"))
        #expect(Strings.Learning.useItAnyway.hasSuffix("…"))
        // These two take nothing away and are not on the ladder, but they are
        // still planned, so they still say so.
        #expect(Strings.Storage.push.hasSuffix("…"))
        #expect(Strings.Storage.pull.hasSuffix("…"))
        #expect(!Strings.Storage.check.hasSuffix("…"), "reading and comparing needs no plan")
        // And a figure on the label keeps the promise at the end of it.
        #expect(Strings.Storage.sized(Strings.Storage.push, "36.3 GB") == "Copy the RAWs to iCloud (36.3 GB)…")
    }

    @Test("no retired word is in a string this crew puts on screen")
    func noRetiredWords() throws {
        // DESIGN.md §2.13, over the strings a person actually reads.
        // `tier`, `rating` and `CSV` are the engine's field names and are not
        // scanned here for the same reason tools/vocabulary-scan.sh does not
        // scan them: they are banned from a label, not from a decoder.
        let retired = ["answer key", "AUC", "held out", "duplicate", "duplicates",
                       "dup", "dups", "veto", "embedding", "embeddings", "./pl",
                       "taste weights", "flaw probe"]
        for (name, text) in Self.sources where name.hasSuffix("Strings.swift") {
            let lower = text.lowercased()
            for word in retired {
                #expect(!lower.contains(word.lowercased()), "\(name) says '\(word)'")
            }
        }
    }

    @Test("changing the library folder is a setting the engine reads at start")
    func theLibraryFolderRestartsTheEngine() {
        #expect(SettingsStore.restartsEngine.contains(.libraryFolder))
        #expect(SettingsStore.restartsEngine.contains(.extensionFolder))
        // And the question that asks before a job of his is stopped names it,
        // and says nothing he decided is lost (`EngineRestartTests`).
        #expect(Strings.Settings.restartStops("the cull of 2026-09-19")
            == "Restarting the engine stops the cull of 2026-09-19.")
        #expect(Strings.Settings.restartStopsBody.contains("Nothing you decided is lost"))
    }

    @Test("the app never offers to delete a shoot's folder, and says so")
    func theAppNeverDeletesAFolder() {
        #expect(Strings.Storage.neverDeletesFolder.contains("Finder"))
        for (name, text) in Self.sources {
            #expect(!text.contains("removeItem(at"), "\(name) removes a file itself")
            #expect(!text.contains("trashItem"), "\(name) trashes a file itself")
        }
    }
}
