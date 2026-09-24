import Testing
import Foundation
@testable import PipelineKit

// The list of work he fills before he walks away.
//
// Every fixture here is bytes the real engine answered with, captured from a
// scratch clone by `tools/capture-fixtures.sh`: a list filled with a cull, the
// presets, a gather and a push of the dog shoot, and one row whose shoot
// changed under it.

@Suite("The list of work")
struct QueueDecodingTests {

    @Test("a filled list decodes with its order, its shoots and what each will do")
    func decodesTheList() throws {
        let q = try Fixture.decode(QueueState.self, "queue")
        #expect(q.running)
        #expect(!q.waiting.isEmpty)
        // His order is the engine's order, exactly as it sent it.
        #expect(q.waiting.map(\.id) == q.waiting.map(\.id).sorted { a, b in
            q.waiting.firstIndex { $0.id == a }! < q.waiting.firstIndex { $0.id == b }!
        })
        for item in q.waiting {
            #expect(item.id > 0)
            #expect(!item.kind.isEmpty)
            #expect(!item.shoot.isEmpty)
        }
        // A row that can still be done says what it will do, in a sentence
        // the engine wrote.
        let ready = q.waiting.filter(\.ready)
        #expect(!ready.isEmpty)
        for item in ready { #expect(!item.does.isEmpty) }
    }

    @Test("a row whose shoot changed under it says so, in the engine's own words")
    func staleRowCarriesItsReason() throws {
        let q = try Fixture.decode(QueueState.self, "queue")
        guard let stale = q.waiting.first(where: { !$0.ready }) else {
            Issue.record("the captured list has no row that went stale")
            return
        }
        #expect(!stale.whyNot.isEmpty)
        // Never rewritten here: what the app adds is the heading, because a
        // heading is a label and the engine has no labels.
        #expect(stale.whyNot.contains("2026-01-01-scratch"))
        #expect(Strings.Queue.cannotRun != stale.whyNot)
    }

    @Test("an empty list is empty and says nothing is happening")
    func decodesEmpty() throws {
        let q = try Fixture.decode(QueueState.self, "queue-empty")
        #expect(q.waiting.isEmpty)
        #expect(!q.running)
        #expect(!q.held)
        #expect(q.listed == 0)
        #expect(q.isFinished)
        #expect(!q.hasAnything)
        #expect(q.count == 0)
    }

    @Test("a list that has finished carries what it did, with each outcome")
    func decodesTheFinishedList() throws {
        let q = try Fixture.decode(QueueState.self, "queue-running")
        #expect(q.waiting.isEmpty)
        #expect(q.done.count == 4)
        #expect(q.done.map(\.kind) == ["cull", "presets", "gather", "stor-push"])
        #expect(q.done.allSatisfy { $0.outcome == "done" })
        #expect(q.fraction == 1.0)
        #expect(q.isFinished)
    }

    @Test("a refusal to put something on the list is the engine's sentence, with the list beside it")
    func decodesARefusal() throws {
        // What the engine really answers for an apply that removes
        // photographs, byte for byte.
        let r = try Fixture.decodeJSON(QueueChanged.self, """
        {"error": "Removing the local RAWs is not something to leave on a list. It runs against \
        the list you read a moment before, and a list an hour old is about a shoot nobody has \
        looked at since. Draw it again and press it while it is in front of you.", \
        "queueable": false, "list": {"queue": [], "held": false, "waiting": 0, "listed": 0, \
        "fraction": 0.0, "pass": 0, "done": [], "skipped": [], "running": false, \
        "from_list": false, "id": 0, "kind": "", "title": "", "shoot": "", "label": "", \
        "remaining_text": "", "job_fraction": 0.0, "background": false}}
        """)
        #expect(r.queueable == false)
        #expect(r.error?.contains("list an hour old") == true)
        #expect(r.list?.waiting.isEmpty == true)
        #expect(r.added == nil)
    }

    @Test("what was skipped decodes with its reason, so it is never lost")
    func decodesSkipped() throws {
        let r = try Fixture.decodeJSON(QueueState.self, """
        {"queue": [], "held": false, "waiting": 0, "listed": 2, "fraction": 1.0, "pass": 3, \
        "done": [{"id": 9, "kind": "cull", "title": "culling 2026-09-13-dog", \
        "shoot": "2026-09-13-dog", "outcome": "done"}], \
        "skipped": [{"id": 10, "kind": "ingest", "title": "copying the card into 2026-02-02-lake", \
        "shoot": "2026-02-02-lake", "why_not": "EOS_DIGITAL is not in this Mac any more"}], \
        "running": false, "from_list": false, "id": 9, "kind": "cull", "title": "", "shoot": "", \
        "label": "", "remaining_text": "", "job_fraction": 0.0, "background": false}
        """)
        #expect(r.skipped.count == 1)
        #expect(r.skipped[0].whyNot == "EOS_DIGITAL is not in this Mac any more")
        #expect(r.skipped[0].what == Strings.Queue.what("ingest"))
        #expect(r.isFinished)
    }
}

