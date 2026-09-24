import Foundation
import Observation

/// The five shapes `/api/reel` makes. The raw values are the engine's words
/// and are what is sent; the labels a person reads are in `ReelsStrings`.
public enum ReelFormat: String, CaseIterable, Sendable, Identifiable {
    case cut, sequence, loop, boomerang, timelapse
    public var id: String { rawValue }
    /// Everything but a timelapse is made of one burst.
    public var isBurst: Bool { self != .timelapse }
}

/// The widths `/api/reel` accepts. `native` is the largest that does not
/// upscale any frame.
public enum ReelSize: String, CaseIterable, Sendable, Identifiable {
    case w1080 = "1080", w1440 = "1440", w2160 = "2160", native
    public var id: String { rawValue }
}

/// How the bursts list is ordered. By number is the default because a burst
/// number is the thing he already knows; the lister's own ranking is one
/// control away.
public enum ReelOrder: String, CaseIterable, Sendable, Identifiable {
    case number, best
    public var id: String { rawValue }
}

/// What the crop can follow in every build. Anything further is the
/// extension's, and arrives in `ReelOptions.follow` (DESIGN.md §2.6).
public enum ReelFollowBase {
    public static let action = "action"
    public static let people = "people"
    public static let none = "none"
    public static let ids = [action, people, none]
}

/// What on the Reels page has the keyboard: the burst field, or the frames.
/// Return means "go to that burst" in the one and Cut It everywhere else.
public enum ReelsFocus: Hashable, Sendable {
    case search, grid
}

/// One change to which frames of a reel are in, kept for Q and ⌘Z: the set
/// of frames he took out before and after it, the frame it was made on and
/// the burst on screen.
struct ReelsChange: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case include, leaveOut, clear, putAllBack, leaveAllOut, startHere, endHere
    }
    let kind: Kind
    let stem: String?
    let burst: String?
    let before: Set<String>
    let after: Set<String>

    /// What Edit ▸ Undo names it: "Leave Out 06264", "Put Them All Back".
    @MainActor var name: String {
        let short = stem.map(ShootSession.shortStem) ?? ""
        switch kind {
        case .include: return Strings.Reels.includeNamed(short)
        case .leaveOut: return Strings.Reels.leaveOutNamed(short)
        case .clear: return Strings.Reels.clearNamed(short)
        case .putAllBack: return Strings.Reels.putBackAll
        case .leaveAllOut: return Strings.Reels.leaveAllOut
        case .startHere: return Strings.Reels.startHere
        case .endHere: return Strings.Reels.endHere
        }
    }
}

/// A frame asked to be seen large: which frames the viewer walks through, and
/// where it starts.
public struct ReelLook: Identifiable, Equatable, Sendable {
    public var id: String { stems.joined(separator: ",") + "#\(start)" }
    public let stems: [String]
    public let start: Int
}

/// Waiting for him to export a burst out of PhotoLab.
///
/// It begins when he presses the button, from the engine's own count of the
/// burst's exports at that moment (`/api/reel/watch`, which walks every folder
/// an export can land in), and it only watches the count once the presets are
/// written and PhotoLab has been asked to open (`ready`). PhotoLab writes the
/// JPEGs one at a time, so a rising count means he is mid-export. Frames
/// exported before the press are not an export that has finished: the page
/// this replaces cut a reel from the three that were already there, six
/// seconds after he pressed it.
///
/// It is finished when every frame of the burst is exported (`target`), or
/// when nothing new has come for `quietPolls` — long enough that one slow
/// frame is not taken for the end. Two quiet polls, ten seconds, was shorter
/// than PhotoLab takes over a single frame with its heaviest noise reduction,
/// and cut a draft from the first four frames of thirteen.
public struct ReelWait: Equatable, Sendable {
    public let burst: String
    /// Exports of this burst when he pressed the button.
    public let baseline: Int
    /// Every frame of the burst. Once this many are exported there is nothing
    /// left to wait for; `nil` when the page did not know.
    public let target: Int?
    /// What the reel is cut with: the page as it was when he pressed, frozen,
    /// so browsing another burst or another format meanwhile changes nothing
    /// about it. The body of `/api/reel` less the shoot's name.
    public let request: [String: JSONValue]
    /// The most seen since.
    public private(set) var seen: Int
    /// Polls in a row that saw nothing new, once something new had come.
    public private(set) var quiet: Int
    /// Polls in a row that saw nothing new at all, for slowing down.
    public private(set) var idle: Int
    /// The presets are written and PhotoLab was asked to open. Until then
    /// there is nothing of his to wait for.
    public private(set) var ready: Bool

    /// Quiet polls before a burst not exported whole is cut from what came:
    /// forty-five seconds.
    public static let quietPolls = 9
    /// Quiet polls once every frame is there: one, so the last file PhotoLab
    /// wrote is read whole rather than while it may still be being written.
    public static let settlePolls = 1
    /// A reel needs this many frames at the least.
    public static let least = 3
    /// How often the count is asked for. Each answer walks the shoot's export
    /// folders and iCloud Drive, so not more often than this.
    public static let interval: Duration = .seconds(5)
    /// Polls at `interval` before the wait slows down: two minutes with
    /// nothing new.
    public static let fastPolls = 24
    /// Polls every 30 s after that, before it slows again: eight minutes.
    public static let slowPolls = 16

    public init(burst: String, baseline: Int, target: Int? = nil,
                request: [String: JSONValue] = [:], ready: Bool = true) {
        self.burst = burst
        self.baseline = baseline
        self.target = target
        self.request = request
        self.seen = baseline
        self.quiet = 0
        self.idle = 0
        self.ready = ready
    }

    /// The presets are written; start watching.
    public mutating func begin() { ready = true }

    /// One poll's answer. Returns whether the reel should now be cut.
    public mutating func saw(_ count: Int) -> Bool {
        guard ready else { return false }
        if count > seen {
            seen = count
            quiet = 0
            idle = 0
            return false
        }
        idle += 1
        if seen > baseline { quiet += 1 }
        return settled
    }

    /// How many frames the reel is, when it is not the whole burst. The
    /// count the wait reads is the burst's, over every frame, so it cannot
    /// tell these from the others: it still waits for the whole burst, or
    /// for the pause, and the line says so.
    public var reelFrames: Int? {
        guard case .array(let named)? = request["frames"] else { return nil }
        return named.count
    }

