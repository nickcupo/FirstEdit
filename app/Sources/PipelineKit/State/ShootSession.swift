import Foundation
import Observation

/// Where he is in a shoot: which burst, which frame, and a generation that
/// increments on every move, so a picture that arrives late for a frame he
/// has already left can never count as the one on screen.
public struct Cursor: Equatable, Sendable {
    public private(set) var burst: Int
    public private(set) var frame: Int
    public private(set) var generation: Int

    public init(burst: Int = 0, frame: Int = 0, generation: Int = 0) {
        self.burst = burst; self.frame = frame; self.generation = generation
    }

    public mutating func move(burst: Int, frame: Int) {
        self.burst = burst
        self.frame = frame
        generation &+= 1
    }
}

/// What happened to a press.
public enum VerdictOutcome: Sendable, Equatable {
    case applied
    /// The same value it already had. Nothing written, no undo step.
    case unchanged
    /// Refused, with the sentence that went on the control bar.
    case refused(String)
    /// A reason on a frame he kept: the view asks first.
    case needsConfirmation
}

/// One open shoot. The **only** writer of verdicts and the only owner of the
/// `VerdictQueue`; views read it and never change a row themselves.
@MainActor @Observable
public final class ShootSession {
    public let name: String
    public private(set) var info: ShootInfo
    /// By stem.
    public private(set) var rows: [String: Row] { didSet { rowsVersion &+= 1 } }
    /// Moves on every change to `rows`, so a count worked out from all of
    /// them can be kept until they change rather than redone on every draw.
    public private(set) var rowsVersion = 0
    /// Shutter order, as the engine sent the rows.
    public private(set) var order: [String]
    public private(set) var bursts: [Burst] { didSet { burstsVersion &+= 1 } }
    /// Moves on every change to `bursts` — an N, its undo, a burst taken back
    /// off the list — as `rowsVersion` does for the rows.
    public private(set) var burstsVersion = 0
    public private(set) var steps: [StepState]
    public private(set) var review: Review
    public private(set) var presets: [PresetRun]
    public private(set) var resume: Resume
    /// Where he is. A move takes down the display gate's refusals (§2.5.4):
    /// each was about the frame he has just left, and "Still opening this
    /// frame." used to stay above Keep and Drop, untrue, while he arrowed
    /// through frames that were plainly open.
    public var cursor: Cursor {
        didSet { if cursor != oldValue { clearDisplayRefusals() } }
    }
    public let undo: VerdictLog
    public let refusals = RefusalBoard()
    /// The engine's informational note after a verdict, printed inline on the
    /// control bar. Never an alert.
    public private(set) var keyNote: String?

    /// Told when the engine has accepted a burst on or off the list of ones
    /// he has been through (N, its undo, or taking one back). What the
    /// library counts for this shoot — "kept" among it — has moved with it.
    @ObservationIgnored public var onSeenChanged: (@MainActor () -> Void)?

    /// The engine client and the image pump, so a step view registered with
    /// nothing but the session can still reach both.
    public let client: StudioClient
    public let pump: ImagePump

    private let queue: VerdictQueue
    /// Set by the viewer from its display link: the frame and generation
    /// whose pixels have been on screen for at least one refresh.
    public private(set) var displayed: (stem: String, generation: Int)?

    public init(response: ShootResponse, ext: ExtConfig?, client: StudioClient, pump: ImagePump,
                queue: VerdictQueue? = nil) {
        name = response.info.name
        info = response.info
        self.client = client
        self.pump = pump
        self.queue = queue ?? VerdictQueue(client: client)
        undo = VerdictLog()
        rows = [:]
        order = []
        bursts = []
        steps = []
        review = response.review
        presets = response.presets
        resume = response.resume
        cursor = Cursor()
        apply(response, ext: ext)
        let seeds = response.rows.map { ($0.file, $0.override) }
        let q = self.queue
        Task { for (f, v) in seeds { await q.seed(file: f, value: v) } }
    }

