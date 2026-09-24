import AppKit
import UserNotifications

// A notification when a long job ends and he is looking at something else.
//
// Authorization is asked for the first time one is about to be posted, never
// at launch: a permission sheet before he has done anything is a sheet about
// nothing. Clicking the notification opens that shoot at the step the job
// leaves him on, and a failure opens the Activity window as well.

@MainActor
public final class Notifications: NSObject {
    public static let shared = Notifications()

    /// What to do when he clicks one: open this shoot at this step, or at
    /// its overview when the step is empty.
    public var open: ((String, String) -> Void)?
    /// The Activity window, where a failure's reason can be read whole.
    public var showActivity: (() -> Void)?
    /// The cull's own two numbers for a shoot, read after its cull ends, for
    /// the sentence a finished cull's notification carries. Nil in a test,
    /// which then posts without it.
    public var cullCounts: ((String) async -> (forward: Int, of: Int)?)?

    /// Injected so the rules can be tested without a signed bundle, a
    /// notification centre or a frontmost app.
    var isFrontmost: () -> Bool = { NSApplication.shared.isActive }
    var post: (UNNotificationContent, String) -> Void = { content, id in
        let r = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(r)
    }
    var requestAuthorization: () async -> Bool = {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private var asked = false
    /// Set once he has said yes. Internal, so a test can start from a Mac
    /// where he already has.
    var allowed = false
    /// Every job already spoken for, so a poll that sees "done" five times
    /// does not post five notifications.
    private var announced = Set<String>()

    /// Whether this process can post at all. `UNUserNotificationCenter`
    /// needs a real bundle identifier; from a `swift run` checkout there is
    /// none, and asking would raise rather than return false.
    lazy var isAvailable: Bool = Bundle.main.bundleIdentifier != nil

    public func attach() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Called on every job poll. It decides for itself whether this is a
    /// moment worth interrupting him for, and where clicking it takes him.
    public func jobChanged(_ job: Job?) {
        guard let job, shouldAnnounce(job) else { return }
        let id = key(job)
        announced.insert(id)
        let step = Self.step(for: job)
        // What went wrong is written in the Activity window: a failure or a
        // refusal opens it over the step that started the work - except a
        // card copy's, whose own page says what reached the shoot and why it
        // stopped (`step(for:)`).
        let activity = (job.outcome == .failed || job.outcome == .refused) && job.kind != "ingest"
        // A finished cull says what it put forward, which is the one thing he
        // wants to know before walking back to the Mac (§2.7). The numbers are
        // read once the cull has written them.
        if job.kind == "cull", job.outcome == .done, let counts = cullCounts {
            Task { @MainActor in
                let c = await counts(job.shoot)
                self.deliver(Self.content(for: job, culled: c), id: id, shoot: job.shoot, step: step,
                             activity: activity)
            }
            return
        }
        deliver(Self.content(for: job), id: id, shoot: job.shoot, step: step, activity: activity)
    }

    /// Not a step: the card page of the copy into this shoot, or, when this
    /// session no longer knows the copy, the shoot's own Copy the Card step,
    /// which carries the copy's sentence from its log.
    public static let cardPage = "card"

    /// One place, so the rule is testable: the job ended, it was doing
    /// something, he is not looking, and it has not been said before.
    func shouldAnnounce(_ job: Job) -> Bool {
        guard !job.running, !job.kind.isEmpty else { return false }
        guard job.outcome != .idle else { return false }
        guard !announced.contains(key(job)) else { return false }
        // The machine's own homework is not his to be told about: he did not
        // ask for it, and it stands down whenever he wants the Mac.
        guard !job.background else { return false }
        // Getting a burst ready for PhotoLab ends with PhotoLab opening in
        // front of him. A banner on top of that is a second answer to a
        // question the screen has already answered.
        guard job.kind != "spread" else { return false }
        // A job that came off the list is spoken for by the list, at the end,
        // once. Four things he stacked up before going to bed must not be
        // four banners; that is the thing the list is for.
        //
        // The engine says so itself, on the same read that says the job ended,
        // so this is a fact and not a race. It used to be a set of ids that
        // `listFinished` filled — but `listFinished` only runs when the whole
        // pass ends, and `JobModel` polls faster (1.2s) than `QueueModel`
        // (1.5s) and calls this the moment the job stops. The set was
        // therefore still empty for the very job it was meant to silence, and
        // the last job of every list he walked away from announced itself a
        // beat before the list did.
        //
        // And the list's own record of it, for an engine that stopped saying
        // so once the job was written down: its readings after the end of
        // the list's last job read "started by hand", and that job had a
        // banner of its own beside the list's.
        guard !job.fromList else { return false }
        if job.id > 0, job.listDone.contains(where: { $0.id == job.id }) { return false }
        return !isFrontmost()
    }

    // MARK: - the one notification, when the list empties

    /// Said once, at the end of a pass, naming what was done and anything
    /// that was skipped (DESIGN.md §2.7). Not one a job — he stacked four
    /// things up precisely so he would not be told four times.
    ///
    /// The rules about being frontmost are the same as a job's: if he is
    /// looking at the app, the list is on screen and a banner about it is
    /// noise.
    public func listFinished(_ state: QueueState) {
        guard !state.done.isEmpty || !state.skipped.isEmpty else { return }
        guard !isFrontmost() else { return }
        let content = Self.content(for: state)
        // The shoot of the last thing it did, so clicking it lands somewhere
        // that makes sense rather than nowhere - unless something failed or
        // was skipped, when it opens the window that says which and why.
        let shoot = state.done.last?.shoot ?? state.skipped.last?.shoot ?? ""
        let kind = state.done.last?.kind ?? ""
        deliver(content, id: "list.\(state.pass)", shoot: shoot,
                step: Self.step(for: Job(running: false, stopped: false, kind: kind, code: 0)),
                activity: state.tally.wentWrong)
    }

    static func content(for state: QueueState) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        // Counted by outcome: "3 done, 1 failed", never "4 finished".
        c.title = Strings.Queue.summary(state.tally)
        // What went wrong, then what was done, each in the app's own word for
        // the work and the shoot it was about. The reason a thing failed or
        // was skipped is in the Activity window, not truncated into a banner.
        c.body = Strings.Queue.whatHappened(state.done.map { (line($0.what, $0.shoot), $0.ended) },
                                            skipped: state.skipped.map { line($0.what, $0.shoot) })
        return c
    }