    /// Something new has arrived since the wait began.
    public var arriving: Bool { seen > baseline }
    /// Every frame of the burst is exported.
    public var complete: Bool { target.map { seen >= $0 } ?? false }
    public var settled: Bool {
        arriving && seen >= Self.least && quiet >= (complete ? Self.settlePolls : Self.quietPolls)
    }
    /// How long until what has come is cut, once a pause has begun: the line
    /// says it, so a reel cut from part of a burst is never a surprise.
    public var cutsIn: Duration? {
        guard arriving, !complete, quiet > 0, !settled else { return nil }
        return ReelWait.interval * (Self.quietPolls - quiet)
    }
    /// How many `interval`s until the next poll. It watches for as long as
    /// the app is open, more slowly the longer nothing new has come: every
    /// 5 s for the first two minutes, then every 30 s until ten minutes,
    /// then every minute. It used to stop after twenty minutes, and an
    /// export he made after editing the burst for twenty-five cut nothing;
    /// a walk of the export folders once a minute is what waiting on him
    /// costs. Anything new puts it back to 5 s.
    public var slowing: Int { Self.slowing(afterIdle: idle) }

    public static func slowing(afterIdle idle: Int) -> Int {
        if idle < fastPolls { return 1 }
        return idle < fastPolls + slowPolls ? 6 : 12
    }

    /// How long nothing new has come, at 5 s an `interval`, for the line.
    public var idleSeconds: Int {
        let step = Int(Self.interval.components.seconds)
        return (0..<idle).reduce(0) { $0 + step * Self.slowing(afterIdle: $1) }
    }
}

/// Everything the Reels step remembers about one shoot (DESIGN.md §2.6).
///
/// It outlives the page, so the format, the burst and the frames he took out
/// are still there when he comes back to the step, the same way every other
/// step keeps its form (§2.4).
@MainActor @Observable
public final class ReelsModel {
    public let session: ShootSession
    public let jobs: JobModel
    public let client: StudioClient

    // What the engine said.
    public private(set) var options: ReelOptions?
    /// The burst `options.frames` belongs to. The lister only lists a burst's
    /// frames when it is asked about that burst.
    public private(set) var framesBurst: String?
    public private(set) var loading = false
    /// A refusal or failure reading the options, in the engine's words.
    public private(set) var loadError: String?

    // What he chose.
    public var format: ReelFormat = .cut
    public var burst: String?
    /// Timelapse: "" is the whole day, otherwise a name filed in the shoot.
    public var tag: String = ""
    /// An export folder, or "" for everywhere the engine looks.
    public var source: String = ""
    /// Frames he took out of the reel. About the frames, not the shape, so a
    /// change of format keeps them; and not about the burst on screen, so
    /// looking at another burst and coming back keeps them too. A stem is
    /// one frame of one shoot, so one set serves every burst of it.
    public var leftOut: Set<String> = []
    public var burstSpeed: Int = 8
    public var timelapseSpeed: Int = 12
    public var burstFollow: String = ReelFollowBase.action
    /// A night of one name is people, frame by frame, not an exchange to track.
    public var timelapseFollow: String = ReelFollowBase.people
    public var ramp = false
    public var size: ReelSize = .w1080
    public var search = ""
    /// Edit ▸ Find Burst… (⌘F) asked for the burst field. The page moves the
    /// keyboard there each time this changes.
    public private(set) var findRequests = 0
    public var order: ReelOrder = .number
    /// The tile the keyboard is on.
    public var cursor: String?
    /// How many tiles a row of the grid holds, for ↑ and ↓. The grid says,
    /// as it lays them out.
    public var columns = 1
    /// Changes to which frames are in, newest last, for Q and ⌘Z.
    private(set) var undoStack: [ReelsChange] = []
    private(set) var redoStack: [ReelsChange] = []
    /// An undo that took the page to another burst: the frame the keys go
    /// to once that burst's frames are read.
    private var pendingCursor: String?
    public var look: ReelLook?
    /// The marks made in the viewer this look, newest last: whether each
    /// reached the undo stack, so the viewer's Q takes back its own change
    /// and never one made on the grid before it opened.
    private var lookChanges: [Bool] = []

    // Work.
    public let reelJob: StepJobRunner
    public let spreadJob: StepJobRunner
    public private(set) var wait: ReelWait?
    /// Why the wait on PhotoLab ended without cutting anything, in a sentence.
    public private(set) var waitNote: String?
    /// The line under the button after he added something to the list.
    public var added: String?
    /// A refusal from something that is not the job: opening the folder.
    public var note: String?
    /// How many reels he cut from this page have come out. The player plays
    /// the one it loads after this moves, rather than sit paused on the reel
    /// he just asked for until he presses play (`ReelPlayer`).
    public private(set) var reelsCut = 0
    /// A reel he cut from this page has not ended yet.
    private var cutPending = false

    /// For the snapshot harness and tests: the options were handed in and
    /// nothing is asked of an engine.
    public private(set) var pinned = false

    private var loadKey: String?
    /// The lister's answers this visit, by `burst|source`.
    private var answers: [String: ReelOptions] = [:]

    /// Something may have changed what the lister would say.
    func forget() { answers = [:] }
    private var pollTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    private var lastJobID: String?

    /// How many of a burst's frames are exported, over every folder an export
    /// can land in: `/api/reel/watch`. Replaced by tests.
    var countExports: @MainActor (_ shoot: String, _ burst: String) async -> Int?
    /// Posts `/api/spread` through the step's job runner. Replaced by tests.
    var startSpread: @MainActor (_ model: ReelsModel, _ burst: String) -> Void = { m, b in m.postSpread(b) }
    /// Posts `/api/reel` through the step's job runner. Replaced by tests.
    var sendReel: @MainActor (_ model: ReelsModel, _ body: [String: JSONValue]) -> Void = { m, b in m.postReel(b) }
    /// The lister, `/api/reel/options`. Replaced by tests.
    var fetchOptions: @MainActor (_ shoot: String, _ burst: String?, _ src: String?) async throws -> ReelOptions
    /// Between polls of the count. Tests shorten it.
    var pollInterval: Duration = ReelWait.interval
    /// The burst the light table is on, once it has been opened in this
    /// launch (`lightTablePlace`). Replaced by tests.
    var lightTableBurst: @MainActor () -> String?
    /// Each burst's length and whether he kept a frame of it, for one
    /// version of the shoot's rows (`facts`).
    @ObservationIgnored var factsCache: BurstFacts?
    /// The light-table burst the page last opened on, so coming back to Reels
    /// without moving on the light table keeps what he chose here.
    public private(set) var tookFromLightTable: String?

    public init(session: ShootSession, jobs: JobModel) {
        self.session = session
        self.jobs = jobs
        self.client = session.client
        reelJob = StepJobRunner(kinds: ["reel"], shoot: session.name, jobs: jobs)
        spreadJob = StepJobRunner(kinds: ["spread"], shoot: session.name, jobs: jobs)
        let c = session.client
        countExports = { shoot, burst in (try? await c.get(Routes.reelWatch(shoot, burst: burst)))?.jpegs }
        fetchOptions = { shoot, burst, src in try await c.get(Routes.reelOptions(shoot, burst: burst, src: src)) }
        lightTableBurst = { [weak session] in session.flatMap(Self.lightTablePlace) }
    }

