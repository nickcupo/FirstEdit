import Foundation

/// What each screen remembers about the picture window (§3.5).
///
/// The window **frame** is deliberately not in here. AppKit owns that, through
/// one autosave name per screen, because AppKit already constrains a restored
/// frame to a visible screen and handles the arrangement arithmetic.
public struct ScreenMemory: Codable, Sendable, Equatable {
    public var mode: DisplayDirector.Mode
    public var fills: Bool
    /// It was open when this screen last went away — the only thing that makes
    /// reopening on reconnect safe.
    public var wasOpen: Bool
    public var lastSeen: Date

    public init(mode: DisplayDirector.Mode = .follow, fills: Bool = true,
                wasOpen: Bool = false, lastSeen: Date = .now) {
        self.mode = mode
        self.fills = fills
        self.wasOpen = wasOpen
        self.lastSeen = lastSeen
    }
}

/// Everything per-screen, in one `Codable` dictionary in `UserDefaults`.
///
/// It is written under two keys. The exact `ScreenKey` carries the arrangement,
/// so a resolution change starts a fresh entry — which is right, because a
/// frame saved for 2560 × 1440 is wrong for 3840 × 2160. The coarse key is the
/// panel without its arrangement, and the mode and the fill flag are mirrored
/// there so *those* survive a resolution change even when the frame does not
/// (§3.4).
public struct DisplayMemory: Codable, Sendable, Equatable {
    public static let defaultsKey = "displays.perScreen"
    /// A hotel monitor does not live in his defaults forever.
    public static let keepFor: TimeInterval = 180 * 24 * 60 * 60

    public var entries: [String: ScreenMemory]

    public init(entries: [String: ScreenMemory] = [:]) { self.entries = entries }

    // MARK: - reading

    /// The mode and the fill flag for a screen: its own entry if it has one,
    /// otherwise the panel's, whatever arrangement it was last in.
    public func panel(for key: ScreenKey) -> ScreenMemory? {
        entries[key.raw] ?? entries[key.coarse.raw]
    }

    /// Whether the window was open on *this exact screen* when it last went
    /// away. A projector, a TV at someone's house, a borrowed monitor never
    /// gets a window thrown onto it.
    public func wasOpen(on key: ScreenKey) -> Bool {
        entries[key.raw]?.wasOpen ?? false
    }

    /// The attached screen it was most recently open on.
    public func mostRecentlyOpen(among set: ScreenSet) -> ScreenKey? {
        set.screens
            .compactMap { info -> (ScreenKey, Date)? in
                guard let e = entries[info.key.raw], e.wasOpen else { return nil }
                return (info.key, e.lastSeen)
            }
            .max { $0.1 < $1.1 }?.0
    }

    // MARK: - writing

    public mutating func remember(open: Bool, on key: ScreenKey, mode: DisplayDirector.Mode, fills: Bool) {
        entries[key.raw] = ScreenMemory(mode: mode, fills: fills, wasOpen: open, lastSeen: .now)
        // The panel's own entry keeps the mode and the fill flag across a
        // resolution change. It never claims the window was open: that is a
        // fact about one arrangement.
        let coarse = key.coarse.raw
        if coarse != key.raw {
            entries[coarse] = ScreenMemory(mode: mode, fills: fills, wasOpen: false, lastSeen: .now)
        }
    }

    public mutating func prune(now: Date = .now) {
        entries = entries.filter { now.timeIntervalSince($0.value.lastSeen) < Self.keepFor }
    }

    // MARK: - defaults

    public static func load(from defaults: UserDefaults) -> DisplayMemory {
        guard let data = defaults.data(forKey: defaultsKey),
              let m = try? JSONDecoder().decode(DisplayMemory.self, from: data)
        else { return DisplayMemory() }
        return m
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - the four rows in Settings ▸ Choosing (§7.2)

extension SettingsStore {
    /// On. Only for a screen the picture has been used on before, so plugging
    /// into a TV at someone's house never throws a window onto it.
    public var bringThePictureBack: Bool {
        get { flag("choosing.bringPictureBack", default: true) }
        set { defaults.set(newValue, forKey: "choosing.bringPictureBack") }
    }
    /// On. Four frames side by side each get nearly seven times the area they
    /// have on the laptop, and the buttons and the strip stay under his hand.
    public var compareOnTheOtherScreen: Bool {
        get { flag("choosing.compareOnOtherScreen", default: true) }
        set { defaults.set(newValue, forKey: "choosing.compareOnOtherScreen") }
    }
    /// Off. The machine's words are its own and they live where his controls
    /// are (`DESIGN.md` principle 4).
    public var cullsLineOnTheOtherScreen: Bool {
        get { flag("choosing.cullLineOnOtherScreen", default: false) }
        set { defaults.set(newValue, forKey: "choosing.cullLineOnOtherScreen") }
    }
    /// On. A stated exception to §2.15's "the pointer is never hidden", and a
    /// narrow one: a black arrow parked over a photograph he is judging is in
    /// the frame.
    public var hidePointerOnTheOtherScreen: Bool {
        get { flag("choosing.hidePointerOnOtherScreen", default: true) }
        set { defaults.set(newValue, forKey: "choosing.hidePointerOnOtherScreen") }
    }

    private func flag(_ key: String, default d: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? d : defaults.bool(forKey: key)
    }
}
