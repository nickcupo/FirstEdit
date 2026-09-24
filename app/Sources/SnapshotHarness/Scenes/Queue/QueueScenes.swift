import AppKit
import SwiftUI
import PipelineKit

/// The list of work and the Activity window, in the states the evening
/// actually reaches: a pass where something went wrong, and the history
/// with a crash in it. The plain states are the commands crew's scenes.
final class QueueScenes: SceneProvider {

    /// He stacked five things and went to bed. The cull failed, he stopped
    /// the gather from his phone's reminder, and the push could not run.
    static let badPass = QueueState(
        listed: 5, fraction: 1, pass: 4,
        done: [QueueDone(id: 1, kind: "ingest", shoot: "2026-09-19"),
               QueueDone(id: 2, kind: "cull", shoot: "2026-09-19", outcome: "failed"),
               QueueDone(id: 3, kind: "presets", shoot: "2026-09-13-dog"),
               QueueDone(id: 4, kind: "gather", shoot: "2026-09-13-dog", outcome: "stopped")],
        skipped: [QueueSkipped(id: 5, kind: "stor-push", shoot: "2026-09-19",
                               whyNot: "2026-09-19 has not been culled yet, so there is nothing to choose from.")])

    /// Named the way `ActivityRow(_:)` names a record in the app: the
    /// list's word for the work, with the shoot in its own column.
    static var rows: [ActivityRow] {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return [
            ActivityRow(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!,
                        what: Strings.Queue.what("ingest") ?? "", shoot: "2026-09-19",
                        started: start, elapsed: 412, outcome: .done,
                        log: "$ pipeline/ingest.py 2026-09-19\n  copied 1,558 photographs."),
            ActivityRow(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!,
                        what: Strings.Queue.what("cull") ?? "", shoot: "2026-09-19",
                        started: start.addingTimeInterval(420), elapsed: 371, outcome: .failed,
                        log: """
                        $ pipeline/cull.py 2026-09-19
                          reading the frames … 1,558
                          looking at faces … 612
                        Traceback (most recent call last):
                          File "pipeline/cull.py", line 900, in <module>
                            main()
                        MemoryError
                        """),
            ActivityRow(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000c")!,
                        what: Strings.Queue.what("presets") ?? "", shoot: "2026-09-13-dog",
                        started: start.addingTimeInterval(800), elapsed: 9, outcome: .done,
                        log: "$ pipeline/presets.py 2026-09-13-dog\n  wrote 23 presets."),
        ]
    }

    override class var scenes: [SnapshotScene] {
        moreScenes + [
            // The list after a pass that went wrong: the count by outcome,
            // failed first, then each piece with the history's own word.
            SnapshotScene(name: "queue-pass-failed", size: CGSize(width: 640, height: 360)) { _ in
                .window(AnyView(QueueList(state: badPass).frame(width: 640)))
            },
            // A check the list ran that said no on purpose: counted as
            // refused, in the ordinary colour, as its history row says - not
            // "1 failed" in red beside a row that says Refused.
            SnapshotScene(name: "activity-pass-refused", size: CGSize(width: 720, height: 560)) { _ in
                let start = Date(timeIntervalSince1970: 1_790_000_000)
                let rows = [
                    ActivityRow(id: UUID(uuidString: "00000000-0000-0000-0000-00000000001a")!,
                                what: Strings.Queue.what("cull") ?? "", shoot: "2026-09-19",
                                started: start, elapsed: 371, outcome: .done,
                                log: "$ pipeline/cull.py 2026-09-19\n  put 368 of 1,558 frames forward."),
                    ActivityRow(id: UUID(uuidString: "00000000-0000-0000-0000-00000000001b")!,
                                what: Strings.Queue.what("stor-check") ?? "", shoot: "2026-09-13-dog",
                                started: start.addingTimeInterval(380), elapsed: 2, outcome: .refused,
                                log: "$ pipeline/archive.py check 2026-09-13-dog\n"
                                    + "2026-09-13-dog has no archive manifest: nothing was ever pushed."),
                ]
                let pass = QueueState(listed: 2, fraction: 1, pass: 5,
                                      done: [QueueDone(id: 1, kind: "cull", shoot: "2026-09-19"),
                                             QueueDone(id: 2, kind: "stor-check", shoot: "2026-09-13-dog",
                                                       outcome: "refused")])
                return .window(AnyView(ActivityWindow(rows: rows, logURL: URL(fileURLWithPath: "/tmp/studio.log"),
                                                      queue: pass)))
            },
            // ⌥⌘L the morning after, at the window's own default width.
            SnapshotScene(name: "activity-pass-failed", size: CGSize(width: 720, height: 640)) { _ in
                .window(AnyView(ActivityWindow(rows: rows,
                                               logURL: URL(fileURLWithPath: "/tmp/studio.log"),
                                               queue: badPass)))
            },
        ]
    }
}

