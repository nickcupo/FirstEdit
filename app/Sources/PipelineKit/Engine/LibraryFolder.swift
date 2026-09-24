import Foundation

/// Which folder is the library, given one he picked.
///
/// The engine appends `shoots` to `PHOTOS_ROOT` and looks there. So the one
/// value it wants is the folder that *holds* `shoots/` — and the folder he
/// double-clicks is the one with his shoots visibly in it, which is
/// `~/photos/shoots`. Choosing the obvious folder set `PHOTOS_ROOT` to
/// `~/photos/shoots`, the engine looked in `~/photos/shoots/shoots`, made that
/// folder because it was not there, found nothing in it and said nothing: an
/// empty sidebar, every shoot he has still on the disk, and no way to tell
/// from inside the app that anything was wrong.
///
/// So the picker stops being a question with one right answer. Either folder
/// resolves, and a folder that plainly holds shoots resolves too. The rule is
/// the same one `pipeline/library.py` uses — is there a shoot in here — and it
/// is asked of the filesystem, never of a folder's name.
public enum LibraryFolder {

    /// What a chosen folder turned out to be.
    public struct Resolution: Equatable, Sendable {
        /// What `PHOTOS_ROOT` should be.
        public let root: URL
        /// Where the shoots actually stand, which is `root/shoots` on the
        /// standard layout and `root` itself on a folder that is the shelf.
        public let shelf: URL
        /// Their names, in the order the disk gives them. Counted, and shown.
        public let shoots: [String]

        public init(root: URL, shelf: URL, shoots: [String]) {
            self.root = root; self.shelf = shelf; self.shoots = shoots
        }
    }

    /// The chosen folder resolved, or `nil` when no shoot can be found under
    /// it any of the three ways.
    ///
    /// Order matters. `root/shoots` is asked first, so a library that has both
    /// a `shoots/` shelf and stray shoot-shaped folders beside it resolves to
    /// its shelf rather than to whatever else is lying about.
    public static func resolve(_ chosen: URL,
                               fileManager fm: FileManager = .default) -> Resolution? {
        let here = directory(chosen.standardizedFileURL.path)
        let shelf = directory(here.appendingPathComponent("shoots").path)
        let onTheShelf = shootNames(in: shelf, fileManager: fm)
        if !onTheShelf.isEmpty {
            return Resolution(root: here, shelf: shelf, shoots: onTheShelf)
        }
        // He picked the shelf itself. The engine is told the folder above it,
        // which is what it appends `shoots` to.
        let inHere = shootNames(in: here, fileManager: fm)
        if !inHere.isEmpty, here.lastPathComponent == "shoots" {
            return Resolution(root: directory(here.deletingLastPathComponent().path),
                              shelf: here, shoots: inHere)
        }
        // A folder that holds shoots under some other name. The engine takes
        // it as it is: `shelf()` in library.py looks in `root/shoots` and then
        // in `root` itself.
        if !inHere.isEmpty {
            return Resolution(root: here, shelf: here, shoots: inHere)
        }
        return nil
    }

    /// Every URL out of here is spelled the same way, so two answers for the
    /// same folder compare equal. `deletingLastPathComponent()` leaves a
    /// trailing slash and `appendingPathComponent` does not, and a URL is
    /// equal to another by its text.
    static func directory(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The same value the engine is given, for a stored setting that may have
    /// been written before this existed — his was. Normalising on the way out
    /// of `SettingsStore` is what makes the wrong value fix itself at launch
    /// instead of needing a hand.
    ///
    /// A folder that cannot be resolved is handed back exactly as it was
    /// stored. The app never quietly points the engine somewhere he did not
    /// choose: a folder that is not there yet, or is on a volume that is not
    /// mounted, stays his answer and the engine says what it found.
    public static func normalised(_ chosen: URL, fileManager fm: FileManager = .default) -> URL {
        resolve(chosen, fileManager: fm)?.root ?? chosen
    }

    // MARK: - what a shoot looks like from outside

    /// The names of the shoots directly inside this folder.
    ///
    /// The three shapes `pipeline/library.py` recognises, and no list of
    /// spellings: a folder with a `raw/` in it, a folder with a `cull/` in it
    /// (his delivered shoots, whose RAWs have been cleared), or a folder with
    /// frames lying loose in it (the ducks shoot, 98 ARW and no `raw/`).
    public static func shootNames(in folder: URL, fileManager fm: FileManager = .default) -> [String] {
        guard let kids = try? fm.contentsOfDirectory(at: folder,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return kids.filter { isShoot($0, fileManager: fm) }
            .map(\.lastPathComponent)
            .sorted()
    }

    public static func isShoot(_ folder: URL, fileManager fm: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return false }
        for named in ["raw", "cull"] {
            var d: ObjCBool = false
            let sub = folder.appendingPathComponent(named, isDirectory: true)
            if fm.fileExists(atPath: sub.path, isDirectory: &d), d.boolValue { return true }
        }
        return holdsFrames(folder, fileManager: fm)
    }

    /// The extensions `pipeline/common.py` calls a frame. A folder of loose
    /// RAWs is a shoot by the only test that matters, which is that it holds
    /// photographs.
    static let frameExtensions: Set<String> = [
        "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "dng", "pef", "srw", "jpg", "jpeg",
    ]

    /// Where the engine will actually look, for a line that has to name it.
    /// `root/shoots` on the standard layout, which is also what it would make
    /// if there were nothing there — so this is the right folder to name both
    /// when shoots were found and when none were.
    public static func shelf(under root: URL, fileManager fm: FileManager = .default) -> URL {
        resolve(root, fileManager: fm)?.shelf
            ?? root.appendingPathComponent("shoots", isDirectory: true)
    }

    static func holdsFrames(_ folder: URL, fileManager fm: FileManager) -> Bool {
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return false }
        for case let u as URL in e where frameExtensions.contains(u.pathExtension.lowercased()) {
            return true
        }
        return false
    }
}