    /// Replaces the snapshot with a fresh one from the engine. His undo stack
    /// and his place are kept.
    public func apply(_ response: ShootResponse, ext: ExtConfig?) {
        info = response.info
        var byStem: [String: Row] = [:]
        for r in response.rows { byStem[r.stem] = r }
        rows = byStem
        order = response.rows.map(\.stem)
        review = response.review
        presets = response.presets
        resume = response.resume
        bursts = response.bursts.isEmpty ? Fallbacks.bursts(response.rows, response.review) : response.bursts
        var marks: [String: Int] = [:]
        for r in response.rows { marks[r.stem] = r.override }
        markedWhenCounted = marks
        seenWhenCounted = Set(bursts.filter(\.seen).map(\.id))
        steps = (response.steps.isEmpty ? Fallbacks.steps(response.info, ext) : response.steps)
            .map { $0.namedByTheApp(ext) }
        if cursor.burst >= bursts.count { cursor.move(burst: max(0, bursts.count - 1), frame: 0) }
    }

    /// His mark on each frame, and the bursts he had been through, as they
    /// were when the engine worked out each burst's counts (`Burst.kept` and
    /// the rest): the counts are the engine's snapshot and no press moves
    /// them.
    @ObservationIgnored private var markedWhenCounted: [String: Int] = [:]
    @ObservationIgnored private var seenWhenCounted: Set<String> = []

    /// Whether the engine's counts for a burst still describe it: no mark of
    /// his on its frames and not its record of being been through has changed
    /// since the engine counted. A burst he has worked on since has to be
    /// counted again, from its frames as they are now.
    public func countedAsItIs(_ b: Burst) -> Bool {
        guard seenWhenCounted.contains(b.id) == b.seen else { return false }
        return b.frames.allSatisfy { rows[$0]?.override == markedWhenCounted[$0] }
    }

    /// The base steps under the names `ext` gives them, when the session was
    /// opened before the library's list said what the extension calls them —
    /// the shoot reopened at launch is asked for beside the list, not after
    /// it. Written only when a name changes, so the sidebar is not redrawn
    /// for nothing on every read of the list.
    public func rename(_ ext: ExtConfig?) {
        let named = steps.map { $0.namedByTheApp(ext) }
        guard zip(named, steps).contains(where: { $0.label != $1.label }) else { return }
        steps = named
    }

    public func reload(ext: ExtConfig?) async throws {
        let r = try await client.get(Routes.shoot(name))
        apply(r, ext: ext)
    }

    // MARK: - where he is

    public var currentBurst: Burst? { bursts.indices.contains(cursor.burst) ? bursts[cursor.burst] : nil }
    public var currentStem: String? {
        guard let b = currentBurst, b.frames.indices.contains(cursor.frame) else { return nil }
        return b.frames[cursor.frame]
    }
    public var currentRow: Row? { currentStem.flatMap { rows[$0] } }

    public func go(burst: Int, frame: Int = 0) {
        guard bursts.indices.contains(burst) else { return }
        let n = bursts[burst].frames.count
        cursor.move(burst: burst, frame: min(max(0, frame), max(0, n - 1)))
    }

    public func go(to stem: String) {
        for (i, b) in bursts.enumerated() {
            if let f = b.frames.firstIndex(of: stem) { go(burst: i, frame: f); return }
        }
    }

    /// The burst a frame is in, looking in the one he is in first.
    public func burstIndex(of stem: String) -> Int? {
        if currentBurst?.frames.contains(stem) == true { return cursor.burst }
        return bursts.firstIndex { $0.frames.contains(stem) }
    }

    /// Next frame in shutter order. Stops silently at the end of the burst:
    /// nothing ever crosses a burst boundary on its own, because crossing one
    /// records "been through".
    @discardableResult
    public func nextFrame() -> Bool {
        guard let b = currentBurst, cursor.frame + 1 < b.frames.count else { return false }
        cursor.move(burst: cursor.burst, frame: cursor.frame + 1)
        return true
    }