extension QueueScenes {
    /// The walker's evening: the push running, a card copy whose card was
    /// taken out (its reason wraps to two lines), a cull and the presets
    /// behind it, and nothing in the history yet.
    static let longReasons = QueueState(
        waiting: [QueueItem(id: 11, kind: "ingest", shoot: "2026-09-23-evening", ready: false,
                            whyNot: "the card SONY-A6500 is not in this Mac any more, so there is nothing to copy from. Put it back in and this starts on its own."),
                  QueueItem(id: 12, kind: "cull", shoot: "2026-09-23-evening",
                            does: "Look at 1,558 frames and put the ones worth keeping forward."),
                  QueueItem(id: 13, kind: "presets", shoot: "2026-09-23-evening",
                            does: "Write the starting edit onto every frame that gets one.")],
        listed: 4, fraction: 0.1, pass: 2, running: true, fromList: true, id: 10,
        kind: "stor-push", title: "copying 2026-09-19 to iCloud", shoot: "2026-09-19",
        label: "copying to iCloud: 212 of 1,558 frames", remainingText: "about 9 minutes left",
        jobFraction: 0.14)

    @MainActor static var moreScenes: [SnapshotScene] {
        [
            // The morning after: last night's list read back from the
            // engine's record, its failure with its day, and this
            // morning's copy under it.
            SnapshotScene(name: "activity-earlier", size: CGSize(width: 720, height: 560)) { _ in
                let night = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
                let last = rows.map { r in
                    ActivityRow(id: r.id, what: r.what, shoot: r.shoot,
                                started: night.addingTimeInterval(r.started.timeIntervalSince1970 - 1_790_000_000),
                                elapsed: r.elapsed, outcome: r.outcome, log: r.log, earlier: true)
                }
                let now = ActivityRow(id: UUID(uuidString: "00000000-0000-0000-0000-00000000002a")!,
                                      what: Strings.Queue.what("ingest") ?? "", shoot: "2026-09-20",
                                      started: Date().addingTimeInterval(-600), elapsed: 380, outcome: .done,
                                      log: "$ pipeline/ingest.py 2026-09-20\n  copied 912 frames.")
                return .window(AnyView(ActivityWindow(rows: last + [now],
                                                      logURL: URL(fileURLWithPath: "/tmp/studio.log"))))
            },
            // The engine stopped under the cull he walked away from. It is
            // back at the top, marked, and the list is held for him.
            SnapshotScene(name: "queue-held-after-crash", size: CGSize(width: 640, height: 360)) { _ in
                .window(AnyView(QueueList(state: QueueState(
                    waiting: [QueueItem(id: 15, kind: "cull", shoot: "2026-09-23-evening",
                                        does: "Look at 1,558 frames and put the ones worth keeping forward.",
                                        interrupted: true),
                              QueueItem(id: 13, kind: "presets", shoot: "2026-09-23-evening",
                                        does: "Write the starting edit onto every frame that gets one.")],
                    held: true,
                    heldAfter: HeldAfter(why: .crashed, kind: "cull", shoot: "2026-09-23-evening"),
                    listed: 2, pass: 1))
                    .frame(maxWidth: .infinity)))
            },
            // The engine stopped during a card copy. The copy is back at the
            // top, marked, as the copy that finishes into the same shoot, and
            // the list says how far it got; the cull behind it waits.
            SnapshotScene(name: "queue-held-after-copy-crash", size: CGSize(width: 640, height: 360)) { _ in
                .window(AnyView(QueueList(state: QueueState(
                    waiting: [QueueItem(id: 17, kind: "ingest", shoot: "2026-09-23-evening",
                                        does: "Copy SONY-A6500 into 2026-09-23-evening, checking as it copies.",
                                        interrupted: true),
                              QueueItem(id: 16, kind: "cull", shoot: "2026-09-23-evening",
                                        does: "Look at 1,558 frames and put the ones worth keeping forward.")],
                    held: true,
                    heldAfter: HeldAfter(why: .crashed, kind: "ingest", shoot: "2026-09-23-evening",
                                         files: 412, of: 1558),
                    listed: 2, pass: 1))
                    .frame(maxWidth: .infinity)))
            },
            // He pressed Stop on the cull the list had started; the presets
            // and the gather behind it are held, and the list says his Stop
            // held them.
            SnapshotScene(name: "queue-held-after-stop", size: CGSize(width: 640, height: 360)) { _ in
                .window(AnyView(QueueList(state: QueueState(
                    waiting: [QueueItem(id: 13, kind: "presets", shoot: "2026-09-23-evening",
                                        does: "Write the starting edit onto every frame that gets one."),
                              QueueItem(id: 14, kind: "gather", shoot: "2026-09-23-evening",
                                        does: "Build the folder of your keepers, each with its sidecar beside it.")],
                    held: true,
                    heldAfter: HeldAfter(why: .stopped, kind: "cull", shoot: "2026-09-23-evening"),
                    listed: 3, pass: 2,
                    done: [QueueDone(id: 10, kind: "cull", shoot: "2026-09-23-evening", outcome: "stopped")]))
                    .frame(maxWidth: .infinity)))
            },
            SnapshotScene(name: "activity-list-long-reasons", size: CGSize(width: 560, height: 640)) { _ in
                .window(AnyView(ActivityWindow(rows: [], logURL: URL(fileURLWithPath: "/tmp/studio.log"),
                                               isRunning: true, queue: longReasons)))
            },
            SnapshotScene(name: "activity-list-long-reasons-history", size: CGSize(width: 720, height: 560)) { _ in
                .window(AnyView(ActivityWindow(rows: rows, logURL: URL(fileURLWithPath: "/tmp/studio.log"),
                                               isRunning: true, queue: longReasons)))
            },
            // A check that said no under the button he pressed, then the
            // presets, then a cull running: the window opens on the cull,
            // not on the sentence he has already read.
            SnapshotScene(name: "activity-opens-on-running", size: CGSize(width: 720, height: 560)) { _ in
                let jobs = JobModel()
                jobs.take(Job(running: false, stopped: false, id: 2, kind: "stor-check", shoot: "2026-09-13-dog",
                              title: "checking 2026-09-13-dog",
                              log: "$ pipeline/archive.py check 2026-09-13-dog\n"
                                + "2026-09-13-dog has no archive manifest: nothing was ever pushed.",
                              elapsed: 2, code: 1))
                jobs.take(Job(running: false, stopped: false, id: 3, kind: "presets", shoot: "2026-09-19",
                              title: "presets for 2026-09-19", log: "$ pipeline/presets.py 2026-09-19\n  12 presets written",
                              fraction: 1, elapsed: 5, code: 0))
                jobs.take(Job(running: true, stopped: false, id: 4, kind: "cull", shoot: "2026-09-23",
                              title: "culling 2026-09-23", label: "looking at faces: 612 of 1,558 frames",
                              log: "$ pipeline/cull.py 2026-09-23\n  reading the frames … 1,558\n  looking at faces … 612",
                              fraction: 0.39, elapsed: 201))
                return .window(AnyView(ActivityWindow(jobs: jobs, logURL: URL(fileURLWithPath: "/tmp/studio.log"))))
            },
            // A row picked, as ⌥⌘↑ and Delete would find it.
            SnapshotScene(name: "queue-picked", size: CGSize(width: 640, height: 360)) { _ in
                .window(AnyView(QueueList(state: longReasons, selected: 12).frame(width: 640)))
            },
        ]
    }
}
