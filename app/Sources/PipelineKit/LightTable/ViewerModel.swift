import Foundation
import Observation
import AppKit
import CoreGraphics

/// The light table, as state.
///
/// Every key, every button, every gesture and every menu item comes through
/// `perform(_:)`, and they come through it **in the order he pressed them**: a
/// single consumer drains one queue, so two fast ⌘Z presses undo two different
/// decisions rather than racing each other, and a Keep that is still being
/// written cannot be overtaken by the Drop after it.
///
/// It owns nothing of his. `ShootSession` is the only writer of verdicts; this
/// type decides *whether* a press is one, and where the refusal goes when it
/// is not (DESIGN.md §2.5.4).
@MainActor @Observable
public final class ViewerModel {

    public let session: ShootSession
    public var navigation: Navigation

    /// **One model per open shoot.** The step and the inspector are two views
    /// of the same light table, and two press queues over one session would
    /// mean two presses racing for the same frame.
    private static var models: [ObjectIdentifier: ViewerModel] = [:]

    public static func shared(for session: ShootSession, navigation: Navigation? = nil) -> ViewerModel {
        let key = ObjectIdentifier(session)
        if let m = models[key] {
            if let navigation { m.navigation = navigation }
            return m
        }
        let m = ViewerModel(session: session, navigation: navigation ?? Navigation())
        models[key] = m
        return m
    }

    public static func forget(_ session: ShootSession) {
        models[ObjectIdentifier(session)] = nil
    }

    // MARK: - what is on screen

    public var mode: ViewerMode = .single
    /// Space. `momentary` is a hold: it returns on release.
    public var fullImage = false
    public var fullImageIsMomentary = false
    /// The HUD comes up from the bottom for 2 s on a pointer move, then fades.
    public var hudVisible = false

    public var zoom = ZoomModel()
    /// The last absolute aim, carried to a frame that has nothing of its own
    /// to aim at, so the view never jumps to centre mid-burst.
    public var heldAim: CGPoint?

    /// How many covers a row of All Bursts holds, so ↑ ↓ can move a row.
    /// Written by the grid.
    @ObservationIgnored public var allBurstsColumns = 4

    /// The frames Compare is showing. Outside Compare, the frames he has
    /// ⌘-clicked or ⇧-clicked in the filmstrip, which C opens.
    public var compareSelection: [String] = []
    /// Compare is showing frames he picked himself, not a stack the cull
    /// found, so its header does not call them similar.
    public private(set) var comparePicked = false
    public var compareFocus: String?
    public var comparePage = 0

    /// The frames a fault in the cull's report covers, while he looks
    /// through them (§2.6): ← → and N P go through these and nothing else,
    /// and nothing is recorded as been through. See `lookThrough(_:)`.
    public internal(set) var lookingThrough: FrameList?

    /// The reasons strip, up for three seconds after D. It blocks nothing.
    public var reasonStripUntil: Date?
    /// The frame that D put out, which is the frame the strip asks about and
    /// the frame a reason pressed while it is up goes to — never the next one,
    /// which D has already moved him onto and which he has not judged.
    public private(set) var reasonStripStem: String?
    /// A reason pressed on a frame he kept asks first.
    public var reasonNeedingConfirmation: DropReason?
    /// The frame that question is about, so his answer lands where he asked.
    private var reasonConfirmationStem: String?
    /// Said once per session, the first time a held key is ignored.
    public var heldKeyTipShown = false
    public var showHeldKeyTip = false
    /// The quiet stack invitation under the picture, once per burst entered:
    /// the biggest stack in it, when that is more than three frames.
    private var invitedBursts: Set<String> = []
    public private(set) var invitedStack: Stack?

    /// The invitation's count, for as long as it can do what it says from
    /// where he stands — before that stack or inside it. It used to stay up
    /// over the photograph for the whole burst, and on a frame outside the
    /// stack its C only bounced; once he has walked past the stack it goes.
    public var stackInvitation: Int? {
        guard let s = invitedStack, mode != .compare, mode != .allBursts,
              currentBurst?.frames.contains(s.top) == true,
              frameIndex < s.range.upperBound else { return nil }
        return s.count
    }

    /// A 1:1 cut in flight: the fitted picture is shown scaled at the new
    /// offset with a small indicator, never a blank frame and never a spinner
    /// over the photograph.
    public var sharpening = false

    /// The viewport the stage is actually drawing into, in points, and the
    /// screen it is on. Set by the stage; read by everything that has to know
    /// how big a picture to ask for.
    public var viewport: CGSize = .zero
    public var backingScale: CGFloat = 2

    /// Settings ▸ Choosing (§2.11), read at the press, so a change there
    /// counts from his next key. Four of its switches used to be written and
    /// never read: Space opened Full Image whichever way he had set it, the
    /// strip came up after D with it turned off, and the other two did
    /// nothing at all.
    @ObservationIgnored public var settings: SettingsStore = .shared


    // MARK: - going through the presses in order

    /// A press, and whether it is one step of an arrow held down, which the
    /// stage spends from its display link. A held arrow runs through a burst
    /// but never out of it: crossing a burst is a fresh press.
    /// `at` is when he pressed it, which is what the strip after D is timed
    /// against: a digit pressed while it was up still answers it when the
    /// press is applied a moment later, behind a crossing.
    private struct Queued: Sendable { let action: KeyMap.Action; let held: Bool; let at: Date }
    private var presses: AsyncStream<Queued>.Continuation?
    private var pump: Task<Void, Never>?
    /// What the bench counts.
    public private(set) var verdictsWritten = 0
    public private(set) var pressesIgnoredAsRepeat = 0

    public init(session: ShootSession, navigation: Navigation) {
        self.session = session
        self.navigation = navigation
        let (stream, continuation) = AsyncStream<Queued>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.presses = continuation
        self.pump = Task { [weak self] in
            for await press in stream {
                guard let self else { return }
                await self.apply(press.action, held: press.held, pressedAt: press.at)
            }
        }
        goToResume()
    }

    /// The window closing, or the step changing. The queue is finished and the
    /// consumer stops; anything already accepted has already been applied.
    public func close() {
        presses?.finish()
        presses = nil
        pump?.cancel()
        pump = nil
    }

    /// The event AppKit is handling as a press arrives, or nothing; a test's
    /// own, since a test has no event loop to hand one over.
    @ObservationIgnored var currentEvent: () -> NSEvent? = { NSApp?.currentEvent }

    /// A press. Returns at once; the work happens in order behind it.
    ///
    /// Rule 5 again here, for the keys that never reach `key(_:)`. Keep,
    /// Drop and Next Burst on the bar carry K, D and N as their shortcuts,
    /// and AppKit offers a key to those before the photograph — repeats
    /// included. So a K held down kept a frame per repeat, and with Settings
    /// ▸ Choosing's Go to the next burst chosen it ran on out of the burst,
    /// recording burst after burst as been through; a held N did that on its
    /// own. Whichever control took the key, a held key that is not movement
    /// is one press.
    public func perform(_ action: KeyMap.Action) {
        if let e = currentEvent(), e.type == .keyDown, e.isARepeat, !action.allowsRepeat {
            ignoreHeld(action)
            return
        }
        resumeNoteShown = false
        presses?.yield(Queued(action: action, held: false, at: Date()))
    }

    /// One step of an arrow held down, spent by the stage's display link one
    /// per refresh. It moves exactly as → and ← do, except that a held →
    /// stops at the end of the burst: leaving a burst forward records it as
    /// been through, which is a claim about his work, and like N that takes a
    /// press of its own rather than a key that happened to still be down.
    public func performHeldMove(forward: Bool) {
        performHeld(forward ? .nextFrame : .previousFrame)
    }

    /// One move of a held key: an arrow's, spent by the stage one per
    /// refresh, or ↑ ↓ and the ⇧-arrows as they repeat. It goes through the
    /// same queue, in order, and stops at an edge with one bump for the hold
    /// (`bumpAtEnd(held:)`); a held → never finishes a burst (rule 5).
    public func performHeld(_ action: KeyMap.Action) {
        resumeNoteShown = false
        presses?.yield(Queued(action: action, held: true, at: Date()))
    }

