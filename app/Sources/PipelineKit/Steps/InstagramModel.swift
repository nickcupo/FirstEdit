import Foundation
import Observation

/// His tick on a photograph. No entry is unmarked.
public enum InstagramMark: String, Sendable, Equatable {
    case include, leaveOut
}

/// Where working out the cuts stands (DESIGN.md §2.17). Derived from what the
/// engine and the job poll say, never stored.
public enum InstagramPlanPhase: Equatable, Sendable {
    /// Every cut is worked out.
    case none
    /// A pass is working them out now: the engine's words and how far.
    case running(label: String, fraction: Double)
    /// A job of his holds the slot; the cuts are worked out when it is done.
    case waiting(String)
    /// He stopped the pass. Nothing asks again until he says so.
    case stopped
    /// The pass failed, with its last line.
    case failed(String)
    /// Cuts are missing and nothing is working them out: the step asks.
    case wanted
}

/// How the last pass of this shoot ended, when that is something to keep
/// saying.
public enum InstagramPlanOutcome: Equatable, Sendable {
    case none, stoppedByHim, failed(String)
}

/// The editor open on one photograph: the draft of its cut.
public struct InstagramEditorState: Equatable, Sendable {
    public var stem: String
    public var view: InstagramEditorView
    /// "crop" or "whole", as the draft has it.
    public var mode: String
    /// The window drawn: the engine's until he moves it, then `windowOf`
    /// of `manual`, exactly as the engine will keep it.
    public var rect: PixelRect
    /// His window, as the draft has it. Kept across Whole and back.
    public var manual: InstagramManual?
    /// Automatic was pressed: saved as `auto`, which takes his window away.
    public var automatic: Bool
    public var dirty: Bool
}

/// One thing undo can take back.
public enum InstagramChange: Equatable, Sendable {
    case mark(stem: String, before: InstagramMark?, after: InstagramMark?)
    case cut(stem: String, before: InstagramCutRecord, after: InstagramCutRecord)

    public var stem: String {
        switch self {
        case .mark(let s, _, _), .cut(let s, _, _): return s
        }
    }
}

/// Everything the Instagram step knows about one shoot (DESIGN.md §2.17).
///
/// One wall of the shoot's exported photographs, each with its cut drawn on
/// it. The cuts are worked out in the background the moment the step opens
/// (`maybeAsk`), a tick chooses what is made, and one primary makes exactly
/// the cuts shown (`makeSet`).
@MainActor @Observable
public final class InstagramModel {
    public let session: ShootSession
    public let jobs: JobModel
    public let client: StudioClient

    public static let planKind = "instagram-plan"
    public static let makeKind = "instagram"

    // What the engine said.
    public private(set) var status: InstagramStatus?
    /// Every frame, by stem, as the tiles draw them: the engine's answer, and
    /// a cut he has just saved before its answer is back.
    public private(set) var frames: [String: InstagramFrame] = [:]
    /// Stems in wall order. The engine's order at load and when a pass ends;
    /// otherwise it stays put, so a tile never moves under his eyes.
    public private(set) var order: [String] = []
    public private(set) var loadError: String?
    public private(set) var loaded = false

    // What he chose. Kept for the app session, per shoot.
    public fileprivate(set) var marks: [String: InstagramMark] = [:]
    /// The tile the keys are on.
    public var ring: String?
    /// A key has moved the ring, so it is drawn.
    public private(set) var ringShown = false
    /// Asks the wall to scroll a tile into view; bumped on each ask.
    public private(set) var revealRequests = 0
    /// The tile Full Keyboard Access has put its focus on, if any.
    public var keyFocus: String?
    /// How many tiles a row of the wall holds, from the wall's own width.
    public var columns = 3
    public private(set) var editor: InstagramEditorState?

    public private(set) var undoStack: [InstagramChange] = []
    public private(set) var redoStack: [InstagramChange] = []

    // Work.
    public let makeJob: StepJobRunner
    public private(set) var lastAsk: Date?
    public private(set) var asking = false
    public private(set) var planOutcome: InstagramPlanOutcome = .none
    /// His job the engine named when it was asked to work out the cuts.
    public private(set) var planWaitingFor: String?
    /// The line after he added the copies to Up Next.
    public var added: String?
    /// A sentence from something that is not the job: the folder, a save.
    public var note: String?
    /// The last save of a cut, said in the editor: which photograph and what.
    public private(set) var saved: (stem: String, text: String, failed: Bool)?
    /// The shape picker's refusal, beside the pickers.
    public private(set) var shapeRefusal: String?
    /// A shape asked for and not yet answered, drawn in the picker meanwhile.
    public private(set) var pendingRatio: String?
    public private(set) var pendingLandscape: String?

    /// For the snapshot harness and tests: the answer was handed in and
    /// nothing is asked of an engine.
    public private(set) var pinned = false
    @ObservationIgnored private var onScreen = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastJobKey: String?
    @ObservationIgnored private var lastLoad: Date?
    @ObservationIgnored private var loadNumber = 0
    /// A load that would have taken the engine's order was overtaken by a
    /// later one, which takes it instead.
    @ObservationIgnored private var resortOwed = false
    /// Saves of a stem on their way, so a load answered meanwhile does not
    /// put the old cut back on the tile.
    @ObservationIgnored private var inFlight: [String: Int] = [:]

    // Seams.
    @ObservationIgnored var fetch: @MainActor (String) async throws -> InstagramStatus
    @ObservationIgnored var askPlan: @MainActor (String) async throws -> InstagramPlanAnswer
    @ObservationIgnored var sendCrop: @MainActor (InstagramCropBody) async throws -> InstagramCropAnswer
    @ObservationIgnored var sendShape: @MainActor (InstagramShapeBody) async throws -> InstagramStatus
    @ObservationIgnored var sendMake: @MainActor (InstagramModel, [String]) -> Void = { m, stems in m.postMake(stems) }
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    /// Tests turn the half-second look off and call `tick()` themselves.
    @ObservationIgnored var ticksByItself = true

