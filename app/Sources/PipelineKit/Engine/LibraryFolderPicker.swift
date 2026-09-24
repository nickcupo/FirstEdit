import AppKit
import Foundation

/// The one folder picker, so Settings, the first-run sheet and the empty
/// sidebar cannot disagree about what a library is. Each of the three used to
/// build its own panel, and each answered an empty folder differently: the
/// sidebar did nothing at all, Settings refused it with a paragraph, and the
/// first run took it and went on saying "Choose a folder".
@MainActor
public enum LibraryFolderPicker {

    public enum Outcome: Equatable {
        /// He picked a folder with shoots under it.
        case chose(LibraryFolder.Resolution)
        /// He picked an empty folder, to start a library in. Accepted: the
        /// engine makes `shoots/` inside it and the first card is copied there.
        /// The value is what `PHOTOS_ROOT` should be.
        case empty(URL)
        /// He picked a folder that holds other things and no shoot. Nothing
        /// is saved, and the sentence says what was looked for.
        case noShoots(URL)
        case cancelled
    }

    /// Runs the open panel and says what came back. It saves nothing: the
    /// caller decides, because a new folder is a new engine and there may be
    /// a job to ask about first (§2.11).
    ///
    /// New Folder is on, so a library can be started without a trip to the
    /// Finder, and the panel opens on the library the engine is reading.
    public static func pick(startingAt: URL? = nil,
                            prompt: String = Strings.Settings.choose) -> Outcome {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = Strings.Settings.pickerMessage
        panel.directoryURL = startingAt
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        return outcome(for: url)
    }

    /// What a chosen folder is, without a panel: the rule, for the tests.
    nonisolated public static func outcome(for url: URL, fileManager fm: FileManager = .default) -> Outcome {
        if let r = LibraryFolder.resolve(url, fileManager: fm) { return .chose(r) }
        if let root = emptyLibrary(url, fileManager: fm) { return .empty(root) }
        return .noShoots(url)
    }

    /// The folder to hand the engine when he picked one with nothing in it to
    /// start a library: nothing visible at all, or nothing but a `shoots`
    /// folder with no shoot in it (what the engine leaves in a library it was
    /// pointed at before a card was ever copied). A folder named `shoots` that
    /// is itself empty is the shelf, and the engine is given the folder above
    /// it — as `LibraryFolder` does for one with shoots in it — so it never
    /// makes `shoots/shoots`.
    ///
    /// Any other folder with no shoot under it is still turned down: his
    /// Documents is not an empty library, and a `shoots/` made inside it
    /// would look, from the app, just like one that had gone missing.
    nonisolated public static func emptyLibrary(_ chosen: URL, fileManager fm: FileManager = .default) -> URL? {
        let here = LibraryFolder.directory(chosen.standardizedFileURL.path)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: here.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let kids = try? fm.contentsOfDirectory(atPath: here.path)
        else { return nil }
        let visible = kids.filter { !$0.hasPrefix(".") }
        if visible.isEmpty {
            return here.lastPathComponent == "shoots"
                ? LibraryFolder.directory(here.deletingLastPathComponent().path)
                : here
        }
        if visible == ["shoots"] {
            let shelf = here.appendingPathComponent("shoots", isDirectory: true)
            var d: ObjCBool = false
            if fm.fileExists(atPath: shelf.path, isDirectory: &d), d.boolValue { return here }
        }
        return nil
    }
}