    /// A key event, from the one path every key takes to the light table
    /// (`LightTableKeys`). This is rule 5's first half: a repeat of anything
    /// that is not movement never becomes a press at all.
    public func key(_ press: KeyMap.Press, at time: TimeInterval = 0) -> Bool {
        guard let action = KeyMap.action(for: press, mode: keyMode,
                                         spaceShowsWholePicture: settings.spaceShowsWholePicture)
        else { return false }
        // ⇧⌘Z puts back what ⌘Z took back last (§2.5.5); with nothing of his
        // to redo it is the Edit menu's, and `LightTableKeys` decides whether
        // the menu has anything to redo. Esc is always the light table's, even with
        // nothing to leave: nothing else in its window answers Esc, so passing
        // it on only sounded the system beep, every time he pressed it once
        // too often after Space or Compare.
        if action == .redo, !session.undo.canRedo { return false }
        if action == .toggleFullImage && !press.isARepeat {
            spaceDown = (time, turnsOn: !fullImage)
        }
        if press.isARepeat && !action.allowsRepeat {
            ignoreHeld(action)
            return true          // eaten, deliberately: it is not the system's
        }
        // A held arrow is spent by the stage that is drawing, one move per
        // display refresh, however fast the key repeats (§2.5.3).
        if press.isARepeat, action == .nextFrame || action == .previousFrame {
            if let stage = heldMoves { stage.hold(action == .nextFrame ? 1 : -1) } else { performHeld(action) }
            return true
        }
        // Any other held movement (↑ ↓, and ⇧-arrows) goes in as held too, so
        // it stops at an edge with one bump, not one bump per repeat.
        if press.isARepeat { performHeld(action); return true }
        perform(action)
        return true
    }

    /// A repeat of a key held down, counted and dropped, and said once.
    private func ignoreHeld(_ action: KeyMap.Action) {
        pressesIgnoredAsRepeat += 1
        if action.explainsHeldKey && !heldKeyTipShown {
            heldKeyTipShown = true
            showHeldKeyTip = true
            Task { try? await Task.sleep(for: .seconds(4)); self.showHeldKeyTip = false }
        }
    }

    /// A key let go.
    public func keyReleased(_ press: KeyMap.Press, at time: TimeInterval = 0) {
        heldMoves?.letGo()
        guard press.key == .space else { return }
        // Space held longer than 300 ms is a peek, and letting go ends it
        // (§2.5.7). Nothing ever set the peek, so a held Space left Full Image
        // up and he had to press it again.
        if let d = spaceDown, d.turnsOn, time - d.time >= Self.peekAfter { fullImageIsMomentary = fullImage }
        spaceDown = nil
        fullImageKeyReleased()
    }

    /// When Space went down, and whether that press was the one turning Full
    /// Image on — a Space that leaves it is never a peek.
    @ObservationIgnored private var spaceDown: (time: TimeInterval, turnsOn: Bool)?
    static let peekAfter: TimeInterval = 0.3

    /// The stage that is drawing, which spends held arrows one per refresh.
    /// None while Compare or All Bursts is up: their arrows move a ring, and
    /// each repeat is a press of its own.
    @ObservationIgnored public weak var heldMoves: (any HeldMoves)?

    public var keyMode: KeyMap.Mode {
        if fullImage { return .fullImage }
        switch mode {
        case .single: return .single
        case .compare: return .compare
        case .allBursts: return .allBursts
        case .review: return .review
        }
    }

    // MARK: - where he is

    public var bursts: [Burst] { session.bursts }
    public var burstIndex: Int { session.cursor.burst }
    public var currentBurst: Burst? { session.currentBurst }
    public var frames: [String] { currentBurst?.frames ?? [] }
    public var frameIndex: Int { session.cursor.frame }
    public var currentStem: String? { session.currentStem }
    public var currentRow: Row? { session.currentRow }

    /// The stacks of the burst he is in. Recomputed when the burst changes.
    public var stacks: [Stack] {
        Stacks.of(burst: frames, rows: session.rows)
    }

    public var currentStack: Stack? {
        currentStem.flatMap { Stacks.stack(for: $0, in: stacks) }
    }

    public var isLastFrameOfBurst: Bool { !frames.isEmpty && frameIndex == frames.count - 1 }
    public var isLastBurst: Bool { burstIndex >= bursts.count - 1 }

    // MARK: - the tally and the captions (§2.5.2)

    /// His numbers, for this burst. Never the cull's.
    public var tally: (kept: Int, out: Int, toGo: Int) {
        var kept = 0, out = 0, toGo = 0
        for stem in frames {
            guard let r = session.rows[stem] else { continue }
            switch VerdictValue.his(r) {
            case .kept: kept += 1
            case .out: out += 1
            case .unmarked: toGo += 1
            }
        }
        return (kept, out, toGo)
    }

    /// His keepers in a burst: the tally's own count, by the same rule, for
    /// every burst at once. The scrubber and All Bursts' covers printed the
    /// engine's number instead, which was read once when the shoot opened and
    /// counts the cull's picks left standing in a burst he has been through
    /// — so the cover of the burst he was in said "14 kept" beside a tally
    /// saying "Kept 15". Worked out once per change to his marks, not once
    /// per cover per draw.
    public func keptByHim(in burst: Burst) -> Int {
        let version = session.rowsVersion
        if keptCounts.version != version || keptCounts.bursts != bursts.count {
            let rows = session.rows
            var counts: [String: Int] = [:]
            for b in bursts {
                var n = 0
                for stem in b.frames {
                    if let r = rows[stem], VerdictValue.his(r) == .kept { n += 1 }
                }
                counts[b.id] = n
            }
            keptCounts = (version, bursts.count, counts)
        }
        return keptCounts.counts[burst.id] ?? 0
    }

    @ObservationIgnored private var keptCounts: (version: Int, bursts: Int, counts: [String: Int]) = (-1, -1, [:])

    /// In a burst he has been through, the frames he left alone are not work
    /// to go: they are the cull's call, agreed — the hollow mark in the strip.
    public var tallyText: String {
        let t = tally
        return (currentBurst?.seen ?? false)
            ? Strings.LightTable.tallyAgreed(kept: t.kept, out: t.out, agreed: t.toGo)
            : Strings.LightTable.tally(kept: t.kept, out: t.out, toGo: t.toGo)
    }

    public var frameCaption: String {
        guard let stem = currentStem else { return "" }
        return Strings.LightTable.frameCaption(ShootSession.shortStem(stem), burst: burstIndex + 1)
    }

    /// What the cull said about this frame, in grey, in its own words. It is
    /// never a tick and never a colour he uses.
    public var cullLine: String { cullLine(for: currentRow) }

    /// Only ever the cull's own fields. It used to print **his** reason here —
    /// he put a frame out with 1, and the cull was credited with "a fault it
    /// can name — shadow" on a frame it had only rated below the cut — while
    /// the fault the cull did name ("blink", on 131 frames of his night) was
    /// never shown on the light table at all. The words are the report's, so
    /// the report and the frame say the same thing.
    public func cullLine(for row: Row?) -> String {
        guard let r = row else { return "" }
        if let fault = Self.cullFault(r) { return Strings.LightTable.cullFault(fault) }
        switch r.rating {
        case 5: return Strings.LightTable.cullClearWin
        case 3, 4: return r.borderline != nil
            ? Strings.LightTable.cullMaybeWhy(Strings.LightTable.softerThanMost)
            : Strings.LightTable.cullMaybe
        default: return Strings.LightTable.cullAside
        }
    }

    /// The fault the cull named, in the report's words, for a frame it put
    /// aside for one (its 0). Nothing for any other frame.
    public static func cullFault(_ r: Row) -> String? {
        guard r.rating == 0, let raw = r.reason?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        return Strings.Cull.reasonWord(raw)
    }

    /// His own line, which never shares a field or a shape with the cull's.
    /// His reason is his, so it is said here: "you put this out — shadow".
    public var hisLine: String { hisLine(for: currentRow) }

    public func hisLine(for row: Row?) -> String {
        guard let r = row else { return "" }
        switch VerdictValue.his(r) {
        case .kept: return Strings.LightTable.youKept
        case .out:
            return r.label.isEmpty ? Strings.LightTable.youPutOut
                                   : Strings.LightTable.youPutOutBecause(word(for: r.label))
        case .unmarked:
            return (currentBurst?.seen ?? false) ? Strings.LightTable.youAgreed
                                                 : Strings.LightTable.youHaventMarked
        }
    }

    private func word(for label: String) -> String {
        DropReason(rawValue: label)?.word ?? label
    }

    /// The end-of-burst line, or nothing.
    ///
    /// Nothing while he looks through the frames one fault covers (§2.6):
    /// there → and N go to the next of them, and the line over the photograph
    /// says so. "Next burst: → or N" under it said the opposite, and on the
    /// last burst its Continue recorded the burst he was only looking in.
    public var endOfBurstLine: String? {
        guard isLastFrameOfBurst, !frames.isEmpty, lookingThrough == nil else { return nil }
        let t = tally
        if isLastBurst {
            return Strings.LightTable.endOfShoot(kept: session.info.kept, of: session.info.frames)
        }
        if currentBurst?.seen == true {
            return Strings.LightTable.endOfBurstAgreed(burstIndex + 1, kept: t.kept, out: t.out, agreed: t.toGo)
        }
        return Strings.LightTable.endOfBurstGoOn(burstIndex + 1, kept: t.kept, out: t.out, unmarked: t.toGo)
    }

