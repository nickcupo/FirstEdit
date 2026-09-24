import Foundation
import Observation

// MARK: - the values that get written

/// What his presses write. One place, as on the page it replaces.
///
/// K writes an *in*: the cull's own number when the cull already had it at 3
/// or above, otherwise 3 — so the effective star, the sidecar, the keeper
/// count and the selects file are byte-identical to what they were before the
/// press. D writes 2. Clearing the mark removes his override entirely, which
/// is not the same thing as writing 0.
public enum VerdictValue {
    public static let out = 2
    public static let inThreshold = 3

    public static func keep(_ row: Row) -> Int { row.rating >= inThreshold ? row.rating : inThreshold }
    public static let drop = out

    /// His verdict, read only from his field. Never falls back to the cull's.
    public static func his(_ row: Row) -> His {
        guard let o = row.override else { return .unmarked }
        return o >= inThreshold ? .kept : .out
    }

    public enum His: Sendable, Equatable { case kept, out, unmarked }
}

/// Why it is out. Six nameable faults, 1–6; the app's words map to the
/// engine's existing label strings. "Just no" is gone: a frame he simply does
/// not like is dropped with no reason (DESIGN.md §2.5.3).
public enum DropReason: String, CaseIterable, Sendable {
    case shadow = "shadow"
    case cutOff = "cut off"
    case face = "expression"
    case blur = "blur"
    case exposure = "exposure"
    case framing = "composition"

    /// 1–6, in the order of the keys.
    public var key: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
    public static func forKey(_ n: Int) -> DropReason? {
        (1...allCases.count).contains(n) ? allCases[n - 1] : nil
    }

    /// The word on screen. Never the engine's label where the two differ.
    public var word: String {
        switch self {
        case .shadow: return "shadow"
        case .cutOff: return "cut off"
        case .face: return "face"
        case .blur: return "blur"
        case .exposure: return "exposure"
        case .framing: return "framing"
        }
    }
}

// MARK: - the queue

/// One write of his to the engine.
public struct VerdictWrite: Sendable, Equatable {
    public let shoot: String
    public let file: String
    public let rating: Int?
    public init(shoot: String, file: String, rating: Int?) {
        self.shoot = shoot; self.file = file; self.rating = rating
    }
}

/// The native form of the page's `queueWrite`, for the same measured reasons
/// (DESIGN.md §7.2 and §7.12).
///
/// - Serialised **per frame**: two writes for one frame never overlap; writes
///   for different frames may.
/// - A write equal to the value already in flight or already committed for
///   that frame is **dropped** — a doubled press is one press counted twice.
/// - A different value is **queued behind** the one in flight and applied in
///   press order. Never debounced, never last-write-wins.
public actor VerdictQueue {
    public typealias Sender = @Sendable (VerdictWrite) async -> Result<RatingResult, StudioError>

    private let sender: Sender
    /// The value of the newest write accepted for each file — in flight,
    /// queued or committed. `.some(nil)` is "cleared".
    private var newest: [String: Int?] = [:]
    /// What the engine is known to hold, for putting `newest` back when the
    /// newest write is refused.
    private var committed: [String: Int?] = [:]
    private var tails: [String: Task<Result<RatingResult, StudioError>, Never>] = [:]

    public private(set) var sent = 0
    public private(set) var dropped = 0

    public init(sender: @escaping Sender) { self.sender = sender }

    public init(client: StudioClient) {
        self.sender = { w in
            do {
                return .success(try await client.post(Routes.rating,
                                                      RatingBody(name: w.shoot, file: w.file, rating: w.rating)))
            } catch let e as StudioError {
                return .failure(e)
            } catch {
                return .failure(.offline)
            }
        }
    }

    /// What the engine holds for a frame when the shoot is opened, so the first
    /// press that repeats it is recognised as a repeat.
    public func seed(file: String, value: Int?) {
        if newest[file] == nil { newest[file] = .some(value) }
        if committed[file] == nil { committed[file] = .some(value) }
    }

    /// `.success` with `dropped == true` in the outcome means nothing was sent.
    public func submit(_ w: VerdictWrite) async -> Result<RatingResult, StudioError> {
        if let n = newest[w.file], n == w.rating {
            dropped += 1
            return .success(RatingResult(ok: true, key_note: ""))
        }
        newest[w.file] = .some(w.rating)
        let before = tails[w.file]
        let send = sender
        let t = Task { () -> Result<RatingResult, StudioError> in
            _ = await before?.value
            return await send(w)
        }
        tails[w.file] = t
        sent += 1
        let r = await t.value
        switch r {
        case .success:
            committed[w.file] = .some(w.rating)
        case .failure:
            // Only the newest write decides what "newest" goes back to; an
            // older refused write behind a newer accepted one changes nothing.
            if let n = newest[w.file], n == w.rating, tails[w.file] == t {
                if let c = committed[w.file] {
                    newest[w.file] = .some(c)
                } else {
                    newest.removeValue(forKey: w.file)
                }
            }
        }
        if tails[w.file] == t { tails[w.file] = nil }
        return r
    }

    public func isIdle(_ file: String) -> Bool { tails[file] == nil }
}

// MARK: - the log behind undo

