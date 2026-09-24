import Foundation

/// What can go wrong between the app and its engine.
///
/// `refused` carries the engine's own sentence and it is **never rewritten**.
/// The engine writes in his words; the app prints them, under the control that
/// raised it, and nowhere else (DESIGN.md principle 8).
public enum StudioError: Error, Sendable, Equatable {
    /// `{"error": …}` — the engine's sentence, shown as it was written.
    case refused(String)
    case http(status: Int, body: String)
    case offline
    case decoding(route: String, detail: String)
    case engineDown

    /// One plain sentence to put under the control. Never a traceback, never a
    /// status code on its own.
    public var sentence: String {
        switch self {
        case .refused(let s): return s
        case .http(let status, _): return Strings.API.httpFailure(status)
        case .offline: return Strings.API.offline
        case .decoding: return Strings.API.notUnderstood
        case .engineDown: return Strings.Engine.stopped
        }
    }

    /// The technical text that goes behind the Details disclosure.
    public var detail: String? {
        switch self {
        case .refused: return nil
        case .http(_, let body): return body.isEmpty ? nil : body
        case .offline: return nil
        case .decoding(let route, let detail): return "\(route): \(detail)"
        case .engineDown: return nil
        }
    }
}

/// Who put a message on screen. A refusal is only ever cleared by the thing
/// that wrote it, so an unrelated success somewhere else cannot wipe it
/// (DESIGN.md §7.7).
public struct RefusalOwner: Hashable, Sendable {
    public let id: String
    public init(_ id: String) { self.id = id }

    public static let verdict = RefusalOwner("verdict")
    public static let navigation = RefusalOwner("navigation")
    public static let job = RefusalOwner("job")
    public static let storage = RefusalOwner("storage")
    public static let engine = RefusalOwner("engine")
    public static let library = RefusalOwner("library")
}
