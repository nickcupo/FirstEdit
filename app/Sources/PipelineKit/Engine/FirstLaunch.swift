import AppKit
import Foundation

/// The first launch under the name First Edit, which was Photo Pipeline:
/// his settings and his support folder come across once, before anything
/// reads a setting or starts the engine.
///
/// Four rules hold everywhere in here. Nothing is deleted. His data is never
/// copied: the folder is renamed in place, which moves nothing on disk. The
/// old app's settings and the old app are never written to, so opening
/// Photo Pipeline again still works exactly as it did. And everything done is
/// recorded where it can be undone: `MIGRATED.json` in the folder, and the
/// `migration.*` keys in the new settings.
///
/// Every step takes the folders and the settings domains it works on, so the
/// tests drive it with temporary folders and scratch suites. Only `atLaunch()`
/// names the real ones, and only in the built app.
public enum FirstLaunch {

    /// What the app was called, and where it kept its things.
    public enum Old {
        public static let name = "Photo Pipeline"
        public static let bundleID = "com.nickcupo.photo-pipeline"
        public static let folder = "Photo Pipeline"
    }

    /// What it is called now.
    public enum New {
        public static let name = "First Edit"
        public static let bundleID = "com.nickcupo.firstedit"
        public static let folder = "First Edit"
    }

    public enum Decision: Equatable, Sendable {
        /// Go on and look at nothing: a scratch support folder (a test, the
        /// smoke run, a run pointed at a clone), or not the built app.
        case skip
        /// Photo Pipeline is open. Nothing is moved and the engine is not
        /// started: two engines on one learned store and one queue is the
        /// failure this exists to prevent.
        case refuse
        /// Bring Photo Pipeline's things across, if there are any left to.
        case migrate
    }

    /// In this order. A `PIPELINE_SUPPORT` in the environment wins even over
    /// an open Photo Pipeline, because a run with its own folder shares
    /// nothing with it. A run from a checkout has no bundle identifier and
    /// moves nothing, so `swift run` can never rename his folder.
    public static func decide(environment: [String: String], bundleID: String?,
                              oldAppRunning: () -> Bool) -> Decision {
        if usesItsOwnFolder(environment) { return .skip }
        if oldAppRunning() { return .refuse }
        guard bundleID == New.bundleID else { return .skip }
        return .migrate
    }

    public struct Outcome: Equatable, Sendable {
        public var folder: SupportMove.Outcome
        public var defaults: DefaultsImport.Outcome
    }

    /// The folder first, then the settings: a setting that names a place in
    /// the old folder is pointed at the new one only once the folder is
    /// really there.
    public static func migrate(oldSupport: URL, newSupport: URL, oldDomain: String, newDomain: String,
                               defaults: UserDefaults, appVersion: String, now: Date = Date(),
                               moves: SupportMove.Moves = .real) -> Outcome {
        let folder = SupportMove.run(old: oldSupport, new: newSupport,
                                     record: .init(oldBundleID: oldDomain, newBundleID: newDomain,
                                                   appVersion: appVersion, at: now),
                                     moves: moves)
        let settings = DefaultsImport.run(from: oldDomain, into: newDomain, defaults: defaults,
                                          movedSupport: folder.folderIsNew ? (oldSupport, newSupport) : nil,
                                          now: now)
        return Outcome(folder: folder, defaults: settings)
    }

    // MARK: - the real launch

    /// What Settings ▸ Advanced says under Show the Support Folder, when the
    /// folder was not brought across as planned. Worked out once, at launch.
    @MainActor public private(set) static var note: String?

