import Foundation
import Observation

// MARK: - what this engine can be asked for

/// What the engine on the other end of the socket can actually do.
///
/// DESIGN.md §3.9 is landing in a parallel crew, so both engines have to be
/// talked to. Everything the app needs that is not there yet sits behind this
/// one protocol with two implementations, and the switch is the one line in
/// `StepCapabilities.current`.
///
/// The rule this exists to keep: a control that would do nothing is never
/// drawn as if it would do something. Where a capability is missing, the
/// control is disabled and says why — never a silent no-op.
public protocol EngineCapabilities: Sendable {
    /// `/api/presets` understands a flag for "only the frames he marked".
    var presetsCanLeaveOutAgreed: Bool { get }
    /// `/api/shoot` sends `will_be_edited` and `agreed` (§3.9-4).
    func countsAreTwoAuthored(_ info: ShootInfo) -> Bool
}

/// Today's engine: it writes a preset for every frame with an effective star
/// of three or more, and has no way to be told to leave his agreements out.
public struct LegacyEngine: EngineCapabilities {
    public init() {}
    public var presetsCanLeaveOutAgreed: Bool { false }
    public func countsAreTwoAuthored(_ info: ShootInfo) -> Bool {
        info.will_be_edited != nil && info.agreed != nil
    }
}

/// The engine of §3.9, once the counts crew has landed the presets flag with
/// its two-authored counts.
public struct CurrentEngine: EngineCapabilities {
    public init() {}
    public var presetsCanLeaveOutAgreed: Bool { true }
    public func countsAreTwoAuthored(_ info: ShootInfo) -> Bool {
        info.will_be_edited != nil && info.agreed != nil
    }
}

@MainActor
public enum StepCapabilities {
    /// The one line. Flip it to `CurrentEngine()` when `/api/presets` takes
    /// the flag that leaves his agreements out.
    public static var current: any EngineCapabilities = LegacyEngine()
}

// MARK: - who chose what gets a preset

/// The honest split of DESIGN.md §2.4.
///
/// `willBeEdited` is the number that decides what happens, and it is labelled
/// for what it decides. `kept` is his presses. `agreed` is the cull's picks, in
/// bursts he has been through and did not mark. `notLookedThrough` is the
/// cull's, in bursts he has not opened — the old page's one red clause, which
/// is the only honest thing to say about a frame nobody has seen.
///
/// Nothing here adds two summary fields together. Either the engine sends the
/// three numbers, or every one of them is counted frame by frame.
public struct PresetSplit: Equatable, Sendable {
    public let willBeEdited: Int
    public let kept: Int
    public let agreed: Int
    public let notLookedThrough: Int
    /// True when the engine worked these out, false when they were counted here.
    public let fromEngine: Bool

    public init(willBeEdited: Int, kept: Int, agreed: Int, notLookedThrough: Int, fromEngine: Bool) {
        self.willBeEdited = willBeEdited
        self.kept = kept
        self.agreed = agreed
        self.notLookedThrough = notLookedThrough
        self.fromEngine = fromEngine
    }

    public static let none = PresetSplit(willBeEdited: 0, kept: 0, agreed: 0,
                                         notLookedThrough: 0, fromEngine: false)
}

public protocol PresetSplitSource: Sendable {
    @MainActor func split(_ session: ShootSession) -> PresetSplit
}

/// The engine's own three numbers.
public struct EnginePresetSplit: PresetSplitSource {
    public init() {}
    @MainActor public func split(_ s: ShootSession) -> PresetSplit {
        let i = s.info
        let will = i.will_be_edited ?? 0
        let agreed = min(i.agreed ?? 0, will)
        // The engine's `kept` is his by gather's rule, which counts a pick he
        // left standing in a burst he went through as his too. Those are
        // `agreed`, so they come out of it here rather than being printed
        // twice: "369 you kept · 64 the cull put forward…" under a headline of
        // 369 was a sum no one could make.
        let yours = max(0, min(i.kept, will) - agreed)
        // The remainder is a third group, not a fourth author: frames the cull
        // put forward in bursts nobody has opened. It is stated, never folded
        // into either of the other two, and the three always add up to the
        // headline.
        let rest = max(0, will - yours - agreed)
        return PresetSplit(willBeEdited: will, kept: yours, agreed: agreed,
                           notLookedThrough: rest, fromEngine: true)
    }
}