    @discardableResult
    public func previousFrame() -> Bool {
        guard cursor.frame > 0 else { return false }
        cursor.move(burst: cursor.burst, frame: cursor.frame - 1)
        return true
    }

    // MARK: - the display gate (§2.5.4)

    /// The viewer reports this from its display link once a picture for this
    /// `(stem, generation)` has been committed *and* one refresh has passed.
    public func didDisplay(stem: String, generation: Int) {
        displayed = (stem, generation)
    }

    /// The display gate's three refusals, and only those: a write the engine
    /// refused is about the frame, not about where he is, and stays. They are
    /// **not** taken down when the frame he is on finishes opening — the
    /// frame did not move and his K did not land, and a line that vanished
    /// 30 ms after it appeared would say neither.
    private func clearDisplayRefusals() {
        guard let message = refusals[.verdict], Self.isDisplayRefusal(message) else { return }
        refusals.clear(.verdict)
    }

    private static func isDisplayRefusal(_ message: String) -> Bool {
        [Strings.Verdict.stillOpening, Strings.Verdict.notOnScreen, Strings.Verdict.noPixels].contains(message)
    }

    /// Compare's tiles, each reported by its own view the same way. Cleared
    /// when Compare closes.
    public private(set) var displayedTiles: Set<String> = []
    public func didDisplayTile(stem: String) { displayedTiles.insert(stem) }
    public func clearDisplayedTiles() { displayedTiles.removeAll() }

    public var isDisplayedFrameCurrent: Bool {
        guard let d = displayed, let stem = currentStem else { return false }
        return d.stem == stem && d.generation == cursor.generation
    }

    /// Which of the three refusals applies, or nil when a verdict may be taken.
    public func displayRefusal() -> String? {
        guard let stem = currentStem, let row = rows[stem] else { return Strings.Verdict.notOnScreen }
        if !row.hasAnyRendering { return Strings.Verdict.noPixels }
        guard let d = displayed, d.stem == stem else { return Strings.Verdict.stillOpening }
        if d.generation != cursor.generation { return Strings.Verdict.notOnScreen }
        return nil
    }

    // MARK: - verdicts

    /// Keep, then the next frame in shutter order.
    @discardableResult
    public func keep(advance: Bool = true) async -> VerdictOutcome {
        await decide(.keep, advance: advance)
    }

    /// Drop, then the next frame. Drop deletes nothing.
    @discardableResult
    public func drop(advance: Bool = true) async -> VerdictOutcome {
        await decide(.drop, advance: advance)
    }

    /// Back to unmarked. Not the same as writing 0.
    @discardableResult
    public func clear() async -> VerdictOutcome {
        await decide(.clear, advance: false)
    }

    /// Why it is out, on the frame on screen. On an unmarked frame it also
    /// drops it — a reason implies out — and, with `advance`, moves on the way
    /// D does. On a frame he kept it asks first.
    @discardableResult
    public func reason(_ r: DropReason, confirmedOnKept: Bool = false,
                       advance: Bool = false) async -> VerdictOutcome {
        if let refusal = displayRefusal() { return refuse(refusal) }
        guard let stem = currentStem else { return .unchanged }
        return await label(stem, r, confirmedOnKept: confirmedOnKept, advance: advance)
    }

    /// Why it is out, on **a frame named**, not the one on screen: the frame D
    /// has just put out, while the strip that asks "why?" is up (§2.5.3).
    ///
    /// D moves on, so by the time his 4 arrives the cursor is on the next
    /// frame, which he has not judged. The reason used to go there — put out
    /// and labelled "blur" without his knowing, and taught to the cull as his
    /// — while the frame he meant kept no reason at all. This labels the frame
    /// he dropped and nothing else: it does not move the cursor and it does not
    /// write the drop again. It needs no display gate of its own; that frame
    /// passed it when D was pressed.
    ///
    /// A frame named here that is not out, and not one he kept and is being
    /// asked about, has had its drop taken back since — refused by the
    /// engine, or undone — and is left alone: a reason would put it out
    /// again without his pressing D.
    @discardableResult
    public func reason(_ r: DropReason, on stem: String, confirmedOnKept: Bool = false) async -> VerdictOutcome {
        guard let row = rows[stem], VerdictValue.his(row) != .unmarked else { return .unchanged }
        return await label(stem, r, confirmedOnKept: confirmedOnKept, advance: false)
    }

