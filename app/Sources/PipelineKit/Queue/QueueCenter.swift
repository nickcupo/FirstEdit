import Foundation
import AppKit

/// Where the app's one list comes from.
///
/// The same shape as `StepJobs`: one model for the life of the app, reached
/// from anywhere that needs it, and settable so the integration crew can hand
/// it the one it made. Without that it keeps one of its own, which polls the
/// same route the same way and is correct but not shared.
///
/// There is exactly one list because there is exactly one engine queue. A
/// second `QueueModel` would not make a second queue — it would make a second
/// opinion about the same one, which is how a screen comes to show an order
/// the engine does not have.
@MainActor
public enum Queues {
    public static var shared: (@MainActor () -> QueueModel)?
    private static var fallback: QueueModel?

    public static func model(client: StudioClient?) -> QueueModel {
        if let shared { return shared() }
        if let fallback {
            if client != nil { fallback.attach(client) }
            return fallback
        }
        let m = QueueModel(client: client)
        fallback = m
        return m
    }

    /// The list as it stands, for a screen that only reads it.
    public static var state: QueueState { shared?().state ?? fallback?.state ?? .empty }

    /// How many pieces of work are waiting — the number on the toolbar.
    public static var waiting: Int { state.waiting.count }

    /// Whether a step's action would start now or go on the list. The button
    /// asks this and then says which; it never queues silently.
    public static var wouldWait: Bool {
        (shared?() ?? fallback)?.wouldWait ?? false
    }

    /// Opens the Activity window, which is where the list lives. Wired by
    /// whoever owns the windows, the same way `StepSlots.showActivity` is.
    public static var showTheList: (@MainActor () -> Void)?

    /// For tests.
    public static func reset() { shared = nil; fallback = nil; showTheList = nil }
}

/// The Dock, for the list rather than for the job.
///
/// §2.7 says the Dock shows the queue's overall progress, not the current
/// job's, and the reason is one he would notice within a minute: a bar that
/// fills and drops back to nothing four times says the machine restarted four
/// times. Four things he asked for in one pass is one piece of work with four
/// parts, and that is the bar.
@MainActor
public enum QueueDock {
    /// Call it with the list on every reading. Nothing is drawn while there
    /// is no list and no job.
    public static func show(_ state: QueueState, job: Job?) {
        // A failure of his work is the one thing the badge says, until he
        // opens Activity: the job he watched end, and anything the list
        // wrote down as failed between two looks.
        if let job, !job.running, !job.background, job.outcome == .failed {
            DockProgress.noteFailure(id: job.id, kind: job.kind, shoot: job.shoot)
        }
        for d in state.done where d.ended == .failed {
            DockProgress.noteFailure(id: d.id, kind: d.kind, shoot: d.shoot)
        }
        // A list of more than one thing, or one that came off the list: the
        // list's own bar. A job he started by hand: that job's bar, which is
        // what the Dock has always shown and is still right for it.
        if state.listed > 1 || (state.listed == 1 && !state.waiting.isEmpty) {
            DockProgress.showFraction(state.fraction,
                                      running: state.running || !state.waiting.isEmpty,
                                      title: title(state), count: state.waiting.count)
            return
        }
        DockProgress.show(job)
    }

    static func title(_ state: QueueState) -> String {
        guard let now = state.runningItem else { return Strings.Queue.title }
        return [now.what, now.shoot].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