    private static func line(_ what: String, _ shoot: String) -> String {
        shoot.isEmpty ? what : "\(what) · \(shoot)"
    }

    func key(_ job: Job) -> String { "\(job.id).\(job.kind).\(job.shoot).\(job.elapsed)" }

    /// Where clicking it takes him: the step a finished job leaves him on,
    /// and for one that did not finish, the step that started it. Empty is
    /// the shoot's overview — an extension's work, whose step this app does
    /// not know. It used to be Choose Keepers for everything: a failed copy
    /// opened the light table of a shoot that had never been culled.
    static func step(for job: Job) -> String {
        let done = job.outcome == .done
        switch job.kind {
        // One that did not finish opens the card's page (`cardPage`).
        case "ingest": return done ? "cull" : cardPage
        case "cull": return done ? "keepers" : "cull"
        case "presets": return done ? "edit" : "presets"
        case "gather": return "edit"
        case "reel", "spread": return "reels"
        case "instagram": return "instagram"
        default:
            // The storage panel, and every plan it asks for, is on Finish (§2.8).
            if job.kind.hasPrefix("stor-") || job.kind.hasPrefix("plan-") { return "done" }
            return ""
        }
    }

    /// Title, the shoot once, and a body that says what happened.
    ///
    /// The title is the app's own word for the work and how it ended — "Cull
    /// finished", "Copy the Card failed" — and the shoot is the subtitle. It
    /// was "<the engine's title> finished · <shoot>" for every outcome, so a
    /// copy that failed read "Copying the card into 2026-09-23 finished ·
    /// 2026-09-23", success and the shoot twice.
    static func content(for job: Job, culled: (forward: Int, of: Int)? = nil) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        let what = JobWords.titled(job)
        // The shoot once, underneath. It was "<the engine's title> finished ·
        // <shoot>", and the engine's title already carries the shoot.
        c.subtitle = job.shoot
        // Said by how it ended. Every ending was "… finished", so a crash, a
        // copy the card was pulled out of, or one the disk had no room for,
        // arrived as finished.
        switch job.outcome {
        case .refused:
            // A copy the engine ended with a sentence - no room on the disk,
            // a failed check - did not finish. Any other plan that says no on
            // purpose did not run; neither is a failure.
            c.title = job.kind == "ingest" ? Words.Notify.didNotFinish(what) : Words.Notify.refused(what)
            // The sentence it wrote belongs in the Activity window where it
            // can be read whole, not truncated into a banner.
            c.body = job.refusalSentence ?? Words.Notify.refusedBody
        case .failed:
            // A copy the card was pulled out of did not finish, and its page
            // says what reached the shoot; anything else crashed. Never the
            // traceback's last line: that is the machine talking to itself.
            if job.kind == "ingest" {
                c.title = Words.Notify.didNotFinish(what)
                c.body = Words.Notify.copyFailedBody
            } else {
                c.title = Words.Notify.failed(what)
                c.body = Words.Notify.failedBody
            }
        case .stopped:
            c.title = Words.Notify.stopped(what)
            c.body = Words.Notify.stoppedBody
        default:
            c.title = Words.Notify.finished(what)
            // What he is waiting to hear when he is in another app. How a copy
            // was checked is its own sentence's to say, on its page.
            if job.kind == "ingest" {
                c.body = Strings.Import.canComeOut
            } else if let culled {
                c.body = Words.Notify.culled(culled.forward, of: culled.of)
            }
        }
        c.userInfo = ["shoot": job.shoot]
        return c
    }

    private func deliver(_ content: UNMutableNotificationContent, id: String,
                         shoot: String, step: String, activity: Bool = false) {
        guard isAvailable else { return }
        content.userInfo = ["shoot": shoot, "step": step, "activity": activity]
        if allowed { post(content, id); return }
        guard !asked else { return }
        asked = true
        // Asked here, with a finished job to announce, and never at launch:
        // a permission sheet before he has done anything is a sheet about
        // nothing.
        Task { @MainActor in
            self.allowed = await self.requestAuthorization()
            if self.allowed { self.post(content, id) }
        }
    }
}