    /// `main.swift`, before the app's first scene reads a setting and before
    /// `AppDelegate` names the support folder or starts the engine.
    @MainActor public static func atLaunch() {
        let base = AppPaths.applicationSupport
        let environment = ProcessInfo.processInfo.environment
        let newSupport = base.appendingPathComponent(New.folder, isDirectory: true)
        let (decision, outcome) = prepare(
            environment: environment,
            bundleID: Bundle.main.bundleIdentifier,
            oldAppRunning: oldAppIsRunning,
            oldSupport: base.appendingPathComponent(Old.folder, isDirectory: true),
            newSupport: newSupport,
            oldDomain: Old.bundleID, newDomain: New.bundleID, defaults: .standard,
            appVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
        if decision == .refuse { refuse() }
        note = outcome?.folder.note
        if let outcome {
            pendingTwoFolders = twoFolders(outcome.folder, inUse: newSupport, defaults: .standard)
        }
        // Whenever this run shares the real folder with the old app: the
        // check above only sees the old app if it opened first.
        if !usesItsOwnFolder(environment) {
            watch = OldAppWatch { oldAppOpened() }
            watch?.start()
        }
    }

    /// `AppDelegate`, once the app has finished launching: what the first
    /// launch has to say in a window, after the first window is up.
    @MainActor public static func afterLaunch() {
        guard pendingTwoFolders != nil else { return }
        DispatchQueue.main.async { tellAboutTwoFolders() }
    }

    /// `FirstEdit --check`, before it starts an engine: one line, and a
    /// failure, while the old app is open on the folder the check would use.
    /// A check never moves anything; it reads whichever folder is there.
    public static func headlessCheckRefusal(environment: [String: String], oldAppRunning: () -> Bool) -> String? {
        decide(environment: environment, bundleID: nil, oldAppRunning: oldAppRunning) == .refuse
            ? Strings.FirstLaunch.checkRefused : nil
    }

    public static func oldAppIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Old.bundleID).isEmpty
    }

    /// A run pointed at a folder of its own shares nothing with the old app.
    static func usesItsOwnFolder(_ environment: [String: String]) -> Bool {
        if let s = environment["PIPELINE_SUPPORT"], !s.isEmpty { return true }
        return false
    }

    /// The decision, and the migration when that is the decision, against
    /// whatever folders and domains it is handed. `atLaunch` hands it the
    /// real ones; a refusal or a skip touches nothing at all.
    public static func prepare(environment: [String: String], bundleID: String?, oldAppRunning: () -> Bool,
                               oldSupport: URL, newSupport: URL, oldDomain: String, newDomain: String,
                               defaults: UserDefaults, appVersion: String, now: Date = Date(),
                               moves: SupportMove.Moves = .real) -> (Decision, Outcome?) {
        let decision = decide(environment: environment, bundleID: bundleID, oldAppRunning: oldAppRunning)
        guard decision == .migrate else { return (decision, nil) }
        return (decision, migrate(oldSupport: oldSupport, newSupport: newSupport, oldDomain: oldDomain,
                                  newDomain: newDomain, defaults: defaults, appVersion: appVersion,
                                  now: now, moves: moves))
    }

    /// The one alert: Photo Pipeline is still open. Its only button quits.
    @MainActor public static func stillOpenAlert() -> NSAlert {
        let a = NSAlert()
        a.messageText = Strings.FirstLaunch.stillOpenTitle
        a.informativeText = Strings.FirstLaunch.stillOpenBody
        a.addButton(withTitle: Words.App.quit)
        return a
    }

    /// Say so and stop, before any window, any setting and any engine.
    @MainActor static func refuse() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate()
        _ = stillOpenAlert().runModal()
        exit(0)
    }

    // MARK: - two folders, and the one in use has no work in it

    /// Both folders are real and First Edit's is the one in use, as the rule
    /// is, but it lacks the models or what the cull has learned, which the
    /// other still has. The cull cannot run and nothing learned is there,
    /// which looks like loss; a line in Settings ▸ Advanced is not where he
    /// would look. So it is said once, in an alert after launch, as well.
    public struct TwoFolders: Equatable, Sendable {
        public var inUse: URL
        public var other: URL
        /// Of `SupportMove.work`, what the other folder has and this one lacks.
        public var missing: [String]

        public init(inUse: URL, other: URL, missing: [String]) {
            self.inUse = inUse
            self.other = other
            self.missing = missing
        }
    }

    /// The other folder's path, once the alert about it has been shown.
    public static let twoFoldersShown = "migration.twoFoldersShown"

    public static func twoFolders(_ outcome: SupportMove.Outcome, inUse: URL, defaults: UserDefaults) -> TwoFolders? {
        guard case .both(let other) = outcome else { return nil }
        guard defaults.string(forKey: twoFoldersShown) != other.path else { return nil }
        let fm = FileManager.default
        let missing = SupportMove.work.filter {
            !fm.fileExists(atPath: inUse.appendingPathComponent($0).path)
                && fm.fileExists(atPath: other.appendingPathComponent($0).path)
        }
        return missing.isEmpty ? nil : TwoFolders(inUse: inUse, other: other, missing: missing)
    }

    @MainActor public private(set) static var pendingTwoFolders: TwoFolders?

    /// Continue is the default and changes nothing; the other button opens
    /// both folders in Finder.
    @MainActor public static func twoFoldersAlert(_ t: TwoFolders) -> NSAlert {
        let a = NSAlert()
        a.messageText = Strings.FirstLaunch.twoFoldersTitle
        a.informativeText = Strings.FirstLaunch.twoFoldersBody(
            inUse: t.inUse.abbreviatedPath,
            missing: ListFormatter.localizedString(byJoining: t.missing.map(Strings.FirstLaunch.checked)),
            other: t.other.abbreviatedPath)
        a.addButton(withTitle: Strings.FirstLaunch.carryOn)
        a.addButton(withTitle: Strings.FirstLaunch.showBothFolders)
        return a
    }

    @MainActor static func tellAboutTwoFolders(defaults: UserDefaults = .standard) {
        guard let t = pendingTwoFolders else { return }
        pendingTwoFolders = nil
        defaults.set(t.other.path, forKey: twoFoldersShown)
        NSApp.activate()
        if twoFoldersAlert(t).runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([t.inUse, t.other])
        }
    }

    // MARK: - the old app, opened while this one runs

    @MainActor private static var watch: OldAppWatch?
    @MainActor private static var saying = false

    /// Quit Photo Pipeline is the default: it asks the old app to quit, as
    /// its own Quit would, so anything it asks before quitting it still asks.
    @MainActor public static func oldOpenedAlert() -> NSAlert {
        let a = NSAlert()
        a.messageText = Strings.FirstLaunch.oldOpenedTitle
        a.informativeText = Strings.FirstLaunch.oldOpenedBody
        a.addButton(withTitle: Strings.FirstLaunch.quitOld)
        a.addButton(withTitle: Strings.FirstLaunch.leaveOldOpen)
        return a
    }

    @MainActor static func oldAppOpened() {
        guard !saying else { return }
        saying = true
        defer { saying = false }
        NSApp.activate()
        guard oldOpenedAlert().runModal() == .alertFirstButtonReturn else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Old.bundleID) {
            app.terminate()
        }
    }
}