@Suite("The list's words")
struct QueueWordsTests {

    /// "Job" is ours. Every kind the engine can be asked for has his word for
    /// it, and the words are §2.13's.
    @Test("every kind the engine can queue has his own word for it")
    func hisWordsForEveryKind() {
        let engineKinds = ["ingest", "cull", "presets", "gather", "spread", "reel",
                           "instagram", "stor-push", "stor-pull", "stor-check"]
        for kind in engineKinds {
            let word = Strings.Queue.what(kind)
            #expect(word != nil, "no word for \(kind)")
            #expect(word != kind)
        }
        #expect(Strings.Queue.what("cull") == "Cull")
        #expect(Strings.Queue.what("presets") == "Write the presets")
        #expect(Strings.Queue.what("stor-push") == "Copy the RAWs to iCloud")
    }

    @Test("a kind the app has no word for is the engine's own title, never a raw kind")
    func unknownKindFallsBackToTheTitle() {
        let item = QueueItem(id: 4, kind: "ext-upload", title: "uploading to the site",
                             shoot: "2026-09-13-dog")
        #expect(Strings.Queue.what("ext-upload") == nil)
        #expect(item.what == "uploading to the site")
    }

    @Test("not one of the list's own words is a retired one")
    func noRetiredWords() {
        var lines = [Strings.Queue.title, Strings.Queue.emptyTitle, Strings.Queue.emptyBody,
                     Strings.Queue.runningNow, Strings.Queue.clear, Strings.Queue.hold,
                     Strings.Queue.letGo, Strings.Queue.heldNote, Strings.Queue.remove,
                     Strings.Queue.reorderHint, Strings.Queue.cannotRun, Strings.Queue.wontBeKept,
                     Strings.Queue.addedHelp, Strings.Queue.addInstead,
                     Strings.Queue.addInsteadSpoken("Cull It"),
                     Strings.Queue.summary(.init(done: 4)),
                     Strings.Queue.summary(.init(done: 3, failed: 1, stopped: 1, skipped: 1))]
        lines += ["ingest", "cull", "presets", "gather", "spread", "reel", "instagram",
                  "stor-push", "stor-pull", "stor-check"].compactMap(Strings.Queue.what)
        for line in lines {
            let lower = line.lowercased()
            for word in ["answer key", "bench", "taste", "weights", "probe", "venue", "auc",
                         "held out", "duplicate", " dup", "tier", "csv", "rating", "veto",
                         "embedding", "./pl", "job"] {
                #expect(!lower.contains(word), "\(line) contains \(word)")
            }
        }
    }

    @Test("the empty list says what the list is for")
    func theEmptyStateExplainsItself() {
        let body = Strings.Queue.emptyBody.lowercased()
        // The evening it exists for, in his own terms.
        #expect(body.contains("cull"))
        #expect(body.contains("icloud"))
        #expect(body.contains("⌥"))
    }
}

@Suite("Filling the list")
@MainActor
struct QueueModelTests {

    @Test("the button says which it will do, and ⌥ always means add")
    func theButtonNeverQueuesSilently() throws {
        let q = QueueModel()
        // Nothing running: the button is the step's own verb.
        q.take(try Fixture.decode(QueueState.self, "queue-empty"))
        #expect(!q.wouldWait)
        #expect(StepPrimaryWords.label(Strings.Cull.run, adds: false) == Strings.Cull.run)
        // Something of his running: it says where it is going instead.
        q.take(try Fixture.decode(QueueState.self, "queue"))
        #expect(q.wouldWait)
        let label = StepPrimaryWords.label(Strings.Cull.run, adds: true)
        #expect(label != Strings.Cull.run)
        // The button does not swallow the step's own sentence - the page
        // above it says which step this is - but what it reads out does.
        #expect(StepPrimaryWords.spoken(Strings.Cull.run, adds: true).contains(Strings.Cull.run))
        #expect(StepPrimaryWords.spoken(Strings.Cull.run, adds: false) == Strings.Cull.run)
    }

