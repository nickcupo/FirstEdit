import Foundation

/// The routes the list is read and changed through.
///
/// Beside `Routes` rather than inside it, because the list is its own subject
/// and this is the only place in the app that talks to it. Every one of the
/// POSTs answers with the list as it is afterwards, so nothing here has to
/// guess what its own request did to the order.
public enum QueueRoutes {
    /// What is happening and what is waiting, in one reading.
    public static func state() -> Route<QueueState> { Route(.get, "/api/queue") }

    /// What finished in the last few days, every run of the engine's.
    public static func earlier() -> Route<EarlierJobs> { Route(.get, "/api/jobs/history") }

    public static let add = Route<QueueChanged>(.post, "/api/queue")
    public static let order = Route<QueueChanged>(.post, "/api/queue/order")
    public static let remove = Route<QueueChanged>(.post, "/api/queue/remove")
    public static let clear = Route<QueueChanged>(.post, "/api/queue/clear")
    public static let hold = Route<QueueChanged>(.post, "/api/queue/hold")
}

/// One piece of work, described rather than commanded: the kind, the shoot,
/// and whatever else that kind of work needs. The options are the same names
/// the route that does this one thing now reads off a body, because they are
/// read by the same code — the engine builds the command from these when the
/// turn comes, not when the tap happens.
public struct QueueAddBody: Encodable, Sendable {
    public let kind: String
    public let name: String
    public let options: [String: JSONValue]

    public init(kind: String, name: String, options: [String: JSONValue] = [:]) {
        self.kind = kind
        self.name = name
        self.options = options
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: StringKey.self)
        try c.encode(kind, forKey: StringKey("kind"))
        try c.encode(name, forKey: StringKey("name"))
        for (k, v) in options where k != "kind" && k != "name" {
            try c.encode(v, forKey: StringKey(k))
        }
    }
}

/// His order, in one move. Ids he did not name keep their places at the end:
/// a drag names what moved, not the whole list.
public struct QueueOrderBody: Encodable, Sendable {
    public let ids: [Int]
    public init(_ ids: [Int]) { self.ids = ids }
}

public struct QueueIDBody: Encodable, Sendable {
    public let id: Int
    public init(_ id: Int) { self.id = id }
}

public struct QueueHoldBody: Encodable, Sendable {
    public let held: Bool
    public init(_ held: Bool) { self.held = held }
}