/// Counted here, frame by frame, from his field and the cull's separately.
public struct DerivedPresetSplit: PresetSplitSource {
    public init() {}
    @MainActor public func split(_ s: ShootSession) -> PresetSplit {
        var seen: Set<String> = []
        for b in s.bursts where b.seen { for f in b.frames { seen.insert(f) } }
        var will = 0, kept = 0, agreed = 0, unseen = 0
        for stem in s.order {
            guard let r = s.rows[stem] else { continue }
            switch VerdictValue.his(r) {
            case .kept:
                will += 1; kept += 1
            case .out:
                continue                       // his word beats the cull's, always
            case .unmarked:
                guard r.rating >= VerdictValue.inThreshold else { continue }
                will += 1
                if seen.contains(stem) { agreed += 1 } else { unseen += 1 }
            }
        }
        return PresetSplit(willBeEdited: will, kept: kept, agreed: agreed,
                           notLookedThrough: unseen, fromEngine: false)
    }
}

/// Whichever of the two this engine can answer.
public struct AutomaticPresetSplit: PresetSplitSource {
    public init() {}
    @MainActor public func split(_ s: ShootSession) -> PresetSplit {
        StepCapabilities.current.countsAreTwoAuthored(s.info) && Self.agreedIsPicks(s.info)
            ? EnginePresetSplit().split(s)
            : DerivedPresetSplit().split(s)
    }

    /// `agreed` is the cull's picks he left standing, which are among the
    /// frames that get a preset and among his by gather's rule, so it is never
    /// more than either. An engine that sends more is counting every frame he
    /// left alone, the old way, and this page counts for itself instead of
    /// printing its number under the wrong words.
    static func agreedIsPicks(_ i: ShootInfo) -> Bool {
        guard let agreed = i.agreed, let will = i.will_be_edited else { return false }
        return agreed <= will && agreed <= i.kept
    }
}

@MainActor
public enum PresetSplits {
    public static var source: any PresetSplitSource = AutomaticPresetSplit()
}

// MARK: - one shoot's step pages

/// Everything the five step pages remember about one shoot.
///
/// It outlives a step change, which is what makes "form state is per step, per
/// shoot, restored on return" (§2.4) true: changing step throws the *view*
/// away and resets its scroll to the top (FLOW-03), and every field he had
/// filled in is still here when he comes back.
@MainActor @Observable
public final class StepsModel {
    public let session: ShootSession
    public let jobs: JobModel
    public let client: StudioClient

    // Copy the Card
    public var card: String = ""
    public var shootName: String = ""
    public var verify: VerifyChoice = .whileCopying
    public var ejectAfter = false
    /// The name of the shoot the last copy on this page made.
    public var copiedShoot: String?
    public var ejectNote: String?

    // Cull
    /// Where the slider's knob is, unrounded, so a drag follows his hand
    /// instead of jumping from notch to notch. What the cull is sent, and what
    /// the page prints, is `focusSetting`.
    public var focus: Double
    public var peopleMove: Bool

    /// The focus the cull runs with: the slider's value to one decimal, the
    /// only precision the engine's number has ever been given in.
    public var focusSetting: Double { Self.roundFocus(focus) }

    public nonisolated static func roundFocus(_ f: Double) -> Double { (f * 10).rounded() / 10 }