    /// Whether N, → off the last frame and the bar's button have a burst to
    /// finish: any burst but the last, and the last until it has been through.
    /// The button used to be greyed on the whole of the last burst while N
    /// quietly recorded it; finished once, a second N there wrote it again
    /// and took another undo step.
    public var canFinishBurst: Bool {
        !isLastBurst || !(currentBurst?.seen ?? true)
    }

    /// N on the last burst: nothing after it to open, so it finishes that
    /// burst — when it is not finished yet — and goes on to Presets, as
    /// Continue to Presets does (§2.5.2). Not in All Bursts, where N goes to
    /// a burst he has not been through, and not in the learning screen's
    /// review, which is a look back and not a way on. Nor while he looks
    /// through a fault's frames, where N goes to the next burst that has any
    /// of them and records nothing (§2.6).
    public var nextBurstLeavesForPresets: Bool {
        isLastBurst && (mode == .single || mode == .compare) && lookingThrough == nil
    }

    /// Whether N, the bar's Next Burst and Frame ▸ Next Burst do anything
    /// from here: finish this burst and open the next, or — on the last —
    /// go on to Presets, finished or not. In All Bursts N finishes nothing
    /// and goes to a burst not looked through, so it is live while one is
    /// left, from any cover: read from the finish, it stayed live with every
    /// burst looked through, where a press only bounced, and went grey on
    /// the last cover while other bursts were still to do.
    public var canGoToNextBurst: Bool {
        if mode == .allBursts { return bursts.contains { !$0.seen } }
        return canFinishBurst || nextBurstLeavesForPresets
    }

    /// Continue, on the line at the end of the last burst: it records that
    /// burst as been through, as N would (§2.5.13), and says whether to go
    /// on. A refused write keeps him here, where the refusal is. While he
    /// looks through a fault's frames it records nothing and goes on, as ⌘]
    /// anywhere short of the end does: looking is not going through (§2.6).
    public func finishBeforeContinuing() async -> Bool {
        guard lookingThrough == nil, currentBurst?.seen == false else { return true }
        if case .refused = await session.finishBurst() { return false }
        return true
    }

    /// Whether Go ▸ Next Step (⌘]) has the last burst to record before it
    /// leaves: on the last frame of a last burst he has not finished, where
    /// the line he reads offers ⌘] as Continue's own key. Anywhere else ⌘]
    /// leaves and records nothing, as it always has — leaving a burst part
    /// way through is not going through it, and nor is looking through a
    /// fault's frames (§2.6), where no line offers Continue.
    public var nextStepFinishesTheShoot: Bool {
        isLastBurst && isLastFrameOfBurst && currentBurst?.seen == false && lookingThrough == nil
    }

    public var unmarkedInBurst: Int? {
        Stacks.firstUnmarked(in: frames, rows: session.rows)
    }

    /// Where the end line's link goes: the first frame he has not marked, in
    /// a burst he has not been through. In one he has, those frames are the
    /// cull's call agreed — the line says so — and a link calling them
    /// unmarked beside it said the opposite, and called sixteen frames "the
    /// one".
    public var unmarkedLink: Int? {
        currentBurst?.seen == false ? unmarkedInBurst : nil
    }

    /// The zoom label, which always says where 1:1 is pointing.
    public var zoomLabel: String? {
        guard !zoom.isFit else { return nil }
        return Aim.zoomLabel(percent: zoom.percent(framePixels: framePixels, viewport: viewport, scale: backingScale),
                             aim: aim)
    }

    public var aim: Aim.Point { Aim.resolve(currentRow, held: heldAim) }

    public var framePixels: CGSize {
        guard let r = currentRow, let w = r.dw, let h = r.dh, w > 0, h > 0 else {
            return CGSize(width: 6024, height: 4024)
        }
        return CGSize(width: w, height: h)
    }

    public var aspect: CGFloat {
        let p = framePixels
        return p.height > 0 ? p.width / p.height : LightTableGeometry.landscape
    }

    /// The way round **the shoot** was mostly shot, worked out once.
    ///
    /// The inspector's default reads this rather than `aspect`, because the
    /// frame under the cursor is not a property of the screen: on a shoot that
    /// mixes the two — his dog shoot has 16 portrait frames of 54 — reading
    /// the current frame made the inspector, and with it the width of the
    /// control bar's column, depend on where he happened to be standing when
    /// the step appeared.
    public var shootAspect: CGFloat {
        if let a = cachedShootAspect { return a }
        var portrait = 0, landscape = 0
        for stem in session.order {
            guard let r = session.rows[stem], let w = r.dw, let h = r.dh, w > 0, h > 0 else { continue }
            if w < h { portrait += 1 } else { landscape += 1 }
        }
        let a = portrait > landscape ? LightTableGeometry.portrait : LightTableGeometry.landscape
        cachedShootAspect = a
        return a
    }

    @ObservationIgnored private var cachedShootAspect: CGFloat?

    // MARK: - the display gate (§2.5.4)

    /// Reported by the stage from its display link, once a picture for this
    /// `(stem, generation)` has been committed *and* one refresh has passed.
    public func didDisplay(stem: String, generation: Int) {
        session.didDisplay(stem: stem, generation: generation)
    }

    /// A Compare tile reports itself the same way. The focused tile is also the
    /// frame the cursor is on, so it satisfies the same gate: a verdict in
    /// Compare is taken on pixels that are on the screen, side by side with the
    /// ones he is comparing them against.
    public func didDisplayTile(_ stem: String) {
        session.didDisplayTile(stem: stem)
        if stem == compareFocus {
            session.didDisplay(stem: stem, generation: session.cursor.generation)
        }
    }

    // MARK: - applying one press, in order