extension Notifications: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let shoot = info["shoot"] as? String ?? ""
        let step = info["step"] as? String ?? ""
        let activity = info["activity"] as? Bool ?? false
        await MainActor.run {
            NSApplication.shared.activate(ignoringOtherApps: true)
            if !shoot.isEmpty { self.open?(shoot, step) }
            // What went wrong is written in the Activity window, and nowhere
            // else: a failure opens it over the step that started the work.
            if activity { self.showActivity?() }
        }
    }
}

/// The app's own word for a piece of work, wherever a job is named: the
/// notification, the Dock menu, what VoiceOver says. The list's word
/// (`Strings.Queue.what`), with the engine's title only for a kind the app has
/// no word for — the engine's is a lower-case "culling 2026-09-19" that already
/// carries the shoot, which every one of these then printed a second time.
@MainActor
public enum JobWords {
    public static func what(_ job: Job) -> String {
        if let w = Strings.Queue.what(job.kind) { return w }
        return (job.title.isEmpty ? job.kind : job.title).capitalizedFirst
    }

    /// The same word in title case, for a notification's title and the Dock
    /// menu, which are titles: "Write the Presets finished", not the list's
    /// "Write the presets finished" beside "Copy the Card stopped", and a
    /// plan named for what it checks, "Check What Would Be Copied", as its
    /// row in Activity is. The engine's own title, for a kind the app has no
    /// word for, is left as it is.
    public static func titled(_ job: Job) -> String {
        guard let w = Strings.Queue.what(job.kind) else { return what(job) }
        return titleCase(w)
    }

    /// Every word capitalised but the small ones inside the title; a word
    /// with a capital already in it (PhotoLab, RAWs, iCloud) is left alone.
    nonisolated static func titleCase(_ s: String) -> String {
        let small: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "in", "into", "of", "on", "or",
                                  "the", "to", "with"]
        let words = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return words.enumerated().map { i, w in
            guard w == w.lowercased(), let first = w.first else { return w }
            if i > 0, i < words.count - 1, small.contains(w) { return w }
            return first.uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
}
