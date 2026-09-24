import Foundation

/// How long a burst lasted, from the capture times of its first and last
/// frames (DESIGN.md §2.6).
///
/// The camera's own clock, as the cull read it into each frame's `shot_at`,
/// and nothing else. How long a reel of the burst would run is the reel
/// maker's arithmetic, which is private; the lister's `seconds` is that, and
/// is not read here.
public struct BurstLength: Equatable, Sendable {
    /// From the first frame's capture to the last's.
    public let seconds: Double
    /// Whether the capture times carried fractions of a second. The cull
    /// writes them to the second, so a length is good to a second either way
    /// and is said so: "under 1 s", "about 2 s".
    public let exact: Bool

    public init(seconds: Double, exact: Bool) {
        self.seconds = seconds
        self.exact = exact
    }

    /// The span of the capture times given; `nil` when fewer than two of
    /// them can be read.
    public static func of(_ times: [String?]) -> BurstLength? {
        let read = times.compactMap { CaptureTime.read($0) }
        guard read.count >= 2, let first = read.map(\.at).min(), let last = read.map(\.at).max() else { return nil }
        return BurstLength(seconds: last - first, exact: read.contains { $0.fractional })
    }
}

/// A frame's capture time as the cull writes it: EXIF's
/// "2026:09:19 20:14:07", maybe with a fraction of a second or a zone after
/// it, which is read and left out.
enum CaptureTime {
    /// Seconds on a scale of its own, good for taking one from another.
    static func read(_ text: String?) -> (at: Double, fractional: Bool)? {
        guard let text, !text.isEmpty else { return nil }
        let halves = text.split(separator: " ", maxSplits: 1)
        guard halves.count == 2 else { return nil }
        let date = halves[0].split(separator: ":").compactMap { Int($0) }
        var clock = String(halves[1])
        if let zone = clock.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) { clock = String(clock[..<zone]) }
        let hms = clock.split(separator: ":")
        guard date.count >= 3, hms.count >= 3, let h = Int(hms[0]), let m = Int(hms[1]),
              let s = Double(hms[2]) else { return nil }
        var parts = DateComponents()
        parts.year = date[0]; parts.month = date[1]; parts.day = date[2]
        guard let day = Self.calendar.date(from: parts) else { return nil }
        let at = day.timeIntervalSinceReferenceDate + Double(h * 3600 + m * 60) + s
        return (at, hms[2].contains("."))
    }

    /// Days counted in one fixed zone: a burst crossing midnight is seconds
    /// long, whatever zone the Mac is in.
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}

extension ReelsModel {
    /// How long the lister's burst lasted, from its frames in the shoot.
    public func length(of burst: String) -> BurstLength? {
        facts.lengths[burst]
    }

    /// Whether he kept a frame of the burst, by the rule "you kept" is
    /// counted by everywhere else: the engine's count while nothing in the
    /// burst has changed since it counted, and once he has worked on it, the
    /// same rule over its frames as they are now. The lister's own count
    /// where the shoot does not have the burst.
    public func keptOne(_ option: BurstOption) -> Bool {
        facts.kept[option.burst] ?? ((option.kept ?? 0) > 0)
    }

    /// Worked out once for each version of the shoot's rows and bursts, not
    /// on every draw of 200 rows.
    var facts: BurstFacts {
        let version = session.rowsVersion, bursts = session.burstsVersion
        if let known = factsCache, known.version == version, known.burstsVersion == bursts,
           known.bursts == session.bursts.count { return known }
        let made = BurstFacts(session, version: version)
        factsCache = made
        return made
    }
}

/// What the bursts list says of each burst beside what the lister sends.
struct BurstFacts {
    let version: Int
    let burstsVersion: Int
    let bursts: Int
    let lengths: [String: BurstLength]
    let kept: [String: Bool]

    @MainActor init(_ session: ShootSession, version: Int) {
        self.version = version
        burstsVersion = session.burstsVersion
        bursts = session.bursts.count
        var lengths: [String: BurstLength] = [:]
        var kept: [String: Bool] = [:]
        for b in session.bursts {
            let rows = b.frames.map { session.rows[$0] }
            lengths[b.id] = BurstLength.of(rows.map { $0?.shot_at })
            kept[b.id] = session.countedAsItIs(b) ? b.kept > 0 : Self.keptOne(b, rows)
        }
        self.lengths = lengths
        self.kept = kept
    }

    /// The engine's rule for "you kept" (`gather.verdicts`), over a burst's
    /// frames as they are now: a frame he marked is his mark, and one he left
    /// alone in a burst he has been through is the cull's pick when the cull
    /// rated it in. The dot once added the engine's count, read when the
    /// shoot was opened, to that, so un-keeping the only frame he had kept
    /// left the dot saying he kept one. What this cannot see is the answer
    /// key of a shoot worked before bursts were recorded as been through,
    /// which the engine's count carries until he works on the burst.
    static func keptOne(_ b: Burst, _ rows: [Row?]) -> Bool {
        rows.contains { row in
            guard let row else { return false }
            if row.override != nil { return VerdictValue.his(row) == .kept }
            return b.seen && row.rating >= VerdictValue.inThreshold
        }
    }
}