    private func label(_ stem: String, _ r: DropReason, confirmedOnKept: Bool,
                       advance: Bool) async -> VerdictOutcome {
        guard let row = rows[stem] else { return .unchanged }
        let his = VerdictValue.his(row)
        if his == .kept && !confirmedOnKept { return .needsConfirmation }

        let labelBefore = row.label
        let before = row.override
        let dropNow = his != .out
        rows[stem]?.label = r.rawValue
        if dropNow { rows[stem]?.override = VerdictValue.drop }
        let step = VerdictStep(kind: .reason(r), stem: stem, file: row.file, before: before,
                               after: dropNow ? VerdictValue.drop : before, labelBefore: labelBefore,
                               burstIndex: burstIndex(of: stem) ?? cursor.burst,
                               name: Strings.Verdict.undoReason(r.word, Self.shortStem(stem)))
        undo.push(step)
        if dropNow && advance && currentStem == stem { nextFrame() }

        do {
            let ok = try await client.post(Routes.label, LabelBody(name: name, file: row.file, label: r.rawValue))
            if let e = ok.error, !ok.ok { throw StudioError.refused(e) }
        } catch {
            rollback(step)
            return refuse(Self.sentence(error))
        }
        if dropNow {
            let result = await queue.submit(VerdictWrite(shoot: name, file: row.file, rating: VerdictValue.drop))
            if case .failure(let e) = result {
                rollback(step)
                return refuse(e.sentence)
            }
        }
        refusals.clear(.verdict)
        return .applied
    }

    /// In Compare: keep this one and drop the rest of its stack, as **his**
    /// verdicts, in one undo step.
    @discardableResult
    public func keepOnly(_ stem: String, dropping others: [String]) async -> VerdictOutcome {
        guard let row = rows[stem] else { return .unchanged }
        // The one he keeps must be on screen. The others are decided by that
        // same press, and he is looking at them side by side.
        let onScreen = displayedTiles.contains(stem) || (displayed?.stem == stem && isDisplayedFrameCurrent)
        if !onScreen { return refuse(row.hasAnyRendering ? Strings.Verdict.notOnScreen : Strings.Verdict.noPixels) }
        let keepV = VerdictValue.keep(row)
        var before: [String: Int?] = [:]
        for s in others { before[s] = rows[s]?.override }
        let step = VerdictStep(kind: .keepOnly(others), stem: stem, file: row.file, before: row.override,
                               after: keepV, others: before, burstIndex: cursor.burst,
                               name: Strings.Verdict.undoKeepOnly(Self.shortStem(stem)))
        rows[stem]?.override = keepV
        for s in others { rows[s]?.override = VerdictValue.drop }
        undo.push(step)

        var writes = [VerdictWrite(shoot: name, file: row.file, rating: keepV)]
        writes += others.compactMap { s in rows[s].map { VerdictWrite(shoot: name, file: $0.file, rating: VerdictValue.drop) } }
        var failure: StudioError?
        await withTaskGroup(of: Result<RatingResult, StudioError>.self) { g in
            for w in writes { g.addTask { await self.queue.submit(w) } }
            for await r in g { if case .failure(let e) = r, failure == nil { failure = e } }
        }
        if let failure {
            rollback(step)
            return refuse(failure.sentence)
        }
        refusals.clear(.verdict)
        return .applied
    }