    private func apply(_ action: KeyMap.Action, held: Bool = false, pressedAt: Date = Date()) async {
        // Every hold starts with a press of its own, so a press that is not
        // a held repeat is where the next hold may bump again.
        if !held { bumpedThisHold = false }
        // A reason pressed while the strip after D is up is about the frame D
        // put out, in every mode (§2.5.3).
        if case .reason(let n) = action, let target = reasonTarget(pressedAt: pressedAt) {
            guard let r = DropReason.forKey(n) else { return }
            await settled(target)
            // The D it answers can be refused while this waits. That frame is
            // then not out, the strip was asking about nothing, and the digit
            // goes nowhere: labelling it would put it out again unasked, and
            // on a frame he had kept, ask him about a frame behind him.
            guard reasonTarget(pressedAt: pressedAt) == target else { closeReasonStrip(); return }
            await giveReason(r, on: target)
            return
        }
        // In Compare, K and D decide the **focused tile** and move to the next
        // member with no verdict yet — not the cursor's own idea of "next".
        if mode == .compare, action.isVerdict, action != .keepOnly {
            await allSettled()
            await decideInCompare(action)
            return
        }
        // All Bursts shows covers, not a frame: a verdict there would land on
        // a frame hidden behind the grid. The menu rows are greyed; the key
        // is refused the same way, with a bump and nothing written. So are
        // Space and the zoom, whose rows are greyed there too: Space used to
        // put up Full Image of the frame behind the grid.
        if mode == .allBursts, action.isVerdict || action.looksAtTheFrame {
            if !held { haptic(.generic) }
            return
        }
        // In the learning screen's read-only review nothing can be marked, and
        // the line that says so goes where the press was (§2.9).
        if case .review = mode, action.isVerdict {
            session.refusals.set(.verdict, Strings.LightTable.reviewNoVerdicts, at: currentStem)
            haptic(.generic)
            return
        }

        if lookingThrough != nil, await lookingThroughTakes(action, held: held) { return }

        switch action {
        case .keep:
            // A K is his next decision, so the question about the frame D put
            // out is closed: a digit after it is about the frame on screen.
            closeReasonStrip()
            let last = isLastFrameOfBurst
            let newest = session.undo.steps.last?.id
            let outcome = await take(.keep)
            await goOnAfterLastFrame(last, after: outcome, newestBefore: newest)
        case .drop:
            let stem = currentStem
            let last = isLastFrameOfBurst
            let newest = session.undo.steps.last?.id
            let outcome = await take(.drop)
            raiseReasonStrip(for: stem, after: outcome)
            await goOnAfterLastFrame(last, after: outcome, newestBefore: newest)
        case .clearMark:
            closeReasonStrip()
            await take(.clear)
        case .reason(let n):
            // No strip up: the frame on screen, put out if it was not, and on
            // to the next the way D goes on.
            guard let r = DropReason.forKey(n) else { return }
            let stem = currentStem
            await settled(stem)
            let last = isLastFrameOfBurst
            let newest = session.undo.steps.last?.id
            let outcome = await write { await self.session.reason(r, advance: true) }
            if outcome == .needsConfirmation {
                reasonNeedingConfirmation = r
                reasonConfirmationStem = stem
            }
            await goOnAfterLastFrame(last, after: outcome, newestBefore: newest)

        case .previousFrame:
            if mode == .compare { moveCompareFocus(-1, held: held) }
            else if mode == .allBursts { moveBurst(-1, held: held) }
            else { await move(-1, held: held) }
        case .nextFrame:
            if mode == .compare { moveCompareFocus(1, held: held) }
            else if mode == .allBursts { moveBurst(1, held: held) }
            else { await move(1, held: held) }
        case .previousPick:
            if mode == .allBursts { moveBurstRow(-1, held: held) } else { movePick(forward: false, held: held) }
        case .nextPick:
            if mode == .allBursts { moveBurstRow(1, held: held) } else { movePick(forward: true, held: held) }

        case .nextBurst:
            // In All Bursts, N jumps to the next burst not been through. It
            // records nothing: only finishing a burst does (§2.5.11, §2.5.13).
            if mode == .allBursts {
                if let i = bursts.indices.first(where: { $0 > burstIndex && !bursts[$0].seen })
                    ?? bursts.indices.first(where: { !bursts[$0].seen }) {
                    goToBurst(i)
                } else { bumpAtEnd() }
            } else if nextBurstLeavesForPresets {
                // On the last burst there is no next one to open, and what
                // comes next is Presets: N finishes the burst, if it is not
                // finished yet, and goes on, as Continue to Presets does. It
                // used to finish it and stay, and a second N only bounced, so
                // the end of every shoot cost a trip to the link or ⌘]. Full
                // Image and Compare are put down first, so coming back to
                // Choose Keepers is not coming back into them.
                if fullImage { setFullImage(false) }
                leaveMode()
                await continueToPresets()
            } else {
                await nextBurst()
            }
        case .previousBurst: previousBurst()

        case .toggleFullImage: toggleFullImage()
        case .oneToOne:
            zoom.goToOneToOne()
            haptic(.alignment)
        // Z checks focus and Z again comes back: it used to go to 1:1 and
        // stay there, and the way back was ⌘9 or a double-click. From a
        // pinched 60 % or 150 % it goes to 1:1, which is what Z is for; only
        // Z at 1:1 goes back to Fit.
        case .toggleOneToOne:
            if zoom.state == .factor(1) { zoom.goToFit() } else { zoom.goToOneToOne() }
            haptic(.alignment)
        case .fit: zoom.goToFit()
        case .zoomIn: zoom.step(1, framePixels: framePixels, viewport: viewport, scale: backingScale)
        case .zoomOut: zoom.step(-1, framePixels: framePixels, viewport: viewport, scale: backingScale)
        case .pan(let dx, let dy):
            let f = zoom.factor(framePixels: framePixels, viewport: viewport, scale: backingScale)
            zoom.pan(by: CGVector(dx: CGFloat(-dx) * 60, dy: CGFloat(-dy) * 60),
                     aim: aim, framePixels: framePixels, viewport: viewport,
                     factor: f, scale: backingScale)

        // C again goes back, as G does for All Bursts.
        case .compare: if mode == .compare { leaveMode() } else { openCompare() }
        case .keepOnly:
            await allSettled()
            await keepOnlyFocused()
        // G again goes back, as Return and Esc do (§2.5.11).
        case .allBursts:
            if mode == .allBursts { leaveMode() } else { leaveMode(); mode = .allBursts }
        case .single: leaveMode()
        case .undo:
            // The strip asks about a drop; once a drop may have been taken
            // back it is no longer a question worth answering.
            closeReasonStrip()
            // The newest step may be a write still on its way; its answer
            // comes first, so the undo is never overtaken by the thing it
            // takes back.
            await allSettled()
            let burst = currentBurst?.id
            if await session.undoLast() == .applied { afterUndoOrRedo(from: burst) }
        case .redo:
            // ⇧⌘Z: what ⌘Z took back last, put back, on its frame (§2.5.5).
            closeReasonStrip()
            await allSettled()
            let burst = currentBurst?.id
            if await session.redoLast() == .applied { afterUndoOrRedo(from: burst) }
        // The Help menu's own row, so ? opens exactly what ⌘/ opens. It used
        // to send a selector nothing in the app answers, and "Press ? for the
        // rest" led nowhere.
        case .shortcuts: _ = CommandCenter.shared.run(CommandTable.ID.shortcuts)
        case .leave: leave()
        }
    }

    /// Undo and redo go to the frame they change, which can be in another
    /// burst; arriving there is arriving in a burst, as any other way in is.
    private func afterUndoOrRedo(from burst: String?) {
        if currentBurst?.id != burst { enteredBurst() }
        syncAfterMove()
    }

    /// K, D or 0 on the frame on screen, **without waiting for the engine**.
    ///
    /// The model, the undo step and the move to the next frame happen now, as
    /// they always did; the write goes on its own and his next press is taken
    /// at once. Every press used to wait for the engine to save the one before
    /// — about 45 ms on his 1,558-frame shoot with the engine idle, far longer
    /// while a job ran — arrows and Space included, so a quick K → felt
    /// sticky. A write the engine refuses still takes back its own step and
    /// says so. What must not overtake it waits for it: another verdict on the
    /// same frame, an undo, and anything that decides several frames at once.
    ///
    /// `advance`: whether the cursor goes on to the next frame of the burst,
    /// as K and D do and clearing a mark does not. Looking through a fault's
    /// frames passes false and goes to the next of them itself (§2.6).
    @discardableResult
    private func take(_ p: ShootSession.Press, advance: Bool? = nil) async -> VerdictOutcome {
        // A click can move him while this waits, so it is the frame he is on
        // when the wait ends that must have nothing on its way.
        while let stem = currentStem, let t = inFlight[stem] { await t.value }
        switch session.take(p, advance: advance ?? (p != .clear)) {
        case .done(let outcome):
            if case .refused = outcome { haptic(.generic) } else { syncAfterMove() }
            return outcome
        case .writing(let w):
            haptic(.levelChange)
            syncAfterMove()
            inFlight[w.stem] = Task { [weak self] in
                guard let self else { return }
                let outcome = await self.session.settle(w)
                self.inFlight[w.stem] = nil
                self.answered(outcome, on: w.stem)
            }
            return .applied
        }
    }