    /// Between two asks to work out the cuts.
    nonisolated static let askPause: TimeInterval = 5
    /// Between two reads of the wall while something is being worked out or made.
    nonisolated static let pollPause: TimeInterval = 1.5
    /// One press of a ⇧-arrow moves the cut this share of the frame.
    nonisolated static let nudgeStep = 0.005
    /// One press of − or = sizes the cut by this.
    nonisolated static let sizeStep = 1.04

    public init(session: ShootSession, jobs: JobModel) {
        self.session = session
        self.jobs = jobs
        self.client = session.client
        makeJob = StepJobRunner(kinds: [Self.makeKind], shoot: session.name, jobs: jobs)
        let c = session.client
        fetch = { name in try await c.get(Routes.instagram(name)) }
        askPlan = { name in try await c.post(Routes.instagramPlan, InstagramPlanBody(name: name)) }
        sendCrop = { body in try await c.post(Routes.instagramCrop, body) }
        sendShape = { body in try await c.post(Routes.instagramShape, body) }
        makeJob.list = { [weak self] in self?.queue }
    }

    public var name: String { session.name }
    public var queue: QueueModel { Queues.model(client: client) }
    public var wouldWait: Bool { queue.wouldWait }
    public var place: InstagramPlace { editor == nil ? .wall : .editor }

    // MARK: - reading

    public var ratio: String { pendingRatio ?? status?.ratio ?? "3:4" }
    public var landscape: String { pendingLandscape ?? status?.landscape ?? "fit" }
    public var want: Double { InstagramWindow.want(status?.ratio ?? "3:4") }

    /// The frames in wall order.
    public var wall: [InstagramFrame] { order.compactMap { frames[$0] } }

    public var exportedCount: Int { frames.count }
    public var plannedCount: Int { frames.values.filter(\.isPlanned).count }
    /// Unplanned and exported again: what a pass would look at.
    public var unplannedCount: Int { frames.values.filter { !$0.isPlanned }.count }
    public var madeCount: Int { frames.values.filter(\.made).count }
    public var gridMisses: Int { frames.values.filter(\.gridMiss).count }

    public func mark(_ stem: String) -> InstagramMark? { marks[stem] }
    public var anyIncluded: Bool { marks.values.contains(.include) }
    public var leftOutCount: Int { order.filter { marks[$0] == .leaveOut }.count }

    /// What he chose: the ones he included if he included any, otherwise
    /// every one he did not leave out. Nothing ticked means all of them.
    public var chosen: [String] {
        let included = order.filter { marks[$0] == .include }
        return included.isEmpty ? order.filter { marks[$0] != .leaveOut } : included
    }

    /// Exactly what Make writes: what he chose, whose cut is on screen, and
    /// whose copy is not already that cut (DESIGN.md §2.17, §7.14). A frame
    /// exported again or not worked out yet is never sent — its cut is not
    /// the one on screen.
    public var makeSet: [String] {
        chosen.filter { s in
            guard let f = frames[s] else { return false }
            return f.isPlanned && !f.copy_current
        }
    }

    /// Chosen, and already made exactly as shown.
    public var chosenCurrent: Int { chosen.filter { frames[$0]?.copy_current == true && frames[$0]?.isPlanned == true }.count }
    /// Chosen, and still being worked out.
    public var chosenUnplanned: Int { chosen.filter { frames[$0]?.isPlanned == false }.count }

    public var makeWord: String { Strings.Instagram.make(makeSet.count) }

    /// The line beside the primary: what it makes, or why it makes nothing.
    public var makeLine: String? {
        guard let status, loadError == nil else { return nil }
        if status.frames.isEmpty { return Strings.Instagram.nothingExported(editorName) }
        let n = makeSet.count
        guard n > 0 else {
            if chosen.isEmpty { return Strings.Instagram.allLeftOut }
            if chosenUnplanned > 0 { return beingWorkedOut ? Strings.Instagram.stillWorking : Strings.Instagram.notWorkedOutYet }
            return Strings.Instagram.allMade(chosenCurrent)
        }
        var parts: [String]
        if anyIncluded {
            parts = [Strings.Instagram.makesIncluded(n)]
        } else if leftOutCount > 0 {
            parts = [Strings.Instagram.makesAllBut(n, leftOut: leftOutCount)]
        } else {
            parts = [Strings.Instagram.makesNotMade(n)]
        }
        if chosenCurrent > 0 { parts.append(Strings.Instagram.alreadyMade(chosenCurrent)) }
        if chosenUnplanned > 0 {
            parts.append(beingWorkedOut ? Strings.Instagram.notIncludedYet(chosenUnplanned)
                                        : Strings.Instagram.notWorkedOutNotIncluded(chosenUnplanned))
        }
        return parts.joined(separator: " ")
    }

    /// Whether anything is working the cuts out, or about to: "still being
    /// worked out" is said only then. After a Stop, a failure, or while his
    /// own job holds the slot, nothing is.
    var beingWorkedOut: Bool {
        switch plan {
        case .running, .wanted: return true
        case .none, .waiting, .stopped, .failed: return false
        }
    }

    /// The editor the shoot is edited in, for "export from PhotoLab first".
    public var editorName: String {
        Editors.name(session.info.editor.isEmpty ? StepsModel.defaultEditor(.shared) : session.info.editor)
    }

    // MARK: - working out the cuts

