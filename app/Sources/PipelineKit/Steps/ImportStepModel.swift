import Foundation
import Observation
import AppKit

/// Copy the Card, for as long as the app is open (DESIGN.md §2.6).
///
/// The card page used to keep all of this itself, and a page's state goes
/// when the page does. Its watcher was started when the page appeared, and
/// the page is only reachable with a card in, so a card put in while he was
/// in Choose Keepers or All Shoots was never noticed: no Memory Card row, a
/// greyed ⌘N, and nothing until some unrelated read of the library happened
/// to see it. One of these belongs to the app, and watches for as long as it
/// is open.
///
/// It also holds the copy he started, from the press to its end, and how it
/// ended. A copy takes five minutes or more and he goes off to finish last
/// night's keepers while it runs: the "Eject after copying" he ticked, the
/// sentence that says how it went, and the lock on the form that stops a
/// second copy of the same card all have to outlive the page.
@MainActor @Observable
public final class ImportModel {
    /// Set by `AppModel`, which owns this for the life of the app.
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var watcher: CardWatcher?

    /// Where his habits are kept. A test hands in a scratch one.
    @ObservationIgnored var settings: SettingsStore = .shared
    /// Ejects a card, off the main thread. A test replaces it, so no test
    /// ever unmounts a volume on the Mac it runs on.
    @ObservationIgnored var ejectCard: @MainActor (String) async -> String? = { path in
        await CardWatcher.ejectOffTheMainThread(path)
    }
    /// Starts a copy now, and answers the engine's number for it, or `nil`
    /// when it was refused (the refusal is already on the job's board).
    @ObservationIgnored var startNow: @MainActor (IngestBody) async -> Int? = { _ in nil }
    /// Puts a copy on his list, and answers its number, or `nil` when it
    /// was refused (the job's board says why).
    @ObservationIgnored var putOnTheList: @MainActor (IngestBody) async -> Int? = { _ in nil }
    /// Stops the running job with this number, and only that one.
    @ObservationIgnored var stopJob: @MainActor (Int?) async -> Void = { _ in }
    /// Reads a card. A test counts the reads.
    @ObservationIgnored var readCard: @Sendable (String) -> CardScan? = { CardScan.read($0) }

    public init() {
        startNow = { [weak self] body in await self?.post(body) }
        putOnTheList = { [weak self] body in await self?.list(body) }
        stopJob = { [weak self] id in await self?.app?.jobs.stop(id: id) }
    }

    func attach(_ app: AppModel) { self.app = app }

    // MARK: - the copy he started, and how it ended

    /// A copy he asked for, from the press until it ends.
    public struct Copy: Equatable, Sendable {
        public let card: String
        public let shoot: String
        public let verify: String
        /// The extension's kind it was sent with, or `nil` for his own kind:
        /// the form shows this copy's answer while it runs, not the page's
        /// starting one.
        public let kind: String?
        /// The engine's number for it: from the answer to the press, or the
        /// list's. 0 until then, and on an engine that does not number jobs.
        public var id: Int
        /// On his list behind other work of his, rather than running.
        public var listed: Bool
        /// The card came out while it was still going.
        public var cardCameOut = false
        /// Its job has been seen running. A copy on the list has not, and
        /// other work in the engine's one slot is only news once it has.
        public var began = false
        /// The engine's slot was seen holding something else, or nothing:
        /// its end was missed, and the shoot's own note is being read.
        var lost = false

        public init(card: String, shoot: String, verify: String, kind: String? = nil,
                    id: Int = 0, listed: Bool = false) {
            self.card = card; self.shoot = shoot; self.verify = verify; self.kind = kind
            self.id = id; self.listed = listed
        }

        /// Whether the engine's job is this copy. By number where there is
        /// one, and by the shoot's name otherwise — a new shoot's name is
        /// not one any other copy can have.
        func matches(_ job: Job) -> Bool {
            guard job.kind == "ingest" else { return false }
            if id > 0, job.id > 0 { return job.id == id }
            return job.shoot == shoot
        }
    }