    /// Single-frame writes still on their way, by frame.
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]

    private func settled(_ stem: String?) async {
        if let stem, let t = inFlight[stem] { await t.value }
    }

    /// Every write still on its way, answered. What ⌘Z, ⇧⌘Z and the presses
    /// that decide several frames at once wait for, and what the tests wait
    /// for.
    public func allSettled() async {
        while let t = inFlight.values.first { await t.value }
    }

    private func answered(_ outcome: VerdictOutcome, on stem: String) {
        switch outcome {
        case .applied:
            verdictsWritten += 1
        case .refused:
            haptic(.generic)
            // Its drop taken back, the frame is not out, and the strip would
            // be asking why about nothing.
            if reasonStripStem == stem, stripFrame == nil { closeReasonStrip() }
        case .unchanged, .needsConfirmation:
            break
        }
    }

    @discardableResult
    private func write(_ act: () async -> VerdictOutcome) async -> VerdictOutcome {
        let outcome = await act()
        switch outcome {
        case .applied:
            verdictsWritten += 1
            haptic(.levelChange)
            syncAfterMove()
        case .refused:
            haptic(.generic)
        case .unchanged, .needsConfirmation:
            syncAfterMove()
        }
        return outcome
    }

    // MARK: - why it is out (§2.5.3)

    /// The frame a digit pressed at `at` goes to: the one D put out, if the
    /// strip naming it was up when he pressed — not when the press is
    /// applied, which can be later — and that frame is still out. Once the
    /// strip has gone, or that frame has been kept or taken back since, a
    /// digit means what it means without the strip — the frame on screen.
    func reasonTarget(pressedAt at: Date = Date()) -> String? {
        guard let until = reasonStripUntil, at < until else { return nil }
        return stripFrame
    }

    /// The frame the strip names, while it is still out.
    private var stripFrame: String? {
        guard let stem = reasonStripStem, let row = session.rows[stem],
              VerdictValue.his(row) == .out else { return nil }
        return stem
    }

    /// Up only for a D that took: a D that was refused put nothing out, and a
    /// strip asking why it is out would be asking about nothing. A D on a
    /// frame that was already out still asks, because the reason is still his
    /// to give.
    private func raiseReasonStrip(for stem: String?, after outcome: VerdictOutcome) {
        guard settings.reasonsStripAfterDrop,
              let stem, outcome == .applied || outcome == .unchanged,
              let row = session.rows[stem], VerdictValue.his(row) == .out else { return }
        reasonStripStem = stem
        reasonStripUntil = Date().addingTimeInterval(3)
    }

    private func closeReasonStrip() {
        reasonStripUntil = nil
        reasonStripStem = nil
    }

    /// A reason for the frame D put out. It moves nothing: he is already on
    /// the next frame, and that is where he stays.
    private func giveReason(_ r: DropReason, on stem: String) async {
        let outcome = await session.reason(r, on: stem)
        switch outcome {
        case .applied:
            verdictsWritten += 1
            haptic(.levelChange)
            closeReasonStrip()
        case .refused:
            haptic(.generic)
        case .needsConfirmation:
            reasonNeedingConfirmation = r
            reasonConfirmationStem = stem
        case .unchanged:
            break
        }
    }

    /// He answered the question a reason on a kept frame asks, about the frame
    /// it asked about.
    public func confirmReason(_ r: DropReason) async {
        reasonNeedingConfirmation = nil
        let stem = reasonConfirmationStem
        reasonConfirmationStem = nil
        let outcome = if let stem {
            await session.reason(r, on: stem, confirmedOnKept: true)
        } else {
            await session.reason(r, confirmedOnKept: true)
        }
        if outcome == .applied { verdictsWritten += 1 }
    }

    // MARK: - moving

    /// The arrows run the whole shoot, not one burst of it.
    ///
    /// They used to stop dead at each end of a burst and bounce, so N was the
    /// only way on and the only way back was the scrubber. He asked for them
    /// to carry on, and they do — but the two directions are not symmetrical,
    /// because one of them is a claim about work he has done.
    ///
    /// FORWARD off the last frame is leaving the burst forward, which is what
    /// records it as been through (§7.4). It is the same write N makes, by the
    /// same call, so it takes an undo step, it is refused the same way when the
    /// engine is not there, and the burst it marks is the one he was in. Any
    /// other choice breaks something: not recording it means his count and his
    /// resume point never move once he stops pressing N, and recording it by a
    /// different route means two ways of marking a burst that could disagree.
    ///
    /// BACK off the first frame records nothing and lands on the LAST frame of
    /// the burst before — where he would have been had he walked there — and
    /// going back has never recorded anything.
    ///
    /// The crossing is **awaited**, as N is, so every press after it waits in
    /// the queue until he is in the next burst. It used to run on its own: a
    /// second → saw the cursor still on the last frame and finished the same
    /// burst again — two been-through writes, two undo steps, the second named
    /// after the burst he had arrived in — and a K pressed straight after
    /// the → was taken on the frame he was leaving.
    ///
    /// A HELD → stops at the end of the burst, with one bounce: leaving a
    /// burst forward is a claim about his work, and like N it takes a press
    /// of its own, not a key that happened to still be down. A held ← goes
    /// on back across bursts as it always has, because going back records
    /// nothing, and bounces once at the start of the shoot.
    private func move(_ delta: Int, held: Bool = false) async {
        let moved = delta > 0 ? session.nextFrame() : session.previousFrame()
        if moved {
            syncAfterMove(forward: delta > 0)
            return
        }
        if held && (delta > 0 || burstIndex == 0) {
            // One bounce for the hold, not one per refresh while it lasts,
            // and what the stage still has pending is dropped.
            bumpAtEnd(held: true)
            return
        }
        if delta > 0 { await crossForward() } else { crossBack() }
    }

    /// → past the end of a burst: finish it, exactly as N does. On the last
    /// frame of the shoot there is nowhere to go, but the burst is still his
    /// to finish: the first → records it, as N does, and the line at the end
    /// of the shoot says what is next; after that → only bounces.
    ///
    /// `joining`: the undo step of the verdict that went on, which the
    /// finish joins so one Q takes back the press (`goOnAfterLastFrame`).
    ///
    /// Never while he looks through a fault's frames (§2.6), which records
    /// nothing as been through: → there is the list's, and this only bumps
    /// should anything reach it.
    private func crossForward(joining verdict: UUID? = nil) async {
        guard lookingThrough == nil else { bumpAtEnd(); return }
        guard bursts.indices.contains(burstIndex + 1) else {
            if canFinishBurst, await session.finishBurst(joining: verdict) == .applied {
                haptic(.levelChange)
            } else {
                bumpAtEnd()
            }
            return
        }
        prefetchNextBurst()
        if await session.finishBurst(joining: verdict) == .applied {
            enteredBurst()
            syncAfterMove(forward: true)
        } else {
            bumpAtEnd()
        }
    }

    /// ← past the start of a burst: the last frame of the one before, and
    /// nothing written.
    private func crossBack() {
        let i = burstIndex - 1
        guard bursts.indices.contains(i) else { bumpAtEnd(); return }
        session.go(burst: i, frame: max(0, bursts[i].frames.count - 1))
        enteredBurst()
        syncAfterMove(forward: false)
    }

    /// Settings ▸ Choosing ▸ "After the last frame of a burst": with Go to
    /// the next burst chosen — the default — K, D or a reason on the last
    /// frame finishes the burst and opens the next, as → there does, so the
    /// end of a burst never needs a press of its own. He asked not to have to
    /// press N at the end of every burst, and the setting that did it sat
    /// switched off. Stay here leaves him on the last frame with the line
    /// that says what is left. A press that was refused, or asks first, goes
    /// nowhere. Nor does one while he looks through a fault's frames (§2.6),
    /// whatever Settings says. On the last burst it records the burst and
    /// stays, as → does: the line there offers Presets, and N takes him
    /// (§2.5.2).
    ///
    /// It is one press, so it is one undo (§2.5.5): the finish joins the
    /// step the verdict pushed — the newest now, where it was not before
    /// the press — and one Q takes back the mark and the burst's record and
    /// puts him back on the frame. A press that pushed nothing (K on a frame
    /// already kept) leaves the finish a step of its own, which is all that
    /// press did.
    private func goOnAfterLastFrame(_ wasLast: Bool, after outcome: VerdictOutcome,
                                    newestBefore: UUID?) async {
        guard wasLast, lookingThrough == nil, outcome == .applied || outcome == .unchanged,
              settings.afterLastFrameGoesOn, isLastFrameOfBurst, canFinishBurst else { return }
        let pushed = session.undo.steps.last?.id
        await crossForward(joining: pushed != newestBefore ? pushed : nil)
    }

    private func movePick(forward: Bool, held: Bool = false) {
        guard let next = Stacks.nextPick(from: frameIndex, frames: frames, rows: session.rows,
                                         stacks: stacks, forward: forward) else {
            // On the last frame the end line offers "the one you haven't
            // marked (↓)", and ↓ bounced: nothing the cull put forward lies
            // past the end. ↓ goes where the line says.
            if forward, isLastFrameOfBurst, let i = unmarkedInBurst, i != frameIndex {
                goToFrame(i)
            } else {
                bumpAtEnd(held: held)
            }
            return
        }
        session.go(burst: burstIndex, frame: next)
        syncAfterMove(forward: forward)
    }

    /// → on the last frame of the LAST burst, or ← on the first frame of the
    /// first: an 8 pt rubber-band bounce and a light haptic. No wrap. Between
    /// bursts the arrows cross (see `move`); this is the end of the shoot.
    ///
    /// **Once per hold.** A held arrow that reaches an edge stops there, and
    /// every repeat after that used to bump again: a fresh 120 ms shove and a
    /// haptic every 33 ms for as long as the key stayed down, so the picture
    /// sat 8 pt off and shuddered at the end of every burst he skimmed. Now
    /// one bump answers a hold, whether the press itself or its first repeat
    /// met the edge; the repeats after it are quiet, and what the stage still
    /// has pending is dropped. A press of its own — which every hold starts
    /// with — may bump again.
    public var bump = 0
    @ObservationIgnored private var bumpedThisHold = false
    private func bumpAtEnd(held: Bool = false) {
        if held {
            heldMoves?.letGo()
            if bumpedThisHold { return }
        }
        bumpedThisHold = true
        bump &+= 1
        haptic(.alignment)
    }

    public func goToFrame(_ index: Int) {
        guard frames.indices.contains(index) else { return }
        resumeNoteShown = false
        // A plain click on a thumbnail, or the end-of-burst line's link, goes
        // somewhere else: a ⌘-click set waiting for C is put down, as a
        // plain click puts down a selection anywhere on the Mac. It used to
        // wait on, so C then opened a set he had clicked past instead of the
        // stack he was standing in.
        if mode != .compare { compareSelection = [] }
        let forward = index > frameIndex
        session.go(burst: burstIndex, frame: index)
        syncAfterMove(forward: forward)
    }

    /// Clicking the scrubber or a cover jumps there and **records nothing**.
    /// Only leaving a burst forward marks it as looked through (§7.4).
    /// Takes a burst back off the list of ones he has been through. The write
    /// is the session's; this is the seam the screen presses (DESIGN.md §7.4).
    public func unmarkBurst(at index: Int) {
        guard bursts.indices.contains(index) else { return }
        let id = bursts[index].id
        Task { await session.unmarkBurst(id) }
    }

    /// ↑ ↓ in All Bursts: a row of covers up or down.
    private func moveBurstRow(_ delta: Int, held: Bool = false) {
        let i = burstIndex + delta * max(1, allBurstsColumns)
        guard bursts.indices.contains(i) else { bumpAtEnd(held: held); return }
        goToBurst(i)
    }

    /// ← → in All Bursts: one cover. At either end it bumps, as ↑ ↓ do; it
    /// used to do nothing at all there.
    private func moveBurst(_ delta: Int, held: Bool = false) {
        let i = burstIndex + delta
        guard bursts.indices.contains(i) else { bumpAtEnd(held: held); return }
        goToBurst(i)
    }

    public func goToBurst(_ index: Int) {
        guard bursts.indices.contains(index) else { return }
        // Once he has gone somewhere himself, "back where you left off" is no
        // longer where he is, so it stops being said.
        resumeNoteShown = false
        session.go(burst: index)
        enteredBurst()
        syncAfterMove()
    }

    private func nextBurst() async {
        // The last burst, already been through, has nothing left to finish;
        // a second N there used to record it again. And nothing is finished
        // while he looks through a fault's frames (§2.6), whose N is theirs.
        guard canFinishBurst, lookingThrough == nil else { bumpAtEnd(); return }
        // Ask for the next burst's first frame before the wait, not after: this
        // is the single biggest wait today, about 1.8 minutes of pure waiting
        // per 155-burst session (PERF-01).
        prefetchNextBurst()
        if await session.finishBurst() == .applied {
            enteredBurst()
            syncAfterMove()
            haptic(.levelChange)
        }
    }

    private func previousBurst() {
        guard burstIndex > 0 else { bumpAtEnd(); return }
        session.go(burst: burstIndex - 1)
        enteredBurst()
        syncAfterMove()
    }

    /// "Continue to Presets" on the last frame of the last burst. It is the
    /// last burst's N (§2.5.13): the burst is recorded as been through, then
    /// the step changes. It used to change the step alone, so the last burst
    /// of every shoot stayed "not been through" and the count never reached
    /// the end. A write that is refused keeps him here, where the refusal is
    /// shown.
    public func continueToPresets() async {
        guard await finishBeforeContinuing() else { return }
        navigation.selection = .step(shoot: session.name, step: "presets")
    }

    /// Opening Choose Keepers (§2.5.13). The server resolves the target; until
    /// it does, `LightTableSeams` does, in the same order.
    public func goToResume() {
        let r = LightTableSeams.resume(for: session)
        resume = r
        if let id = r.burst_id, let i = bursts.firstIndex(where: { $0.id == id }) {
            session.go(burst: i, frame: resumeFrame(in: i))
        } else if let i = bursts.firstIndex(where: { !$0.seen }) {
            session.go(burst: i, frame: resumeFrame(in: i))
        }
        enteredBurst()
        syncAfterMove()
    }

    /// Where in a burst he left off: in one he has not finished, the frame
    /// after the furthest one he marked, so a burst he quit on frame 25 of 32
    /// reopens there rather than making him walk back over 24 frames he had
    /// been through. Not the first frame he left unmarked: he keeps with K
    /// and walks past the rest, and on a burst like that — Kept 15 · Out 1 ·
    /// 16 unmarked — the first unmarked frame is near the start. A burst he
    /// marked to its last frame opens on that frame, with the line that says
    /// what is left; one he has been through, or marked nothing in, opens at
    /// its start.
    private func resumeFrame(in i: Int) -> Int {
        guard bursts.indices.contains(i), !bursts[i].seen else { return 0 }
        let frames = bursts[i].frames
        guard let furthest = frames.lastIndex(where: { stem in
            session.rows[stem].map { VerdictValue.his($0) != .unmarked } ?? false
        }) else { return 0 }
        return min(furthest + 1, frames.count - 1)
    }

    /// Where this session opened, and the engine's own sentence about it. The
    /// note stays up until his first press: it is an answer to "where was I",
    /// not a thing to dismiss.
    public private(set) var resume: Resume = Resume(burst_id: nil, kind: .fresh, note: "")
    public var resumeNote: String? { resumeNoteShown && !resume.note.isEmpty ? resume.note : nil }
    public private(set) var resumeNoteShown = true

    /// Entering a burst: Fit, the invitation, once, and the prefetch ladder.
    ///
    /// A new burst opens at Fit (§2.5.7). The zoom is held from frame to
    /// frame of one burst, where the eyes stay in one place; it used to be
    /// carried into the next burst too, which opened at 1:1 on a face he had
    /// not yet seen whole.
    ///
    /// Compare is of frames in one burst, so it closes when he goes to
    /// another — by N, P, an arrow, the scrubber or a cover. It used to stay
    /// open on the burst he had left while the bar named the new one, and his
    /// next K kept a tile in the old burst and pulled him back to it. Frames
    /// he had picked to compare go the same way.
    private func enteredBurst() {
        if !zoom.isFit { zoom.goToFit() }
        invitedStack = nil
        autoCompared = []
        guard let b = currentBurst else { return }
        if !compareSelection.isEmpty, !compareSelection.allSatisfy(b.frames.contains) {
            if mode == .compare { leaveMode() } else { compareSelection = [] }
        }
        if !invitedBursts.contains(b.id) {
            invitedBursts.insert(b.id)
            if let biggest = stacks.max(by: { $0.count < $1.count }), biggest.count > 3 {
                invitedStack = biggest
            }
        }
        let px = prefetchPixels
        let pump = session.pump
        let shoot = session.name
        let frames = b.frames
        let cursor = frameIndex
        Task { await pump.burstOpened(shoot, frames: frames, cursor: cursor, fullPx: px) }
    }

    /// After any move: the held aim, the prefetch in the direction of travel,
    /// and the next burst when the end is in sight.
    private func syncAfterMove(forward: Bool = true) {
        heldAim = zoom.isFit ? nil : zoom.heldPosition(aim: aim)
        let px = prefetchPixels
        let pump = session.pump
        let shoot = session.name
        let f = frames
        let i = frameIndex
        Task { await pump.cursorMoved(shoot, frames: f, cursor: i, forward: forward, fullPx: px) }
        if f.count - i <= 3 { prefetchNextBurst() }
        openLargeStackIfAsked()
    }

    /// Settings ▸ Choosing ▸ "Open stacks of 4 or more in Compare", off by
    /// default (§2.5.12): arriving on a frame of such a stack, by a press of
    /// his, opens Compare on it — once per stack for as long as he stays in
    /// the burst, so Esc or S out of it is not undone by his next arrow. Never
    /// on opening the light table: that is not a press.
    private func openLargeStackIfAsked() {
        guard settings.openLargeStacksInCompare, !resumeNoteShown, mode == .single, !fullImage,
              let s = currentStack, s.count >= 4, !autoCompared.contains(s.id) else { return }
        autoCompared.insert(s.id)
        openCompare(on: s.frames)
    }

    /// The stacks of this burst that have opened in Compare by themselves.
    @ObservationIgnored private var autoCompared: Set<String> = []

    /// The `/full` size the stage will ask for at Fit: the picture fitted into
    /// the viewport, not the viewport. The prefetch used to ask for the
    /// viewport's size — a 3:2 frame in the 1084 × 526 viewer is drawn
    /// 789 pt wide, a tier smaller — so what it fetched ahead was a size the
    /// stage never asked for, and the stage then fetched its own.
    var prefetchPixels: Int {
        let a = aspect > 0 ? aspect : LightTableGeometry.landscape
        var fitted = viewport
        if viewport.width > 0, viewport.height > 0 {
            fitted = viewport.width / viewport.height > a
                ? CGSize(width: viewport.height * a, height: viewport.height)
                : CGSize(width: viewport.width, height: viewport.width / a)
        }
        return LightTableSeams.current.fullPixels(forPoints: fitted, scale: backingScale)
    }

    private func prefetchNextBurst() {
        guard bursts.indices.contains(burstIndex + 1),
              let first = bursts[burstIndex + 1].frames.first else { return }
        let px = prefetchPixels
        let pump = session.pump
        let shoot = session.name
        Task { await pump.nextBurstComing(shoot, firstFrame: first, fullPx: px) }
    }

    // MARK: - modes

    /// C. **Compare never opens by itself** (§2.5.12): this is only ever
    /// reached from a press of his.
    ///
    /// What it opens, in order: the frames he picked with ⌘-click, the stack
    /// he is standing in, and the stack the invitation names — which it goes
    /// to first, landing on the cull's guess. C used to know only the second:
    /// his picked frames were thrown away for the stack or a bounce, and the
    /// invitation's own C bounced on every frame outside its stack.
    public func openCompare(on stems: [String]? = nil) {
        let picked = mode == .compare ? [] : compareSelection
        if stems == nil, picked.count < 2, (currentStack?.count ?? 0) < 2,
           stackInvitation != nil, let s = invitedStack {
            session.go(to: s.top)
            syncAfterMove()
        }
        let set = stems ?? (picked.count >= 2 ? picked : nil) ?? currentStack?.frames ?? []
        guard set.count >= 2 else { bumpAtEnd(); return }
        comparePicked = stems == nil && picked.count >= 2
        compareSelection = Array(set.prefix(8))
        compareFocus = currentStem.flatMap { compareSelection.contains($0) ? $0 : nil } ?? compareSelection.first
        comparePage = 0
        session.clearDisplayedTiles()
        mode = .compare
    }

    /// The invitation, clicked: the stack it names, from wherever he is in
    /// the burst, opened on the cull's guess.
    public func compareInvitedStack() {
        guard let s = invitedStack, stackInvitation != nil else { return }
        if currentStack?.id != s.id {
            session.go(to: s.top)
            syncAfterMove()
        }
        openCompare(on: s.frames)
    }

    /// Whether C has anything to open from here. The menu row, the bar's
    /// button and the toolbar's segment all read this, so none of them offers
    /// a press that only bounces.
    public var canCompare: Bool {
        mode == .compare || compareSelection.count >= 2 || (currentStack?.count ?? 0) > 1
            || stackInvitation != nil
    }

    /// Compare's header: a stack the cull found is "similar"; frames he
    /// picked himself are only frames.
    public var compareHeader: String {
        comparePicked ? Strings.LightTable.comparePicked(compareSelection.count)
                      : Strings.LightTable.compareHeader(compareSelection.count)
    }

    /// The line under the picture while he is picking frames to compare.
    public var pickedLine: String? {
        guard mode == .single, !fullImage, !compareSelection.isEmpty else { return nil }
        return Strings.LightTable.pickedForCompare(compareSelection.count)
    }

    /// K / D / 0 on the focused tile, then the focus moves to the next member
    /// he has not decided. The cursor goes to the tile first, so the display
    /// gate and the undo step both name the frame he was actually looking at.
    private func decideInCompare(_ action: KeyMap.Action) async {
        guard let focus = compareFocus else { return }
        session.go(to: focus)
        // Moving the cursor onto the focused tile does not un-draw it: its
        // pixels are on the screen, beside the ones he is comparing them
        // against. So the gate is satisfied again for the move it just made —
        // and only for a tile that has actually reported itself drawn.
        if session.displayedTiles.contains(focus) {
            session.didDisplay(stem: focus, generation: session.cursor.generation)
        }
        let outcome: VerdictOutcome
        switch action {
        case .keep:
            closeReasonStrip()
            outcome = await session.keep(advance: false)
        case .drop:
            outcome = await session.drop(advance: false)
            raiseReasonStrip(for: focus, after: outcome)
        case .clearMark:
            closeReasonStrip()
            outcome = await session.clear()
        case .reason(let n):
            // A digit while the strip after D is up has already gone to the
            // tile D put out (`apply`); this is a reason for the tile in focus.
            guard let r = DropReason.forKey(n) else { return }
            let o = await session.reason(r)
            if o == .needsConfirmation {
                reasonNeedingConfirmation = r
                reasonConfirmationStem = focus
            }
            outcome = o
        default: return
        }
        if outcome == .applied {
            verdictsWritten += 1
            haptic(.levelChange)
            moveCompareFocusToNextUndecided(after: focus)
        } else if case .refused = outcome {
            haptic(.generic)
        }
    }

    private func moveCompareFocusToNextUndecided(after stem: String) {
        guard let i = compareSelection.firstIndex(of: stem) else { return }
        let order = compareSelection[(i + 1)...] + compareSelection[..<i]
        if let next = order.first(where: { s in
            guard let r = session.rows[s] else { return false }
            return VerdictValue.his(r) == .unmarked
        }) {
            compareFocus = next
            session.go(to: next)
        }
    }

    /// Whether the frames in Compare are a stack the cull found, rather than
    /// a set he chose — the header only calls them "similar" when they are.
    public var comparingAStack: Bool { mode == .compare && !comparePicked }

    /// A click on a tile: the ring, the frame and the bar all go to it. It
    /// used to move the ring alone, so the bar and the filmstrip went on
    /// naming the frame before.
    public func focusTile(_ stem: String) {
        guard let i = compareSelection.firstIndex(of: stem) else { return }
        compareFocus = stem
        session.go(to: stem)
        comparePage = i / LightTableGeometry.compareGrid(count: compareSelection.count).perPage
    }

    /// The label between Drop and Keep: the frame's place in the burst, or in
    /// Compare its place among the tiles.
    public var positionText: String {
        if mode == .compare, let f = compareFocus, let i = compareSelection.firstIndex(of: f) {
            return Strings.LightTable.comparedPosition(i + 1, compareSelection.count)
        }
        return Strings.LightTable.position(frameIndex + 1, frames.count)
    }

    /// ← → in Compare move the focus ring, not the frame.
    public func moveCompareFocus(_ delta: Int, held: Bool = false) {
        guard let focus = compareFocus, let i = compareSelection.firstIndex(of: focus) else { return }
        let n = min(max(0, i + delta), compareSelection.count - 1)
        guard n != i else { bumpAtEnd(held: held); return }
        compareFocus = compareSelection[n]
        session.go(to: compareSelection[n])
        let grid = LightTableGeometry.compareGrid(count: compareSelection.count)
        comparePage = n / grid.perPage
    }

    /// ⇧K: the focused tile kept and the rest of the set put out, one undo
    /// step — and then Compare closes and he is on the first frame after the
    /// set (§2.5.12), because every frame in it has just been decided and
    /// there is nothing left to compare. It used to stay open on the tiles it
    /// had just decided, and the way on was Esc and then → past the frames he
    /// had already judged. A set that ends the burst leaves him on its last
    /// frame, where K goes on as it does there (Settings ▸ Choosing). A
    /// refused write leaves Compare open, with the refusal over the buttons.
    ///
    /// A set he ⌘-clicked can have gaps, and a frame in a gap was not in
    /// Compare and has not been decided: with {1, 4} kept-only, landing on 5
    /// left 2 and 3 unmarked behind him, and a later N recorded them as the
    /// cull's call agreed. So the first frame in a gap he has not marked comes
    /// first; with none, the frame after the set, as before. A stack the cull
    /// found has no gaps and lands where it always did.
    ///
    /// While he looks through a fault's frames (§2.6) it is the next of them
    /// after the set instead, and the burst is never gone on out of.
    private func keepOnlyFocused() async {
        guard mode == .compare, let focus = compareFocus else { return }
        let set = compareSelection
        let others = set.filter { $0 != focus }
        let newest = session.undo.steps.last?.id
        guard await session.keepOnly(focus, dropping: others) == .applied else {
            haptic(.generic)
            return
        }
        verdictsWritten += 1
        haptic(.levelChange)
        let members = set.compactMap { frames.firstIndex(of: $0) }.sorted()
        leaveMode()
        guard let first = members.first, let last = members.last else { return }
        if let list = lookingThrough {
            if let next = listed(list, after: frames[first], skipping: Set(set)) {
                go(toListed: next, forward: true)
            } else {
                session.go(to: focus)
                syncAfterMove(forward: true)
                bumpAtEnd()
            }
            return
        }
        let inSet = Set(members)
        if let gap = (first...last).first(where: { i in
            !inSet.contains(i) && session.rows[frames[i]].map { VerdictValue.his($0) == .unmarked } == true
        }) {
            session.go(burst: burstIndex, frame: gap)
            syncAfterMove(forward: true)
            return
        }
        let next = min(last + 1, frames.count - 1)
        session.go(burst: burstIndex, frame: next)
        syncAfterMove(forward: true)
        // One press, one undo: going on joins the keep-only's step (§2.5.5).
        if next == last { await goOnAfterLastFrame(true, after: .applied, newestBefore: newest) }
    }

    public func leaveMode() {
        if mode == .compare { session.clearDisplayedTiles() }
        mode = .single
        compareSelection = []
        comparePicked = false
    }

    /// Esc: out of Full Image, then out of Compare or All Bursts, then the
    /// frames he had picked to compare — one at a time.
    public func leave() {
        if fullImage { setFullImage(false); return }
        if mode != .single { leaveMode(); return }
        if !compareSelection.isEmpty { compareSelection = [] }
    }

    public func toggleFullImage() { setFullImage(!fullImage) }

    public func setFullImage(_ on: Bool, momentary: Bool = false) {
        fullImage = on
        fullImageIsMomentary = on && momentary
        hudVisible = false
    }

    /// Space held longer than 300 ms is momentary and returns on release.
    public func fullImageKeyReleased() {
        if fullImage && fullImageIsMomentary { setFullImage(false) }
    }

    // MARK: - haptics (§2.5.8)

    /// Where a haptic goes. The trackpad, unless a test is counting them.
    ///
    /// Reduce Motion deliberately does **not** silence these. §2.14 is about
    /// animation on the screen — crossfades, the rubber band, the swipe — and a
    /// bump under the fingers is neither. Someone who turns animation off has
    /// not asked to stop feeling Keep land.
    nonisolated(unsafe) public static var hapticPerformer:
        @MainActor (NSHapticFeedbackManager.FeedbackPattern) -> Void = { pattern in
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }

    public func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        ViewerModel.hapticPerformer(pattern)
    }

    // MARK: - accessibility (§2.15)

    public var frameAnnouncement: String {
        guard let stem = currentStem else { return "" }
        return announcement(for: stem)
    }

    /// The same sentence for any frame of this burst, so a Compare tile and a
    /// filmstrip thumbnail say what the stage says rather than each inventing
    /// its own words.
    public func announcement(for stem: String) -> String {
        let row = session.rows[stem]
        let n = (frames.firstIndex(of: stem) ?? frameIndex) + 1
        return Strings.LightTable.frameAnnouncement(
            frame: ShootSession.shortStem(stem), n: n, of: frames.count,
            burst: burstIndex + 1, his: hisLine(for: row), cull: cullLine(for: row),
            stack: Stacks.stack(for: stem, in: stacks)?.count)
    }

    /// Everything `frameAnnouncement` says, in a shape that costs nothing to
    /// compare. The stage checks this on every refresh and only builds the
    /// sentence when VoiceOver has something new to hear — the sentence itself
    /// is six string lookups and a stack walk, which is not a per-frame cost
    /// worth paying 120 times a second.
    public struct AnnouncementKey: Equatable, Sendable {
        var stem: String
        var generation: Int
        var his: VerdictValue.His
        var rating: Int
        var label: String
        var seen: Bool
    }

    public var announcementKey: AnnouncementKey {
        let row = currentRow
        return AnnouncementKey(stem: currentStem ?? "",
                               generation: session.cursor.generation,
                               his: row.map(VerdictValue.his) ?? .unmarked,
                               rating: row?.rating ?? 0,
                               label: row?.label ?? "",
                               seen: currentBurst?.seen ?? false)
    }
}