    /// The pass working out this shoot's cuts, while one runs: the job poll's
    /// word first, which moves every second, then the wall's.
    public var runningPlan: (label: String, fraction: Double)? {
        if let j = jobs.job, j.kind == Self.planKind, j.shoot == name {
            if j.running {
                let label = !j.label.isEmpty ? j.label : (status?.planning?.label ?? j.title)
                return (label, j.fraction)
            }
            // It has ended, and the wall read before it did still says so.
            if let p = status?.planning, p.id == j.id || p.id == 0 { return nil }
        }
        if let p = status?.planning { return (p.label, p.fraction) }
        return nil
    }

    /// A job of his holding the slot.
    var hisJob: Job? {
        guard let j = jobs.job, j.running, !j.background else { return nil }
        return j
    }

    public var plan: InstagramPlanPhase {
        if let p = runningPlan { return .running(label: p.label, fraction: p.fraction) }
        guard status != nil, unplannedCount > 0 else { return .none }
        if case .failed(let line) = planOutcome { return .failed(line) }
        if let his = hisJob { return .waiting(his.title) }
        if let w = planWaitingFor { return .waiting(w) }
        if jobs.job == nil, let w = status?.waiting_for { return .waiting(w.title) }
        if planOutcome == .stoppedByHim { return .stopped }
        return .wanted
    }

    /// Whether the step asks the engine to work out the cuts now: they are
    /// wanted, nothing is asking, no copies of this shoot are being made,
    /// and the last ask was more than five seconds ago.
    var shouldAsk: Bool {
        guard !pinned, onScreen, !asking, plan == .wanted else { return false }
        switch makeJob.phase {
        case .running, .starting, .stopping: return false
        default: break
        }
        if let last = lastAsk, now().timeIntervalSince(last) < Self.askPause { return false }
        return true
    }

    func maybeAsk() {
        guard shouldAsk else { return }
        ask()
    }

    /// POST /api/instagram/plan. The engine starts a pass in the background,
    /// or says why not.
    func ask() {
        asking = true
        lastAsk = now()
        let name = self.name
        let ask = askPlan
        Task { @MainActor in
            defer { self.asking = false }
            do {
                let a = try await ask(name)
                if let e = a.error, !a.ok {
                    self.planOutcome = .failed(e)
                    return
                }
                if a.planning {
                    self.planWaitingFor = nil
                    self.jobs.watch()
                    self.load()
                } else if let w = a.waiting_for {
                    self.planWaitingFor = w.title
                    self.jobs.keepWatching()
                } else if a.nothing {
                    self.load()
                }
            } catch let e as StudioError {
                switch e {
                case .offline, .engineDown: break      // asked again in five seconds
                default: self.planOutcome = .failed(e.sentence)
                }
            } catch {}
        }
    }

    /// Work Out the Rest, after he stopped the pass; Try Again, after one
    /// failed. Both ask at once.
    public func askAgain() {
        planOutcome = .none
        planWaitingFor = nil
        lastAsk = nil
        maybeAsk()
    }

    // MARK: - keeping up

    /// The step came on screen.
    public func appeared() {
        onScreen = true
        load(resort: true)
        observe()
    }

    /// The step went away. A pass that is running goes on: it is harmless,
    /// and its cuts are kept.
    public func disappeared() {
        if editor != nil { closeEditor() }
        onScreen = false
        pollTask?.cancel()
        pollTask = nil
        makeJob.teardown()
    }