/// Photo Pipeline opening while First Edit runs. After the move it follows
/// the link into the same folder, so two engines would share one learned
/// store and one queue, which is what the check at launch refuses; that
/// check only sees an old app that opened first.
@MainActor public final class OldAppWatch {
    private var observer: NSObjectProtocol?
    private let center: NotificationCenter
    private let identify: @Sendable (Notification) -> String?
    private let opened: @MainActor () -> Void

    /// - Parameters:
    ///   - center: the workspace's, in the app; a private one in a test.
    ///   - identify: the bundle identifier of the app a notification is about.
    public init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
                identify: @escaping @Sendable (Notification) -> String? = OldAppWatch.bundleID,
                opened: @escaping @MainActor () -> Void) {
        self.center = center
        self.identify = identify
        self.opened = opened
    }

    public nonisolated static func bundleID(_ note: Notification) -> String? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    public var isWatching: Bool { observer != nil }

    public func start() {
        guard observer == nil else { return }
        let identify = self.identify
        observer = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                      queue: .main) { [weak self] note in
            guard identify(note) == FirstLaunch.Old.bundleID else { return }
            MainActor.assumeIsolated { self?.opened() }
        }
    }

    public func stop() {
        if let observer { center.removeObserver(observer) }
        observer = nil
    }
}