/// What spends held arrows: the stage, whose display link applies one pending
/// move per refresh.
@MainActor
public protocol HeldMoves: AnyObject {
    func hold(_ delta: Int)
    func letGo()
}

// MARK: - looking through the frames one fault covers (§2.6)

extension ViewerModel {

    /// A list of frames from the cull's report — every frame it put aside
    /// for one fault — and the fault's name. In the order he shot them.
    public struct FrameList: Equatable, Sendable {
        public let name: String
        public let stems: [String]

        public init(name: String, stems: [String]) {
            self.name = name
            self.stems = stems
        }
    }

    /// A click on "eyes closed 131" in the report: the light table on the
    /// first of those frames, with ← → going through them and nothing else.
    ///
    /// It is a way of looking, not a way of finishing: it records no burst as
    /// been through, however many it crosses, and K, D and the digits decide
    /// the frame on screen as they always do — then go on to the next of
    /// these frames, never on out of a burst. Esc stops it where he is.
    public func lookThrough(_ list: FrameList) {
        let stems = list.stems.filter { session.rows[$0] != nil }
        guard let first = stems.first else { return }
        if fullImage { setFullImage(false) }
        leaveMode()
        closeReasonStrip()
        resumeNoteShown = false
        lookingThrough = FrameList(name: list.name, stems: stems)
        let before = currentBurst?.id
        session.go(to: first)
        if currentBurst?.id != before { enteredBurst() }
        syncAfterMove()
    }

