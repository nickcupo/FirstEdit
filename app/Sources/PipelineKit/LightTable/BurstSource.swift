import Foundation
import CoreGraphics

/// The three places the light table has to work differently before and after
/// the server changes of DESIGN.md §3.9 land — and the one line that switches
/// each of them.
///
/// §5.1 says this crew is blocked on §3.9-2 (the `/full?px=` tier), §3.9-3 (the
/// `/crop` clamp) and §3.9-6 (server-side time bursts and resume), and that
/// until they land it uses `/full` at 2600, a 3000 px tile and client-side
/// grouping **behind one protocol with two implementations**. So: one protocol,
/// two implementations, and `LightTableSeams.current` is the line.
///
/// The app is written against the *new* shape throughout. Nothing above this
/// file asks which server it is talking to.
public protocol BurstSource: Sendable {

    /// The bursts of a shoot. The server's own grouping when it sends one.
    @MainActor func bursts(in response: ShootResponse) -> [Burst]

    /// Where opening Choose Keepers goes, and the sentence that says why
    /// (§2.5.13).
    @MainActor func resume(in response: ShootResponse, bursts: [Burst]) -> Resume

    /// The `/full?px=` tier to ask for, for a picture this many device pixels
    /// wide. The engine honours `px` up to 4096 (§3.9-2 has landed:
    /// `FULL_TIERS` in `studio.py`).
    func fullPixels(forPoints points: CGSize, scale: CGFloat) -> Int

    /// The widest `/crop` tile the app asks for: 4096. The engine cuts up to
    /// 6144 now (§3.9-3 landed and went further).
    var maximumTilePixels: Int { get }
}

// MARK: - what the server sends today

/// Groups on today's `scene/burst` key, which is the key the engine's review
/// file is written under, so "been through" reads back correctly. It is also
/// the key that splits one time burst across several screens — 56 of 89 bursts
/// of his gym shoot (DUP-6) — which is exactly why the server is taking it over.
public struct TodaysServer: BurstSource {
    public init() {}

    @MainActor public func bursts(in r: ShootResponse) -> [Burst] {
        r.bursts.isEmpty ? Fallbacks.legacyBursts(r.rows, r.review) : r.bursts
    }

    @MainActor public func resume(in r: ShootResponse, bursts: [Burst]) -> Resume {
        if r.resume.kind != .fresh || r.resume.burst_id != nil { return r.resume }
        return Self.resolve(at: r.review.at, bursts: bursts, stale: r.review.stale, kept: r.info.kept,
                            frames: r.info.frames)
    }

    /// §2.5.13, in order: where he left off, else the first burst not been
    /// through, else every burst is through, else a fresh shoot.
    @MainActor static func resolve(at: String, bursts: [Burst], stale: String,
                                   kept: Int, frames: Int) -> Resume {
        let total = bursts.count
        func note(_ s: String) -> String {
            stale.isEmpty ? s : "\(stale) \(s)"
        }
        if !at.isEmpty, let i = bursts.firstIndex(where: { $0.id == at }) {
            let seen = bursts.filter(\.seen).count
            return Resume(burst_id: at, kind: .left_off,
                          note: note(Strings.LightTable.resumeLeftOff(i + 1, total, seen, total - seen)))
        }
        if let first = bursts.first(where: { !$0.seen }) {
            let kind: ResumeKind = at.isEmpty ? .fresh : .moved
            let text = at.isEmpty
                ? Strings.LightTable.resumeFresh(total)
                : Strings.LightTable.resumeMoved(total)
            return Resume(burst_id: first.id, kind: kind, note: note(text))
        }
        return Resume(burst_id: bursts.first?.id, kind: .all_seen,
                      note: note(Strings.LightTable.resumeAllSeen(kept, frames)))
    }

    /// The size the picture is drawn at, rounded up to a tier. This was
    /// capped at 2600 for an engine that cut `/full` at 2600 whatever it was
    /// asked; the engine serves up to 4096 now, and the cap left Full Image
    /// on a laptop (2834 px) and the fit view on a 27" (3606 px) stretched
    /// from 2600 — softness in the one picture he calls a missed focus on.
    public func fullPixels(forPoints points: CGSize, scale: CGFloat) -> Int {
        ImagePump.fullPixels(forPoints: points, scale: scale)
    }

    public var maximumTilePixels: Int { TileFetcher.maximumTilePixels }
}

// MARK: - what the server sends once §3.9 lands

/// The server groups by time and resolves the resume target itself, `/full`
/// takes a `px` tier up to 4096 and `/crop` clamps at 6144. Fixing the grouping
/// in one place fixes it for both readers (§2.5.13).
public struct NewServer: BurstSource {
    public init() {}

    @MainActor public func bursts(in r: ShootResponse) -> [Burst] { r.bursts }
    @MainActor public func resume(in r: ShootResponse, bursts: [Burst]) -> Resume { r.resume }

    public func fullPixels(forPoints points: CGSize, scale: CGFloat) -> Int {
        ImagePump.fullPixels(forPoints: points, scale: scale)
    }

    public var maximumTilePixels: Int { TileFetcher.serverClampLanded }
}

// MARK: - the line

@MainActor
public enum LightTableSeams {
    /// **This is the switch.** One line, when §3.9-2/3/6 land.
    public static var current: any BurstSource = TodaysServer()

    /// A shoot's bursts and resume note, however the server behaves.
    public static func read(_ r: ShootResponse) -> (bursts: [Burst], resume: Resume) {
        let b = current.bursts(in: r)
        return (b, current.resume(in: r, bursts: b))
    }

    /// Where an open session should open, and the sentence that says why.
    ///
    /// The session carries whatever the engine sent; when that is nothing —
    /// which is every engine today — §2.5.13's four cases are worked out here
    /// instead, from the same review record the engine writes. The day the
    /// server resolves it, this returns the server's answer untouched.
    public static func resume(for session: ShootSession) -> Resume {
        let sent = session.resume
        if sent.burst_id != nil || !sent.note.isEmpty { return sent }
        return TodaysServer.resolve(at: session.review.at, bursts: session.bursts,
                                    stale: session.review.stale, kept: session.info.kept,
                                    frames: session.info.frames)
    }
}
