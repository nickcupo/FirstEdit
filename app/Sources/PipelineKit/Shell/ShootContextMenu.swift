import SwiftUI
import AppKit

/// A shoot row's context menu, the same in the sidebar and in All Shoots
/// (DESIGN.md §2.1): Show in Finder, Open My Keepers in PhotoLab, This Shoot
/// Is Finished, Copy Path. A right click on a shoot did nothing in the
/// sidebar and opened an empty menu in All Shoots.
///
/// The two that act on the shoot are judged by **that** shoot's own facts —
/// culled, and with keepers to open or not yet finished — never by the shoot
/// on screen, and each goes to that shoot's step whose button it is (Edit in
/// PhotoLab, Finish) and, where the Shoot menu's row is live there, runs it
/// on the next turn. Greyed from `CommandCenter.isRegistered` instead, they
/// were greyed for good wherever nothing registered the rows, and would have
/// been live for any shoot, judged against the one on screen, wherever
/// something did.
struct ShootContextMenu: View {
    let app: AppModel
    let row: ShootRowOK

    var body: some View {
        Button(Strings.ShootMenu.showInFinder) { Self.showInFinder(app, row.name) }
        Button(Words.Shoot.openInEditor) { openInEditor() }
            .disabled(!Self.canOpenInEditor(row, presetsInHand: presetsInHand))
        if !row.finished {
            Button(Words.Shoot.finished) { go(to: "done", then: CommandTable.ID.finished) }
                .disabled(!Self.canFinish(row))
        }
        Divider()
        Button(Strings.ShootMenu.copyPath) { Self.copy(row.path) }
    }

    /// Open must not start writing presets under a different name.
    static func canOpenInEditor(_ row: ShootRowOK, presetsInHand: Bool = false) -> Bool {
        row.culled && (row.will_be_edited ?? row.keepers) > 0
            && ((row.presets > 0 && row.sidecars > 0) || presetsInHand)
    }

    private var presetsInHand: Bool {
        PagePresses.inHand(shoot: row.name, job: app.jobs.job, list: Queues.state).contains("presets")
    }

    func openInEditor() {
        guard Self.canOpenInEditor(row, presetsInHand: presetsInHand) else { return }
        // Bind the press to the row now. A deferred global command would
        // re-read whichever shoot became selected before it got to run.
        PagePresses.shared.ask(CommandTable.ID.openInEditor, shoot: row.name,
                               optionHeld: NSEvent.modifierFlags.contains(.option))
        app.navigation.selection = .step(shoot: row.name, step: "edit")
    }

    /// Culled and not finished: the Finish step's own rule.
    static func canFinish(_ row: ShootRowOK) -> Bool { row.culled && !row.finished }

    private func go(to step: String, then id: CommandID) {
        app.navigation.selection = .step(shoot: row.name, step: step)
        // The step is on screen for this shoot now, so the row, where it is
        // live, is about this shoot and nothing else.
        Task { @MainActor in
            if CommandCenter.shared.canRun(id) { _ = CommandCenter.shared.run(id) }
        }
    }

    /// The shoot's folder in Finder, through the engine, which knows where a
    /// shoot's folder is (§7.10: nothing is made by being shown).
    static func showInFinder(_ app: AppModel, _ name: String) {
        guard let client = app.client else { return }
        Task {
            do {
                let r = try await client.post(Routes.open, OpenBody(name: name, what: "folder"))
                if let e = r.error { app.library.refusals.set(.library, e) } else { app.library.refusals.clear(.library) }
            } catch let e as StudioError {
                app.library.refusals.set(.library, e.sentence)
            } catch {}
        }
    }

    static func copy(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

/// A broken shoot's menu: the file that will not read, and its path.
struct BrokenShootContextMenu: View {
    let row: ShootRowBroken

    var body: some View {
        if let f = row.broken_file {
            Button(Strings.Library.showTheFile) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)])
            }
        }
        Button(Strings.ShootMenu.copyPath) { ShootContextMenu.copy(row.broken_file ?? row.path) }
    }
}