    func observe() {
        guard !pinned, ticksByItself else { return }
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// One look at the job slot and the wall: what the step does every half
    /// second while it is on screen.
    func tick() {
        noticeJobChange()
        if planWaitingFor != nil, let j = jobs.job, !j.running || j.background { planWaitingFor = nil }
        maybeAsk()
        let busy: Bool
        if case .running = plan { busy = true } else { busy = makeJob.mine != nil }
        if busy, lastLoad.map({ now().timeIntervalSince($0) >= Self.pollPause }) ?? true { load() }
    }

    func noticeJobChange() {
        guard let j = jobs.job else { return }
        let key = "\(j.id)/\(j.kind)/\(j.shoot)/\(j.running)/\(j.stopped)/\(j.code.map(String.init) ?? "-")"
        guard key != lastJobKey else { return }
        lastJobKey = key
        guard j.shoot == name, !j.running else { return }
        ended(j)
    }

    /// A job of this shoot's has ended.
    func ended(_ j: Job) {
        switch j.kind {
        case Self.planKind:
            switch j.outcome {
            case .stopped:
                // Stopped by his Stop is his; stood down by the engine for a
                // press of his - Make, a shape, something off Up Next - is
                // not, and the rest is asked for again once the slot is free.
                // The engine says which (`stood_down`). A shape change starts
                // the pass again itself, and a pass read as his Stop there
                // said "Stopped." and never worked out the rest.
                if j.stoodDown {
                    planOutcome = .none
                } else {
                    switch makeJob.phase {
                    case .running, .starting: break
                    default: planOutcome = .stoppedByHim
                    }
                }
            case .failed, .refused:
                planOutcome = .failed(j.refusalSentence ?? Strings.Instagram.planFailed)
            case .done:
                planOutcome = .none
            case .idle, .running:
                break
            }
            load(resort: true)
        case Self.makeKind:
            makeJob.noteEnded(j)
            load()
            Task { try? await self.session.reload(ext: nil) }
        default:
            break
        }
    }

    public func load(resort: Bool = false) {
        guard !pinned else { return }
        loadNumber += 1
        let n = loadNumber
        if resort { resortOwed = true }
        lastLoad = now()
        let name = self.name
        let fetch = self.fetch
        Task { @MainActor in
            do {
                let s = try await fetch(name)
                guard n == self.loadNumber else { return }
                self.adopt(s, resort: self.resortOwed || self.order.isEmpty)
                self.resortOwed = false
                self.loadError = nil
            } catch let e as StudioError {
                guard n == self.loadNumber else { return }
                self.loadError = e.sentence
            } catch {
                guard n == self.loadNumber else { return }
                self.loadError = Strings.API.offline
            }
            self.loaded = true
            self.maybeAsk()
        }
    }

    /// The engine's answer, taken. With `resort` the wall takes the engine's
    /// order; otherwise every tile keeps its place, stems the answer adds go
    /// at the end in the engine's order, and stems it drops go.
    func adopt(_ s: InstagramStatus, resort wanted: Bool) {
        // A pass that ended while the job poll was not watching — it was
        // running when the step opened — is seen here, by the wall's own
        // word for it going away: the wall takes the engine's order once.
        let passEnded = status?.planning != nil && s.planning == nil
        let resort = wanted || passEnded
        // One is running: the job poll watches it, so its end is heard.
        if s.planning != nil, !pinned { jobs.keepWatching() }
        status = s
        pendingRatio = nil
        pendingLandscape = nil
        var byStem: [String: InstagramFrame] = [:]
        for f in s.frames { byStem[f.stem] = f }
        for (stem, n) in inFlight where n > 0 {
            if let mine = frames[stem], byStem[stem] != nil { byStem[stem] = mine }
        }
        frames = byStem
        let engine = s.frames.map(\.stem)
        if resort || order.isEmpty {
            // The wall takes the engine's order, the grid misses to the front.
            // The ring stays on its photograph, and the wall follows it there:
            // a pass ending while he keyed through the tiles moved the ringed
            // one out of sight with nothing scrolling after it.
            let moved = order != engine
            order = engine
            if moved, ringShown, let r = ring, byStem[r] != nil { revealRequests += 1 }
        } else {
            var kept = order.filter { byStem[$0] != nil }
            let known = Set(kept)
            kept += engine.filter { !known.contains($0) }
            order = kept
        }
        if let r = ring, byStem[r] == nil { ring = nil }
        if let e = editor, byStem[e.stem] == nil { editor = nil }
    }

    // MARK: - choosing

    /// A click on a tile's box: included, or back to unmarked.
    public func toggleInclude(_ stem: String) {
        set(stem, marks[stem] == .include ? nil : .include)
    }

    public func set(_ stem: String, _ m: InstagramMark?) {
        guard frames[stem] != nil else { return }
        let before = marks[stem]
        guard before != m else { return }
        marks[stem] = m
        undoStack.append(.mark(stem: stem, before: before, after: m))
        redoStack.removeAll()
    }

    // MARK: - the keys

    /// A key press from the step's one monitor. Whether it was taken.
    public func key(_ p: KeyMap.Press) -> Bool {
        guard let m = InstagramKeys.action(p, place) else {
            return false
        }
        // Keepers' rule: a held key that is not movement is one press, and
        // its repeats are taken and do nothing.
        if p.isARepeat && !InstagramKeys.allowsRepeat(p, place) {
            return true
        }
        perform(m)
        return true
    }

    /// Whether a meaning would do something now: what a menu row greys on.
    public func canPerform(_ m: InstagramMeaning) -> Bool {
        let hasFrame = editor != nil || !order.isEmpty
        switch m {
        case .include, .leaveOut, .clear, .next, .previous: return hasFrame
        case .open: return editor != nil || !order.isEmpty
        case .oneToOne, .fit: return editor != nil
        case .undo: return editor?.dirty == true || !undoStack.isEmpty
        case .redo: return editor?.dirty != true && !redoStack.isEmpty
        default: return true
        }
    }

    public func perform(_ m: InstagramMeaning) {
        if editor != nil { performInEditor(m); return }
        switch m {
        case .next: moveRing(by: 1)
        case .previous: moveRing(by: -1)
        case .rowDown: moveRing(by: columns)
        case .rowUp: moveRing(by: -columns)
        case .include, .leaveOut:
            guard let s = ringed else { return }
            set(s, m == .include ? .include : .leaveOut)
            ring = s
            moveRing(by: 1)
        case .clear:
            guard let s = ringed else { return }
            set(s, nil)
            ring = s
            showRing()
        case .open(let v):
            guard let s = ringed else { return }
            open(s, view: v)
        case .undo: undo()
        case .redo: redo()
        case .shortcuts: _ = CommandCenter.shared.run(CommandTable.ID.shortcuts)
        case .nothing, .close, .toggleOneToOne, .oneToOne, .fit, .nudge, .automatic, .cutOrWhole,
             .result, .smaller, .larger:
            break
        }
    }

    /// The tile the keys act on: the ringed one, or the first.
    var ringed: String? {
        if let r = ring, frames[r] != nil { return r }
        return order.first
    }

    func moveRing(by delta: Int) {
        guard !order.isEmpty else { return }
        if let r = ring, let i = order.firstIndex(of: r) {
            ring = order[min(max(0, i + delta), order.count - 1)]
        } else {
            ring = order.first
        }
        showRing()
    }

    func showRing() {
        ringShown = true
        revealRequests += 1
    }

    // MARK: - the editor

    /// A click on a tile, Space, Z, or Return on a tile he tabbed to.
    public func open(_ stem: String, view: InstagramEditorView = .fit) {
        guard let f = frames[stem] else { return }
        ring = stem
        editor = Self.draft(for: f, view: view)
    }

    static func draft(for f: InstagramFrame, view: InstagramEditorView) -> InstagramEditorState {
        let mode = f.mode ?? "crop"
        let rect = f.cut?.rect ?? PixelRect(0, 0, f.frame?.w ?? 1, f.frame?.h ?? 1)
        return InstagramEditorState(stem: f.stem, view: view, mode: mode, rect: rect, manual: f.manual,
                                    automatic: false, dirty: false)
    }

    /// Done, Esc, Space: the cut saved, and back to the wall with the keys
    /// on the photograph he was looking at.
    public func closeEditor() {
        guard let e = editor else { return }
        saveEditor()
        editor = nil
        ring = e.stem
        showRing()
    }

    /// The frame the editor is open on.
    public var editing: InstagramFrame? { editor.flatMap { frames[$0.stem] } }

    /// Whether the cut of the frame on screen can be changed: it is worked
    /// out, from the export that is there now.
    public var canEdit: Bool { editing?.isPlanned == true }

    /// Its place in the wall, for "3 of 40".
    public var editorPosition: (index: Int, count: Int)? {
        guard let e = editor, let i = order.firstIndex(of: e.stem) else { return nil }
        return (i + 1, order.count)
    }

    func performInEditor(_ m: InstagramMeaning) {
        guard var e = editor else { return }
        switch m {
        case .next: go(by: 1)
        case .previous: go(by: -1)
        case .include, .leaveOut:
            set(e.stem, m == .include ? .include : .leaveOut)
            go(by: 1)
        case .clear: set(e.stem, nil)
        case .close: closeEditor()
        case .toggleOneToOne:
            e.view = e.view == .oneToOne ? .fit : .oneToOne
            editor = e
        case .oneToOne: e.view = .oneToOne; editor = e
        case .fit: e.view = .fit; editor = e
        case .result:
            e.view = e.view == .result ? .fit : .result
            editor = e
        case .nudge(let dx, let dy): nudge(dx: dx, dy: dy)
        case .smaller: resize(by: 1 / Self.sizeStep)
        case .larger: resize(by: Self.sizeStep)
        case .automatic: automatic()
        case .cutOrWhole: cutOrWhole()
        case .undo: undo()
        case .redo: redo()
        case .shortcuts: _ = CommandCenter.shared.run(CommandTable.ID.shortcuts)
        case .open, .rowDown, .rowUp, .nothing: break
        }
    }

    /// The previous or next photograph in the wall's order, the cut saved
    /// first. Stops at the ends.
    public func go(by delta: Int) {
        guard let e = editor, let i = order.firstIndex(of: e.stem) else { return }
        let j = min(max(0, i + delta), order.count - 1)
        guard j != i else { return }
        saveEditor()
        open(order[j], view: e.view)
    }

    /// A scroll over the photograph, at Fit or Result: photograph by
    /// photograph, as a scroll over the fitted frame steps frames in Choose
    /// Keepers (DESIGN.md §2.5.8, §2.17). The steps are Keepers' own
    /// (`ScrollInput.FrameScroll`), read through the same meanings as the
    /// keys, so ⌥'s picks, which mean nothing here, do nothing. At 1:1 a
    /// scroll pans, as it does there.
    public func scrolled(_ steps: [ScrollInput.FrameScroll.Step]) {
        guard let e = editor, e.view != .oneToOne else { return }
        for step in steps {
            guard let m = InstagramKeys.meaning(of: step.action, in: .editor) else { continue }
            perform(m)
        }
    }

    /// His window, as the draft has it now: the one he placed, or the one
    /// drawn, as fractions.
    var draftManual: InstagramManual? {
        guard let e = editor, let size = editing?.frame else { return nil }
        return e.manual ?? InstagramWindow.fromRect(e.rect, w: size.w, h: size.h, want: want)
    }

    /// A window he dragged, nudged or sized: through `windowOf` and back, so
    /// it stays inside the frame exactly as the engine will keep it.
    public func setDraft(_ m: InstagramManual) {
        guard var e = editor, e.mode == "crop", canEdit, let size = editing?.frame else { return }
        let w = want
        let inside = InstagramWindow.windowOf(size, want: w, m)
        let kept = InstagramWindow.kept(InstagramWindow.fromRect(inside, w: size.w, h: size.h, want: w))
        e.manual = kept
        e.rect = InstagramWindow.windowOf(size, want: w, kept)
        e.automatic = false
        e.dirty = true
        editor = e
    }

    public func nudge(dx: Int, dy: Int) {
        guard var m = draftManual else { return }
        m.cx += Double(dx) * Self.nudgeStep
        m.cy += Double(dy) * Self.nudgeStep
        setDraft(m)
    }

    public func resize(by factor: Double) {
        guard var m = draftManual else { return }
        m.scale = min(1, max(InstagramWindow.leastScale, m.scale * factor))
        setDraft(m)
    }

    /// Back to the window the engine worked out.
    public func automatic() {
        guard var e = editor, canEdit, let f = editing else { return }
        e.mode = "crop"
        e.rect = f.auto ?? e.rect
        e.manual = nil
        e.automatic = true
        e.dirty = true
        editor = e
    }

    /// Cut to the shoot's shape, or left whole.
    public func cutOrWhole() {
        setMode(editor?.mode == "whole" ? "crop" : "whole")
    }

    public func setMode(_ mode: String) {
        guard var e = editor, canEdit, let f = editing, let size = f.frame, mode != e.mode else { return }
        e.mode = mode
        if mode == "whole" {
            e.rect = f.whole?.rect ?? PixelRect(0, 0, size.w, size.h)
        } else {
            e.rect = e.manual.map { InstagramWindow.windowOf(size, want: want, $0) } ?? f.auto ?? e.rect
        }
        e.dirty = true
        editor = e
    }

    /// The size the draft is written at.
    public var draftOut: PixelSize? {
        guard let e = editor, let f = editing else { return nil }
        return e.mode == "whole" ? (f.whole?.out ?? f.cut?.out) : InstagramWindow.outSize(want: want)
    }

    /// The faint window of the draft: the other portrait shape while it is
    /// cut, the cut at the shoot's shape while it is whole.
    public var draftOther: PixelRect? {
        guard let e = editor, let f = editing, let size = f.frame else { return nil }
        if e.mode == "whole" {
            if let m = e.manual { return InstagramWindow.windowOf(size, want: want, m) }
            return f.auto
        }
        let other = InstagramWindow.want(InstagramWindow.other(status?.ratio ?? "3:4"))
        if let m = e.manual { return InstagramWindow.windowOf(size, want: other, m) }
        guard let s = f.subject else { return f.other?.rect }
        return InstagramWindow.auto(size, subject: s, want: other)
    }

    /// Whether the draft's subject is inside what the profile grid shows.
    public var draftGridOK: Bool {
        guard let e = editor, let f = editing, let size = f.frame, let s = f.subject, let out = draftOut else {
            return true
        }
        return InstagramWindow.gridOK(subject: s, frame: size, rect: e.rect, out: out)
    }

    /// Saved when he goes to another photograph, closes, or undoes: the tile
    /// takes the draft at once, and the engine's answer replaces it.
    public func saveEditor() {
        guard var e = editor, e.dirty, let f = frames[e.stem], f.isPlanned else { return }
        let was = Self.record(f)
        let body: InstagramCropBody
        let after: InstagramCutRecord
        let by = e.mode != (f.mode ?? "crop") ? "you" : (f.mode_by ?? "run")
        if e.mode == "whole" {
            // Left whole, the faint line is the cut it would have: the
            // window he moved before pressing Whole, or the automatic one
            // after Automatic. That window is kept with it, so the tile's
            // faint line is the one the editor drew.
            if e.automatic {
                body = InstagramCropBody(name: name, stem: e.stem, mode: "whole", auto: true)
                after = InstagramCutRecord(mode: "whole", mode_by: by, manual: nil)
            } else if let m = e.manual, m != f.manual {
                body = InstagramCropBody(name: name, stem: e.stem, mode: "whole", manual: m)
                after = InstagramCutRecord(mode: "whole", mode_by: by, manual: m)
            } else {
                body = InstagramCropBody(name: name, stem: e.stem, mode: "whole")
                after = InstagramCutRecord(mode: "whole", mode_by: by, manual: f.manual)
            }
        } else if e.automatic {
            body = InstagramCropBody(name: name, stem: e.stem, mode: "crop", auto: true)
            after = InstagramCutRecord(mode: "crop", mode_by: by, manual: nil)
        } else if let m = e.manual {
            body = InstagramCropBody(name: name, stem: e.stem, mode: "crop", manual: m)
            after = InstagramCutRecord(mode: "crop", mode_by: by, manual: m)
        } else {
            // Cut, and no window of his placed: the engine's own.
            body = InstagramCropBody(name: name, stem: e.stem, mode: "crop")
            after = InstagramCutRecord(mode: "crop", mode_by: by, manual: nil)
        }
        e.dirty = false
        e.automatic = false
        e.manual = after.manual
        editor = e
        guard after != was else { return }
        let change = InstagramChange.cut(stem: e.stem, before: was, after: after)
        undoStack.append(change)
        redoStack.removeAll()
        send(body, projecting: after, onto: f, change: change)
    }

    /// The cut, sent. The tile shows it before the answer; a refusal puts
    /// the frame back as it was and says why.
    func send(_ body: InstagramCropBody, projecting rec: InstagramCutRecord, onto f: InstagramFrame,
              change: InstagramChange?) {
        let stem = f.stem
        frames[stem] = project(f, rec)
        inFlight[stem, default: 0] += 1
        let crop = sendCrop
        Task { @MainActor in
            defer { self.inFlight[stem, default: 1] -= 1 }
            do {
                let a = try await crop(body)
                if let fr = a.frame, self.inFlight[stem] == 1 { self.frames[stem] = fr }
                if let e = a.error, !a.ok {
                    self.saved = (stem, e, true)
                } else {
                    self.saved = (stem, a.remade ? Strings.Instagram.savedAndMade : Strings.Instagram.savedNotMade, false)
                }
            } catch let e as StudioError {
                self.putBack(f, change: change, why: e.sentence)
            } catch {
                self.putBack(f, change: change, why: Strings.API.offline)
            }
        }
    }

    private func putBack(_ f: InstagramFrame, change: InstagramChange?, why: String) {
        frames[f.stem] = f
        if let change, let i = undoStack.lastIndex(of: change) { undoStack.remove(at: i) }
        saved = (f.stem, why, true)
        if editor == nil { note = why }
        if var e = editor, e.stem == f.stem, !e.dirty {
            e = Self.draft(for: f, view: e.view)
            editor = e
        }
    }

    static func record(_ f: InstagramFrame) -> InstagramCutRecord {
        InstagramCutRecord(mode: f.mode ?? "crop", mode_by: f.mode_by ?? "run", manual: f.manual)
    }

    /// A frame as the engine will describe it once `rec` is saved: the same
    /// arithmetic the engine does, so the tile never waits for the answer.
    func project(_ f: InstagramFrame, _ rec: InstagramCutRecord) -> InstagramFrame {
        guard let size = f.frame else { return f }
        var g = f
        g.mode = rec.mode
        g.mode_by = rec.mode_by
        g.manual = rec.manual
        let ratio = status?.ratio ?? "3:4"
        let w = InstagramWindow.want(ratio)
        let otherRatio = InstagramWindow.other(ratio)
        let wo = InstagramWindow.want(otherRatio)
        let subject = f.subject ?? InstagramSubject(cx: 0.5, cy: 0.5)
        func cut(_ shape: String, _ want: Double) -> InstagramCut {
            // The engine's own automatic window at the shoot's shape, where
            // it sent one; the same arithmetic otherwise.
            let automatic = shape == ratio ? f.auto : nil
            let r = rec.manual.map { InstagramWindow.windowOf(size, want: want, $0) }
                ?? automatic ?? InstagramWindow.auto(size, subject: subject, want: want)
            let out = InstagramWindow.outSize(want: want)
            return InstagramCut(shape: shape, rect: r, out: out,
                                grid_ok: InstagramWindow.gridOK(subject: subject, frame: size, rect: r, out: out),
                                kept: InstagramWindow.kept(r, of: size))
        }
        if rec.mode == "whole" {
            g.cut = f.whole ?? InstagramWindow.whole(size, subject: subject)
            g.other = cut(ratio, w)
            g.adjusted = false
        } else {
            g.cut = cut(ratio, w)
            g.other = cut(otherRatio, wo)
            g.adjusted = rec.manual != nil
        }
        // A copy that is there is made again with the cut the moment it is
        // saved, so it stays the cut shown.
        return g
    }

    // MARK: - undo

    /// ⌘Z, Q or U. With a draft in the editor, the first undo throws the
    /// draft away rather than taking back what was saved before it.
    public func undo() {
        if var e = editor, e.dirty, let f = editing {
            e = Self.draft(for: f, view: e.view)
            editor = e
            return
        }
        guard let c = undoStack.popLast() else { return }
        apply(c, back: true)
        redoStack.append(c)
    }

    /// ⇧⌘Z. Not over a draft: the draft is a change of its own not yet
    /// saved, and a redo taking the editor somewhere else would lose it.
    public func redo() {
        guard editor?.dirty != true, let c = redoStack.popLast() else { return }
        apply(c, back: false)
        undoStack.append(c)
    }

    /// Puts a change back, or does it again, and takes him to the photograph
    /// it is on, as Q does in Choose Keepers: the ring on the wall, or the
    /// editor, open on that photograph. With the editor on another one the
    /// cut used to change out of sight while the editor stayed where it was.
    private func apply(_ c: InstagramChange, back: Bool) {
        switch c {
        case .mark(let stem, let before, let after):
            marks[stem] = back ? before : after
            show(stem)
        case .cut(let stem, let before, let after):
            guard let f = frames[stem] else { return }
            let rec = back ? before : after
            send(InstagramCropBody(name: name, stem: stem, restore: rec), projecting: rec, onto: f, change: nil)
            show(stem)
        }
    }

    /// The photograph a change was on, in front of him: the editor redrawn
    /// on it from what the tile now shows, or the ring on its tile.
    private func show(_ stem: String) {
        if let e = editor {
            if let g = frames[stem] { editor = Self.draft(for: g, view: e.view) }
            ring = stem
        } else {
            ring = stem
            showRing()
        }
    }

    /// What Edit ▸ Undo and Redo say here: "Undo Include 05901".
    public func changeName(_ c: InstagramChange) -> String {
        let short = ShootSession.shortStem(c.stem)
        switch c {
        case .mark(_, _, let after):
            switch after {
            case .include?: return Strings.Instagram.includeNamed(short)
            case .leaveOut?: return Strings.Instagram.leaveOutNamed(short)
            case nil: return Strings.Instagram.clearNamed(short)
            }
        case .cut: return Strings.Instagram.cutNamed(short)
        }
    }

    /// A menu row's title while the step answers it.
    public func rowTitle(_ m: InstagramMeaning) -> String? {
        let stem = editor?.stem ?? ringed
        let short = stem.map(ShootSession.shortStem)
        switch m {
        case .include: return short.map(Strings.Instagram.includeNamed) ?? Strings.Instagram.include
        case .leaveOut: return short.map(Strings.Instagram.leaveOutNamed) ?? Strings.Instagram.leaveOut
        case .clear: return Strings.Instagram.clearTheMark
        case .next: return Strings.Instagram.nextPhotograph
        case .previous: return Strings.Instagram.previousPhotograph
        case .open: return editor == nil ? Strings.Instagram.adjustTheCut : Strings.Instagram.backToThePhotographs
        case .undo:
            if editor?.dirty == true { return Words.Edit.undoNamed(Strings.Instagram.cutNamed(short ?? "")) }
            return undoStack.last.map { Words.Edit.undoNamed(changeName($0)) }
        case .redo: return redoStack.last.map { Words.Edit.redoNamed(changeName($0)) }
        default: return nil
        }
    }

    // MARK: - the shape

    public func choose(ratio r: String) {
        guard r != ratio, InstagramWindow.want(r) > 0 else { return }
        pendingRatio = r
        reshape(InstagramShapeBody(name: name, ratio: r))
    }

    public func choose(landscape l: String) {
        guard l != landscape else { return }
        pendingLandscape = l
        reshape(InstagramShapeBody(name: name, landscape: l))
    }

    private func reshape(_ body: InstagramShapeBody) {
        guard !pinned else { return }
        shapeRefusal = nil
        let send = sendShape
        Task { @MainActor in
            do {
                let s = try await send(body)
                self.adopt(s, resort: false)
                if let e = self.editor, let f = self.frames[e.stem], !e.dirty {
                    self.editor = Self.draft(for: f, view: e.view)
                }
                // A pass stood down for the new shape is started again by
                // the engine in the same request; should it not have been
                // (something of his took the slot first), the step asks.
                self.lastAsk = nil
                self.maybeAsk()
            } catch let e as StudioError {
                self.pendingRatio = nil
                self.pendingLandscape = nil
                self.shapeRefusal = e.sentence
            } catch {
                self.pendingRatio = nil
                self.pendingLandscape = nil
                self.shapeRefusal = Strings.API.offline
            }
        }
    }

    // MARK: - making

    /// Make N Copies: exactly the cuts shown.
    public func make() {
        let stems = makeSet
        guard !stems.isEmpty else { return }
        added = nil
        sendMake(self, stems)
    }

    func postMake(_ stems: [String]) {
        let jobs = self.jobs
        let c = client
        let body = InstagramMakeBody(name: name, stems: stems)
        makeJob.run(orAdd: { [weak self] in self?.addToTheList() }) {
            await jobs.start {
                let r = try await c.post(Routes.instagramMake, body)
                if let e = r.error, !r.ok { throw StudioError.refused(e) }
            }
        }
    }

    /// ⌥, or something of his running: the same copies, on Up Next.
    public func addToTheList() {
        let stems = makeSet
        guard !stems.isEmpty else { return }
        let q = queue
        let name = self.name
        Task { @MainActor in
            if let item = await q.add(kind: Self.makeKind, shoot: name,
                                      options: ["stems": .array(stems.map(JSONValue.string))]) {
                self.added = Strings.Queue.added(item.what)
            } else {
                self.added = nil
            }
        }
    }

    /// Asks the engine to show the copies' folder. It never creates one
    /// (DESIGN.md §7.10).
    public func showFolder() {
        note = nil
        let c = client
        let body = OpenBody(name: name, what: "instagram")
        Task { @MainActor in
            do {
                let r = try await c.post(Routes.open, body)
                if let e = r.error, !r.ok { self.note = e } else if let m = r.missing, !r.ok { self.note = m }
            } catch let e as StudioError {
                self.note = e.sentence
            } catch {
                self.note = Strings.API.offline
            }
        }
    }

    // MARK: - for the snapshot harness and tests

    /// Take this answer as the engine's and ask the engine nothing.
    public func preview(_ s: InstagramStatus) {
        pinned = true
        adopt(s, resort: true)
        loaded = true
    }

    /// Marks, as he might have left them.
    public func previewMarks(_ m: [String: InstagramMark]) { marks = m }

    /// The editor open on a photograph, in a view, optionally with a draft.
    public func previewEditor(_ stem: String, view: InstagramEditorView, draft: InstagramManual? = nil) {
        open(stem, view: view)
        if let draft { setDraft(draft) }
    }

    public func previewRing(_ stem: String) {
        ring = stem
        ringShown = true
    }

    public func previewRefusal(_ s: String) { shapeRefusal = s }

    public func previewPlanOutcome(_ o: InstagramPlanOutcome) { planOutcome = o }
}

extension InstagramWindow {
    /// The window a frame gets of a shape when nobody has placed one: on the
    /// subject, moved just enough to keep every face that fits
    /// (`instagram.auto`). Python's `round` goes to even, and so does this.
    public static func auto(_ size: PixelSize, subject s: InstagramSubject, want: Double) -> PixelRect {
        let w = Double(size.w), h = Double(size.h)
        let faces = s.faces.flatMap { f in f.count == 4 ? (f[0] * w, f[1] * h, f[2] * w, f[3] * h) : nil }
        func place(_ length: Int, _ span: Int, _ centre: Double, _ keep: (Double, Double)?) -> Int {
            var at = centre - Double(span) / 2
            if let k = keep, k.1 - k.0 <= Double(span) { at = min(max(at, k.1 - Double(span)), k.0) }
            return Int(min(max(at, 0), Double(length - span)).rounded(.toNearestOrEven))
        }
        if w / h > want {
            let cw = Int((h * want).rounded(.toNearestOrEven))
            return PixelRect(place(size.w, cw, s.cx * w, faces.map { ($0.0, $0.2) }), 0, cw, size.h)
        }
        let ch = Int((w / want).rounded(.toNearestOrEven))
        return PixelRect(0, place(size.h, ch, s.cy * h, faces.map { ($0.1, $0.3) }), size.w, ch)
    }

