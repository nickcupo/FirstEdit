import Foundation

/// Prefetch for the second window, which must never get in front of the first.
///
/// `DESIGN.md` §3.5's rule is "at most 2 concurrent cold `/full` requests". With
/// two windows it becomes: **at most 2 in total, of which at most 1 may be the
/// picture window's** (§4.7). Otherwise a pair of 4096 px decodes on the far
/// screen can sit in front of the one frame he is about to press a key on —
/// the exact stall PERF-01 measured at 650–720 ms.
///
/// `ImagePump` does not carry a consumer yet, so the rule is kept here, by
/// this side never having more than one request of its own in the air. The day
/// `prefetch(_:for:priority:)` lands, `ConsumerPicturePrefetch` is the whole of
/// the change and `PicturePrefetcher.strategy` is the one line that picks it.
@MainActor
public protocol PicturePrefetching: AnyObject {
    func want(shoot: String, stems: [String], pixels: Int)
    func cancelAll()
}

@MainActor
public final class PicturePrefetcher: PicturePrefetching {
    /// Flip to `.consumer` the day `ImagePump` carries a `Consumer`.
    public enum Strategy: Sendable { case oneAtATime, consumer }
    public static let strategy: Strategy = .oneAtATime

    private let pump: ImagePump
    private var running: Task<Void, Never>?
    private var queued: [ImagePump.Key] = []
    /// Counted for the bench and for the test that asserts this side never has
    /// two cold requests in the air at once.
    public private(set) var peakInFlight = 0
    public private(set) var inFlight = 0

    public init(pump: ImagePump) { self.pump = pump }

    /// The frame he is on and one in each direction, at this window's own
    /// size. Issued after the stage's, always.
    public func want(shoot: String, stems: [String], pixels: Int) {
        let keys = stems.map { ImagePump.Key(shoot: shoot, stem: $0, tier: .full(px: pixels)) }
        guard keys != queued else { return }
        queued = keys
        running?.cancel()
        let pump = self.pump
        switch Self.strategy {
        case .consumer:
            running = Task { [weak self] in
                // One line, once `ImagePump.Consumer` exists:
                //   await pump.prefetch(keys, for: .picture, priority: .utility)
                await pump.prefetch(keys, priority: .utility)
                self?.inFlight = 0
            }
        case .oneAtATime:
            running = Task { [weak self] in
                for key in keys {
                    if Task.isCancelled { return }
                    self?.enter()
                    _ = try? await pump.image(key, priority: .utility)
                    self?.leave()
                }
            }
        }
    }

    /// The big requests in flight go at once, so they cannot queue ahead of
    /// the laptop's next frame. Only this side's: cancelling the pump's whole
    /// prefetch set would take the stage's with it, which is the opposite of
    /// the rule.
    ///
    /// One line, once `ImagePump.Consumer` exists:
    ///   `await pump.cancelPrefetch(for: .picture)`
    public func cancelAll() {
        running?.cancel()
        running = nil
        queued = []
        inFlight = 0
    }

    private func enter() {
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
    }

    private func leave() {
        inFlight = max(0, inFlight - 1)
    }
}