/// One undo step. Named for the thing it did: "Keep 04330".
public struct VerdictStep: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case keep, drop, clear, keepOnly([String]), reason(DropReason), finishBurst(burstID: String)
    }
    public let id: UUID
    public let kind: Kind
    public let stem: String
    public let file: String
    /// His override before and after. `nil` is unmarked.
    public let before: Int?
    public let after: Int?
    /// The label before, for a reason step.
    public let labelBefore: String?
    /// For Keep Only: every member's override before, so one step undoes all.
    public let others: [String: Int?]
    public let burstIndex: Int
    /// "Keep 04330" — the menu reads "Undo Keep 04330".
    public let name: String
    /// The step under this one that the same press made, taken back and put
    /// back with it: a burst finished by a verdict on its last frame joins
    /// that verdict, so one Q takes back the press — the mark and the
    /// burst's record together — and not the crossing alone (§2.5.5).
    public let joins: UUID?

    public init(kind: Kind, stem: String, file: String, before: Int?, after: Int?,
                labelBefore: String? = nil, others: [String: Int?] = [:], burstIndex: Int, name: String,
                joins: UUID? = nil) {
        self.id = UUID()
        self.kind = kind; self.stem = stem; self.file = file; self.before = before
        self.after = after; self.labelBefore = labelBefore; self.others = others
        self.burstIndex = burstIndex; self.name = name; self.joins = joins
    }
}

/// Undo, owned by the `ShootSession`.
///
/// One press, one step: consecutive verdicts are **never** coalesced — two
/// presses folded into one undo is exactly how a way back was lost before.
/// The one press that writes twice — a verdict on a burst's last frame, which
/// goes on and records the burst — pushes two entries, the second `joins` the
/// first, and undo and redo take them as one.
/// 200 deep, per shoot, not cleared by changing step. ⌘Z pops the newest
/// entry immediately, before its inverse write resolves, so two fast presses
/// undo two different decisions rather than racing each other.
@MainActor @Observable
public final class VerdictLog {
    public static let depth = 200

    public private(set) var steps: [VerdictStep] = []
    /// Steps he has taken back, newest last, for ⇧⌘Z (§2.5.5). A new step of
    /// his clears them, as in every Mac app: redo is only ever the way back
    /// out of an undo, never a replay over something he has done since.
    public private(set) var undone: [VerdictStep] = []

    public init() {}

    public var canUndo: Bool { !steps.isEmpty }
    /// "Keep 04330", for "Undo Keep 04330".
    public var undoName: String? { steps.last?.name }
    public var canRedo: Bool { !undone.isEmpty }
    /// "Keep 04330", for "Redo Keep 04330".
    public var redoName: String? { undone.last?.name }

    public func push(_ s: VerdictStep) {
        append(s)
        undone.removeAll()
    }

    private func append(_ s: VerdictStep) {
        steps.append(s)
        if steps.count > Self.depth { steps.removeFirst(steps.count - Self.depth) }
    }

    /// Takes the newest step off at once.
    public func pop() -> VerdictStep? { steps.popLast() }

    /// A step whose undo went through, kept for redo.
    public func keepUndone(_ s: VerdictStep) {
        undone.append(s)
        if undone.count > Self.depth { undone.removeFirst(undone.count - Self.depth) }
    }

    /// Takes the newest undone step off at once, as `pop()` does.
    public func popUndone() -> VerdictStep? { undone.popLast() }

    /// A step put back by redo. What is still taken back after it stays.
    public func pushRedone(_ s: VerdictStep) { append(s) }

    /// Its own entry, not whatever is on top. Two verdicts on two frames can
    /// be in the air at once; when the first is refused, the second's undo
    /// step must survive.
    @discardableResult
    public func remove(_ id: UUID) -> VerdictStep? {
        guard let i = steps.lastIndex(where: { $0.id == id }) else { return nil }
        return steps.remove(at: i)
    }

    /// For a step whose undo was itself refused: it goes back where it was,
    /// and nothing taken back before it is lost.
    public func restore(_ s: VerdictStep) {
        append(s)
    }
}

// MARK: - refusals, by owner

/// What is refused, and who said so. A refusal is only ever cleared by the
/// thing that wrote it, so the next unrelated success cannot wipe it
/// (DESIGN.md §7.7).
@MainActor @Observable
public final class RefusalBoard {
    public private(set) var messages: [RefusalOwner: String] = [:]
    /// Where each refusal was raised, when its owner says: for a verdict, the
    /// frame that was on screen. It changes nothing about who clears it; it
    /// lets the light table tell a refusal about the frame in front of him
    /// from one he has since walked away from (§2.5.2).
    public private(set) var places: [RefusalOwner: String] = [:]
    public init() {}

    public func set(_ owner: RefusalOwner, _ message: String, at place: String? = nil) {
        messages[owner] = message
        places[owner] = place
    }
    public func clear(_ owner: RefusalOwner) {
        messages[owner] = nil
        places[owner] = nil
    }
    public subscript(owner: RefusalOwner) -> String? { messages[owner] }
    /// Where the refusal standing for `owner` was raised, if it said.
    public func place(_ owner: RefusalOwner) -> String? { places[owner] }
}