    @Test("the machine's own homework is never a reason to wait")
    func backgroundWorkIsNotAReasonToWait() {
        let q = QueueModel()
        q.take(QueueState(running: true, kind: "learn-learn",
                          title: "Learning from 2026-09-21", background: true))
        // The engine stands it down for anything he asks for, so the button
        // says "Cull It" and culls.
        #expect(!q.wouldWait)
    }

    @Test("a held list is a reason to wait even when nothing is running")
    func aHeldListWaits() {
        let q = QueueModel()
        q.take(QueueState(waiting: [QueueItem(id: 1, kind: "cull", shoot: "2026-09-13-dog")],
                          held: true, listed: 1))
        #expect(q.wouldWait)
        #expect(q.isHeld)
        #expect(q.count == 1)
    }

    @Test("he is told once, when the list empties, and not once a job")
    func oneNotificationAtTheEnd() throws {
        let q = QueueModel()
        var told: [QueueState] = []
        q.finished = { told.append($0) }

        let working = QueueState(waiting: [QueueItem(id: 2, kind: "presets", shoot: "d")],
                                 listed: 3, pass: 1,
                                 done: [QueueDone(id: 1, kind: "cull", shoot: "d")],
                                 running: true, fromList: true, kind: "presets")
        q.take(working)
        #expect(told.isEmpty, "it spoke before the list was empty")

        let ended = QueueState(listed: 3, fraction: 1, pass: 1,
                               done: [QueueDone(id: 1, kind: "cull", shoot: "d"),
                                      QueueDone(id: 2, kind: "presets", shoot: "d")],
                               skipped: [QueueSkipped(id: 3, kind: "gather", shoot: "d",
                                                      whyNot: "d has not been culled yet")])
        q.take(ended)
        #expect(told.count == 1)
        // Twenty more readings of the same finished list say nothing more.
        q.take(ended)
        q.take(ended)
        #expect(told.count == 1)
    }

    @Test("a list that finished while the app was shut is history, not an interruption")
    func nothingIsAnnouncedForAPassItNeverWatched() {
        let q = QueueModel()
        var told = 0
        q.finished = { _ in told += 1 }
        // The first thing this app ever sees is a finished pass.
        q.take(QueueState(listed: 2, fraction: 1, pass: 7,
                          done: [QueueDone(id: 1, kind: "cull", shoot: "d")]))
        #expect(told == 0)
    }

    @Test("what he is told names what was done and what was skipped, and nothing else")
    func theSentenceAtTheEnd() {
        let state = QueueState(listed: 3, pass: 1,
                               done: [QueueDone(id: 1, kind: "cull", shoot: "2026-09-13-dog"),
                                      QueueDone(id: 2, kind: "presets", shoot: "2026-09-13-dog")],
                               skipped: [QueueSkipped(id: 3, kind: "ingest", shoot: "2026-02-02-lake",
                                                      whyNot: "EOS_DIGITAL is not in this Mac any more")])
        let c = Notifications.content(for: state)
        #expect(c.title == Strings.Queue.summary(.init(done: 2, skipped: 1)))
        #expect(c.body.contains("Cull"))
        #expect(c.body.contains("2026-09-13-dog"))
        #expect(c.body.contains(Strings.Queue.what("ingest")!))
        // The reason lives in the window, where it can be read whole. A
        // banner is not the place for the engine's sentence.
        #expect(!c.body.contains("EOS_DIGITAL"))
    }

