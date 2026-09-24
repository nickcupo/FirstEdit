import Foundation

/// What the app does while the engine does not yet send `bursts` and `steps`
/// on `GET /api/shoot` (DESIGN.md §3.9-6/7).
///
/// Two seams, each one line to switch. The light table's `BurstSource` and the
/// steps' `StepSource` adapters replace these by assigning to them at launch;
/// the moment the engine sends its own arrays, `ShootSession` uses those and
/// these are never called.
@MainActor
public enum Fallbacks {

    /// Groups frames client-side on today's `scene/burst` key. That is the key
    /// the engine's review file is written under today, so "been through" reads
    /// back correctly; it is also the key that splits one time burst across
    /// several screens (DUP-6), which is why the server takes this over.
    public static var bursts: @MainActor ([Row], Review) -> [Burst] = legacyBursts

    /// The engine's eight step ids, in its order, with the extension's own
    /// steps where it declares them. **Done-ness is not computed here**: every
    /// step is reported not done and enabled, because the app never works out
    /// done-ness for itself (§4.2). The Reels step is absent when the engine
    /// says it cannot encode.
    public static var steps: @MainActor (ShootInfo, ExtConfig?) -> [StepState] = listSteps

    public static let baseStepIDs = ["ingest", "cull", "keepers", "presets", "edit", "instagram", "reels", "done"]

    public static func baseLabel(_ id: String) -> String {
        switch id {
        case "ingest": return Strings.Steps.ingest
        case "cull": return Strings.Steps.cull
        case "keepers": return Strings.Steps.keepers
        case "presets": return Strings.Steps.presets
        case "edit": return Strings.Steps.edit
        case "instagram": return Strings.Steps.instagram
        case "reels": return Strings.Steps.reels
        case "done": return Strings.Steps.done
        default: return id
        }
    }

    /// An extension's own list of the steps, with Instagram where the engine
    /// puts it when the list does not name it (DESIGN.md §2.17): right after
    /// Edit, else before Reels, else before Finish. A list written before
    /// the step was built-in would otherwise leave it out, and the public
    /// step would be missing from exactly the build that had it first. A list
    /// that names it keeps its own place for it.
    public static func withInstagram(_ steps: [String]) -> [String] {
        guard !steps.contains("instagram") else { return steps }
        var out = steps
        if let i = out.firstIndex(of: "edit") {
            out.insert("instagram", at: i + 1)
        } else if let i = out.firstIndex(of: "reels") {
            out.insert("instagram", at: i)
        } else if let i = out.firstIndex(of: "done") {
            out.insert("instagram", at: i)
        } else {
            out.append("instagram")
        }
        return out
    }

    public static func legacyBursts(_ rows: [Row], _ review: Review) -> [Burst] {
        var order: [String] = []
        var members: [String: [Row]] = [:]
        for r in rows {
            let k = r.legacyBurstKey
            if members[k] == nil { order.append(k) }
            members[k, default: []].append(r)
        }
        return order.enumerated().map { i, k in
            let rs = members[k] ?? []
            let seen = review.bursts[k].map { !$0.seen.isEmpty } ?? false
            var kept = 0, out = 0, undecided = 0
            for r in rs {
                switch VerdictValue.his(r) {
                case .kept: kept += 1
                case .out: out += 1
                case .unmarked: undecided += 1
                }
            }
            return Burst(id: k, index: i, scene: rs.first?.scene, started_at: rs.first?.shot_at,
                         frames: rs.map(\.stem), cover: rs.first(where: { $0.rating >= 3 })?.stem ?? rs.first?.stem,
                         seen: seen, kept: kept, out: out,
                         cull_picks: rs.filter { $0.rating >= 3 }.count, undecided: undecided)
        }
    }

    public static func listSteps(_ info: ShootInfo, _ ext: ExtConfig?) -> [StepState] {
        var ids = baseStepIDs.filter { $0 != "reels" || info.can_cut_reels }
        var labels: [String: String] = [:]
        var sources: [String: StepSource] = [:]
        if let ext {
            // The extension's STEPS list is the whole ordered list with its own
            // steps inserted; where it names only its own, they go before
            // Finish.
            let own = ext.steps.filter { !baseStepIDs.contains($0) }
            if ext.steps.contains(where: baseStepIDs.contains) {
                ids = withInstagram(ext.steps).filter { $0 != "reels" || info.can_cut_reels }
            } else if let at = ids.firstIndex(of: "done") {
                ids.insert(contentsOf: own, at: at)
            }
            for id in own {
                labels[id] = ext.labels[id] ?? id
                sources[id] = .extensionProvided
            }
        }
        return ids.map {
            StepState(id: $0, label: labels[$0] ?? baseLabel($0), done: false, enabled: true,
                      why_disabled: nil, source: sources[$0] ?? .base)
        }
    }
}
