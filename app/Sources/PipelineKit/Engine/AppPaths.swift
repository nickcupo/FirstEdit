import Foundation

/// Where the app keeps its own things.
public enum AppPaths {
    /// `~/Library/Application Support`.
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// `~/Library/Application Support/First Edit`, unless the environment
    /// names another — which is how a scratch run keeps every write away from
    /// the real one.
    ///
    /// The one place the app works out its folder, in the order the first
    /// launch leaves things (`FirstLaunch`, `SupportMove`): First Edit's own
    /// folder whenever it is there, the old app's where it is when renaming
    /// it failed or has not happened yet (a run from a checkout never renames
    /// it), and First Edit's, to be made, on a Mac that has neither.
    public static func support(environment env: [String: String] = ProcessInfo.processInfo.environment,
                               applicationSupport base: URL = AppPaths.applicationSupport) -> URL {
        if let s = env["PIPELINE_SUPPORT"], !s.isEmpty {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true)
        }
        let new = base.appendingPathComponent(FirstLaunch.New.folder, isDirectory: true)
        let old = base.appendingPathComponent(FirstLaunch.Old.folder, isDirectory: true)
        if SupportMove.isDirectory(new) { return new }
        if SupportMove.isDirectory(old) { return old }
        return new
    }

    /// Where the library would be if nothing were changed: his own choice
    /// first, then whatever `PHOTOS_ROOT` names, then the engine's default.
    ///
    /// Only ever read, and only ever to say "there are N shoots here already"
    /// on the first-run sheet. Nothing is written to it from here.
    public static func libraryCandidate(settings: SettingsStore = .shared,
                                        environment env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let chosen = settings.libraryFolder { return chosen }
        if let root = env["PHOTOS_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("photos", isDirectory: true)
    }

    /// The folder the engine is actually reading, in the engine's own order:
    /// a `PHOTOS_ROOT` already in this process's environment wins (the smoke
    /// script, a run pointed at a scratch clone), then his choice in Settings,
    /// then the engine's default. `EngineHost.environment` hands the child
    /// exactly this. `libraryCandidate` puts his choice first because the
    /// first-run sheet is asking what he chose; the place he left off has to
    /// be recorded against the library the engine listed, or a run against a
    /// clone would save the clone's shoot under his real library's folder.
    public static func engineLibrary(settings: SettingsStore = .shared,
                                     environment env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let root = env["PHOTOS_ROOT"] {
            return URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let chosen = settings.libraryFolder { return chosen }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("photos", isDirectory: true)
    }
}
