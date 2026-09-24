import Foundation

/// The cull's own focus figure, read against its neighbours (DESIGN.md
/// §2.5.12).
///
/// Sharpness is why he opens Compare: 81 of the 156 close calls on his gym
/// shoot were sharpness calls. The figure under each tile was a bare number in
/// faint grey — "focus 61" beside "focus 161" — with what it meant only in a
/// hover, and that hover compared it with the focus *setting* of the next cull
/// (1.9, printed as 1) rather than with anything in the frames. So Compare now
/// says which tile the cull measures sharpest and how far under it each other
/// one is, and the inspector says where a frame sits in its burst.
///
/// It only says what an existing measure says. Nothing here decides, moves or
/// marks a frame.
public enum Sharpness {

    /// Where one frame stands among the frames it is shown with.
    public struct Standing: Equatable, Sendable {
        /// The one the cull measures sharpest. Exactly one frame is, however
        /// close the others come.
        public let sharpest: Bool
        /// How far under the sharpest it measures, in whole percent. Zero on
        /// the sharpest, and on any frame within half a percent of it.
        public let under: Int
        /// How many of the frames shown have a figure at all.
        public let of: Int
        /// The sharpest one's own figure, and its frame.
        public let best: Double
        public let bestStem: String
    }

    /// Each frame's standing, for frames with a figure, when at least two of
    /// them have one — one figure has nothing to stand against.
    public static func standings(_ stems: [String], rows: [String: Row]) -> [String: Standing] {
        let measured = stems.compactMap { s -> (String, Double)? in
            guard let f = rows[s]?.focus, f > 0 else { return nil }
            return (s, f)
        }
        guard measured.count >= 2,
              let top = measured.max(by: { $0.1 < $1.1 })   // the first of equals, in the order shown
        else { return [:] }
        var out: [String: Standing] = [:]
        for (s, f) in measured {
            let under = Int(((1 - f / top.1) * 100).rounded())
            out[s] = Standing(sharpest: s == top.0, under: max(0, under), of: measured.count,
                              best: top.1, bestStem: top.0)
        }
        return out
    }

    /// The middle of the figures in these frames — "most frames here are near
    /// 140" — or nothing when fewer than two have one.
    public static func typical(_ stems: [String], rows: [String: Row]) -> Double? {
        let figures = stems.compactMap { rows[$0]?.focus }.filter { $0 > 0 }.sorted()
        guard figures.count >= 2 else { return nil }
        let mid = figures.count / 2
        return figures.count % 2 == 1 ? figures[mid] : (figures[mid - 1] + figures[mid]) / 2
    }
}