    /// The widest a feed post may be, and the tallest.
    public static let widest = 1.91
    public static let tallest = 3.0 / 4.0

    /// A frame left whole, as `instagram.rect` writes it: the frame, or the
    /// tallest or widest post the frame allows, cut around the subject.
    public static func whole(_ size: PixelSize, subject s: InstagramSubject) -> InstagramCut {
        let fr = size.aspect
        let rect: PixelRect, out: PixelSize
        if fr > widest {
            rect = auto(size, subject: s, want: widest)
            out = PixelSize(wide, Int((Double(wide) / widest).rounded(.toNearestOrEven)))
        } else if fr < tallest {
            rect = auto(size, subject: s, want: tallest)
            out = PixelSize(wide, Int((Double(wide) / tallest).rounded(.toNearestOrEven)))
        } else {
            rect = PixelRect(0, 0, size.w, size.h)
            out = PixelSize(wide, Int((Double(wide) / fr).rounded(.toNearestOrEven)))
        }
        return InstagramCut(shape: "whole", rect: rect, out: out,
                            grid_ok: gridOK(subject: s, frame: size, rect: rect, out: out),
                            kept: kept(rect, of: size))
    }
}

/// One `InstagramModel` per shoot, for as long as the app is open: his ticks
/// and the wall's order are there when he comes back to the step.
@MainActor
public final class InstagramModelStore {
    public static let shared = InstagramModelStore()
    private var models: [String: InstagramModel] = [:]

    public init() {}

    public func model(for session: ShootSession, jobs: JobModel) -> InstagramModel {
        if let m = models[session.name], m.session === session { return m }
        let m = InstagramModel(session: session, jobs: jobs)
        if let old = models[session.name] {
            old.disappeared()
            m.marks = old.marks
        }
        models[session.name] = m
        return m
    }

    /// For tests and the snapshot harness.
    public func reset() {
        for m in models.values { m.disappeared() }
        models.removeAll()
    }
}