    /// How a copy ended. Kept until another card goes in at the same place,
    /// or he starts another copy of this one.
    public struct Ending: Equatable, Sendable {
        public let card: String
        public let shoot: String
        public let verify: String
        public let outcome: Job.Outcome
        /// The engine's own last sentence, when it wrote one rather than a
        /// traceback — "not enough room for …".
        public let sentence: String?
        public let cardCameOut: Bool
        public var eject: Eject
        /// Which ended last, for the page with no card to show.
        let order: Int
        /// The app did not see it end: the engine restarted under it, or it
        /// ended between two reads and other work took the slot. How it
        /// went is the shoot's own note's to say, read afresh each time.
        public var unseen = false
        /// What it did not see was the engine restarting.
        public var engineRestarted = false

        public var copied: Bool { outcome == .done }

        /// Whether it finished, by the shoot's own note where the app did
        /// not see the end: a copy the engine left running when it
        /// restarted goes on to the end by itself, and says so in its log.
        public func copied(row: ShootRowOK?) -> Bool {
            copied || (unseen && row?.ingest.isDone == true)
        }
    }

    public enum Eject: Equatable, Sendable {
        case notAsked
        case going
        case done
        case failed(String)
    }

    /// By card, because two cards can be in at once and one can copy while
    /// the other waits its turn.
    public private(set) var copies: [String: Copy] = [:]
    public private(set) var endings: [String: Ending] = [:]
    /// How many times a card has gone in at each place. Every card his
    /// camera formats mounts as /Volumes/Untitled, so the place alone cannot
    /// tell tonight's card from last night's: the page is fresh for each one.
    public private(set) var generation: [String: Int] = [:]
    /// What is on each card, read once per card rather than on every visit,
    /// so the button does not start as "Copy the Card" every time he looks.
    public private(set) var scans: [String: CardScan] = [:]
    /// "Copy the Card is on the list." after a copy went on it.
    public private(set) var listedNote: String?
    @ObservationIgnored private var endingsSoFar = 0
    @ObservationIgnored private var scanning: [String: Scanning] = [:]
    /// The generation of the card each place last read, found or not.
    private var readAt: [String: Int] = [:]

    /// "Eject after copying", which is his habit and not a card's. Read when
    /// a copy ends, not when it starts, so a change of mind while it runs
    /// counts.
    public var ejectAfter: Bool {
        get { access(keyPath: \.ejectAfter); return settings.ejectAfterCopying }
        set { withMutation(keyPath: \.ejectAfter) { settings.ejectAfterCopying = newValue } }
    }

    /// The card the card page is about. The sidebar's row when one is chosen
    /// — the picker on the page writes the same selection, so the two are
    /// one choice — then the first card that is in, then, with none in, the
    /// copy still going or the one that ended last, so a card pulled mid-copy
    /// or ejected after it does not take its sentence with it.
    public func volume(for selection: SidebarSelection?, cards: [String]) -> String {
        if case .card(let v) = selection, !v.isEmpty,
           cards.contains(v) || copies[v] != nil || endings[v] != nil {
            return v
        }
        if let first = cards.first { return first }
        if let going = copies.keys.sorted().first { return going }
        return endings.values.max { $0.order < $1.order }?.card ?? ""
    }

    /// The copy of this card that is under way or waiting its turn.
    public func copy(for card: String) -> Copy? {
        if let c = copies[card] { return c }
        // The snapshot harness shows a running copy by handing the steps a
        // job, the way it does for every other step.
        if let p = StepJobs.previewJob, p.running, p.kind == "ingest", !card.isEmpty {
            return Copy(card: card, shoot: p.shoot, verify: "in-flight", id: p.id)
        }
        return nil
    }

    /// The engine's job for this card's copy, while it runs.
    public func job(for card: String) -> Job? {
        if let p = StepJobs.previewJob { return p.running && p.kind == "ingest" && copy(for: card) != nil ? p : nil }
        guard let copy = copies[card], let j = app?.jobs.job, j.running, copy.matches(j) else { return nil }
        return j
    }

    /// The list went on without a copy he left on it: its card was not in
    /// when its turn came. The engine's sentence is the ending.
    func listChanged(_ state: QueueState) {
        for (card, copy) in copies where copy.listed && copy.id > 0 {
            guard let skipped = state.skipped.first(where: { $0.id == copy.id }) else { continue }
            copies[card] = nil
            listedNote = nil
            endingsSoFar += 1
            endings[card] = Ending(card: card, shoot: copy.shoot, verify: copy.verify, outcome: .refused,
                                   sentence: skipped.whyNot.isEmpty ? nil : skipped.whyNot,
                                   cardCameOut: !(app?.library.cards.contains(card) ?? false),
                                   eject: .notAsked, order: endingsSoFar)
        }
    }

