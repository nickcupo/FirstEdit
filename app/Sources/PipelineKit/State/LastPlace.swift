import Foundation

/// Where he was: the shoot he had open and the step he was on (DESIGN.md §2.1,
/// "Where the window opens").
///
/// The app opens there, so he never has to expand the sidebar and click down
/// to the step he quit from. Only the shoot and the step are kept. Where to go
/// *inside* Choose Keepers is the engine's answer (`resume` on `/api/shoot`,
/// §2.5.13) and is not duplicated here.
///
/// A library page — All Shoots, the learning page, Storage, a memory card —
/// is never remembered and never overwrites this: those are side trips, and
/// quitting from one opens the shoot he was working in, which is where the
/// work is.
public struct LastPlace: Codable, Sendable, Equatable {
    /// The library folder the engine was looking in, as a path. A place from
    /// another library is not a place in this one, even under the same name.
    public var library: String
    public var shoot: String
    /// `nil`: the shoot's own page, with no step selected.
    public var step: String?

    public init(library: String, shoot: String, step: String?) {
        self.library = library
        self.shoot = shoot
        self.step = step
    }

    /// The same folder, however it was spelled.
    public static func folder(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Where the window should open, from what the engine says is in the
    /// library now. `nil` is "nowhere of his": the window stays on All Shoots
    /// and says nothing, which is what a fresh install sees.
    ///
    /// - The library folder changed: nowhere.
    /// - The shoot is gone, renamed, or its decisions file will not read:
    ///   nowhere. A broken shoot is a red row in the sidebar and in All
    ///   Shoots already; opening onto it would greet him with an error.
    /// - The step is no longer one this shoot has — the engine says it cannot
    ///   cut reels, an extension step whose extension is gone — the shoot's
    ///   own page, with every step it does have under it in the sidebar.
    @MainActor
    public func selection(library now: String, shoots: [ShootRowOK], ext: ExtConfig?) -> SidebarSelection? {
        guard now == library, let row = shoots.first(where: { $0.name == shoot }) else { return nil }
        guard let step else { return .shoot(shoot) }
        let steps = Fallbacks.listSteps(canCutReels: row.can_cut_reels, ext: ext)
        return steps.contains { $0.id == step } ? .step(shoot: shoot, step: step) : .shoot(shoot)
    }
}

extension SettingsStore {
    /// The one place remembered, app-wide. Written on every move to a shoot
    /// or a step, read once at launch.
    public var lastPlace: LastPlace? {
        get {
            guard let d = defaults.data(forKey: Key.lastPlace.rawValue) else { return nil }
            return try? JSONDecoder().decode(LastPlace.self, from: d)
        }
        set {
            guard let newValue, let d = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Key.lastPlace.rawValue)
                return
            }
            defaults.set(d, forKey: Key.lastPlace.rawValue)
        }
    }
}

/// Per shoot, the step he was last on in it, in one library (DESIGN.md §2.1,
/// "Clicking a shoot"). A click on a shoot opens there, where it opened on a
/// page of numbers with nothing to press, and switching between two shoots
/// took two clicks each way. Like `LastPlace`, a library page is never a
/// step of a shoot and never lands here, and a map from another library
/// folder is nothing in this one.
public struct ShootSteps: Codable, Sendable, Equatable {
    public var library: String
    public var steps: [String: String]

    public init(library: String, steps: [String: String]) {
        self.library = library
        self.steps = steps
    }
}

extension SettingsStore {
    /// Written whenever the step he is on in a shoot changes, read once at
    /// launch.
    public var shootSteps: ShootSteps? {
        get {
            guard let d = defaults.data(forKey: Key.shootSteps.rawValue) else { return nil }
            return try? JSONDecoder().decode(ShootSteps.self, from: d)
        }
        set {
            guard let newValue, let d = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Key.shootSteps.rawValue)
                return
            }
            defaults.set(d, forKey: Key.shootSteps.rawValue)
        }
    }
}