// MARK: - the support folder

/// `~/Library/Application Support/Photo Pipeline` becomes `…/First Edit`,
/// and a link to it appears at the old name in the same instant: the link is
/// made first under the new name, and then one `renamex_np(RENAME_SWAP)`
/// exchanges the two names. The models, the learned store and the queue move without a byte
/// being copied, and there is no moment at which the old path names nothing:
/// before the swap it is the folder, after it the link to the folder. So the
/// engine run from a checkout, the extension's own tools, an engine left
/// behind by a crash and the old app, if he opens it, all go on finding it,
/// even when one of them is writing at the instant of the move.
///
/// A rename followed by a link, which this replaced, left the old path empty
/// between the two calls: a writer that went through it then got "No such
/// file", and one that made its folder as it wrote (the learned store does)
/// would have made a new, empty Photo Pipeline folder there.
public enum SupportMove {

    public enum Outcome: Equatable, Sendable {
        /// Neither folder: a new Mac. The engine makes First Edit's.
        case fresh
        /// First Edit's folder, and nothing under the old name.
        case alreadyNew
        /// First Edit's folder, and the link to it at the old name.
        case alreadyMoved
        /// First Edit's name is a link to the old folder, made by hand: one
        /// folder, used through the link.
        case sameFolder
        /// Renamed now. `linked` is whether the old name is a link to the
        /// new folder afterwards, as the swap leaves it; `notFound` is what
        /// resolved before the move and not after; `record` is the file the
        /// undo steps were written to.
        case moved(linked: Bool, notFound: [String], record: String?)
        /// The move failed. The old folder is used where it is, untouched.
        case couldNotMove(old: URL, why: String)
        /// Two real folders. First Edit's is used; the other is left alone,
        /// never merged.
        case both(other: URL)
        /// Only the old name, and it is a link he made to somewhere else:
        /// left alone, and used through the link.
        case oldIsALink(URL)

        /// Whether the folder in use is First Edit's own, so a setting that
        /// named a place in the old one should now name the new one.
        public var folderIsNew: Bool {
            switch self {
            case .moved, .alreadyMoved, .alreadyNew: return true
            default: return false
            }
        }

        /// The line for Settings ▸ Advanced, when there is one to say.
        public var note: String? {
            switch self {
            case .couldNotMove(let old, _):
                return Strings.FirstLaunch.couldNotMove(old.abbreviatedPath)
            case .both(let other):
                return Strings.FirstLaunch.otherFolder(other.abbreviatedPath)
            case .moved(_, let notFound, _) where !notFound.isEmpty:
                return Strings.FirstLaunch.notFoundAfterMove(
                    ListFormatter.localizedString(byJoining: notFound.map(Strings.FirstLaunch.checked)))
            case .moved(false, _, _):
                return Strings.FirstLaunch.noLinkAfterMove
            default:
                return nil
            }
        }
    }

    /// The two calls that change anything, injectable so a test can make
    /// either one fail. Each returns 0 or the `errno` it failed with.
    public struct Moves: Sendable {
        public var link: @Sendable (_ destination: String, _ at: URL) -> Int32
        public var swap: @Sendable (_ a: URL, _ b: URL) -> Int32

        public init(link: @escaping @Sendable (String, URL) -> Int32,
                    swap: @escaping @Sendable (URL, URL) -> Int32) {
            self.link = link
            self.swap = swap
        }