    /// Something of his is running, so a copy asked for now goes on the list
    /// behind it rather than waiting inside a page he may leave.
    public var wouldWait: Bool {
        if Queues.wouldWait { return true }
        guard let j = app?.jobs.job else { return false }
        return j.running && !j.background
    }

    /// Copy this card into a new shoot, or `into` the shoot of that name that
    /// already exists — to finish a copy that stopped, or to add a second
    /// card to it before it is culled: now, or on his list when something of
    /// his is running. The engine checks the card is still in when the turn
    /// comes and says so on the list if it has gone. Either way the copy asks
    /// to be followed by the cull (`IngestBody.then_cull`).
    public func start(card: String, name: String, verify: String, kind: String?, addToTheList: Bool,
                      into: Bool = false) async {
        guard copies[card] == nil else { return }
        endings[card] = nil
        listedNote = nil
        if notice?.card == card { unsay() }
        copies[card] = Copy(card: card, shoot: name, verify: verify, kind: kind, listed: addToTheList)
        let into: Bool? = into ? true : nil
        if addToTheList {
            let body = IngestBody(card: card, name: name, kind: kind, verify: verify, queue: true, into: into)
            guard let id = await putOnTheList(body) else { copies[card] = nil; return }
            copies[card]?.id = id
            listedNote = Strings.Queue.added(Strings.Queue.what("ingest") ?? Strings.Import.title)
        } else {
            guard let id = await startNow(IngestBody(card: card, name: name, kind: kind, verify: verify,
                                                     into: into)) else {
                copies[card] = nil
                return
            }
            copies[card]?.id = id
        }
    }

    /// Takes a copy that is waiting its turn back off the list.
    public func takeOffTheList(_ card: String) async {
        guard let copy = copies[card], copy.listed else { return }
        if copy.id > 0 { await Queues.model(client: app?.client).remove(copy.id) }
        copies[card] = nil
        listedNote = nil
    }

    /// Stops this card's copy, and nothing else of his. Only while the
    /// engine says it is running, and by its number: the engine's stop
    /// without one stops whatever is running, which after a copy it lost
    /// sight of could be his cull.
    public func stop(_ card: String) async {
        guard let j = job(for: card) else { return }
        await stopJob(j.id > 0 ? j.id : nil)
    }

    /// Told by `AppModel` whenever a job ends, on whatever page he is on.
    func jobEnded(_ job: Job) {
        // A job the list overtook between two reads is told as ended with
        // the last reading the app had of it, which still says running: how
        // it ended was not seen, and a copy's own log says (`lostSight`, told
        // by `jobSeen` on the same read). Ended as that reading, a copy that
        // finished was put down as neither done nor ejected.
        guard !job.running else { return }
        guard let (card, copy) = copies.first(where: { $0.value.matches(job) }) else { return }
        end(card, copy, outcome: job.outcome, sentence: job.outcome == .refused ? job.refusalSentence : nil)
    }

    /// Told by `AppModel` on every answer about the engine's one slot,
    /// including a fresh engine's, which names no job at all.
    ///
    /// A copy's end is told by `jobEnded`, which needs the engine to say
    /// that job ended. After an engine restart it never does, and a copy
    /// that ended between two reads while the list started the next thing
    /// is never seen ending either: the page said "Copying…" for the rest
    /// of the evening, and its Stop stopped whatever ran next. So a copy
    /// that is running — pressed now, or off the list once its turn came —
    /// is over the moment the slot holds anything else.
    func jobSeen(_ job: Job) {
        for (card, copy) in copies where copy.id > 0 && !copy.lost {
            if copy.matches(job) {
                if job.running, !copy.began { copies[card]?.began = true }
                continue
            }
            guard !copy.listed || copy.began else { continue }
            lostSight(of: card, engineRestarted: false)
        }
    }

    /// The engine was restarted. It knows nothing of a copy the last one
    /// was running; one still waiting on his list is still on it, because
    /// the list is kept on disk.
    func engineRestarted() {
        for (card, copy) in copies where !copy.listed || copy.began {
            lostSight(of: card, engineRestarted: true)
        }
    }