    /// N: finish this burst and open the next. **What every forward way out of
    /// a burst goes through, and the only thing that records "looked
    /// through".** Frames he did not press a key on keep the cull's
    /// call, marked as agreed — not as his.
    ///
    /// Everything it names is read **before** the wait: the burst, its number
    /// for the undo step, and the frame he finished it from, which is where
    /// ⌘Z takes him back to. They used to be read after it, from wherever the
    /// cursor was by then. A burst whose finish is already on its way is not
    /// finished a second time.
    ///
    /// `joining`: the undo step of the verdict whose press this finish is
    /// the rest of — E, D or a reason on a burst's last frame, going on
    /// (§2.5.2). The finish joins it, so one Q takes back both. It joins only
    /// while that verdict is still the newest step: one the engine refused
    /// has already come off, and then the finish is a step of its own.
    @discardableResult
    public func finishBurst(joining verdict: UUID? = nil) async -> VerdictOutcome {
        await finishBurst(redoing: false, joining: verdict)
    }

    /// `redoing`: ⇧⌘Z putting back a finish he took back, which leaves the
    /// rest of what he has taken back where it is.
    private func finishBurst(redoing: Bool, joining verdict: UUID? = nil) async -> VerdictOutcome {
        guard let b = currentBurst else { return .unchanged }
        guard !finishing.contains(b.id) else { return .unchanged }
        let index = cursor.burst
        let from = currentStem ?? b.frames.first ?? ""
        let nextIndex = index + 1
        let next = bursts.indices.contains(nextIndex) ? bursts[nextIndex] : nil
        finishing.insert(b.id)
        defer { finishing.remove(b.id) }
        do {
            _ = try await client.post(Routes.review, ReviewBody(name: name, at: next?.id ?? b.id, seen: [b.id]))
        } catch {
            return refuse(Self.sentence(error), owner: .navigation)
        }
        // Named for the verdict it joins, which is what he pressed: the menu
        // reads "Undo Keep 04330", and that one undo takes back both.
        let joined = undo.steps.last.flatMap { $0.id == verdict ? $0 : nil }
        let step = VerdictStep(kind: .finishBurst(burstID: b.id), stem: from, file: "",
                               before: nil, after: nil, burstIndex: index,
                               name: joined?.name ?? Strings.Verdict.undoFinishBurst(index + 1),
                               joins: joined?.id)
        if redoing { undo.pushRedone(step) } else { undo.push(step) }
        markSeen(b.id, true)
        if next != nil { go(burst: nextIndex) }
        refusals.clear(.navigation)
        return .applied
    }

    /// The bursts whose been-through write is on its way.
    @ObservationIgnored private var finishing: Set<String> = []

    /// Takes a burst back off the list of ones he has been through
    /// (DESIGN.md §7.4). N is the only thing that puts it on, so N pressed by
    /// mistake is the whole reason this exists: the count of bursts he has
    /// been through may never be a machine's flattery of work he did not do,
    /// and that cuts both ways - it may not hold work he did not do either.
    ///
    /// Undo already reaches the most recent N, and nothing further back. This
    /// reaches any burst at any time, which is what the retired page offered
    /// and what §2.5.13 has promised ever since.
    ///
    /// Not an undo step of its own: undo is for a run of verdicts he is
    /// working through, and this is a correction to a fact about a burst he
    /// may have left an hour ago. Pressing N again is how it goes back.
    @discardableResult
    public func unmarkBurst(_ id: String) async -> VerdictOutcome {
        guard let b = bursts.first(where: { $0.id == id }), b.seen else { return .unchanged }
        do {
            _ = try await client.post(Routes.review, ReviewBody(name: name, unseen: [id]))
        } catch {
            return refuse(Self.sentence(error), owner: .navigation)
        }
        markSeen(id, false)
        refusals.clear(.navigation)
        return .applied
    }

