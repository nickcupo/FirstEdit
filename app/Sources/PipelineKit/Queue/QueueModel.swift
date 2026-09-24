import Foundation
import Observation
import AppKit

/// The list of work, as the app holds it. One, for the life of the app.
///
/// He asked for "a job queue so i can just tap all the jobs i need to happen",
/// and the shape of the evening is: home from a card with 1,500 frames, say
/// all of it in one pass — copy this card, cull it, write the presets, gather
/// the keepers, cut a reel, make the Instagram copies, push the RAWs — and
/// leave. So this is a place he fills, not a thing that happens to him.
///
/// Three rules it keeps.
///
/// 1. **Nothing is queued silently.** Every add is asked for: by a button
///    that says "Add to Up Next" rather than "Cull It", or by ⌥ on the
///    action, which always means add. A button that reads "Cull It" culls.
/// 2. **The engine owns the order.** Every change is a POST that answers with
///    the list as it is afterwards, and that answer replaces this one. A drag
///    that the engine refuses snaps back, because what is drawn is what the
///    engine has.
/// 3. **He is told once.** One notification when the list empties, naming
///    what was done and anything that was skipped — not one a job.
@MainActor @Observable
public final class QueueModel {
    public private(set) var state: QueueState = .empty
    /// The engine's refusal of an add, where the control that asked can print
    /// it. Never an alert: a list is not an emergency.
    public let refusals = RefusalBoard()
    /// Whether the last refusal was "never, and it never will be" rather than
    /// "not now". The two read differently beside a control.
    public private(set) var refusedForever = false

    // The poll's own bookkeeping is not something a screen draws, so it is
    // not observed. A step reads the list through `Queues.model(client:)`
    // from its body; observed, every one of these writes redrew the body
    // that made it, which wrote them again, for ever.
    @ObservationIgnored private var client: StudioClient?
    @ObservationIgnored private var poll: Task<Void, Never>?
    /// Whether a poll is alive, the same way `JobModel.isWatching` is.
    @ObservationIgnored public private(set) var isWatching = false
    @ObservationIgnored private var pollNumber = 0
    /// The job poll, which feeds the toolbar, the step's own progress, Stop
    /// (⌘.), the Dock and the lock that keeps the Mac awake. The engine starts
    /// the list's next piece of work by itself; when this poll is the one
    /// that sees it, that one is woken, or none of those five would know a
    /// cull he walked away from had begun (DESIGN.md §3.6).
    @ObservationIgnored weak var jobs: JobModel?
    /// The pass this session has already spoken about, so the poll can see
    /// "empty" twenty times and say it once.
    private var announced = 0
    /// The passes this app actually watched working, so one that finished
    /// while it was shut is not announced when it comes back.
    private var watched: Set<Int> = []
    /// Set by whoever owns notifications; called with the finished pass.
    public var finished: ((QueueState) -> Void)?

    /// Injected so the poll can be tested without an app being frontmost.
    var isFrontmost: @MainActor () -> Bool = { NSApp?.isActive ?? true }

    public static let busyInterval: Duration = .milliseconds(1500)
    public static let idleInterval: Duration = .seconds(5)
    /// Two adds of the same work closer together than this are one click
    /// that bounced, not two requests.
    static let doubleClick: Duration = .seconds(1)
    /// Test the click interval independently of a busy runner's scheduling.
    @ObservationIgnored var nowForAdds: @MainActor () -> ContinuousClock.Instant = { .now }
    @ObservationIgnored private var adding: Set<String> = []
    @ObservationIgnored private var lastAdded: (key: String, at: ContinuousClock.Instant, item: QueueItem)?

    public init(client: StudioClient? = nil) { self.client = client }

    /// Another engine, or none. The same one again is nothing: a screen
    /// that reaches the list from its body attaches it on every redraw, and
    /// that cancelled the list's poll each time.
    public func attach(_ client: StudioClient?) {
        guard client !== self.client else { return }
        self.client = client
        cancelWatching()
    }

    /// The job poll and this one, made to wake each other. Each starts the
    /// other when it sees work running that the other may not be watching;
    /// neither restarts one that is already alive.
    public func pair(with jobs: JobModel) {
        self.jobs = jobs
        jobs.list = self
    }

    // MARK: - what the screens read

    public var waiting: [QueueItem] { state.waiting }
    public var count: Int { state.waiting.count }
    public var isHeld: Bool { state.held }
    /// Whether pressing a step's action now would start it or add it. The
    /// button says which, and this is what it asks.
    public var wouldWait: Bool { state.held || (state.running && !state.background) }

    // MARK: - filling it

    /// Put one piece of work on the list.
    ///
    /// `options` are the same names the route that does this one thing now
    /// reads off a body — the engine builds the command from them when the
    /// turn comes, not when the tap happens, so a shoot that changes in
    /// between changes what runs.
    @discardableResult
    public func add(kind: String, shoot: String, options: [String: JSONValue] = [:],
                    owner: RefusalOwner = .job) async -> QueueItem? {
        guard let client else { return nil }
        // A double-click on "Add to Up Next" is one add. The engine
        // takes two identical culls if it is asked twice, and it was: the
        // second click lands while the first is on its way or a moment after.
        let key = "\(kind)|\(shoot)|\(options.sorted { $0.key < $1.key })"
        if adding.contains(key) { return nil }
        if let last = lastAdded, last.key == key, nowForAdds() - last.at < Self.doubleClick {
            return last.item
        }
        adding.insert(key)
        defer { adding.remove(key) }
        do {
            let r = try await client.post(QueueRoutes.add,
                                          QueueAddBody(kind: kind, name: shoot, options: options))
            if let list = r.list { adopt(list) }
            if let e = r.error, !e.isEmpty {
                // The engine's sentence, as it wrote it. The app adds nothing
                // to it: what may not be left on a list, and why, is the
                // engine's to say once and both sides print the same words.
                refusedForever = r.queueable == false
                refusals.set(owner, e)
                return nil
            }
            refusals.clear(owner)
            refusedForever = false
            if let item = r.added { lastAdded = (key, nowForAdds(), item) }
            watch()
            return r.added
        } catch let e as StudioError {
            refusals.set(owner, e.sentence)
        } catch {
            refusals.set(owner, Strings.API.offline)
        }
        return nil
    }