    /// A copy whose end was missed. The page keeps its bar, without a Stop,
    /// while the library is read; then the shoot's own note says how far it
    /// got — its log is the copy's proof, not the app's guess.
    private func lostSight(of card: String, engineRestarted: Bool) {
        guard let copy = copies[card], !copy.lost else { return }
        copies[card]?.lost = true
        Task {
            await self.app?.library.refresh(quietly: true)
            // It may have been told ending in the meantime.
            guard let copy = self.copies[card], copy.lost else { return }
            let done = self.app?.library.row(named: copy.shoot)?.ingest.isDone == true
            self.end(card, copy, outcome: done ? .done : .failed, sentence: nil,
                     unseen: true, engineRestarted: engineRestarted)
        }
    }

    private func end(_ card: String, _ copy: Copy, outcome: Job.Outcome, sentence: String?,
                     unseen: Bool = false, engineRestarted: Bool = false) {
        copies[card] = nil
        if listedNote != nil { listedNote = nil }
        let stillIn = app?.library.cards.contains(card) ?? false
        let eject = outcome == .done && ejectAfter && stillIn
        endingsSoFar += 1
        endings[card] = Ending(card: card, shoot: copy.shoot, verify: copy.verify, outcome: outcome,
                               sentence: sentence, cardCameOut: copy.cardCameOut || !stillIn,
                               eject: eject ? .going : .notAsked, order: endingsSoFar,
                               unseen: unseen, engineRestarted: engineRestarted)
        Task { await self.finish(card, eject: eject) }
    }

    /// The card page after a copy into this shoot, for a notification about
    /// it: the page of the card it copied, while this session remembers the
    /// copy.
    public func card(copiedInto shoot: String) -> String? {
        endings.values.filter { $0.shoot == shoot }.max { $0.order < $1.order }?.card
    }

    /// After a copy: read the library so the new shoot and its copy's own
    /// sentence are there, take the card out if he asked, and say how it
    /// went at the top of the window when he is somewhere else.
    private func finish(_ card: String, eject: Bool) async {
        await app?.library.refresh(quietly: true)
        if eject {
            let why = await ejectCard(card)
            endings[card]?.eject = why.map(Eject.failed) ?? .done
            await app?.library.refresh(quietly: true)
        }
        guard let ending = endings[card], let app else { return }
        if case .card = app.navigation.selection,
           volume(for: app.navigation.selection, cards: app.library.cards) == card { return }
        say(Self.headline(ending, row: app.library.row(named: ending.shoot)), about: card)
    }

    /// One line for the top of the window: the shoot, the copy's own
    /// sentence, and what happened to the card.
    static func headline(_ ending: Ending, row: ShootRowOK?) -> String {
        var line: String
        if let row, row.ingest.isRecorded,
           let (sentence, _) = IngestNoteView.sentence(row.ingest, frames: row.frames, verify: row.verify) {
            line = Strings.Import.about(ending.shoot, sentence)
        } else if let s = ending.sentence {
            line = Strings.Import.about(ending.shoot, s)
        } else {
            line = ending.copied ? Strings.Import.copiedInto(ending.shoot) : Strings.Import.didNotFinish(ending.shoot)
        }
        switch ending.eject {
        case .done: line += " " + Strings.Import.ejected
        case .failed(let why): line += " " + Strings.Import.ejectFailed(why)
        case .notAsked, .going: break
        }
        return line
    }

    // MARK: - what is on the card

    /// Reads the card once, off the main thread: how many photographs, the
    /// day its last evening started, and whether a shoot already holds them.
    ///
    /// Started the moment a card goes in, not when he reaches its page, so
    /// the day is usually known before he has pressed ⌘N: read on arrival,
    /// a quick ⌘N and "-night" on a 1,558-frame card beat it, and the shoot
    /// got the Mac's date. The page asking again waits for the read already
    /// out rather than starting a second one, and returns once it is done.
    public func scan(_ card: String) async {
        guard !card.isEmpty, app != nil else { return }
        let gen = generation[card, default: 0]
        guard scans[card] == nil, readAt[card] != gen else { return }
        if let going = scanning[card], going.generation == gen {
            await going.task.value
            return
        }
        // Everything the read changes is changed inside the task, so one
        // who waits on it finds the answer there when it returns.
        let task = Task { [weak self] () -> Void in await self?.read(card, generation: gen) }
        scanning[card] = Scanning(generation: gen, task: task)
        await task.value
    }