    public func stopLookingThrough() { lookingThrough = nil }

    /// Where he is among them — 12 of 131 — or nothing on a frame he has
    /// clicked his way to that is not one of them.
    public var lookingThroughPosition: Int? {
        guard let list = lookingThrough, let stem = currentStem,
              let i = list.stems.firstIndex(of: stem) else { return nil }
        return i + 1
    }

    /// The line over the photograph while he looks through them.
    public var lookingThroughLine: String? {
        guard let list = lookingThrough, mode == .single else { return nil }
        return Strings.LightTable.lookingThrough(list.name, at: lookingThroughPosition, of: list.stems.count,
                                                 next: LightTableKeys.key(CommandTable.ID.nextFrame) ?? "→",
                                                 stop: "Esc")
    }

    /// One press while he looks through a list: true when it was the list's
    /// to take. On the single frame and in Full Image over it, the arrows, N,
    /// P, K, D and the digits are the list's. In Compare N and P are too: the
    /// ordinary N there finishes the burst, which records it as been through
    /// and moves him on out of the list, so it closes Compare and goes to the
    /// first of them in the next burst instead, and P to the burst before.
    /// Everything else in Compare, and all of All Bursts, is what it always
    /// is, and the list is there again when he comes back to one frame.
    func lookingThroughTakes(_ action: KeyMap.Action, held: Bool) async -> Bool {
        guard let list = lookingThrough else { return false }
        if mode == .compare {
            switch action {
            case .nextBurst: stepBurst(through: list, forward: true, held: held)
            case .previousBurst: stepBurst(through: list, forward: false, held: held)
            default: return false
            }
            return true
        }
        guard mode == .single else { return false }
        switch action {
        case .nextFrame: step(through: list, forward: true, held: held)
        case .previousFrame: step(through: list, forward: false, held: held)
        case .nextBurst: stepBurst(through: list, forward: true, held: held)
        case .previousBurst: stepBurst(through: list, forward: false, held: held)
        case .keep, .drop, .reason:
            await decideWhileLookingThrough(action, list)
        case .leave:
            // Full Image first, then a ⌘-click set, as Esc always goes; then
            // the list itself, leaving him on the frame he is on.
            guard !fullImage, compareSelection.isEmpty else { return false }
            stopLookingThrough()
        default:
            return false
        }
        return true
    }

