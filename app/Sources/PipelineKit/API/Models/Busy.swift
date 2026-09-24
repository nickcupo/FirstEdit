import Foundation
import Observation

/// Why what he pressed cannot start yet, with enough in it to decide.
///
/// The engine used to answer `{"error": "a job is already running"}` and
/// nothing else. That sentence names no job, says nothing about how far along
/// it is or when it will end, and offers him nothing to do about it. He was
/// standing in a gym with a card to copy, and the only information on his
/// screen was the word "a".
///
/// It now answers with the sentence **and** this: which job, where it has got
/// to, roughly how long is left, and whether it is his own work or the
/// machine's homework. Two rules follow from that and hold everywhere this is
/// used.
///
/// 1. **The sentence is the engine's and is never rewritten.** What the app
///    adds is the two choices, because those are buttons and the engine has
///    no buttons.
/// 2. **A background job never reaches here.** It stands down before the slot
///    is asked for, so anything in a `Busy` is work he asked for himself —
///    which is exactly why waiting or stopping it is his decision and not the
///    app's. `background` is carried anyway, so a screen can say so rather
///    than assume, and an older engine that does refuse from the homework is
///    still described truthfully.
public struct Busy: Sendable, Hashable {
    public let id: Int
    public let kind: String
    public let title: String
    public let shoot: String
    public let stage: String
    /// The engine's stage words and count — "looking at faces: 240 of 1,157
    /// frames". The app never writes a stage name of its own.
    public let label: String
    public let fraction: Double
    public let elapsed: Int
    /// `nil` when the engine will not estimate yet. Nothing downstream
    /// invents one.
    public let remaining: Int?
    /// The engine's own words for what is left — "about 4 minutes left" — or
    /// empty when it will not say. Shown as written.
    public let remaining_text: String
    public let background: Bool
    /// Whether the engine will take this request into the queue behind what is
    /// running. It says so; the app never assumes it.
    public let can_queue: Bool
    /// What he was trying to do, as the engine titled it.
    public let wanted: String

    public init(fields f: Fields) {
        id = f.int("id")
        kind = f.string("kind")
        title = f.string("title")
        shoot = f.string("shoot")
        stage = f.string("stage")
        label = f.string("label")
        fraction = f.double("fraction")
        elapsed = f.int("elapsed")
        remaining = f.intOrNil("remaining")
        remaining_text = f.string("remaining_text")
        background = f.bool("background")
        can_queue = f.bool("can_queue")
        wanted = f.string("wanted")
    }

    public init(id: Int = 0, kind: String = "", title: String = "", shoot: String = "",
                stage: String = "", label: String = "", fraction: Double = 0, elapsed: Int = 0,
                remaining: Int? = nil, remaining_text: String = "", background: Bool = false,
                can_queue: Bool = true, wanted: String = "") {
        self.id = id; self.kind = kind; self.title = title; self.shoot = shoot
        self.stage = stage; self.label = label; self.fraction = fraction; self.elapsed = elapsed
        self.remaining = remaining; self.remaining_text = remaining_text
        self.background = background; self.can_queue = can_queue; self.wanted = wanted
    }

    /// The one line under the title: where it has got to, and how long is
    /// left. Both halves are the engine's; this only joins them, and joins
    /// nothing when there is nothing to join.
    public var whereItHasGot: String {
        [label, remaining_text].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A refusal that came with a job attached, and the one the app raised
/// because it could not reach the engine at all.
///
/// Kept beside `RefusalBoard` rather than inside it: a board entry is a
/// sentence, and a sentence is all most refusals are. This is the exception,
/// and it is stored as what it is instead of being parsed back out of a string.
@MainActor @Observable
public final class BusyBoard {
    public private(set) var busy: [RefusalOwner: Busy] = [:]
    public init() {}

    public func set(_ owner: RefusalOwner, _ b: Busy) { busy[owner] = b }
    public func clear(_ owner: RefusalOwner) { busy[owner] = nil }
    public subscript(owner: RefusalOwner) -> Busy? { busy[owner] }
}