    /// Whether the card in at this place has been read, whatever it held.
    public func hasRead(_ card: String) -> Bool { readAt[card] == generation[card, default: 0] }

    private func read(_ card: String, generation gen: Int) async {
        let shoots = app?.library.shoots.map { (name: $0.name, raw: $0.raw) } ?? []
        let readCard = readCard
        let found = await Task.detached(priority: .userInitiated) { () -> CardScan? in
            guard var s = readCard(card) else { return nil }
            if let newest = s.newest { s.copiedAs = CardScan.copiedAs(newest, shoots: shoots) }
            return s
        }.value
        var scan = found
        if scan != nil, let client = app?.client,
           let c = try? await client.get(Routes.cards()).described.first(where: { $0.path == card }) {
            scan?.contents = c
        }
        if scanning[card]?.generation == gen { scanning[card] = nil }
        // A card that went out and came back while this read is not the
        // card it read.
        guard generation[card, default: 0] == gen else { return }
        readAt[card] = gen
        if let scan { scans[card] = scan }
    }

    private struct Scanning {
        let generation: Int
        let task: Task<Void, Never>
    }

    /// For the snapshot harness: what a card holds, without a card.
    public func preview(scan: CardScan, for card: String) { scans[card] = scan }

    /// For the snapshot harness: a copy under way, or one that has ended.
    public func preview(copy: Copy) { copies[copy.card] = copy }
    public func preview(ending outcome: Job.Outcome, card: String, shoot: String, verify: String = "in-flight",
                        sentence: String? = nil, cardCameOut: Bool = false, eject: Eject = .notAsked,
                        engineRestarted: Bool = false) {
        endingsSoFar += 1
        endings[card] = Ending(card: card, shoot: shoot, verify: verify, outcome: outcome, sentence: sentence,
                               cardCameOut: cardCameOut, eject: eject, order: endingsSoFar,
                               unseen: engineRestarted, engineRestarted: engineRestarted)
    }

    /// For the snapshot harness: the line at the top of the window.
    public func preview(notice line: String, card: String) {
        notice = Notice(line: line, card: card)
    }

    // MARK: - noticing the card

    /// Start noticing cards. Once, when the app launches, and never in the
    /// snapshot harness, which must not answer to what is plugged into the
    /// Mac it runs on.
    public func watch() {
        guard watcher == nil else { return }
        let w = CardWatcher { [weak self] change in await self?.cardsChanged(change) }
        w.start()
        watcher = w
    }

    public var isWatching: Bool { watcher?.isWatching ?? false }

    /// A volume came or went: read the list again at once, so the Memory
    /// Card row, ⌘N and the card page all see it. A direct read rather than
    /// `refreshSoon`, which returns without waiting when a read is already
    /// out, and what follows needs the answer.
    func cardsChanged(_ change: CardWatcher.Change) async {
        guard let app else { return }
        switch change {
        case .mounted(let path):
            // Whatever was known about the card that was last in here is
            // about that card, not this one — except a copy of it that did
            // not finish. The page told him to put the card back in, and
            // back in, it says what reached that shoot and that copying it
            // again needs a new name, rather than a fresh form whose same
            // name is then refused in red.
            if let path {
                generation[path, default: 0] += 1
                if let e = endings[path], e.copied(row: app.library.row(named: e.shoot)) { endings[path] = nil }
                scans[path] = nil
            }
        case .unmounted(let path):
            if let path {
                scans[path] = nil
                // Running, or waiting its turn: either way this copy is
                // not going to get the rest of this card.
                if copies[path] != nil { copies[path]?.cardCameOut = true }
            }
        }
        await app.library.refresh(quietly: true)
        switch change {
        case .mounted(let path):
            guard let path, app.library.cards.contains(path) else { return }
            cardWentIn(path)
        case .unmounted(let path):
            if let path, let n = notice, n.card == path, n.line == Strings.Import.cardIsIn(CardWatcher.volumeName(path)) {
                unsay()
            }
        }
    }

