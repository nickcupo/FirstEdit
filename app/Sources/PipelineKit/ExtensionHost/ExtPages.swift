import Foundation

/// Which address a step's page lives at.
///
/// An extension declares a whole page per step — `pages[step]` is a URL
/// template carrying `{shoot}` (DESIGN.md §3.9-9). Until an engine sends that
/// map, a declared step falls back to the engine's own `/ext/<step>` route, so
/// the host works against both servers and the switch is one field.
@MainActor
public enum ExtPages {

    /// Only the loopback. An extension serves from this Mac or it does not
    /// serve: a page template that named somewhere on the internet would put
    /// his shoot's name into a request that leaves the machine.
    public nonisolated static let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]", "::1"]

    /// The upstream address of `step` for `shoot`, or nothing when the
    /// extension does not claim that step.
    public static func upstream(step: String, shoot: String, config: ExtConfig?, engine: URL) -> URL? {
        guard let config, claims(step: step, config: config) else { return nil }
        if let template = config.pages[step], !template.isEmpty {
            return resolve(template: template, shoot: shoot, engine: engine)
        }
        // The engine's own route, which is where an extension's pages live
        // until it declares its own.
        var c = URLComponents(url: engine, resolvingAgainstBaseURL: true)
        c?.path = "/ext/" + step
        c?.queryItems = [URLQueryItem(name: "shoot", value: shoot)]
        return c?.url
    }

    /// Does the extension claim this step? Its own ids are the ones in `steps`
    /// or `every` that are not the engine's seven.
    public static func claims(step: String, config: ExtConfig) -> Bool {
        guard !Fallbacks.baseStepIDs.contains(step) else { return false }
        return config.steps.contains(step) || config.every.contains(step) || config.pages[step] != nil
    }

    /// Every step id the extension contributes, in the order it declared them.
    public static func steps(_ config: ExtConfig?) -> [String] {
        guard let config else { return [] }
        var seen = Set<String>()
        return (config.steps + config.every + config.pages.keys.sorted())
            .filter { !Fallbacks.baseStepIDs.contains($0) && seen.insert($0).inserted }
    }

    /// `{shoot}` is the only placeholder, and it is percent-encoded for the
    /// part of the URL it lands in — a shoot name may hold a space.
    nonisolated static func resolve(template: String, shoot: String, engine: URL) -> URL? {
        let split = template.components(separatedBy: "{shoot}")
        guard split.count > 1 else { return absolute(split[0], engine: engine) }
        // Everything from the first `?` on is query; before it is path.
        let question = template.firstIndex(of: "?")
        var out = ""
        var consumed = 0
        for (i, part) in split.enumerated() {
            out += part
            consumed += part.count
            guard i < split.count - 1 else { break }
            let inQuery = question.map { template.distance(from: template.startIndex, to: $0) < consumed } ?? false
            out += escape(shoot, inQuery: inQuery)
            consumed += "{shoot}".count
        }
        return absolute(out, engine: engine)
    }

    nonisolated static func escape(_ s: String, inQuery: Bool) -> String {
        let allowed: CharacterSet = inQuery
            ? CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
            : CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// A template may be absolute — the extension's own port — or relative to
    /// the engine. Either way it has to stay on this Mac over plain HTTP.
    nonisolated static func absolute(_ text: String, engine: URL) -> URL? {
        guard let url = URL(string: text, relativeTo: engine)?.absoluteURL else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host?.lowercased(), allowedHosts.contains(host) else { return nil }
        return url
    }

    /// The origin a handler speaks for: scheme, host and port, nothing else.
    public nonisolated static func origin(of url: URL) -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: true)
        c?.path = "/"
        c?.query = nil
        c?.fragment = nil
        return c?.url ?? url
    }
}