    /// Takes back the newest step and goes to the frame it changed. The step
    /// comes off the log before the inverse write is sent.
    ///
    /// A finish that joins the verdict under it is one press with it (a
    /// verdict on a burst's last frame, going on), so it is one undo: the
    /// burst's record comes off, then the verdict, and he is on that frame
    /// with it unmarked. It used to take two — the first only took him back
    /// to the frame, still kept, at every burst's end. When the verdict's own
    /// undo is refused, the finish stays taken back, he is on the frame, and
    /// the refusal says why; it counts as applied, because he has moved.
    @discardableResult
    public func undoLast() async -> VerdictOutcome {
        guard let step = undo.pop() else { return .unchanged }
        goTo(step)
        let outcome = await takeBack(step)
        guard outcome == .applied else { return outcome }
        undo.keepUndone(step)
        if let joined = step.joins, undo.steps.last?.id == joined, let verdict = undo.pop() {
            goTo(verdict)
            if await takeBack(verdict) == .applied { undo.keepUndone(verdict) }
        }
        return outcome
    }

    /// The frame a step changed, in the burst it changed it in.
    private func goTo(_ step: VerdictStep) {
        guard bursts.indices.contains(step.burstIndex) else { return }
        if let f = bursts[step.burstIndex].frames.firstIndex(of: step.stem) {
            go(burst: step.burstIndex, frame: f)
        } else {
            go(burst: step.burstIndex)
        }
    }

    /// ⇧⌘Z: puts back the step he took back last and goes to the frame it
    /// changes. It writes exactly what the press first wrote — the same
    /// value, the same reason, the same burst recorded as looked through —
    /// by the same routes, and a refused write leaves it taken back and says
    /// why. Redo used to do nothing at all: a verdict undone once too often
    /// had to be found and pressed again.
    ///
    /// A verdict that went on into the next burst comes back with the finish
    /// that joined it, as one redo: the mark, then the burst's record, and he
    /// is in the next burst again, where the press first took him.
    @discardableResult
    public func redoLast() async -> VerdictOutcome {
        guard let step = undo.popUndone() else { return .unchanged }
        goTo(step)
        let outcome = await putBack(step)
        guard outcome == .applied else {
            undo.keepUndone(step)
            return outcome
        }
        if undo.undone.last?.joins == step.id, let finish = undo.popUndone() {
            goTo(finish)
            if await putBack(finish) != .applied { undo.keepUndone(finish) }
        }
        return outcome
    }

    private func putBack(_ step: VerdictStep) async -> VerdictOutcome {
        switch step.kind {
        case .finishBurst(let id):
            guard currentBurst?.id == id else { return .unchanged }
            return await finishBurst(redoing: true, joining: step.joins)
        case .reason(let r):
            rows[step.stem]?.label = r.rawValue
            rows[step.stem]?.override = step.after
            undo.pushRedone(step)
            do {
                let ok = try await client.post(Routes.label, LabelBody(name: name, file: step.file, label: r.rawValue))
                if let e = ok.error, !ok.ok { throw StudioError.refused(e) }
            } catch {
                rollback(step)
                return refuse(Self.sentence(error))
            }
            if step.after != step.before,
               case .failure(let e) = await queue.submit(VerdictWrite(shoot: name, file: step.file, rating: step.after)) {
                rollback(step)
                return refuse(e.sentence)
            }
        case .keepOnly(let others):
            rows[step.stem]?.override = step.after
            for s in others { rows[s]?.override = VerdictValue.drop }
            undo.pushRedone(step)
            var writes = [VerdictWrite(shoot: name, file: step.file, rating: step.after)]
            writes += others.compactMap { s in rows[s].map { VerdictWrite(shoot: name, file: $0.file, rating: VerdictValue.drop) } }
            for w in writes {
                if case .failure(let e) = await queue.submit(w) {
                    rollback(step)
                    return refuse(e.sentence)
                }
            }
        case .keep, .drop, .clear:
            rows[step.stem]?.override = step.after
            undo.pushRedone(step)
            if case .failure(let e) = await queue.submit(VerdictWrite(shoot: name, file: step.file,
                                                                       rating: step.after)) {
                rollback(step)
                return refuse(e.sentence)
            }
        }
        refusals.clear(.verdict)
        return .applied
    }