    @Test("a job off the list says nothing for itself, however fast the job poll is")
    func aListJobNeverSpeaksForItself() throws {
        let n = Notifications()
        n.isAvailable = true
        nonisolated(unsafe) var posted: [String] = []
        n.post = { content, _ in posted.append(content.title) }
        n.allowed = true
        n.isFrontmost = { false }        // he has gone to bed; this is the case that matters

        // The exact order the two pollers produce. `JobModel` reads
        // /api/job every 1.2s and sees the last job of the list stop;
        // `QueueModel` reads every 1.5s and has not yet noticed the pass
        // ended, so `listFinished` has NOT run. This is the beat in which the
        // old code posted a banner for the job.
        let last = try Fixture.decodeJob(running: false, fraction: 1, kind: "presets",
                                         shoot: "2026-09-13-dog",
                                         title: "presets for 2026-09-13-dog",
                                         code: 0, fromList: true)
        n.jobChanged(last)
        #expect(posted.isEmpty, "the list speaks for it, not the job")

        // And the same for every job before it, each of which stops with more
        // still waiting behind it.
        n.jobChanged(try Fixture.decodeJob(running: false, fraction: 1, kind: "cull",
                                           code: 0, fromList: true))
        n.jobChanged(try Fixture.decodeJob(running: false, fraction: 1, kind: "gather",
                                           code: 0, fromList: true))
        #expect(posted.isEmpty, "four things stacked up are not four banners")

        // Then the queue poll catches up, and he is told once.
        n.listFinished(QueueState(listed: 3, fraction: 1, pass: 1,
                                  done: [QueueDone(id: 1, kind: "cull", shoot: "2026-09-13-dog"),
                                         QueueDone(id: 2, kind: "gather", shoot: "2026-09-13-dog"),
                                         QueueDone(id: 3, kind: "presets", shoot: "2026-09-13-dog")]))
        #expect(posted.count == 1)
        #expect(posted[0] == Strings.Queue.summary(.init(done: 3)))
    }

    @Test("a job he started by hand still speaks for itself")
    func aHandStartedJobStillSpeaks() throws {
        let n = Notifications()
        n.isAvailable = true
        nonisolated(unsafe) var posted = 0
        n.post = { _, _ in posted += 1 }
        n.allowed = true
        n.isFrontmost = { false }
        // Nothing silences this one: there is no list to speak for it.
        n.jobChanged(try Fixture.decodeJob(running: false, fraction: 1, kind: "cull",
                                           code: 0, fromList: false))
        #expect(posted == 1)
    }

    @Test("with nothing skipped it says only how many finished")
    func theSentenceWithNoSkips() {
        let state = QueueState(listed: 2, pass: 1,
                               done: [QueueDone(id: 1, kind: "cull", shoot: "d"),
                                      QueueDone(id: 2, kind: "gather", shoot: "d")])
        #expect(Notifications.content(for: state).title == Strings.Queue.summary(.init(done: 2)))
    }
}

@Suite("The list on the Dock")
@MainActor
struct QueueDockTests {

    @Test("the Dock shows the whole list, not the job inside it")
    func theDockShowsTheList() throws {
        let q = try Fixture.decode(QueueState.self, "queue")
        // The list's own bar and the running job's are different numbers, and
        // the one the Dock is given is the list's: a bar that fills and drops
        // back to nothing four times in an evening says the machine restarted
        // four times.
        #expect(q.listed > 1)
        #expect(q.fraction != q.jobFraction || q.jobFraction == 0)
        #expect(QueueDock.title(q).contains(q.runningItem?.what ?? ""))
    }

    @Test("a job he started by hand is still the job's own bar")
    func oneJobIsStillOneBar() {
        // No list: nothing here claims there is one.
        let alone = QueueState(listed: 0, running: true, fromList: false, kind: "cull")
        #expect(alone.listed <= 1)
        #expect(alone.waiting.isEmpty)
    }
}


@Suite("What the list passed over")
@MainActor
struct QueueSkippedTests {

    /// A row that can no longer run has to be findable afterwards. The whole
    /// point of looking at a shoot again before starting is undone if the
    /// answer then goes quiet.
    @Test("what was skipped is on the screen, with the engine's reason under it")
    func skippedIsDrawn() {
        let state = QueueState(listed: 3, fraction: 1, pass: 2,
                               done: [QueueDone(id: 1, kind: "cull", shoot: "2026-09-13-dog")],
                               skipped: [QueueSkipped(id: 2, kind: "ingest", shoot: "2026-02-02-lake",
                                                      whyNot: "EOS_DIGITAL is not in this Mac any more")])
        // The list is empty and the pass is over, and the screen still has
        // both halves of what happened.
        #expect(state.isFinished)
        #expect(!state.skipped.isEmpty)
        #expect(state.skipped[0].what == Strings.Queue.what("ingest"))
        #expect(state.skipped[0].whyNot.contains("EOS_DIGITAL"))
    }