    /// Where the light table is in a shoot, once it has been opened in this
    /// launch: its first act is to go where the engine says (§2.5.13), which
    /// moves the cursor. Before that the cursor is the first burst of a shoot
    /// nobody has looked at here, which is nobody's place.
    static func lightTablePlace(_ session: ShootSession) -> String? {
        session.cursor.generation > 0 ? session.currentBurst?.id : nil
    }

    // MARK: - reading

    /// The bursts on offer for this format: the lister's cuts for a cut, its
    /// sequences for everything else, in the order he asked for.
    public var bursts: [BurstOption] {
        guard let o = options else { return [] }
        let list = format == .cut ? o.cuts : o.sequences
        return Self.ordered(list, by: order)
    }

    /// The same, narrowed by what is typed in the search field.
    public var shownBursts: [BurstOption] { Self.matching(bursts, search) }

    nonisolated public static func ordered(_ list: [BurstOption], by order: ReelOrder) -> [BurstOption] {
        guard order == .number else { return list }
        return list.sorted { a, b in
            switch (Int(a.burst), Int(b.burst)) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.burst.localizedStandardCompare(b.burst) == .orderedAscending
            }
        }
    }

    nonisolated public static func matching(_ list: [BurstOption], _ text: String) -> [BurstOption] {
        let q = text.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? list : list.filter { $0.burst.contains(q) }
    }

    /// The burst Return in the field goes to: the one whose number is exactly
    /// what he typed, otherwise the first the field shows. Typing 93 among
    /// 93, 193 and 293 means 93 whatever order the list is in. Nothing typed
    /// is no burst: it went to the top of the list, off the one he was on,
    /// and the next Return cut that.
    nonisolated public static func searched(_ list: [BurstOption], _ text: String) -> BurstOption? {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let shown = matching(list, q)
        return shown.first { $0.burst == q } ?? shown.first
    }

    /// The frame a cut of each burst lands on: its cover in the list, because
    /// it is the moment the burst is about.
    public var covers: [String: String] {
        var out: [String: String] = [:]
        for c in options?.cuts ?? [] { if let l = c.lands_on { out[c.burst] = l } }
        return out
    }

    public var chosenBurst: BurstOption? {
        guard let burst else { return nil }
        return (options?.cuts ?? []).first { $0.burst == burst }
            ?? (options?.sequences ?? []).first { $0.burst == burst }
    }

    /// The frames of the chosen burst, when the lister has said which.
    public var frames: [ReelFrame] {
        guard let burst, framesBurst == burst else { return [] }
        return options?.frames ?? []
    }

    /// While the lister is asked about the chosen burst, how many frames it
    /// has, so the grid keeps their place rather than collapsing and
    /// springing back.
    public var framesComing: Int {
        guard let b = chosenBurst, framesBurst != b.burst else { return 0 }
        return b.frames
    }

    /// The frames that will go in: every one there is a picture of, less the
    /// ones he took out. Shutter order, always.
    public var chosen: [String] {
        frames.filter { $0.visible && !leftOut.contains($0.stem) }.map(\.stem)
    }

    public var usable: [String] { frames.filter(\.visible).map(\.stem) }

    /// Whether a tile badges "Not exported": only when the burst is partly
    /// exported, where it says which frames are the gap. All or none, the
    /// draft line says so once; and while the wait watches this burst the
    /// lister's per-frame answer is out of date and the wait's line counts.
    public var badgesExports: Bool {
        let shown = frames.filter(\.visible)
        guard shown.contains(where: \.exported), shown.contains(where: { !$0.exported }) else { return false }
        return wait?.burst != burst
    }

    /// A burst not exported whole is cut off the cull's decodes and named a
    /// draft on disk. The engine decides this over the whole burst, not over
    /// the frames he ticked, so this does too.
    public var isDraft: Bool {
        guard let b = chosenBurst else { return false }
        return b.exported < b.frames
    }

    public var speed: Int {
        get { format == .timelapse ? timelapseSpeed : burstSpeed }
        set { if format == .timelapse { timelapseSpeed = newValue } else { burstSpeed = newValue } }
    }

    public var follow: String {
        get { format == .timelapse ? timelapseFollow : burstFollow }
        set { if format == .timelapse { timelapseFollow = newValue } else { burstFollow = newValue } }
    }

    /// The three every build has, then whatever the extension offers.
    public var followChoices: [ReelFollow] {
        let base = [ReelFollow(id: ReelFollowBase.action, label: Strings.Reels.followAction),
                    ReelFollow(id: ReelFollowBase.people, label: Strings.Reels.followPeople),
                    ReelFollow(id: ReelFollowBase.none, label: Strings.Reels.followNone, note: Strings.Reels.followNoneNote)]
        let extra = (options?.follow ?? []).filter { !ReelFollowBase.ids.contains($0.id) }
        return base + extra
    }

    nonisolated public static let speeds = [6, 8, 10, 12]

    /// How many frames a timelapse would play, before thinning.
    public var timelapseFrames: Int {
        guard let o = options else { return 0 }
        if tag.isEmpty { return o.visible ?? 0 }
        return (o.tags ?? []).first { $0.name == tag }?.frames ?? 0
    }

    /// Whether pressing Cut It now has something to cut.
    public var canCut: Bool {
        guard options != nil, loadError == nil else { return false }
        if format == .timelapse { return timelapseFrames >= ReelWait.least }
        guard burst != nil, framesBurst == burst else { return false }
        return chosen.count >= ReelWait.least
    }

    /// How many of a burst's frames the page says are exported. While the
    /// wait watches that burst it is the wait's count, over every folder,
    /// so the list, the draft line and the wait never give three numbers
    /// for one thing.
    public func exported(_ b: BurstOption) -> Int {
        guard let w = wait, w.burst == b.burst, w.ready else { return b.exported }
        return max(b.exported, min(w.seen, b.frames))
    }

    /// The last reel cut from this shoot, newest by the time the engine gave.
    public var lastReel: ReelFile? {
        (options?.reels ?? []).max { $0.at < $1.at }
    }

    public var reelDirectory: String {
        let d = options?.reel_dir ?? ""
        return d.isEmpty ? session.info.reel_dir : d
    }

    public var lastReelURL: URL? {
        guard let r = lastReel else { return nil }
        return URL(fileURLWithPath: reelDirectory).appendingPathComponent(r.name)
    }

    // MARK: - what is sent

    /// The body of `/api/reel`, less the shoot's name, with exactly the names
    /// `_b_reel` reads — which are also the options the list is given, since
    /// the engine builds the command from them when the turn comes.
    public var request: [String: JSONValue] {
        Self.request(format: format, burst: burst, tag: tag, chosen: chosen, usable: usable,
                     speed: speed, follow: follow, size: size, ramp: ramp, source: source)
    }

    nonisolated public static func request(format: ReelFormat, burst: String?, tag: String, chosen: [String],
                               usable: [String], speed: Int, follow: String, size: ReelSize,
                               ramp: Bool, source: String) -> [String: JSONValue] {
        var o: [String: JSONValue] = [
            "format": .string(format.rawValue),
            "fps": .integer(speed),
            "follow": .string(follow),
            "size": .string(size.rawValue),
        ]
        if format == .timelapse {
            if !tag.isEmpty { o["tag"] = .string(tag) }
            return o
        }
        if let burst { o["burst"] = .string(burst) }
        // Only a subset is named. Every frame is what the engine takes when
        // it is not told, and a list of all of them is the same thing longer.
        if !chosen.isEmpty, chosen != usable { o["frames"] = .array(chosen.map(JSONValue.string)) }
        if format == .cut && ramp { o["ramp"] = .bool(true) }
        if !source.isEmpty { o["exports"] = .string(source) }
        return o
    }

    // MARK: - choosing

    public func choose(format f: ReelFormat) {
        guard f != format else { return }
        // The burst survives the format. Every format is built from the same
        // bursts, so clearing it threw away what he had chosen and sent him
        // back to hunting for it among two hundred.
        format = f
        if f.isBurst, burst == nil { load() }
    }

    /// A burst chosen. `byKeys`: he is walking the list with the arrows or N
    /// and P, and the lister is asked only once he pauses on one, not once
    /// for every row he passes.
    public func choose(burst b: String, byKeys: Bool = false) {
        guard b != burst else { return }
        burst = b
        cursor = nil
        load(after: byKeys ? Self.keyPause : .zero)
    }

    /// How long a burst reached by the keys is held before the lister is
    /// asked about it: shorter than a look, longer than a key repeat.
    nonisolated static let keyPause: Duration = .milliseconds(250)

    /// N and P from the frames: the burst after or before the chosen one in
    /// the list as it is shown. Whether there was one to go to.
    @discardableResult
    public func chooseNeighbour(_ delta: Int) -> Bool {
        let list = shownBursts
        guard !list.isEmpty else { return false }
        let i = burst.flatMap { b in list.firstIndex { $0.burst == b } }
        let j = i.map { $0 + delta } ?? (delta > 0 ? 0 : list.count - 1)
        guard list.indices.contains(j) else { return false }
        choose(burst: list[j].burst, byKeys: true)
        return true
    }

    /// Return in the burst field: go to the burst he typed, and give him the
    /// whole list back around it, so N and P from the frames walk the bursts
    /// beside it rather than the ones that happen to share its digits.
    /// Whether there was one.
    @discardableResult
    public func goToSearched() -> Bool {
        guard let b = Self.searched(bursts, search) else { return false }
        search = ""
        choose(burst: b.burst)
        return true
    }

    /// Typing narrowed the list to one burst: that is the one he is after,
    /// so it is chosen without Return. The field keeps the keyboard.
    public func searchChanged() {
        let shown = shownBursts
        guard shown.count == 1, let only = shown.first, only.burst != burst else { return }
        choose(burst: only.burst)
    }

    /// Edit ▸ Find Burst…: the burst field, where there is one.
    public func find() {
        guard format.isBurst else { return }
        findRequests += 1
    }

    public func choose(source s: String) {
        guard s != source else { return }
        source = s
        load()
    }

    /// A single click on a tile: in or out of the reel. A frame there is no
    /// picture of cannot go in, and says so rather than toggling.
    public func toggle(_ stem: String) {
        guard let f = frames.first(where: { $0.stem == stem }), f.visible else { return }
        let goIn = leftOut.contains(stem)
        change(goIn ? .include : .leaveOut, on: stem) {
            if goIn { leftOut.remove(stem) } else { leftOut.insert(stem) }
        }
        cursor = stem
    }

    /// The frame the keys act on: the one they are on, or the first there is
    /// a picture of when they are on none yet. Only a frame there is a
    /// picture of can go in or out.
    var keyFrame: String? {
        guard let c = cursor ?? frames.first(where: \.visible)?.stem,
              frames.contains(where: { $0.stem == c && $0.visible }) else { return nil }
        return c
    }

    /// E, D and X, as Keep, Drop and Clear the Mark are on the light table
    /// and Include, Leave Out and Clear on Instagram: E puts the frame in the
    /// reel and D leaves it out, each then on to the next frame; X clears
    /// what he did to it, which on a reel is back in, and stays. Whether
    /// there was a frame to mark.
    @discardableResult
    public func mark(_ m: ReelsMeaning) -> Bool {
        guard let c = keyFrame else { return false }
        switch m {
        case .include: change(.include, on: c) { leftOut.remove(c) }
        case .clear: change(.clear, on: c) { leftOut.remove(c) }
        case .leaveOut: change(.leaveOut, on: c) { leftOut.insert(c) }
        default: return false
        }
        cursor = c
        if m != .clear { moveCursor(by: 1) }
        return true
    }

    public func isIn(_ stem: String) -> Bool {
        guard let f = frames.first(where: { $0.stem == stem }) else { return false }
        return f.visible && !leftOut.contains(stem)
    }

    /// Every frame of this burst back in; the frames he took out of other
    /// bursts stay out.
    public func putAllBack() {
        change(.putAllBack, on: nil) { leftOut.subtract(frames.map(\.stem)) }
    }

    /// Every frame of this burst out, so keeping three of twenty-one is
    /// three clicks rather than eighteen.
    public func leaveAllOut() {
        change(.leaveAllOut, on: nil) { leftOut.formUnion(frames.filter(\.visible).map(\.stem)) }
    }

    /// Shift-click: every frame from the one the keys were on to this one
    /// takes this one's new state — out if it was in, in if it was out.
    public func toggleRun(to stem: String) {
        guard let j = frames.firstIndex(where: { $0.stem == stem }), frames[j].visible else { return }
        let i = cursor.flatMap { c in frames.firstIndex { $0.stem == c } } ?? j
        let goIn = leftOut.contains(stem)
        change(goIn ? .include : .leaveOut, on: stem) {
            for f in frames[min(i, j)...max(i, j)] where f.visible {
                if goIn { leftOut.remove(f.stem) } else { leftOut.insert(f.stem) }
            }
        }
        cursor = stem
    }

    /// I: the reel starts on this frame (the keys' frame when none is
    /// named). Every frame before it goes out, and the reel runs as far as
    /// it ends now — the last frame in, or the end of the burst when none
    /// after it is. Whether there was a frame.
    @discardableResult
    public func startHere(_ stem: String? = nil) -> Bool {
        guard let c = index(of: stem) else { return false }
        let end = frames.indices.last { $0 >= c && isIn(frames[$0].stem) } ?? frames.count - 1
        change(.startHere, on: frames[c].stem) { trim(to: c...max(c, end), on: c) }
        return true
    }

    /// O: the reel ends on this frame, the same way round.
    @discardableResult
    public func endHere(_ stem: String? = nil) -> Bool {
        guard let c = index(of: stem) else { return false }
        let start = frames.indices.first { $0 <= c && isIn(frames[$0].stem) } ?? 0
        change(.endHere, on: frames[c].stem) { trim(to: min(start, c)...c, on: c) }
        return true
    }

    /// A frame named, or the keys' frame, or the first; and the keys move
    /// to it.
    private func index(of stem: String?) -> Int? {
        guard !frames.isEmpty else { return nil }
        let i = (stem ?? cursor).flatMap { c in frames.firstIndex { $0.stem == c } } ?? 0
        cursor = frames[i].stem
        return i
    }

    /// The reel now runs over `r`, starting or ending on frame `c`, which is
    /// in. Frames outside it go out; frames it gains past where the reel
    /// started or ended come in; a frame inside both that he took out by
    /// hand — a soft one in the middle — stays out, where putting the whole
    /// run back brought it back without a word.
    private func trim(to r: ClosedRange<Int>, on c: Int) {
        let was = frames.indices.first { isIn(frames[$0].stem) }
            .flatMap { a in frames.indices.last { isIn(frames[$0].stem) }.map { a...$0 } }
        for (i, f) in frames.enumerated() where f.visible {
            if !r.contains(i) {
                leftOut.insert(f.stem)
            } else if i == c || !(was?.contains(i) ?? false) {
                leftOut.remove(f.stem)
            }
        }
    }

    // MARK: - undo

    /// Q, U and ⌘Z: the last change to which frames are in, taken back, on
    /// the frame it was made on — as Q takes back a verdict on the light
    /// table and a mark on Instagram. There was no undo here at all: a D
    /// pressed on the wrong frame was a second press to find and put right.
    /// A change made on another burst takes the page back to that burst.
    public func undo() {
        guard let c = undoStack.popLast() else { return }
        leftOut = c.before
        redoStack.append(c)
        show(c)
    }

    /// ⇧⌘Z: what the last undo took back, done again.
    public func redo() {
        guard let c = redoStack.popLast() else { return }
        leftOut = c.after
        undoStack.append(c)
        show(c)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// What Edit ▸ Undo and Redo say here: "Undo Leave Out 06264".
    public var undoName: String? { undoStack.last.map { Words.Edit.undoNamed($0.name) } }
    public var redoName: String? { redoStack.last.map { Words.Edit.redoNamed($0.name) } }

    /// Runs one change to `leftOut` and, when it changed anything, keeps it
    /// for undo. A redo that is no longer the next thing is let go, as
    /// everywhere else.
    private func change(_ kind: ReelsChange.Kind, on stem: String?, _ body: () -> Void) {
        let before = leftOut
        body()
        guard leftOut != before else { return }
        undoStack.append(ReelsChange(kind: kind, stem: stem, burst: burst, before: before, after: leftOut))
        redoStack.removeAll()
    }

    /// The frame a change was on, in front of him: the ring on it, or its
    /// burst opened with the keys waiting for it.
    private func show(_ c: ReelsChange) {
        if let b = c.burst, b != burst, format.isBurst {
            // Before the burst is chosen: an answer already read this visit
            // is adopted at once, inside the choosing.
            pendingCursor = c.stem
            choose(burst: b)
        } else if let stem = c.stem, frames.contains(where: { $0.stem == stem }) {
            cursor = stem
        }
    }

    // MARK: - the keys

    /// A key, from anywhere in the page's window (`ReelsKeys.route`).
    /// Whether the page took it.
    @discardableResult
    public func key(_ p: KeyMap.Press) -> Bool {
        guard let m = ReelsKeys.action(p) else { return false }
        // Keepers' rule: a held key that is not movement is one press, and
        // its repeats are taken and do nothing.
        if p.isARepeat && !ReelsKeys.allowsRepeat(p) { return true }
        perform(m)
        keysTaken += 1
        return true
    }

    /// How many keys the page has taken. The grid scrolls the ring into
    /// sight each time it moves; a click, which moves the ring too, scrolls
    /// nothing.
    public private(set) var keysTaken = 0

    /// Whether a meaning would do something now: what a menu row greys on.
    /// Nothing is pressed from the menu while a frame is open large: the
    /// viewer in front has the keys, and a row would change the grid behind
    /// it.
    public func canPerform(_ m: ReelsMeaning) -> Bool {
        guard look == nil else { return false }
        switch m {
        case .include, .leaveOut, .clear, .open: return keyFrame != nil
        case .next, .previous, .rowDown, .rowUp, .startHere, .endHere: return !frames.isEmpty
        case .nextBurst, .previousBurst: return format.isBurst && !shownBursts.isEmpty
        case .undo: return canUndo
        case .redo: return canRedo
        case .nothing, .shortcuts: return true
        }
    }

    public func perform(_ m: ReelsMeaning) {
        switch m {
        case .next: moveCursor(by: 1)
        case .previous: moveCursor(by: -1)
        case .rowDown: moveCursor(by: columns)
        case .rowUp: moveCursor(by: -columns)
        case .include, .leaveOut, .clear: mark(m)
        case .open: if let c = keyFrame { openLarge(c) }
        case .nextBurst: chooseNeighbour(1)
        case .previousBurst: chooseNeighbour(-1)
        case .undo: undo()
        case .redo: redo()
        case .startHere: startHere()
        case .endHere: endHere()
        case .shortcuts: _ = CommandCenter.shared.run(CommandTable.ID.shortcuts)
        case .nothing: break
        }
    }

    /// A menu row's help tag while the page answers it, where the light
    /// table's would say something untrue here: Next Burst records nothing
    /// on Reels, and Keep and Drop write no verdict.
    public static func rowHelp(_ m: ReelsMeaning) -> String? {
        switch m {
        case .include: return Strings.Reels.includeHelp
        case .leaveOut: return Strings.Reels.leaveOutHelp
        case .nextBurst: return Strings.Reels.nextBurstHelp
        default: return nil
        }
    }

    /// A menu row's title while the page answers it: "Include 06264".
    public func rowTitle(_ m: ReelsMeaning) -> String? {
        let short = keyFrame.map(ShootSession.shortStem)
        switch m {
        case .include: return short.map(Strings.Reels.includeNamed) ?? Strings.Reels.include
        case .leaveOut: return short.map(Strings.Reels.leaveOutNamed) ?? Strings.Reels.leaveOut
        case .undo: return undoName
        case .redo: return redoName
        default: return nil
        }
    }

    /// Double-click, Space or a firm click: the frame large, walking through
    /// every frame of the burst there is a picture of.
    public func openLarge(_ stem: String) {
        let stems = usable
        guard let i = stems.firstIndex(of: stem) else { return }
        cursor = stem
        lookChanges = []
        look = ReelLook(stems: stems, start: i)
    }

    /// The viewer's one mark: in the reel. The viewer reads Keepers' keys as
    /// the grid does — E puts the frame on screen in, D leaves it out, X
    /// puts it back — so a soft frame seen large is taken out there and then.
    nonisolated public static let inReelMark = "in"

    /// The viewer's checkbox: in the reel, with no letter of its own — E,
    /// D and X reach it (`lookVerdicts`).
    public static var lookActions: [ExtViewerAction] {
        [ExtViewerAction(id: inReelMark, label: Strings.Reels.inReel)]
    }
    /// E puts the frame in, D leaves it out, X clears what he did — back in.
    nonisolated public static let lookVerdicts = ExtViewerVerdicts(include: inReelMark, leaveOut: nil,
                                                                   clear: inReelMark)

    /// Each mark goes on the page's own undo as it is made, and Q in the
    /// viewer takes it back off it: one undo, as Full Image and Single share
    /// one on the light table. The viewer's Q used to reach the page as a
    /// new mark, kept as one more change, so after D then Q there Edit ▸
    /// Undo read "Undo Include 06264" and the grid's Q left the frame out
    /// again.
    public var lookMarking: ExtViewerMarking {
        ExtViewerMarking(actions: Self.lookActions,
                         marks: Dictionary(uniqueKeysWithValues: chosen.map { ($0, Self.inReelMark) }),
                         verdicts: Self.lookVerdicts,
                         onMark: { [weak self] stem, mark in self?.lookMarked(stem, in: mark == Self.inReelMark) },
                         onUndo: { [weak self] stem, mark in self?.lookTookBack(stem, in: mark == Self.inReelMark) })
    }

    /// One frame in or out, as the viewer says.
    public func set(_ stem: String, in isIn: Bool) {
        guard frames.contains(where: { $0.stem == stem && $0.visible }) else { return }
        change(isIn ? .include : .leaveOut, on: stem) {
            if isIn { leftOut.remove(stem) } else { leftOut.insert(stem) }
        }
    }

    /// A mark made in the viewer, and whether it went on the undo stack:
    /// a mark that changed nothing is not a change to take back.
    func lookMarked(_ stem: String, in isIn: Bool) {
        let depth = undoStack.count
        set(stem, in: isIn)
        lookChanges.append(undoStack.count > depth)
    }

    /// Q in the viewer: its last mark, taken back off the page's undo stack
    /// — so it waits for ⇧⌘Z like any undo, and the grid's next Q is the
    /// change before it. A mark that never reached the stack is only put
    /// back.
    func lookTookBack(_ stem: String, in isIn: Bool) {
        if lookChanges.popLast() == true, undoStack.last?.stem == stem {
            undo()
        } else {
            set(stem, in: isIn)
        }
    }

    /// The viewer closed: the keys are on the frame he was looking at, so
    /// the grid rings it.
    public func lookEnded(_ r: ExtViewerResult) {
        if frames.contains(where: { $0.stem == r.stem }) { cursor = r.stem }
        look = nil
        lookChanges = []
    }

    public func moveCursor(by delta: Int) {
        let stems = frames.map(\.stem)
        guard !stems.isEmpty else { return }
        let i = cursor.flatMap { stems.firstIndex(of: $0) } ?? (delta > 0 ? -1 : stems.count)
        cursor = stems[min(max(0, i + delta), stems.count - 1)]
    }

    // MARK: - asking the engine

    /// Ask the lister, unless what it would be asked has not changed, or it
    /// was asked already this visit. Each answer is a new process that walks
    /// every export folder, so a burst looked at again is not asked about
    /// again until something could have changed it: the page coming back on
    /// screen, or a reel or a spread ending (`forget()`).
    public func load(force: Bool = false, after pause: Duration = .zero) {
        guard !pinned else { return }
        let key = "\(burst ?? "")|\(source)"
        if !force, key == loadKey, options != nil { return }
        if force { forget() }
        loadKey = key
        let b = burst
        if let known = answers[key] {
            adopt(known, burst: b)
            loading = false
            return
        }
        loading = true
        let name = session.name
        let src = source.isEmpty ? nil : source
        let fetch = fetchOptions
        Task { @MainActor in
            do {
                if pause > .zero {
                    try? await Task.sleep(for: pause)
                    guard self.loadKey == key else { return }    // he went on past it
                }
                let o = try await fetch(name, b, src)
                guard self.loadKey == key else { return }    // he moved on while that was read
                self.answers[key] = o
                self.adopt(o, burst: b)
            } catch let e as StudioError {
                guard self.loadKey == key else { return }
                self.loadError = e.sentence
            } catch {
                guard self.loadKey == key else { return }
                self.loadError = Strings.API.offline
            }
            if self.loadKey == key { self.loading = false }
        }
    }

    private func adopt(_ o: ReelOptions, burst b: String?) {
        // A burst remembered from the last launch that the lister no longer
        // offers — culled again since — is let go, and the page chooses as
        // it does with none.
        if let b, b == burst, !o.cuts.contains(where: { $0.burst == b }),
           !o.sequences.contains(where: { $0.burst == b }), !(o.cuts.isEmpty && o.sequences.isEmpty) {
            burst = nil
        }
        options = o
        framesBurst = b
        loadError = o.error
        // The keys start on the burst's first frame, so the ring shows where
        // E, D and Space will land before he has pressed anything — or on
        // the frame an undo took the page to this burst for.
        if let p = pendingCursor, o.frames.contains(where: { $0.stem == p }) {
            cursor = p
        } else if b != nil, cursor.map({ c in !o.frames.contains { $0.stem == c } }) ?? true {
            cursor = o.frames.first(where: \.visible)?.stem
        }
        pendingCursor = nil
        // The lister only lists a burst's frames when asked about that burst,
        // so choosing one for him has to go back and ask. The one it ranks
        // first, because it is the one most worth cutting.
        if burst == nil, let first = (format == .cut ? o.cuts : o.sequences).first {
            burst = first.burst
            load()
        }
    }

    /// The same shoot opened afresh: the page goes on where the one it
    /// replaces was.
    func copyChoices(from old: ReelsModel) {
        format = old.format
        burst = old.burst
        tag = old.tag
        source = old.source
        leftOut = old.leftOut
        burstSpeed = old.burstSpeed
        timelapseSpeed = old.timelapseSpeed
        burstFollow = old.burstFollow
        timelapseFollow = old.timelapseFollow
        ramp = old.ramp
        size = old.size
        order = old.order
        tookFromLightTable = old.tookFromLightTable
    }

    /// For the snapshot harness and tests: take this answer as the engine's,
    /// and ask the engine nothing.
    public func preview(_ o: ReelOptions, burst b: String?) {
        pinned = true
        options = o
        burst = b
        framesBurst = b
        loadError = o.error
        loading = false
    }

    public func previewWait(_ w: ReelWait?, note: String? = nil) { wait = w; waitNote = note }

    // MARK: - doing

    public var queue: QueueModel { Queues.model(client: client) }
    public var wouldWait: Bool { queue.wouldWait }

    public func cut() { post(request) }

    /// Waiting on PhotoLab for the burst he is looking at: the step's primary
    /// is Cut Now, which stops waiting and cuts what has come, as he had it
    /// when he pressed. A second Cut It beside the wait would give him two
    /// reels of one burst and no way to tell which was which.
    public var waitingHere: Bool {
        guard let w = wait, format.isBurst else { return false }
        return w.burst == burst
    }

    /// What the step's primary says: Cut It, or Cut Now while waiting here.
    public var primaryWord: String { waitingHere ? Strings.Reels.cutNow : Strings.Reels.cutIt }

    /// Whether the primary can be pressed now.
    public var canPressPrimary: Bool { waitingHere ? wait?.ready == true : canCut }

    /// The step's primary, the toolbar's copy and Shoot ▸ Cut a Reel.
    public func primary() {
        if waitingHere { cutNow() } else { cut() }
    }

    /// Stop waiting and cut the burst from what is exported now, with what
    /// he had chosen when he pressed.
    public func cutNow() {
        guard let w = wait, w.ready else { return }
        stopWaiting()
        waitTask = Task { @MainActor [weak self] in await self?.cutWhenExported(w) }
    }

    /// He has changed the burst's frames or settings since he pressed, and
    /// the reel will not have them. Said, rather than found out from the reel.
    public var frozenChanged: Bool {
        guard waitingHere, let w = wait else { return false }
        var now = request
        now["exports"] = nil
        return now != w.request
    }

    /// The body of `/api/reel`, through the step's runner.
    func post(_ values: [String: JSONValue]) {
        added = nil
        cutPending = true
        sendReel(self, values)
    }

    func postReel(_ values: [String: JSONValue]) {
        var body = values
        body["name"] = .string(session.name)
        let jobs = self.jobs
        let c = client
        let b = ReelBody(body)
        reelJob.run {
            await jobs.start {
                let r = try await c.post(Routes.reel, b)
                if let e = r.error, !r.ok { throw StudioError.refused(e) }
            }
        }
    }

    public func addToTheList() {
        let q = queue
        let name = session.name
        var options = request
        // Cut Now, added rather than started: the reel he froze, and the wait
        // is over because the list will cut it.
        if waitingHere, let w = wait {
            options = w.request
            stopWaiting()
        }
        Task { @MainActor in
            if let item = await q.add(kind: "reel", shoot: name, options: options) {
                self.added = Strings.Queue.added(item.what)
            } else {
                self.added = nil
            }
        }
    }

    /// The shoot's own preset beside every frame of the burst he has not
    /// edited, PhotoLab opened on it, and then a wait for his exports that
    /// cuts the reel when they stop arriving.
    ///
    /// The count the wait starts from is read from the engine at the press,
    /// over every folder the watch walks. It is not the lister's `exported`:
    /// with "Pictures from" set to one folder that counts only that folder,
    /// and a wait started from it saw the burst's exports elsewhere as new and
    /// cut a draft about twelve seconds after the press.
    @discardableResult
    public func finishInPhotoLab() -> Task<Void, Never>? {
        guard let b = chosenBurst, spreadJob.phase == .idle else { return nil }
        waitNote = nil
        let name = session.name
        let burst = b.burst
        let target = b.frames
        // Frozen now: what he sees as he presses is what is cut, however he
        // browses while PhotoLab exports. From the exports wherever they
        // land, because PhotoLab writes wherever it was last pointed.
        var frozen = request
        frozen["exports"] = nil
        stopWaiting()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let base = await self.countExports(name, burst) else {
                self.waitNote = Strings.API.offline
                return
            }
            guard !Task.isCancelled else { return }
            self.wait = ReelWait(burst: burst, baseline: base, target: target, request: frozen, ready: false)
            self.startSpread(self, burst)
            self.watchSpread(burst)
        }
        waitTask = task
        return task
    }

    /// The POST, through the step's runner so it waits its turn behind a job
    /// of his that is running. A refusal lands on the job's refusal row, and
    /// then there is nothing to wait for.
    func postSpread(_ burst: String) {
        let jobs = self.jobs
        let c = client
        let body = SpreadBody(name: session.name, burst: burst)
        spreadJob.run { [weak self] in
            await jobs.start {
                let r = try await c.post(Routes.spread, body)
                if let e = r.error, !r.ok { throw StudioError.refused(e) }
            }
            if jobs.refusals[.job] != nil, let self, self.wait?.burst == burst, self.wait?.ready == false {
                self.stopWaiting()
            }
        }
    }

    /// Waits for the spread to end, from the job poll, whether or not the
    /// page is on screen, then watches the count.
    private func watchSpread(_ burst: String) {
        let name = session.name
        waitTask = Task { @MainActor [weak self] in
            var sawRunning = false
            while !Task.isCancelled {
                guard let self, let w = self.wait, w.burst == burst, !w.ready else { return }
                if let j = self.jobs.job, j.kind == "spread", j.shoot.isEmpty || j.shoot == name {
                    if j.running {
                        sawRunning = true
                    } else if sawRunning {
                        self.spreadEnded(j)
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// The spread has ended. Done: the wait starts watching the count.
    /// Anything else: there is nothing of his to wait for, and the page says
    /// why rather than waiting for ever.
    public func spreadEnded(_ j: Job) {
        guard var w = wait, !w.ready else { return }
        switch j.outcome {
        case .done:
            w.begin()
            wait = w
            pollExports(w.burst)
        case .refused:
            stopWaiting()
            waitNote = "\(Strings.Step.refusedNote): \(j.refusalSentence ?? "")"
        case .stopped:
            stopWaiting()
            waitNote = Strings.Step.stoppedNote
        case .failed:
            stopWaiting()
            waitNote = Strings.Reels.spreadFailed
        case .idle, .running:
            return
        }
    }

    /// For the snapshot harness and tests: wait from here, to cut what the
    /// page shows now unless told otherwise.
    public func startWaiting(burst b: String, baseline: Int, target: Int? = nil,
                             request: [String: JSONValue]? = nil) {
        var frozen = request ?? self.request
        if request == nil { frozen["exports"] = nil }
        stopWaiting()
        waitNote = nil
        wait = ReelWait(burst: b, baseline: baseline, target: target, request: frozen)
        pollExports(b)
    }

    /// The same shoot opened afresh replaced this page's model: a wait that
    /// was already watching the count goes on in the new one rather than
    /// ending without a word. One still writing presets cannot follow its
    /// job across, and says it stopped.
    func takeWait(from old: ReelsModel) {
        guard let w = old.wait else { return }
        old.stopWaiting()
        if w.ready {
            wait = w
            pollExports(w.burst)
        } else {
            waitNote = Strings.Reels.waitLost(w.burst)
        }
    }

    /// Watches the count until the reel is cut, he stops waiting, or the app
    /// quits — more slowly the longer nothing new comes (`ReelWait.slowing`).
    private func pollExports(_ b: String) {
        let name = session.name
        waitTask?.cancel()
        waitTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: interval * (self?.wait?.slowing ?? 1))
                guard let self, var w = self.wait, w.burst == b, !Task.isCancelled else { return }
                guard let n = await self.countExports(name, b), !Task.isCancelled else { continue }
                let go = w.saw(n)
                self.wait = w
                if go {
                    await self.cutWhenExported(w)
                    return
                }
            }
        }
    }

    public func stopWaiting() {
        waitTask?.cancel()
        waitTask = nil
        // What came in while it waited is not in the answers kept so far.
        if wait != nil { forget() }
        wait = nil
    }

    /// The exports are all there, or stopped arriving: cut the reel with
    /// what he had chosen when he pressed (`ReelWait.request`), whatever the
    /// page shows now. The page is not moved to the burst: he may be looking
    /// at another one. The burst is read again only when he named frames, to
    /// drop one that is no longer there.
    private func cutWhenExported(_ w: ReelWait) async {
        var body = w.request
        if case .array(let named)? = body["frames"] {
            if let o = try? await fetchOptions(session.name, w.burst, nil) {
                let there = Set(o.frames.filter(\.visible).map(\.stem))
                body["frames"] = .array(named.filter { if case .string(let s) = $0 { there.contains(s) } else { false } })
            }
            // Stop Waiting, or another burst sent to PhotoLab, while that was
            // read: nothing is cut, and the new wait is not his to clear.
            guard !Task.isCancelled else { return }
        }
        wait = nil
        waitTask = nil
        if case .array(let named)? = body["frames"], named.count < ReelWait.least {
            waitNote = Strings.Reels.needThree
            return
        }
        post(body)
    }

    /// Asks the engine to show the reels folder. A button that says it will
    /// show a folder never creates one (§7.10): with nothing cut yet the
    /// engine says there is nothing to show, and that sentence is printed.
    public func showFolder() {
        note = nil
        let c = client
        let body = OpenBody(name: session.name, what: "reels")
        Task { @MainActor in
            do {
                let r = try await c.post(Routes.open, body)
                if let e = r.error, !r.ok { self.note = e }
            } catch let e as StudioError {
                self.note = e.sentence
            } catch {
                self.note = Strings.API.offline
            }
        }
    }

    // MARK: - keeping up with the engine

    /// The page came on screen. Coming back to it asks the lister again: a
    /// reel cut from the list or by the wait while he was elsewhere, and the
    /// frames he exported in PhotoLab meanwhile, are not in what it said last.
    public func appeared() {
        followTheLightTable()
        load(force: options != nil)
        observeJobs()
    }

    /// Arriving from Choose Keepers: the burst he was just on there, asked
    /// about in the lister's first answer, so a reel of "this burst" is one
    /// key and not a search, a click and three answers. Only a burst he has
    /// moved to on the light table since the page last took one: coming back
    /// without moving there keeps the burst he chose here. One the lister
    /// does not offer (fewer than three frames) is let go for its first pick,
    /// as a remembered one is (`adopt`).
    func followTheLightTable() {
        guard !pinned, let b = lightTableBurst(), b != tookFromLightTable else { return }
        tookFromLightTable = b
        guard b != burst else { return }
        burst = b
        cursor = nil
    }

    /// Notice a reel ending, so the preview shows the one just cut and the
    /// shoot's count moves.
    public func observeJobs() {
        guard !pinned else { return }
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: StepsModel.watchInterval(self?.jobs.job))
                guard let self else { return }
                self.noticeJobChange()
            }
        }
    }

    public func stopObserving() {
        pollTask?.cancel()
        pollTask = nil
        // Leaving the page drops a spread still queued behind another job
        // (the runner's rule), and a wait for presets that will now never be
        // written would say "Writing the presets" for ever.
        if spreadJob.isQueued, wait?.ready == false { stopWaiting() }
        reelJob.teardown()
        spreadJob.teardown()
    }

    private func noticeJobChange() {
        guard let j = jobs.job else { return }
        let id = "\(j.kind)/\(j.shoot)/\(j.running)/\(j.elapsed)/\(j.code.map(String.init) ?? "-")"
        guard id != lastJobID else { return }
        lastJobID = id
        guard !j.running, j.shoot.isEmpty || j.shoot == session.name else { return }
        ended(j)
    }

    /// A job of this shoot's has ended.
    func ended(_ j: Job) {
        for runner in [reelJob, spreadJob] where runner.kinds.contains(j.kind) {
            runner.noteEnded(j)
        }
        if j.kind == "spread" { forget() }
        guard j.kind == "reel" else { return }
        if j.outcome == .done, cutPending { reelsCut += 1 }
        cutPending = false
        if j.outcome == .done {
            load(force: true)
            Task { try? await self.session.reload(ext: nil) }
        }
    }
}