    /// The inverse of one step, written. The step is already off the log.
    private func takeBack(_ step: VerdictStep) async -> VerdictOutcome {
        switch step.kind {
        case .finishBurst(let id):
            do {
                _ = try await client.post(Routes.review, ReviewBody(name: name, unseen: [id]))
                markSeen(id, false)
            } catch {
                undo.restore(step)
                return refuse(Self.sentence(error), owner: .navigation)
            }
        case .reason:
            rows[step.stem]?.label = step.labelBefore ?? ""
            rows[step.stem]?.override = step.before
            do {
                _ = try await client.post(Routes.label, LabelBody(name: name, file: step.file,
                                                                  label: step.labelBefore ?? ""))
            } catch {
                undo.restore(step)
                return refuse(Self.sentence(error))
            }
            if step.after != step.before {
                if case .failure(let e) = await queue.submit(VerdictWrite(shoot: name, file: step.file,
                                                                           rating: step.before)) {
                    undo.restore(step)
                    return refuse(e.sentence)
                }
            }
        case .keepOnly:
            rows[step.stem]?.override = step.before
            var writes = [VerdictWrite(shoot: name, file: step.file, rating: step.before)]
            for (s, v) in step.others {
                rows[s]?.override = v
                if let f = rows[s]?.file { writes.append(VerdictWrite(shoot: name, file: f, rating: v)) }
            }
            for w in writes {
                if case .failure(let e) = await queue.submit(w) {
                    undo.restore(step)
                    return refuse(e.sentence)
                }
            }
        case .keep, .drop, .clear:
            rows[step.stem]?.override = step.before
            if case .failure(let e) = await queue.submit(VerdictWrite(shoot: name, file: step.file,
                                                                       rating: step.before)) {
                rows[step.stem]?.override = step.after
                undo.restore(step)
                return refuse(e.sentence)
            }
        }
        refusals.clear(.verdict)
        return .applied
    }

    // MARK: - the one path every single-frame verdict takes

    /// K, D and 0.
    public enum Press: Sendable { case keep, drop, clear }

    /// A single-frame verdict the moment he pressed it: turned down or already
    /// his, or taken — the model, the undo step and the move all done — with
    /// the engine's answer still to come.
    public enum Taken {
        case done(VerdictOutcome)
        case writing(Writing)
    }

    /// A write on its way, which `settle(_:)` waits for.
    public struct Writing {
        public let stem: String
        let step: VerdictStep
        let answer: Task<Result<RatingResult, StudioError>, Never>
        /// Which of his presses this was, counting from the launch.
        let press: Int
    }

    /// His single-frame verdicts so far, and the count when the refusal on
    /// the control bar went up — or, for a write the engine refused, that
    /// write's own number. Writes for different frames overlap now, so a
    /// success can arrive after a refusal of a later press; only a success
    /// of a press made after the refused one may take its sentence down.
    @ObservationIgnored private var presses = 0
    @ObservationIgnored private var refusedAtPress = 0

    private func decide(_ p: Press, advance: Bool) async -> VerdictOutcome {
        switch take(p, advance: advance) {
        case .done(let outcome): return outcome
        case .writing(let w): return await settle(w)
        }
    }