    /// The list's own height is counted off its rows, because a `List` in a
    /// `VStack` asks for a height of its own that has nothing to do with how
    /// many rows it holds — and a list of two showed one and a half.
    @Test("the list is as tall as its rows, however many there are")
    func heightFollowsTheRows() {
        let one = QueueList(state: QueueState(
            waiting: [QueueItem(id: 1, kind: "cull", shoot: "d", does: "Look at 54 frames.")]))
        let two = QueueList(state: QueueState(
            waiting: [QueueItem(id: 1, kind: "cull", shoot: "d", does: "Look at 54 frames."),
                      QueueItem(id: 2, kind: "presets", shoot: "d", does: "Write the presets.")]))
        #expect(two.wanted > one.wanted)
        // A row that will be skipped is taller: it carries the heading and
        // the engine's sentence.
        let stale = QueueList(state: QueueState(
            waiting: [QueueItem(id: 1, kind: "cull", shoot: "d", ready: false,
                                whyNot: "there are no photographs in d any more")]))
        #expect(stale.wanted > one.wanted)
        // A long list asks for every row. Where it scrolls is the window's
        // to say, once the history under it is at its least; a cap of 320
        // of its own scrolled four rows in a window with room to spare.
        let many = QueueList(state: QueueState(
            waiting: (1...20).map { QueueItem(id: $0, kind: "cull", shoot: "d", does: "x") }))
        #expect(many.wanted >= 20 * QueueList.row)
    }

    /// Until the list has laid itself out, the estimate stands, and it is
    /// what the list itself measured (`ListHeightProbe`, read off the
    /// rendered scenes): the one it replaced was a few points short on
    /// every list, and three rows showed a scroller.
    @Test("before it measures itself, the list's estimate is what it measured")
    func estimateIsTheMeasuredHeight() {
        let held = QueueList(state: QueueState(
            waiting: [QueueItem(id: 3, kind: "cull", shoot: "d", does: "Look at 1,558 frames."),
                      QueueItem(id: 4, kind: "presets", shoot: "d", does: "Write the presets."),
                      QueueItem(id: 5, kind: "gather", shoot: "d", does: "Build the folder.")],
            held: true))
        #expect(held.estimated == 183, "queue-held: three rows and the hint")
        let evening = QueueList(state: QueueState(
            waiting: [QueueItem(id: 11, kind: "ingest", shoot: "e", ready: false, whyNot: "the card is out"),
                      QueueItem(id: 12, kind: "cull", shoot: "e", does: "x"),
                      QueueItem(id: 13, kind: "presets", shoot: "e", does: "y")],
            running: true, fromList: true, id: 10, kind: "stor-push", shoot: "f"))
        #expect(evening.estimated == 321, "activity-list-long-reasons: the running row, a wrapped reason, two rows")
    }
}

/// Rule 2 of `StepPrimary`: **⌥ always means add**, on every control that
/// offers the step's primary action.
///
/// The toolbar's copy read only `wouldWait` and had no modifier observer at
/// all, so with ⌥ held the box at the bottom of the page said "Add Cull It to
/// the List" and added, while the button at the top still said "Cull It" and
/// started the job. Both ask this one question now.
@MainActor
@Suite("The toolbar and the box cannot disagree about ⌥")
struct StepPrimaryAgreementTests {
    @Test("the answer is the same wherever it is asked")
    func oneAnswer() {
        #expect(!StepPrimaryWords.adds(wouldWait: false, optionHeld: false))
        #expect(StepPrimaryWords.adds(wouldWait: true, optionHeld: false))
        // Held, it adds whether or not anything is running.
        #expect(StepPrimaryWords.adds(wouldWait: false, optionHeld: true))
        #expect(StepPrimaryWords.adds(wouldWait: true, optionHeld: true))
    }

    @Test("the label and the sentence follow the same answer, never wouldWait alone")
    func labelFollows() {
        let run = Strings.Cull.run
        // ⌥ held with nothing running: both controls say "add".
        let adds = StepPrimaryWords.adds(wouldWait: false, optionHeld: true)
        #expect(StepPrimaryWords.label(run, adds: adds) != run)
        #expect(StepPrimaryWords.spoken(run, adds: adds).contains(run))
        // Nothing held and nothing running: both say the step's own verb.
        let plain = StepPrimaryWords.adds(wouldWait: false, optionHeld: false)
        #expect(StepPrimaryWords.label(run, adds: plain) == run)
        #expect(StepPrimaryWords.spoken(run, adds: plain) == run)
    }
}