        /// `symlink(2)` refuses, rather than replaces, anything already at
        /// the new name. `renamex_np` with `RENAME_SWAP` exchanges two names
        /// in one step and never falls back to copying the way a move across
        /// volumes would; a disk that cannot swap says so, and nothing moves.
        public static let real = Moves(
            link: { destination, at in
                symlink(destination, at.path) == 0 ? 0 : errno
            },
            swap: { a, b in
                renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
            })
    }

    /// What `MIGRATED.json` says besides the two folders.
    public struct Record: Sendable {
        public var oldBundleID: String
        public var newBundleID: String
        public var appVersion: String
        public var at: Date
        public init(oldBundleID: String, newBundleID: String, appVersion: String, at: Date) {
            self.oldBundleID = oldBundleID
            self.newBundleID = newBundleID
            self.appVersion = appVersion
            self.at = at
        }
    }

    /// What has to resolve inside the folder after the rename exactly as it
    /// did before: the models, the learned store and the extension, which is
    /// a link of its own and the one thing a rename could leave pointing
    /// nowhere.
    static let checked = ["models", "learned", "extension/studio_ext.py"]

    /// What a support folder with his work in it has, and an empty one lacks.
    static let work = ["models", "learned"]

    public static func run(old: URL, new: URL, record: Record, moves: Moves = .real) -> Outcome {
        let oldKind = kind(old)
        switch kind(new) {
        case .absent:
            switch oldKind {
            case .directory:
                return move(old: old, new: new, record: record, moves: moves)
            case .link:
                return isDirectory(old) ? .oldIsALink(old) : .fresh
            case .absent, .other:
                return .fresh
            }
        case .other, .directory, .link:
            // The link this step makes before its swap, left by a launch that
            // stopped between the two: the move is simply finished.
            if isPreparedLink(new), oldKind == .directory {
                return move(old: old, new: new, record: record, moves: moves)
            }
            guard isDirectory(new) else {
                // A file, or a link to nothing, where the new folder goes.
                return isDirectory(old)
                    ? .couldNotMove(old: old, why: "\(new.path) is in the way and is not a folder")
                    : .fresh
            }
            let newReal = realPath(new)
            switch oldKind {
            case .absent, .other:
                return .alreadyNew
            case .link:
                guard isDirectory(old) else { return .alreadyNew }
                guard realPath(old) == newReal else { return .both(other: old) }
                // Moved, by a launch that stopped before it wrote the record,
                // or by hand: the undo steps are written down now.
                if !hasRecord(new) {
                    _ = write(MigrationRecord(old: old, new: new, record: record, linked: true,
                                              checked: [], notFound: [], foundMoved: true), in: new)
                }
                return .alreadyMoved
            case .directory:
                return realPath(old) == newReal ? .sameFolder : .both(other: old)
            }
        }
    }

    private static func move(old: URL, new: URL, record: Record, moves: Moves) -> Outcome {
        let fm = FileManager.default
        let before = checked.filter { fm.fileExists(atPath: old.appendingPathComponent($0).path) }
        // The link that ends up at the old name, made first at the new one.
        // Relative, naming the folder beside it: it stays right if his home
        // folder is ever restored somewhere else, and until the swap it names
        // itself, which nothing mistakes for a folder.
        if !isPreparedLink(new) {
            let err = moves.link(new.lastPathComponent, new)
            guard err == 0 else {
                return .couldNotMove(old: old, why: String(cString: strerror(err)))
            }
        }
        let err = moves.swap(old, new)
        guard err == 0 else {
            // Only the link made a moment ago is taken back, and only while
            // it is still that link: the old folder never moved.
            if isPreparedLink(new) { unlink(new.path) }
            return .couldNotMove(old: old, why: String(cString: strerror(err)))
        }
        let linked = kind(old) == .link && realPath(old) != nil && realPath(old) == realPath(new)
        let notFound = before.filter { !fm.fileExists(atPath: new.appendingPathComponent($0).path) }
        let written = write(MigrationRecord(old: old, new: new, record: record, linked: linked,
                                            checked: before, notFound: notFound), in: new)
        return .moved(linked: linked, notFound: notFound, record: written)
    }