    /// The settings his cull waiting on the list was put there with, which
    /// are what it will run with. While it waits the page holds its two
    /// controls still and says so; they showed what the shoot said instead,
    /// which after a relaunch is the last cull started and not this one.
    /// An option the engine did not send leaves that control as it is.
    public func adoptWaiting(_ item: QueueItem) {
        guard item.kind == "cull" else { return }
        if let f = item.options["focus"]?.doubleValue, f > 0 { focus = f }
        if let style = item.options["style"]?.stringValue { peopleMove = style == "action" }
    }
    public var cullAgainAsked = false
    /// Whether the report's "Settings for Cull Again" is open. Shut until he
    /// opens it, and then as he left it for this shoot.
    public var cullSettingsShown = false

    // Presets
    public var leaveOutAgreed = false
    public var alsoDropped = false
    public var editor: String
    public var presetsAgainAsked = false

    // Edit in PhotoLab
    public private(set) var exportedLive: Int?
    public var buildingEditFolder = false
    public var openNote: String?
    /// He asked for the keepers to open once the presets being written are
    /// on disk. Opening before they are is the trap the Edit page's own
    /// footnote describes: PhotoLab keeps its own record of the folder, and
    /// presets written a minute later do not show.
    public var openWhenWritten = false
    /// When the editor was last asked to open this shoot's keepers, so the
    /// page can say it happened while the editor takes its seconds to appear.
    public var openedAt: Date?
    /// Why the last Open was refused, in the engine's words. The model's and
    /// not a page's, because the Presets page's Return opens the editor and
    /// then shows the Edit page, which is where he reads how it went.
    public var openRefusal: String?

    // Finish
    public var finishing = false
    public var recordedKeepers: Int?
    /// Where the engine said the keepers just recorded came from.
    public var recordedFrom: String?
    public var shrink: ShrinkQuestion?
    public var finishedNow = false
    /// What Finish did about learning, in one line under the finished
    /// sentence: that it is learning now, or the engine's own sentence when
    /// the run waits (for the job running, or for a Mac left alone). Nil when
    /// automatic learning is off, and when the page is read again later: then
    /// it is about a moment that has passed. The app never starts that run:
    /// marking a shoot finished starts it server-side.
    public var learningLine: String?

    public let ingestJob: StepJobRunner
    public let cullJob: StepJobRunner
    public let presetsJob: StepJobRunner

    private var watcher: ExportWatcher?
    private var pollTask: Task<Void, Never>?
    private var lastJobID: String?

    public init(session: ShootSession, jobs: JobModel) {
        self.session = session
        self.jobs = jobs
        self.client = session.client
        // The engine's answer for what the next cull runs with: the shoot's
        // own, or on a shoot no cull was asked of yet, his last shoot's
        // (`cull_from`), never 1.9 and off by default.
        self.focus = session.info.focus > 0 ? session.info.focus : 1.9
        self.peopleMove = session.info.style == "action"
        self.editor = session.info.editor.isEmpty ? Self.defaultEditor(.shared) : session.info.editor
        self.shootName = ""
        self.ingestJob = StepJobRunner(kinds: ["ingest"], shoot: session.name, jobs: jobs)
        self.cullJob = StepJobRunner(kinds: ["cull"], shoot: session.name, jobs: jobs)
        self.presetsJob = StepJobRunner(kinds: ["presets"], shoot: session.name, jobs: jobs)
        // Each step's work waits on the one list, and each box reads it back
        // from there, so a request survives his leaving the page.
        for r in [ingestJob, cullJob, presetsJob] { r.list = { [weak self] in self?.queue } }
    }

    /// A shoot with no editor of its own starts on the one he chose on the
    /// first-run sheet or in Settings. It always started on DxO: nothing read
    /// that choice, so it had to be made again on every new shoot.
    public static func defaultEditor(_ settings: SettingsStore) -> String {
        if let e = settings.editor, Editors.ids.contains(e) { return e }
        return "dxo"
    }

    public enum VerifyChoice: String, CaseIterable, Sendable {
        case whileCopying = "in-flight"
        case againAtTheEnd = "end"
        case dont = "none"

