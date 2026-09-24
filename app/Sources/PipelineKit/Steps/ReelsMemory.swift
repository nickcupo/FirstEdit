import Foundation

/// What the Reels step remembers across a relaunch (DESIGN.md §2.6).
///
/// The app reopens on the step he was on, and on Reels that came back as the
/// lister's top burst, cut as a Cut at 8 a second in 1080 with every frame
/// back in. Two kinds of thing are kept, apart:
///
/// - **His habits**, for every shoot: the speeds, what the crop follows, the
///   size and the order of the list.
/// - **Where he was in a shoot**: the format, the burst and the frames he
///   took out.
///
/// Nothing here is a decision about a photograph that the engine keeps; it is
/// the page's own state, the same kind the other steps keep for their forms.
/// A memory with no defaults remembers nothing — every model made outside
/// `ReelsModelStore`, the tests and the snapshot harness.
public final class ReelsMemory: @unchecked Sendable {
    public static let shared = ReelsMemory(defaults: .standard)

    private let defaults: UserDefaults?

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    /// Remembers nothing.
    public static var none: ReelsMemory { ReelsMemory(defaults: nil) }

    public var remembers: Bool { defaults != nil }

    struct Habits: Codable, Equatable {
        var burstSpeed: Int
        var timelapseSpeed: Int
        var burstFollow: String
        var timelapseFollow: String
        var size: String
        var order: String
    }

    struct Place: Codable, Equatable {
        var format: String
        var burst: String?
        var leftOut: [String]
    }

    static let habitsKey = "reels.habits"
    static let placePrefix = "reels.place."

    func habits() -> Habits? { read(Self.habitsKey) }
    func save(_ h: Habits) { write(h, Self.habitsKey) }

    func place(shoot: String) -> Place? { read(Self.placeKey(shoot)) }
    func save(_ p: Place, shoot: String) { write(p, Self.placeKey(shoot)) }

    /// The shoot's name goes in whole: two shoots whose names differ only by
    /// a dot cannot read each other's place.
    static func placeKey(_ shoot: String) -> String {
        placePrefix + ExtStateStore.escape(shoot)
    }

    private func read<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable & Equatable>(_ value: T, _ key: String) {
        guard let defaults, let data = try? JSONEncoder().encode(value) else { return }
        if defaults.data(forKey: key) != data { defaults.set(data, forKey: key) }
    }
}

extension ReelsModel {
    var habits: ReelsMemory.Habits {
        ReelsMemory.Habits(burstSpeed: burstSpeed, timelapseSpeed: timelapseSpeed,
                           burstFollow: burstFollow, timelapseFollow: timelapseFollow,
                           size: size.rawValue, order: order.rawValue)
    }

    var place: ReelsMemory.Place {
        ReelsMemory.Place(format: format.rawValue, burst: burst, leftOut: leftOut.sorted())
    }

    /// Before the page first asks the lister: his habits, and where he was in
    /// this shoot. A value this build does not know is left as it is.
    func restore(from memory: ReelsMemory) {
        if let h = memory.habits() {
            if Self.speeds.contains(h.burstSpeed) { burstSpeed = h.burstSpeed }
            if Self.speeds.contains(h.timelapseSpeed) { timelapseSpeed = h.timelapseSpeed }
            if !h.burstFollow.isEmpty { burstFollow = h.burstFollow }
            if !h.timelapseFollow.isEmpty { timelapseFollow = h.timelapseFollow }
            if let s = ReelSize(rawValue: h.size) { size = s }
            if let o = ReelOrder(rawValue: h.order) { order = o }
        }
        if let p = memory.place(shoot: session.name) {
            if let f = ReelFormat(rawValue: p.format) { format = f }
            burst = p.burst
            leftOut = Set(p.leftOut)
        }
    }

    /// Writes both down whenever either changes, for as long as the model
    /// lives.
    func remember(in memory: ReelsMemory) {
        guard memory.remembers else { return }
        let name = session.name
        withObservationTracking {
            memory.save(habits)
            memory.save(place, shoot: name)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.remember(in: memory) }
        }
    }
}