    /// The next of them after `stem` in the order he shot them, or the last
    /// of them before it — from any frame at all, one of them or one he
    /// clicked his way to — passing over `skipping`.
    func listed(_ list: FrameList, after stem: String?, forward: Bool = true,
                skipping: Set<String> = []) -> String? {
        var at: [String: Int] = [:]
        for (i, s) in session.order.enumerated() { at[s] = i }
        let here = stem.flatMap { at[$0] } ?? -1
        let stems = list.stems.filter { !skipping.contains($0) }
        return forward ? stems.first { (at[$0] ?? -1) > here }
                       : stems.last { at[$0].map { $0 < here } ?? false }
    }

    private func step(through list: FrameList, forward: Bool, held: Bool) {
        guard let next = listed(list, after: currentStem, forward: forward) else {
            bumpAtEnd(held: held)
            return
        }
        go(toListed: next, forward: forward)
    }

    /// N and P while he looks through them: the first of them in the next
    /// burst that has any, or the last burst before. Records nothing. From
    /// Compare it is the way out of Compare too, since that burst is left.
    private func stepBurst(through list: FrameList, forward: Bool, held: Bool) {
        let here = burstIndex
        let inBurst = list.stems.map { session.burstIndex(of: $0) ?? -1 }
        // Forward, the first listed frame past this burst; back, the burst of
        // the last listed frame before this one, and its first listed frame.
        let burst = forward ? inBurst.first { $0 > here } : inBurst.last { $0 >= 0 && $0 < here }
        guard let burst, let target = inBurst.firstIndex(of: burst) else { bumpAtEnd(held: held); return }
        if mode == .compare { leaveMode() }
        go(toListed: list.stems[target], forward: forward)
    }

    private func go(toListed stem: String, forward: Bool) {
        let before = currentBurst?.id
        session.go(to: stem)
        if currentBurst?.id != before { enteredBurst() }
        syncAfterMove(forward: forward)
    }

    /// K, D or a digit on the frame on screen, written as it always is, and
    /// then on to the next of these frames — never on out of the burst,
    /// which would record it as been through. K and D take the same path as
    /// anywhere else, without waiting for the engine (`take`): they used to
    /// wait for its answer here, about 45 ms a press. Clearing a mark moves
    /// nothing anywhere, so it is not the list's and goes the usual way.
    private func decideWhileLookingThrough(_ action: KeyMap.Action, _ list: FrameList) async {
        let stem = currentStem
        let outcome: VerdictOutcome
        switch action {
        case .keep:
            closeReasonStrip()
            outcome = await take(.keep, advance: false)
        case .drop:
            outcome = await take(.drop, advance: false)
            raiseReasonStrip(for: stem, after: outcome)
        case .reason(let n):
            guard let r = DropReason.forKey(n) else { return }
            await settled(stem)
            outcome = await write { await self.session.reason(r) }
            if outcome == .needsConfirmation {
                reasonNeedingConfirmation = r
                reasonConfirmationStem = stem
            }
        default: return
        }
        guard outcome == .applied || outcome == .unchanged else { return }
        step(through: list, forward: true, held: false)
    }
}