        /// The one he chose last time, or checking while copying. Never
        /// *Don't check*: that is for one card on one evening, and carried
        /// over it would let a bad copy go unnoticed on a later card, which is
        /// then reformatted on the strength of it (§2.6).
        public init(settings: SettingsStore) {
            let last = settings.copyCheck.flatMap(VerifyChoice.init(rawValue:))
            self = (last == nil || last == .dont) ? .whileCopying : last!
        }

        /// Keeps a check he chose for next time. *Don't check* is not kept,
        /// so the check he last chose before it is still what comes back.
        public func remember(in settings: SettingsStore) {
            guard self != .dont else { return }
            settings.copyCheck = rawValue
        }

        public var label: String {
            switch self {
            case .whileCopying: return Strings.Import.checkInFlight
            case .againAtTheEnd: return Strings.Import.checkEnd
            case .dont: return Strings.Import.checkNone
            }
        }
        public var note: String {
            switch self {
            case .whileCopying: return Strings.Import.checkInFlightNote
            case .againAtTheEnd: return Strings.Import.checkEndNote
            case .dont: return Strings.Import.checkNoneNote
            }
        }
    }

    /// The question the Finish step asks when the engine would record fewer
    /// keepers than it already has.
    public struct ShrinkQuestion: Equatable, Sendable {
        /// The engine's own sentence, shown as it wrote it.
        public let sentence: String
        public let had: Int?
        public let now: Int?
        public init(sentence: String, had: Int?, now: Int?) {
            self.sentence = sentence; self.had = had; self.now = now
        }
    }

    public var split: PresetSplit { PresetSplits.source.split(session) }

    /// Write the presets with what the Presets page is set to. The Presets
    /// page's primary, and the Edit page's "Write the Presets, Then Open".
    public func writePresets(force: Bool) {
        clearAdded()
        // `picks_only` is the engine's flag for "not the frames he put out".
        // Ticking the box asks for them too, so the flag is its opposite.
        let body = PresetsBody(name: session.name, force: force ? true : nil,
                               picks_only: alsoDropped ? false : true, editor: editor)
        let jobs = self.jobs
        let client = self.client
        // While something else runs it goes on Up Next, where it is kept when
        // he leaves the page, rather than waiting inside it (§2.7).
        presetsJob.run(orAdd: { [weak self] in self?.addPresetsToTheList(force: force) }) {
            await jobs.start {
                let r = try await client.post(Routes.presets, body)
                if let e = r.error, !r.ok { throw StudioError.refused(e) }
            }
        }
    }

    /// Opens his keepers in the editor the presets are written for: the Edit
    /// page's Open, and the Presets page's once they are written (§2.6). The
    /// engine builds the folder of keepers and opens it; a refusal is kept
    /// here, where either page can say it.
    public func openKeepers() {
        guard !buildingEditFolder else { return }
        openRefusal = nil
        openNote = nil
        openedAt = nil
        buildingEditFolder = true
        let client = self.client
        let name = session.name
        let body = OpenBody(name: name, what: "photolab", editor: editor)
        Task { @MainActor in
            defer { self.buildingEditFolder = false }
            do {
                let r = try await client.post(Routes.open, body)
                if let e = r.error, !r.ok {
                    self.openRefusal = e
                } else {
                    self.openNote = r.note
                    self.openedAt = Date()
                    if let light = try? await client.get(Routes.shootLight(name)) {
                        self.noteExported(light.info.exported)
                    }
                }
            } catch let e as StudioError {
                self.openRefusal = e.sentence
            } catch {
                self.openRefusal = Strings.API.offline
            }
        }
    }

    /// The same work, described rather than started: the kind and the page's
    /// options, which the engine builds a command from when the turn comes.
    public func addPresetsToTheList(force: Bool) {
        addToTheList(kind: "presets", options: [
            "force": .bool(force),
            "picks_only": .bool(!alsoDropped),
            "editor": .string(editor),
        ])
    }