/// One `ReelsModel` per shoot, for as long as the app is open, and what they
/// remember across a relaunch (`ReelsMemory`).
@MainActor
public final class ReelsModelStore {
    public static let shared = ReelsModelStore()
    private var models: [String: ReelsModel] = [:]
    /// The snapshot harness sets `.none`, so no render is drawn from another.
    public var memory: ReelsMemory

    public init(memory: ReelsMemory = .shared) {
        self.memory = memory
    }

    public func model(for session: ShootSession, jobs: JobModel) -> ReelsModel {
        // A wait on PhotoLab belongs to its shoot and goes on while he looks
        // at another shoot's reels: each polls one burst, and ending it
        // quietly meant his export in PhotoLab cut nothing. A model replaced
        // because the shoot was opened afresh hands its wait to the new one.
        if let m = models[session.name], m.session === session { return m }
        let m = ReelsModel(session: session, jobs: jobs)
        if let old = models[session.name] {
            old.stopObserving()
            m.takeWait(from: old)
            m.copyChoices(from: old)
        } else {
            m.restore(from: memory)
        }
        m.remember(in: memory)
        models[session.name] = m
        return m
    }

    /// The model the page made, without making one: Shoot ▸ Cut a Reel asks
    /// whether there is something to cut, and asking must change nothing.
    public func existing(for session: ShootSession) -> ReelsModel? {
        models[session.name].flatMap { $0.session === session ? $0 : nil }
    }

    /// For tests and the snapshot harness.
    public func reset() {
        for m in models.values { m.stopObserving(); m.stopWaiting() }
        models.removeAll()
    }
}