    public func clearRefusal(_ owner: RefusalOwner = .job) {
        refusals.clear(owner)
        refusedForever = false
    }

    /// He left the page whose add was refused; see `JobModel.leftThePage`.
    public func leftThePage() { clearRefusal(.job) }

    // MARK: - ordering it

    /// His order. What is sent is every waiting id in the order he dragged
    /// them into, and what is drawn afterwards is the engine's answer — so a
    /// drag the engine cannot honour snaps back rather than lying.
    public func reorder(_ ids: [Int]) async {
        await change { try await $0.post(QueueRoutes.order, QueueOrderBody(ids)) }
    }

    /// Move one item, by the offsets a SwiftUI `List` hands back.
    public func move(from source: IndexSet, to destination: Int) async {
        var ids = state.waiting.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        await reorder(ids)
    }

    public func remove(_ id: Int) async {
        await change { try await $0.post(QueueRoutes.remove, QueueIDBody(id)) }
    }

    public func clear() async {
        await change { try await $0.post(QueueRoutes.clear, EmptyBody()) }
    }

    /// Hold the list, or let it go. Holding stops the NEXT one starting; what
    /// is running is work already under way and is not touched by it.
    public func hold(_ held: Bool) async {
        await change { try await $0.post(QueueRoutes.hold, QueueHoldBody(held)) }
    }

    /// A change he made to the list itself - an order, a removal, Hold. Its
    /// refusal is the list's own (`.list`), printed over the list in the
    /// Activity window where he made it, and never under a step's button:
    /// a refused drag used to appear in red on every step page.
    private func change(_ run: (StudioClient) async throws -> QueueChanged) async {
        guard let client else { return }
        do {
            let r = try await run(client)
            if let list = r.list { adopt(list) }
            if let e = r.error, !e.isEmpty { refusals.set(.list, e) } else { refusals.clear(.list) }
        } catch let e as StudioError {
            refusals.set(.list, e.sentence)
        } catch is CancellationError {
            return
        } catch {
            refusals.set(.list, Strings.API.offline)
        }
        watch()
    }

    // MARK: - keeping up with it

    /// Ask once now, and keep asking while there is something to see.
    ///
    /// It is a slow poll on purpose. The bar for the job that is running is
    /// `JobModel`'s and moves at 1.2 s; this is the list, and a list changes
    /// when a job ends or when he touches it, neither of which needs a
    /// reading a second.
    public func watch() {
        guard client != nil else { return }
        poll?.cancel()
        pollNumber += 1
        let n = pollNumber
        isWatching = true
        poll = Task { [weak self] in
            await self?.runPoll()
            self?.pollEnded(n)
        }
    }

    /// Start watching unless a poll is already alive; see
    /// `JobModel.keepWatching` for why it must not restart one.
    public func keepWatching() {
        guard !isWatching else { return }
        watch()
    }

    public func cancelWatching() {
        poll?.cancel()
        poll = nil
        pollNumber += 1
        isWatching = false
    }

    private func pollEnded(_ n: Int) {
        guard n == pollNumber else { return }
        poll = nil
        isWatching = false
    }

    /// The list as a POST answered it. What the engine did with the add, or
    /// with Continue, can be to start something at once.
    private func adopt(_ s: QueueState) {
        state = s
        if s.running { jobs?.keepWatching() }
    }

    private func runPoll() async {
        while !Task.isCancelled {
            guard let client else { return }
            do {
                take(try await client.get(QueueRoutes.state()))
            } catch is CancellationError {
                return
            } catch {
                // The engine is down or restarting; EngineHost says so. This
                // stops rather than hammering a dead port.
                return
            }
            if state.isFinished && !state.running { return }
            let wait = isFrontmost() ? Self.busyInterval : Self.idleInterval
            try? await Task.sleep(for: wait)
        }
    }

    /// Take one reading. Public so a test and the snapshot harness can put a
    /// filled list in front of a window without an engine behind it.
    public func take(_ s: QueueState) {
        state = s
        if s.running { jobs?.keepWatching() }
        // A pass is only worth speaking about if this app watched it working.
        // Launching into a list that finished overnight is not an
        // interruption, it is history, and history belongs in the window.
        if !s.isFinished { watched.insert(s.pass) }
        // The one notification, at the end, naming what was done and anything
        // that was skipped. Not one a job: he stacked four things up so that
        // he would not have to be told four times.
        guard s.pass > 0, s.pass != announced, watched.contains(s.pass) else { return }
        guard s.isFinished, !s.done.isEmpty || !s.skipped.isEmpty else { return }
        announced = s.pass
        finished?(s)
    }

    /// For tests and for a fresh launch: forget what was already said.
    public func forgetWhatWasSaid() { announced = 0; watched.removeAll() }
}

extension RefusalOwner {
    /// The list's own controls, in the Activity window.
    public static let list = RefusalOwner("list")
}