    /// For the snapshot harness: report this job on the runner of that kind,
    /// so a scene can show a step mid-job without an engine behind it.
    public func showPreviewJob(_ job: Job?) {
        for r in [ingestJob, cullJob, presetsJob] { r.preview = job }
    }

    /// The engine's export count: whatever `?light=1` last said, or whatever
    /// the shoot was loaded with. The app never counts the files itself —
    /// exports are found in the export folder, the editing folder or iCloud,
    /// and only the engine looks in all three.
    public var exported: Int { exportedLive ?? session.info.exported }

    // MARK: - keeping up with the engine

    /// Reload the shoot after a job of this step's kind ends, and notice a job
    /// ending at all so a step can print what happened.
    public func observeJobs(ext: ExtConfig?) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval(self?.jobs.job))
                guard let self else { return }
                self.noticeJobChange(ext: ext)
            }
        }
    }

    /// How long a step page's watcher rests before it looks at the job again.
    ///
    /// Quick only while there is a job to watch. With nothing running this was
    /// two main-actor wake-ups a second for the whole time a step page was
    /// open, doing nothing on almost every one of them — a third timer
    /// competing for the main actor with the display link and the job poll.
    /// It only ever acts on a job that has **ended**, so the slower rate costs
    /// nothing: the first sight of a running job turns it fast again.
    ///
    /// Running, not merely known: the launch read of the job leaves the last
    /// one in place for good, so "is there a job" was true forever and the
    /// Cull, Presets and Reels pages woke twice a second with nothing to
    /// watch. The Reels page's watcher asks this too.
    public nonisolated static func watchInterval(_ job: Job?) -> Duration {
        job?.running == true ? .milliseconds(500) : .seconds(2)
    }

    public func stopObserving() {
        pollTask?.cancel()
        pollTask = nil
        ingestJob.teardown()
        cullJob.teardown()
        presetsJob.teardown()
        watcher?.stop()
        watcher = nil
    }

    private func noticeJobChange(ext: ExtConfig?) {
        guard let j = jobs.job else { return }
        // A job is identified by what it is and what it ran on, because the
        // engine's monotonic id (§3.9-10) is not on every engine yet.
        let id = "\(j.kind)/\(j.shoot)/\(j.running)/\(j.elapsed)/\(j.code.map(String.init) ?? "-")"
        guard id != lastJobID else { return }
        lastJobID = id
        guard !j.running, !j.kind.isEmpty else { return }
        for runner in [ingestJob, cullJob, presetsJob] where runner.kinds.contains(j.kind) {
            guard j.shoot.isEmpty || j.shoot == session.name || j.shoot == copiedShoot else { continue }
            runner.noteEnded(j)
            if j.outcome == .done { Task { try? await self.session.reload(ext: ext) } }
        }
    }

    /// Watch the export folder while the Edit step is on screen. The watcher
    /// only says *something changed*; the count still comes from the engine.
    public func watchExports() {
        guard watcher == nil else { return }
        let name = session.name
        let c = client
        watcher = ExportWatcher(paths: [session.info.export, session.info.path]) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let light = try? await c.get(Routes.shootLight(name)) {
                    self.exportedLive = light.info.exported
                }
            }
        }
        watcher?.start()
        // The backup, and the first answer: the engine's own cheap poll.
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.watcher != nil else { return }
                if let light = try? await c.get(Routes.shootLight(name)) {
                    self.exportedLive = light.info.exported
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The engine's count, from whichever of the two asked for it.
    public func noteExported(_ n: Int) { exportedLive = n }

    // MARK: - putting a step's work on the list

    /// The one list, as this step sees it.
    public var queue: QueueModel { list ?? Queues.model(client: client) }

    /// A list of its own instead of the app's one. For tests.
    var list: QueueModel?

    /// The kinds whose add has not been answered yet. A second press in
    /// that time read the list as it was before the first — `alreadyAsked`
    /// had nothing to see yet — and the engine takes the same work twice.
    @ObservationIgnored private var adding: Set<String> = []

    /// Whether pressing this step's action now would add rather than start.
    /// The button reads this and then says which, so what it says and what it
    /// does are one decision.
    public var wouldWait: Bool { queue.wouldWait }

    /// The line under the button after he added something — his word for the
    /// work, and nothing else. Cleared the moment he does anything else.
    public var added: String?

    /// Put this step's work on the list instead of doing it now.
    ///
    /// The options are the same names the route that does this work reads off
    /// a body, because the engine builds the command from them when the turn
    /// comes — which is what lets a shoot that changes in between change what
    /// runs, and what lets a card taken out of the Mac say so in his list.
    public func addToTheList(kind: String, options: [String: JSONValue]) {
        let q = queue
        let name = session.name
        guard !adding.contains(kind) else { return }
        if let already = alreadyAsked(kind) {
            added = already
            return
        }
        adding.insert(kind)
        Task { @MainActor in
            defer { self.adding.remove(kind) }
            if let item = await q.add(kind: kind, shoot: name, options: options) {
                self.added = Strings.Queue.added(item.what)
            } else {
                self.added = nil
            }
        }
    }

    public func clearAdded() { added = nil }

    /// Why this shoot's `kind` of work would not be added again, or nil.
    ///
    /// A second press — a double-click on "Add It to the List", ⌘R while his
    /// own cull ran — put the same seven-minute cull on the list twice, and
    /// the second one started as soon as the first ended, ahead of the
    /// presets he had stacked up behind it. The engine takes any number of the
    /// same thing, so the question is asked here, of the list the page reads.
    public func alreadyAsked(_ kind: String) -> String? {
        let runningHere = [ingestJob, cullJob, presetsJob].contains { $0.kinds.contains(kind) && $0.mine != nil }
        return Self.alreadyAsked(kind, shoot: session.name, list: queue.state, runningHere: runningHere)
    }

    /// The same question, of a list and of whether this step's job is the one
    /// running, so it can be asked without an engine.
    public static func alreadyAsked(_ kind: String, shoot: String, list s: QueueState,
                                    runningHere: Bool) -> String? {
        if s.waiting.contains(where: { $0.kind == kind && $0.shoot == shoot }) {
            return Strings.Step.alreadyOnTheList(shoot)
        }
        if runningHere || (s.running && !s.background && s.kind == kind && s.shoot == shoot) {
            return Strings.Step.alreadyRunning(shoot)
        }
        return nil
    }

    public func stopWatchingExports() {
        watcher?.stop()
        watcher = nil
    }
}