    /// A card went in. It is read at once, whatever page he is on. On the
    /// card page it is the card the page is about — unless that page is
    /// watching a copy, which stays in front of him. With the sidebar
    /// showing, its Memory Card row is the news. With it hidden — the light
    /// table below 1280 pt hides it — the row is out of sight, so a line at
    /// the top of the window says so, and ⌘N is the way there. Nothing moves
    /// him off any other page: whether a card should take him to its page is
    /// his to say.
    func cardWentIn(_ path: String) {
        guard let app else { return }
        Task { await self.scan(path) }
        if case .card = app.navigation.selection {
            let showing = volume(for: app.navigation.selection, cards: app.library.cards)
            if copies[showing] == nil { app.navigation.selection = .card(path) }
            return
        }
        guard !app.navigation.sidebarShown else { return }
        say(Strings.Import.cardIsIn(CardWatcher.volumeName(path)), about: path)
    }

    // MARK: - the line at the top of the window

    /// A line about a card, drawn over the top of the window rather than
    /// above it: the window's banner is a safe-area inset, and a line there
    /// shrank and lowered the photograph in Choose Keepers the moment a card
    /// went in, while he was pressing K and D, and held it there until he
    /// clicked. This one moves nothing. It goes by itself after a few
    /// seconds, or when he goes anywhere, and clicking it opens the card's
    /// page.
    public struct Notice: Equatable, Sendable {
        public let line: String
        /// The card it is about; clicking the line opens its page.
        public let card: String
    }

    public private(set) var notice: Notice?
    @ObservationIgnored private var noticeGoes: Task<Void, Never>?
    /// How long a line stays. A test shortens it.
    @ObservationIgnored var noticeLasts: Duration = .seconds(8)

    /// He is on the card page: a line telling him to go there, or telling
    /// him what happened there, is spent.
    func arrived() {
        if notice != nil { unsay() }
    }

    /// He went somewhere: a line about the page he was on is spent.
    public func navigated() {
        if notice != nil { unsay() }
    }

    /// He clicked the line: the card's page, which is what it was about.
    public func openNotice() {
        guard let n = notice, let app else { return }
        unsay()
        app.navigation.selection = .card(n.card)
    }

    private func say(_ line: String, about card: String) {
        notice = Notice(line: line, card: card)
        noticeGoes?.cancel()
        let lasts = noticeLasts
        noticeGoes = Task { [weak self] in
            try? await Task.sleep(for: lasts)
            guard !Task.isCancelled, let self, self.notice?.line == line else { return }
            self.notice = nil
        }
    }

    private func unsay() {
        noticeGoes?.cancel()
        noticeGoes = nil
        notice = nil
    }

    // MARK: - the engine

    /// POST /api/ingest. A refusal lands on the job's board, where the page
    /// shows it beside the button.
    private func post(_ body: IngestBody) async -> Int? {
        guard let app else { return nil }
        let client = app.client
        let answer = Answer()
        await app.jobs.start {
            guard let client else { throw StudioError.engineDown }
            let r = try await client.post(Routes.ingest, body)
            if let e = r.error, !r.ok { throw StudioError.refused(e) }
            answer.id = max(r.id, 0)
        }
        return answer.id
    }

    /// The same route with `queue`, which puts the copy on his list; the
    /// engine builds it again when its turn comes and looks for the card
    /// first. The list is read again at once so it shows there.
    private func list(_ body: IngestBody) async -> Int? {
        guard let id = await post(body) else { return nil }
        Queues.model(client: app?.client).watch()
        return id
    }

    /// The engine's number, carried out of the sendable closure `JobModel`
    /// runs the POST in.
    private final class Answer: @unchecked Sendable {
        var id: Int?
    }
}

extension IngestNote {
    /// The copy kept its own log and the engine read an ending out of it.
    var isRecorded: Bool {
        if case .none = self { return false }
        return true
    }

    /// The copy's own log says it finished.
    var isDone: Bool {
        if case .done = self { return true }
        return false
    }

    /// The copy's own log says it stopped, failed its check, or ended in a
    /// way nothing can read: a card of the shoot is not all there.
    var isUnfinished: Bool {
        switch self {
        case .stopped, .failed, .unclear: return true
        case .none, .copying, .done: return false
        }
    }
}

extension ShootRowOK {
    /// A copy into this shoot did not finish - its last card's, or an
    /// earlier card's under it. Only that card may be added to it now, to
    /// finish the copy, and nothing carries him on to its cull.
    var copyUnfinished: Bool { ingest.isUnfinished || earlier_copies.contains { !$0.finished } }
}

extension ShootInfo {
    /// As `ShootRowOK.copyUnfinished`.
    var copyUnfinished: Bool { ingest.isUnfinished || earlier_copies.contains { !$0.finished } }
}