    /// The link `move` makes at the new name before its swap: a link whose
    /// text is its own name.
    static func isPreparedLink(_ url: URL) -> Bool {
        kind(url) == .link
            && (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == url.lastPathComponent
    }

    /// Whether a `MIGRATED.json`, or a numbered one, is already in the folder.
    static func hasRecord(_ folder: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0.hasPrefix("MIGRATED") && $0.hasSuffix(".json") }
    }

    /// `MIGRATED.json`, or `MIGRATED 2.json` and on if one is already there
    /// (a move undone and done again): never written over.
    static func write(_ r: MigrationRecord, in folder: URL) -> String? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(r) else { return nil }
        for n in 1...50 {
            let name = n == 1 ? "MIGRATED.json" : "MIGRATED \(n).json"
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            if (try? data.write(to: url, options: .withoutOverwriting)) != nil { return name }
        }
        return nil
    }

    // MARK: what is on disk

    enum Kind: Equatable { case absent, directory, link, other }

    /// What is at the path itself, without following a link.
    static func kind(_ url: URL) -> Kind {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return .absent }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .link
        default: return .other
        }
    }

    /// A folder, or a link that ends at one.
    static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    static func realPath(_ url: URL) -> String? {
        guard let p = realpath(url.path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}

/// `MIGRATED.json`: what moved, from where to where, when, and how to put it
/// back, in the folder that moved.
struct MigrationRecord: Codable, Equatable {
    var what: String
    var from: String
    var to: String
    var at: Date
    var fromBundleID: String
    var toBundleID: String
    var appVersion: String
    var linkLeftAtOldPlace: Bool
    var checked: [String]
    var notFoundAfter: [String]
    var undo: [String]
    /// What an undo does not put back, said before he relies on it.
    var afterUndo: [String]

    /// - Parameter foundMoved: the folder was already under the new name,
    ///   with the link at the old one, and nothing said how it got there: a
    ///   launch that stopped before writing this, or a move made by hand.
    init(old: URL, new: URL, record: SupportMove.Record, linked: Bool, checked: [String], notFound: [String],
         foundMoved: Bool = false) {
        what = foundMoved
            ? "\(FirstLaunch.New.name) found \(FirstLaunch.Old.name)'s folder already under its own name, with a "
                + "link at the old one, and no record of the move, so it wrote this one. Nothing was copied or deleted."
            : "\(FirstLaunch.New.name) renamed \(FirstLaunch.Old.name)'s folder to its own name on its first "
                + "launch. Nothing was copied or deleted, and \(FirstLaunch.Old.name)'s own settings were only read."
        from = old.path
        to = new.path
        at = record.at
        fromBundleID = record.oldBundleID
        toBundleID = record.newBundleID
        appVersion = record.appVersion
        linkLeftAtOldPlace = linked
        self.checked = checked
        notFoundAfter = notFound
        undo = [
            "Quit \(FirstLaunch.New.name).",
            linked
                ? "Remove the link at the old place. It is a link, not the data, and rm without -r refuses a real folder: rm \"\(old.path)\""
                : "There is no link at the old place to remove.",
            "Rename the folder back: mv \"\(new.path)\" \"\(old.path)\"",
            "Open \(FirstLaunch.Old.name), from wherever its app was kept when \(FirstLaunch.New.name) was installed. "
                + "Its settings were never changed. Anything learned under the new name moves back with the folder.",
        ]
        afterUndo = [
            "\(FirstLaunch.New.name) copies \(FirstLaunch.Old.name)'s settings once. Opened again after an undo, it "
                + "moves the folder again but keeps its own settings: anything changed in \(FirstLaunch.Old.name) "
                + "in between is not copied across.",
            "Sidecars \(FirstLaunch.New.name) wrote say first-edit sidecar, which \(FirstLaunch.Old.name) does not "
                + "know as its own, so it leaves them as they are rather than refreshing them.",
        ]
    }
}

// MARK: - the settings

/// Photo Pipeline's settings, copied once into First Edit's.
///
/// Photo Pipeline's value wins over anything already in First Edit's domain:
/// before this runs, anything there can only have come from a test or the
/// build's smoke run of the signed bundle. What it replaces is kept under
/// `migration.replaced.<key>`, and it never runs again once
/// `migration.importedFrom` is set. The old domain is only read.
public enum DefaultsImport {

    public static let importedFrom = "migration.importedFrom"
    public static let importedAt = "migration.importedAt"
    public static let importedKeys = "migration.importedKeys"
    public static let replacedPrefix = "migration.replaced."
    public static let wasPrefix = "migration.was."

    public enum Outcome: Equatable, Sendable {
        /// Done at an earlier launch.
        case alreadyImported(from: String)
        /// No settings under the old name: nothing to do, and nothing marked,
        /// as the plan has it.
        case nothingThere
        /// Copied now: how many keys, which ones replaced a value First Edit
        /// already had, and which were pointed from the old folder to the new.
        case imported(keys: Int, replaced: [String], repointed: [String])
    }

    /// - Parameter movedSupport: the old and new support folders when the
    ///   folder in use is now the new one; a setting that names a place in the
    ///   old folder is then pointed at the same place in the new one, and its
    ///   old value kept under `migration.was.<key>`. `nil` copies every value
    ///   as it is.
    public static func run(from oldDomain: String, into newDomain: String, defaults: UserDefaults,
                           movedSupport: (old: URL, new: URL)?, now: Date) -> Outcome {
        let current = defaults.persistentDomain(forName: newDomain) ?? [:]
        if let from = current[importedFrom] as? String { return .alreadyImported(from: from) }
        guard let old = defaults.persistentDomain(forName: oldDomain) else { return .nothingThere }

        var merged = current
        var count = 0
        var replaced: [String] = []
        var repointed: [String] = []
        for (key, oldValue) in old.sorted(by: { $0.key < $1.key }) where !key.hasPrefix("migration.") {
            var value = oldValue
            if let moved = movedSupport, let there = repoint(oldValue, from: moved.old, to: moved.new) {
                merged[wasPrefix + key] = oldValue
                value = there
                repointed.append(key)
            }
            if let mine = current[key], !same(mine, value) {
                merged[replacedPrefix + key] = mine
                replaced.append(key)
            }
            merged[key] = value
            count += 1
        }
        merged[importedFrom] = oldDomain
        merged[importedAt] = now
        merged[importedKeys] = count
        // One write, so there is never a domain with half of it in.
        defaults.setPersistentDomain(merged, forName: newDomain)
        return .imported(keys: count, replaced: replaced, repointed: repointed)
    }

    /// The same place in the new folder, for a path in the old one; `nil`
    /// for anything else, `general.libraryFolder` included.
    ///
    /// The setting and the folder are put in the same form before they are
    /// compared: standardizing drops a leading `/private` from a path that
    /// exists, so a folder standardized on one side only and not the other
    /// (`/private/var/…` against `/var/…`) never matched, and the setting
    /// kept naming the old folder.
    static func repoint(_ value: Any, from old: URL, to new: URL) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        let expanded = (s as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let o = old.standardizedFileURL.path, n = new.standardizedFileURL.path
        if path == o || path == o + "/" { return n }
        guard path.hasPrefix(o + "/") else { return nil }
        return n + path.dropFirst(o.count)
    }

    static func same(_ a: Any, _ b: Any) -> Bool {
        guard let a = a as? NSObject, let b = b as? NSObject else { return false }
        return a.isEqual(b)
    }
}