/// One `StepsModel` per shoot, kept for as long as the app is open, so every
/// field he filled in survives leaving the step and coming back.
@MainActor
public final class StepsModelStore {
    public static let shared = StepsModelStore()
    private var models: [String: StepsModel] = [:]

    public init() {}

    public func model(for session: ShootSession, jobs: JobModel) -> StepsModel {
        if let m = models[session.name], m.session === session { return m }
        let m = StepsModel(session: session, jobs: jobs)
        models[session.name] = m
        return m
    }

    public func forget(_ name: String) {
        models[name]?.stopObserving()
        models[name] = nil
    }

    /// For tests.
    public func reset() {
        for m in models.values { m.stopObserving() }
        models.removeAll()
    }
}

/// Where the app's one `JobModel` comes from. The integration crew sets this
/// in a line; without it each shoot's steps keep a `JobModel` of their own,
/// which polls the same route the same way and is correct but not shared.
@MainActor
public enum StepJobs {
    public static var shared: (@MainActor () -> JobModel)?
    /// For the snapshot harness: a job every runner made from here on reports
    /// as its own. Production never sets it.
    public static var previewJob: Job?
    private static var fallback: JobModel?

    public static func model(client: StudioClient) -> JobModel {
        if let shared { return shared() }
        if let fallback { return fallback }
        let m = JobModel(client: client)
        fallback = m
        return m
    }

    /// For tests.
    public static func reset() { shared = nil; fallback = nil; previewJob = nil }
}