    /// Everything a single-frame verdict does before the engine answers, and
    /// nothing that waits for it. The light table takes his next press as
    /// soon as this returns (§2.5.6); `keep()`, `drop()` and `clear()` are
    /// this and `settle(_:)` one after the other.
    public func take(_ p: Press, advance: Bool) -> Taken {
        // Rule 5: only ever on a frame that is actually on screen.
        if let refusal = displayRefusal() { return .done(refuse(refusal)) }
        guard let stem = currentStem, let row = rows[stem] else { return .done(.unchanged) }
        // It passed: whatever the gate said about an earlier press is past.
        clearDisplayRefusals()

        let value: Int?
        let kind: VerdictStep.Kind
        let label: String
        switch p {
        case .keep: value = VerdictValue.keep(row); kind = .keep; label = Strings.Verdict.undoKeep(Self.shortStem(stem))
        case .drop: value = VerdictValue.drop; kind = .drop; label = Strings.Verdict.undoDrop(Self.shortStem(stem))
        case .clear: value = nil; kind = .clear; label = Strings.Verdict.undoClear(Self.shortStem(stem))
        }

        if row.override == value {
            if advance { nextFrame() }
            return .done(.unchanged)
        }

        // Optimistic, but never a lie: the model changes now, the step is
        // pushed now, and a refused write takes back exactly this step.
        let step = VerdictStep(kind: kind, stem: stem, file: row.file, before: row.override, after: value,
                               burstIndex: cursor.burst, name: label)
        rows[stem]?.override = value
        undo.push(step)
        if advance { nextFrame() }

        let queue = self.queue
        let write = VerdictWrite(shoot: name, file: row.file, rating: value)
        presses += 1
        return .writing(Writing(stem: stem, step: step, answer: Task { await queue.submit(write) },
                                press: presses))
    }

    /// The engine's answer to a verdict `take(_:advance:)` sent. A refusal
    /// takes back that one step and says why, wherever he is by then.
    public func settle(_ w: Writing) async -> VerdictOutcome {
        switch await w.answer.value {
        case .success(let r):
            keyNote = r.key_note.isEmpty ? nil : r.key_note
            // Only a refused write's sentence: a line the display gate has
            // put up since, about the frame he is on now, is not this
            // write's to take down (§7.7). Nor is the refusal of a press he
            // made after this one: K on one frame answered late used to take
            // down the sentence saying why K on the next was refused.
            if let message = refusals[.verdict], !Self.isDisplayRefusal(message), w.press > refusedAtPress {
                refusals.clear(.verdict)
            }
            return .applied
        case .failure(let e):
            rollback(w.step)
            let outcome = refuse(e.sentence)
            refusedAtPress = w.press
            return outcome
        }
    }

    private func rollback(_ step: VerdictStep) {
        undo.remove(step.id)
        rows[step.stem]?.override = step.before
        if case .reason = step.kind { rows[step.stem]?.label = step.labelBefore ?? "" }
        if case .keepOnly = step.kind {
            for (s, v) in step.others { rows[s]?.override = v }
        }
    }

    /// The refusal goes up tagged with the frame on screen as it is said,
    /// which for a write the engine turned down is where he has got to by
    /// then, so it is read on the frame he is looking at.
    @discardableResult
    private func refuse(_ message: String, owner: RefusalOwner = .verdict) -> VerdictOutcome {
        refusals.set(owner, message, at: currentStem)
        if owner == .verdict { refusedAtPress = presses }
        return .refused(message)
    }

    private func markSeen(_ id: String, _ seen: Bool) {
        guard let i = bursts.firstIndex(where: { $0.id == id }) else { return }
        let b = bursts[i]
        bursts[i] = Burst(id: b.id, index: b.index, scene: b.scene, started_at: b.started_at, frames: b.frames,
                          cover: b.cover, seen: seen, kept: b.kept, out: b.out, cull_picks: b.cull_picks,
                          undecided: b.undecided)
        onSeenChanged?()
    }

    static func sentence(_ e: Error) -> String {
        (e as? StudioError)?.sentence ?? Strings.API.offline
    }

    /// "04330" out of "TSC04330": the number he reads off the camera.
    /// `nonisolated` because a file promise is written off the main actor and
    /// this is pure string work: it was isolated only because its type is.
    public nonisolated static func shortStem(_ stem: String) -> String {
        let digits = stem.reversed().prefix(while: \.isNumber)
        return digits.isEmpty ? stem : String(digits.reversed())
    }
}
