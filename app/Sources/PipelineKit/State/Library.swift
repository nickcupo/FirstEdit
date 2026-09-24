import Foundation
import Observation

/// The library: every shoot, the memory cards, the extension's configuration
/// and the update line. One, for the life of the app.
@MainActor @Observable
public final class Library {
    public private(set) var shoots: [ShootRowOK] = []
    /// One damaged decisions file costs one row, never the list.
    public private(set) var broken: [ShootRowBroken] = []
    /// Both, in the engine's order, so a broken shoot sits where it belongs.
    public private(set) var rows: [ShootRow] = []
    public private(set) var cards: [String] = []
    public private(set) var ext: ExtConfig?
    public private(set) var ready = false
    public private(set) var update: UpdateInfo = .none
    /// False until the first answer: "no shoots" and "not asked yet" are not
    /// the same thing, and only one of them is an empty library.
    public private(set) var loaded = false
    public let refusals = RefusalBoard()

    public private(set) var client: StudioClient?
    public private(set) var pump: ImagePump?
    private var sessions: [String: ShootSession] = [:]

    public init(client: StudioClient? = nil, pump: ImagePump? = nil) {
        self.client = client
        self.pump = pump
    }

    /// For the snapshot harness and previews: a library that already has its
    /// answer and never asks the engine.
    public init(preview: ShootsResponse, client: StudioClient? = nil, pump: ImagePump? = nil) {
        self.client = client
        self.pump = pump
        take(preview)
    }

    /// After the engine starts or restarts, with a fresh key. Open sessions
    /// are let go: they hold the old client, and his verdicts are on disk.
    public func attach(client: StudioClient, pump: ImagePump) {
        self.client = client
        self.pump = pump
        sessions.removeAll()
    }

    public func detach() {
        client = nil
        pump = nil
        sessions.removeAll()
    }

    /// Read the list. `quietly` is for the reads nobody asked for — after an
    /// N, after a job — which used to put "offline" at the foot of the
    /// sidebar on one failed read until the next good one, and on a good one
    /// cleared a refused Eject or Show in Finder from the same place seconds
    /// after it was said. A quiet read keeps what the list already said on a
    /// failure and touches no sentence, unless the list has never been read,
    /// where its failure is the one thing All Shoots has to say.
    public func refresh(quietly: Bool = false) async {
        guard let client else { return }
        let speaks = !quietly || !loaded
        do {
            let r = try await client.get(Routes.shoots())
            take(r)
            if speaks { refusals.clear(.library) }
        } catch is CancellationError {
        } catch let e as StudioError {
            if speaks { refusals.set(.library, e.sentence) }
        } catch {
            if speaks { refusals.set(.library, Strings.API.offline) }
        }
    }

    private var refreshing = false
    private var refreshAgain = false

    /// Read the list again, at most one read at a time: a second ask while one
    /// is out becomes one more read after it, never a pile of them. For the
    /// moments the counts in the sidebar and the title may have moved — a job
    /// ended, or he has left a shoot's step — rather than on a timer.
    public func refreshSoon() async {
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            await refresh(quietly: true)
        } while refreshAgain
    }

    func take(_ r: ShootsResponse) {
        ShootNames.set(r.shoots.map(\.name))
        rows = r.shoots
        shoots = r.ok
        broken = r.broken
        cards = r.cards
        ext = r.ext
        // A session opened before the list — the shoot reopened at launch —
        // was named without the extension's labels.
        for s in sessions.values { s.rename(r.ext) }
        ready = r.ready
        update = r.update
        loaded = true
    }

    /// Shoots not yet marked finished, and those that are — the sidebar's two
    /// sections, in the engine's order.
    public var inProgress: [ShootRowOK] { shoots.filter { !$0.finished } }
    public var finished: [ShootRowOK] { shoots.filter(\.finished) }

    /// The engine has answered and there was nothing in it. Never true before
    /// the first answer: "no shoots" and "not asked yet" are different things
    /// and the sidebar says so.
    public var isEmpty: Bool { loaded && shoots.isEmpty && broken.isEmpty }

    public func row(named name: String) -> ShootRowOK? { shoots.first { $0.name == name } }

    /// The open session for a shoot, fetched once and kept.
    public func session(for name: String) async throws -> ShootSession {
        if let s = sessions[name] { return s }
        guard let client, let pump else { throw StudioError.engineDown }
        let r = try await client.get(Routes.shoot(name))
        if let s = sessions[name] { return s }
        let s = ShootSession(response: r, ext: ext, client: client, pump: pump)
        follow(s)
        sessions[name] = s
        return s
    }

    public func cachedSession(for name: String) -> ShootSession? { sessions[name] }

    /// For the harness: a session built from a fixture, with no engine behind it.
    public func adopt(_ s: ShootSession) { follow(s); sessions[s.name] = s }

    /// "Kept" beside "3 of 19 bursts" in the title and the sidebar: the
    /// bursts move with each N, so the list is read again with each N too,
    /// rather than holding "kept" still for the hours of Choose Keepers.
    private func follow(_ s: ShootSession) {
        s.onSeenChanged = { [weak self] in
            guard let self else { return }
            Task { await self.refreshSoon() }
        }
    }
}

extension UpdateInfo {
    /// Nothing known yet.
    public static let none: UpdateInfo = (try? UpdateInfo(fields: Fields([:])))!
}