/// What is on a card, read off the card itself before anything is copied
/// (DESIGN.md §2.6).
public struct CardScan: Equatable, Sendable {
    /// The photographs the copy will take: the engine's own RAW and JPEG
    /// extensions, and nothing else. It counted every file with a three
    /// letter extension, so a card with clips and their sidecars on it said
    /// one number on the button and the copy another.
    public var photographs: Int
    /// The day the card's last evening started, as a shoot's name starts:
    /// "2026-09-19". Taken from the photographs, not the Mac's clock, so a
    /// card copied after midnight or the next morning is still the 19th.
    public var day: String?
    /// The newest photograph on the card.
    public var newest: Fingerprint?
    /// The shoot that already holds that photograph, when one does.
    public var copiedAs: String?
    /// What the engine found of this card in the library, counted frame by
    /// frame (`/api/cards`): how many of its photographs a shoot holds, and
    /// whether a copy into it is running, waiting or stopped. Said in place
    /// of `copiedAs` when it answered, which looks only at the newest frame.
    public var contents: CardContents?

    public init(photographs: Int, day: String? = nil, newest: Fingerprint? = nil, copiedAs: String? = nil,
                contents: CardContents? = nil) {
        self.photographs = photographs; self.day = day; self.newest = newest; self.copiedAs = copiedAs
        self.contents = contents
    }

    /// What a copy keeps of a photograph: its name, its size and its time.
    /// The copy keeps the time (`copystat`), so the three together are the
    /// same frame on the card and in the shoot.
    public struct Fingerprint: Equatable, Sendable {
        public let name: String
        public let size: Int
        public let modified: Date
    }

    /// `ingest.py`'s own list, `common.RAW_EXTS | JPEG_EXTS`. A test reads
    /// the two sets out of common.py, so the count cannot drift from what is
    /// copied.
    public static let extensions: Set<String> = [
        "arw", "cr2", "cr3", "nef", "raf", "dng", "orf", "rw2", "jpg", "jpeg",
    ]

    /// A longer gap than this between two frames is another evening. A card
    /// is the backup until the photographs are delivered, so it often still
    /// holds the last shoot as well as tonight's.
    static let evening: TimeInterval = 6 * 3600

    /// Walks the card's DCIM folder the way `ingest.py` does: every file with
    /// one of the extensions, whatever folder it is in, except a name that
    /// starts with a dot.
    public nonisolated static func read(_ volume: String) -> CardScan? {
        let dcim = URL(fileURLWithPath: volume).appendingPathComponent("DCIM")
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: dcim, includingPropertiesForKeys: keys,
                                                     options: [.skipsPackageDescendants])
        else { return nil }
        var n = 0
        var dates: [Date] = []
        var newest: Fingerprint?
        for case let url as URL in e {
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), extensions.contains(url.pathExtension.lowercased()),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true
            else { continue }
            n += 1
            guard let d = v.contentModificationDate else { continue }
            dates.append(d)
            if newest.map({ d > $0.modified || (d == $0.modified && name > $0.name) }) ?? true {
                newest = Fingerprint(name: name, size: v.fileSize ?? 0, modified: d)
            }
        }
        guard n > 0 else { return nil }
        return CardScan(photographs: n, day: lastEvening(dates).map(dayName), newest: newest)
    }

    /// When the card's last evening started: back from the newest frame for
    /// as long as no gap is longer than `evening`.
    static func lastEvening(_ dates: [Date]) -> Date? {
        let sorted = dates.sorted()
        guard var start = sorted.last else { return nil }
        for d in sorted.reversed().dropFirst() {
            if start.timeIntervalSince(d) > evening { break }
            start = d
        }
        return start
    }

    static func dayName(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// The shoot whose own folder holds this photograph: same name, same
    /// size, same time. The card's name proves nothing — every card his
    /// camera formats mounts as Untitled — so "already copied" was said of
    /// every new card and he learned to ignore it.
    public nonisolated static func copiedAs(_ newest: Fingerprint, shoots: [(name: String, raw: String)]) -> String? {
        for s in shoots where !s.raw.isEmpty {
            let u = URL(fileURLWithPath: s.raw).appendingPathComponent(newest.name)
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  v.fileSize == newest.size, let m = v.contentModificationDate,
                  abs(m.timeIntervalSince(newest.modified)) < 2
            else { continue }
            return s.name
        }
        return nil
    }
}
