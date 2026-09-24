import Testing
import Foundation
@testable import PipelineKit

// MARK: - the cull's report

@Suite("The cull's report")
struct CullReportTests {

    /// The dog shoot, as the engine really answered it: 54 frames, 23 put
    /// forward, one frame he has marked.
    func dogRows() throws -> [Row] {
        try Fixture.decode(ShootResponse.self, "shoot-decided").rows
    }

    /// A row as cull.csv would have it: a rating and a reason, nothing else.
    func row(_ stem: String, _ rating: Int, _ reason: String) -> Row {
        try! Row(fields: Fields(["file": .string("\(stem).ARW"), "stem": .string(stem),
                                 "rating": .string("\(rating)"), "reason": .string(reason)]))
    }

    @Test("every count comes from the cull's own column")
    func countsAreTheMachines() throws {
        let rows = try dogRows()
        let report = CullReport(rows: rows)
        #expect(report.frames == 54)
        #expect(report.putForward == rows.filter { $0.rating >= 3 }.count)
        #expect(report.putForward == 23)
        #expect(report.stacked == rows.filter { $0.rating == 1 }.count)
        #expect(report.setAside == rows.filter { $0.rating == 2 }.count)
        #expect(report.faults == rows.filter { $0.rating == 0 }.count)
        #expect(report.setAside + report.faults + report.stacked + report.putForward == report.frames)
    }

    /// One real evening's tally, as its cull.csv has it: 863 fine frames that
    /// were not shortlisted, and 283 with something wrong, under six of the
    /// engine's own words. The line said "1,146 set aside: below the cut 863 ·
    /// blink 131 · …" — two different things under one number, the engine's
    /// words, and four counts that added up to 1,139.
    @Test("the faults and the fine frames are two lines, and the faults add up")
    func faultsApartFromSetAside() {
        var rows: [Row] = []
        func add(_ n: Int, _ rating: Int, _ reason: String) {
            for _ in 0..<n {
                rows.append(row("f\(rows.count)", rating, reason))
            }
        }
        add(150, 5, "clear win")
        add(863, 2, "below the cut")
        add(262, 1, "duplicate")
        add(131, 0, "blink")
        add(65, 0, "soft")
        add(12, 0, "soft for this person")
        add(68, 0, "blown highlights")
        add(5, 0, "face in the dark")
        add(2, 0, "blown face")
        let report = CullReport(rows: rows)
        #expect(report.setAside == 863)
        #expect(report.faults == 283)
        #expect(report.setAsideLine == Strings.Cull.setAside(863))
        #expect(!report.setAsideLine.contains("below the cut"))
        // Read as he reads it: the no-break spaces that hold a reason to its
        // count are spaces on screen.
        let line = report.faultsLine.replacingOccurrences(of: "\u{00A0}", with: " ")
        #expect(line.hasPrefix(Strings.Cull.faults(283)))
        // The engine's words, in his.
        for word in ["blink", "below the cut", "face in the dark", "blown face"] {
            #expect(!line.contains(word), "\(line) contains \(word)")
        }
        #expect(line.contains("eyes closed 131"))
        #expect(line.contains("too soft to read 77"))
        #expect(line.contains("blown highlights 70"))
        #expect(line.contains("face in shadow 5"))
        // Every fault is in a named count or in the other.
        let named = report.reasons.reduce(0) { $0 + $1.count }
        #expect(named + report.otherFaults == report.faults)
        // At 900 pt it wrapped "face in / shadow 5". A reason and its count
        // are one unbreakable piece; the line breaks only at a " · ".
        let pieces = report.faultsLine.components(separatedBy: ": ").dropFirst().joined()
            .components(separatedBy: " · ")
        #expect(pieces.count == 4)
        for piece in pieces { #expect(!piece.contains(" "), "\(piece) can break inside") }
        #expect(pieces.last == "face\u{00A0}in\u{00A0}shadow\u{00A0}5")
    }

    /// "Culled with …" names what the results on screen came from. The
    /// engine's `focus` and `style` are written when a cull starts, so after
    /// a re-cull he stopped they named a run nothing on screen came from, and
    /// on a shoot that recorded nothing they were the defaults.
    @Test("the settings line is what the finished cull recorded, or nothing at all")
    func culledWithIsWhatItRecorded() throws {
        #expect(try PatchedFixture.shoot("shoot-decided").info.cull_ran_with == nil)
        let empty = try PatchedFixture.shoot("shoot-decided", patchInfo: ["cull_ran_with": [String: Any]()])
        #expect(empty.info.cull_ran_with == nil)
        let ran = try PatchedFixture.shoot("shoot-decided", patchInfo: [
            "cull_ran_with": ["focus": 2.37, "style": "action"], "focus": 1.6, "style": "normal"])
        #expect(ran.info.cull_ran_with == CullRun(focus: 2.37, style: "action"))
        #expect(ran.info.cull_ran_with?.moving == true)
        // What the next cull starts from is another fact, and stays apart.
        #expect(ran.info.focus == 1.6)
        #expect(ran.info.extra["cull_ran_with"] == nil)
    }

    /// Straight under "262 stacked behind a similar frame", "316 of them"
    /// read as 316 of the 262.
    @Test("his count names the whole it is out of")
    func markedNamesTheWhole() {
        #expect(Strings.Cull.markedByHim(316, of: 954) == "You have marked 316 of the 954 frames yourself.")
    }

    @Test("past the names it has room for, the rest is counted, never dropped")
    func otherFaultsAreCounted() {
        var rows: [Row] = []
        let reasons = ["blink", "soft", "blown highlights", "too dark", "head cut", "mid-word"]
        for (i, reason) in reasons.enumerated() {
            for _ in 0..<(10 - i) { rows.append(row("f\(rows.count)", 0, reason)) }
        }
        rows.append(row("nameless", 0, ""))
        let report = CullReport(rows: rows)
        #expect(report.reasons.count == CullReport.namedReasons)
        #expect(report.otherFaults == 6 + 5 + 1)
        #expect(report.faultsLine.hasSuffix(CullReport.unbroken(Strings.Cull.otherFaults(12))))
    }

    /// The report is of the machine's own work. Changing every verdict of his
    /// must not move a single number in it (DESIGN.md §2.6 and §7.5).
    @Test("his verdicts never change a number in it")
    func hisVerdictsDoNotCount() throws {
        let rows = try dogRows()
        let before = CullReport(rows: rows)
        let after = CullReport(rows: try PatchedFixture.shoot("shoot-decided", overrides: ["*": 5]).rows)
        #expect(after.putForward == before.putForward)
        #expect(after.setAside == before.setAside)
        #expect(after.stacked == before.stacked)
        #expect(after.reasons.map(\.count) == before.reasons.map(\.count))
        // The only thing that does change is the line that says so.
        #expect(after.movedSince == 54)
        #expect(before.movedSince == 1)
    }

    @Test("the cull's word for a frame like its neighbour never reaches a screen")
    func noRetiredWords() throws {
        let report = CullReport(rows: try dogRows())
        let lines = [report.faultsLine, report.setAsideLine, report.stackedLine]
        for line in lines {
            let lower = line.lowercased()
            for word in ["duplicate", "dupe", " dup", "answer key", "bench", "taste", "./pl", "tier", "csv"] {
                #expect(!lower.contains(word), "\(line) contains \(word)")
            }
        }
    }

    @Test("a reason the app does not know is the engine's own words")
    func unknownReasonPassesThrough() {
        #expect(Strings.Cull.reasonWord("a thing nobody planned for") == "a thing nobody planned for")
        #expect(Strings.Cull.reasonWord("soft duplicate") == Strings.Cull.reasonWord("soft"))
        #expect(!Strings.Cull.reasonWord("duplicate").lowercased().contains("dup"))
    }

    @Test("the number of stacks is printed only when the engine has said")
    func stacksOnlyWhenKnown() throws {
        let report = CullReport(rows: try dogRows())
        // Today's engine sends no stack column, so the line names the frames
        // and not a number of stacks it would have had to invent.
        #expect(report.stacks == 0)
        #expect(!report.stackedLine.contains("stacked into"))
    }
}

// MARK: - who chose what gets a preset

@Suite("Where the editor is")
struct EditorLocationTests {

    /// The lookup is a folder on a disk and LaunchServices, so it is not done
    /// while a view is being drawn. Until an answer arrives the page knows it
    /// has none, and says nothing about the editor rather than saying it is
    /// missing.
    @Test("nothing is claimed about an editor nobody has looked for yet")
    @MainActor func unknownUntilLooked() async {
        Editors.pretend("darktable", at: nil)      // clears any earlier run
        #expect(Editors.isKnown("darktable"))
        #expect(Editors.location("darktable") == nil)

        // An editor this Mac has never heard of: the look still finishes and
        // still answers, off the main actor, and the page hears about it.
        Editors.look(for: "rawtherapee")
        var waited = 0
        while !Editors.isKnown("rawtherapee") && waited < 100 {
            try? await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(Editors.isKnown("rawtherapee"))
    }

    /// PhotoLab 10 installs as DXOPhotoLab10.app and declares
    /// com.dxo.PhotoLab10. A prefix of "DxO PhotoLab" and a list of
    /// identifiers that stopped at 8 found neither, and both pages said it was
    /// not on a Mac that had it.
    @Test("every spelling DxO has used for PhotoLab is PhotoLab")
    func photoLabByAnyName() {
        #expect(Editors.isNamed("DXOPhotoLab10.app", "dxo"))
        #expect(Editors.isNamed("DxO PhotoLab 8.app", "dxo"))
        #expect(Editors.isNamed("DxO PhotoLab.app", "dxo"))
        #expect(!Editors.isNamed("DxO PureRAW 4.app", "dxo"))
        #expect(!Editors.isNamed("DXOPhotoLab10", "dxo"))          // a folder, not an app
        #expect(Editors.isNamed("darktable.app", "darktable"))
        #expect(!Editors.isNamed("DXOPhotoLab10.app", "lightroom"))
    }

    /// "9" sorts after "10" as text, so taking the last name in order hands a
    /// Mac with both the older one.
    @Test("the newest copy is the one with the highest version, not the last name")
    func newestByNumber() {
        let nine = URL(fileURLWithPath: "/Applications/DXOPhotoLab9.app")
        let ten = URL(fileURLWithPath: "/Applications/DXOPhotoLab10.app")
        let eight = URL(fileURLWithPath: "/Applications/DxO PhotoLab 8.app")
        let copies = [nine, ten, eight].map {
            (url: $0, version: Editors.version(declared: nil, file: $0.lastPathComponent))
        }
        #expect(Editors.newest(copies) == ten)
        // What the bundle declares wins over its file name.
        #expect(Editors.version(declared: "10.0.2", file: "DxO PhotoLab.app") == [10, 0, 2])
        #expect(Editors.version(declared: "", file: "DxO PhotoLab 8.app") == [8])
        #expect(Editors.newest([]) == nil)
    }
}

@Suite("The presets split")
struct PresetSplitTests {

    @MainActor func session(_ r: ShootResponse) -> ShootSession {
        let c = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "t"))
        return ShootSession(response: r, ext: nil, client: c, pump: ImagePump(client: c))
    }

    @Test("counted frame by frame when the engine does not send the two authors")
    @MainActor func derived() throws {
        let s = session(try Fixture.decode(ShootResponse.self, "shoot-decided"))
        #expect(s.info.will_be_edited == nil)
        let split = DerivedPresetSplit().split(s)
        #expect(split.fromEngine == false)
        #expect(split.willBeEdited == 23)
        // One frame of his, and it was already one the cull had put forward.
        #expect(split.kept == 1)
        // No burst has been been-through on this shoot, so nothing is agreed.
        #expect(split.agreed == 0)
        #expect(split.notLookedThrough == 22)
        #expect(split.kept + split.agreed + split.notLookedThrough == split.willBeEdited)
    }

    @Test("his word beats the cull's, so a frame he put out gets no preset")
    @MainActor func hisOutWins() throws {
        let plain = session(try Fixture.decode(ShootResponse.self, "shoot-decided"))
        let before = DerivedPresetSplit().split(plain)
        // A frame the cull put forward, which he has since put out.
        let stem = try #require(plain.order.first {
            (plain.rows[$0]?.rating ?? 0) >= 3 && plain.rows[$0]?.override == nil
        })
        let after = session(try PatchedFixture.shoot("shoot-decided",
                                                      overrides: [stem: VerdictValue.drop]))
        let now = DerivedPresetSplit().split(after)
        #expect(now.willBeEdited == before.willBeEdited - 1)
        #expect(now.kept == before.kept)
    }

    /// The engine's `kept` is gather's rule, which already holds the picks he
    /// left standing — `agreed` — so the page takes them out of it.
    @Test("the engine's own numbers, when it sends them")
    @MainActor func fromEngine() throws {
        let s = session(try PatchedFixture.shoot("shoot-decided",
                                                  patchInfo: ["will_be_edited": 23, "agreed": 9, "kept": 23]))
        let split = EnginePresetSplit().split(s)
        #expect(split.fromEngine)
        #expect(split.willBeEdited == 23)
        #expect(split.kept == 14)
        #expect(split.agreed == 9)
        #expect(split.notLookedThrough == 0)
    }

    /// The 2026-09-19 shoot as the engine counts it now: 305 frames he pressed
    /// Keep on and 64 picks he left standing, all inside his 369. The page
    /// read "369 you kept · 1,242 the cull put forward…" under "369 frames
    /// will get a preset".
    @Test("the three lines always add up to the headline")
    @MainActor func addsUp() throws {
        for (will, kept, agreed) in [(369, 369, 64), (23, 1, 0), (23, 14, 9), (10, 12, 3), (5, 0, 9)] {
            let s = session(try PatchedFixture.shoot(
                "shoot-decided", patchInfo: ["will_be_edited": will, "agreed": agreed, "kept": kept]))
            let split = EnginePresetSplit().split(s)
            #expect(split.kept + split.agreed + split.notLookedThrough == split.willBeEdited)
        }
        let s = session(try PatchedFixture.shoot(
            "shoot-decided", patchInfo: ["will_be_edited": 369, "agreed": 64, "kept": 369]))
        let split = EnginePresetSplit().split(s)
        #expect(split.kept == 305 && split.agreed == 64 && split.notLookedThrough == 0)
    }

    /// The 2026-09-19 shoot as the engine counted it before: every frame he
    /// left alone was "agreed", 1,242 of them against 369 that get a preset.
    @Test("an engine that counts agreed the old way is counted for, not believed")
    @MainActor func oldAgreed() throws {
        let s = session(try PatchedFixture.shoot(
            "shoot-decided", patchInfo: ["will_be_edited": 23, "agreed": 40, "kept": 23]))
        #expect(!AutomaticPresetSplit.agreedIsPicks(s.info))
        #expect(AutomaticPresetSplit().split(s).fromEngine == false)
        let ok = session(try PatchedFixture.shoot(
            "shoot-decided", patchInfo: ["will_be_edited": 23, "agreed": 9, "kept": 23]))
        #expect(AutomaticPresetSplit.agreedIsPicks(ok.info))
    }

    @Test("the switch between the two engines is one line")
    @MainActor func theSwitch() throws {
        let old = session(try Fixture.decode(ShootResponse.self, "shoot-decided"))
        StepCapabilities.current = LegacyEngine()
        #expect(!StepCapabilities.current.presetsCanLeaveOutAgreed)
        #expect(!StepCapabilities.current.countsAreTwoAuthored(old.info))
        #expect(AutomaticPresetSplit().split(old).fromEngine == false)

        let new = session(try PatchedFixture.shoot("shoot-decided",
                                                    patchInfo: ["will_be_edited": 23, "agreed": 9, "kept": 14]))
        #expect(StepCapabilities.current.countsAreTwoAuthored(new.info))
        #expect(AutomaticPresetSplit().split(new).fromEngine == true)

        StepCapabilities.current = CurrentEngine()
        #expect(StepCapabilities.current.presetsCanLeaveOutAgreed)
        StepCapabilities.current = LegacyEngine()
    }
}

// MARK: - the copy's own log

@Suite("What the copy says about itself")
struct IngestNoteTests {

    @Test("all six sentences, and which three report a copy nothing proved")
    @MainActor func sentences() throws {
        let cases: [(IngestNote, Bool, String)] = [
            (.done(files: 1157, proof: "read back on the way in"), false, "1,157"),
            (.failed(detail: "TSC04330.ARW"), true, "FAILED"),
            (.stopped(files: 412, of: 1157), true, "412"),
            (.unclear(log: "/x/cull/logs/ingest.log"), true, "ingest.log"),
            (.none, false, ""),
        ]
        for (note, bad, contains) in cases {
            let (text, isBad) = try #require(IngestNoteView.sentence(note, frames: 54, verify: ""))
            #expect(isBad == bad, "\(text)")
            if !contains.isEmpty { #expect(text.contains(contains), "\(text)") }
        }
        // The sixth: a shoot copied before the copy kept a log of its own.
        let (old, oldBad) = try #require(IngestNoteView.sentence(.none, frames: 54, verify: "in-flight"))
        #expect(!oldBad)
        #expect(old.contains("54"))
        #expect(old.contains("in-flight"))
        // And before any log at all, with nothing in the folder yet.
        let (copying, _) = try #require(IngestNoteView.sentence(.none, frames: 0, verify: ""))
        #expect(copying == Strings.Import.copying)
        // And while a copy into it is still going, whatever its log says so far.
        let (going, goingBad) = try #require(IngestNoteView.sentence(.copying(files: 412, of: 1157),
                                                                     frames: 412, verify: "in-flight"))
        #expect(going == Strings.Import.copying)
        #expect(!goingBad)
    }

    @Test("a copy still going is decoded as going, not stopped")
    func copyingDecodes() throws {
        let note = try Fixture.decodeJSON(IngestNote.self, #"{"state": "copying", "files": 412, "of": 1157}"#)
        guard case .copying(let files, let of) = note else {
            Issue.record("decoded as \(note)")
            return
        }
        #expect(files == 412 && of == 1157)
    }

    @Test("the note is never built from a count of the folder")
    @MainActor func neverFromTheFolder() throws {
        // A copy that stopped part way still says so, however many files are
        // in the shoot afterwards.
        let (text, bad) = try #require(IngestNoteView.sentence(.stopped(files: 3, of: 1157),
                                                               frames: 1157, verify: "in-flight"))
        #expect(bad)
        #expect(text.contains("3 of 1157") || text.contains("3 of 1,157"))
    }
}

// MARK: - a name the engine would take

@Suite("Naming a shoot")
struct ShootNameTests {
    @Test("the engine's own rule, checked under the field")
    func rule() {
        #expect(ShootName.problem("", taken: []) == Strings.Import.nameEmpty)
        #expect(ShootName.problem("2026-10-04-lake", taken: []) == nil)
        #expect(ShootName.problem("2026 10 04", taken: []) == Strings.Import.nameCharacters)
        #expect(ShootName.problem("lake/../etc", taken: []) == Strings.Import.nameCharacters)
        #expect(ShootName.problem("dog", taken: ["dog"]) != nil)
        #expect(ShootName.problem("dog", taken: ["cat"]) == nil)
    }
}

// MARK: - a long job, in place

@Suite("A long job where the button was")
struct JobInPlaceTests {

    @Test("elapsed and remaining come from the engine's own numbers")
    func timing() {
        #expect(JobTiming.clock(0) == "0:00")
        #expect(JobTiming.clock(53) == "0:53")
        #expect(JobTiming.clock(607) == "10:07")
        #expect(JobTiming.clock(3661) == "1:01:01")
        // The time left is the engine's sentence, the same one the toolbar and
        // the list print, and never a figure worked out here.
        let running = Job(running: true, stopped: false, fraction: 0.42, elapsed: 53,
                          remaining: 240, remaining_text: "about 4 minutes left")
        #expect(JobTiming.text(running) == "0:53 · about 4 minutes left")
        // Too early for the engine to say, so nothing is said.
        #expect(JobTiming.text(Job(running: true, stopped: false, fraction: 0.01, elapsed: 2)) == "0:02")
        // A job that has stopped has no time left in it.
        #expect(JobTiming.text(Job(running: false, stopped: false, fraction: 1, elapsed: 90,
                                   remaining_text: "about a minute left")) == "1:30")
    }

    @Test("a job of this step's kind is this step's, and nobody else's")
    @MainActor func whoseJob() {
        let jobs = JobModel()
        let runner = StepJobRunner(kinds: ["cull"], shoot: "2026-09-13-dog", jobs: jobs)
        jobs.take(Job(running: true, stopped: false, kind: "cull", shoot: "2026-09-13-dog",
                      title: "culling 2026-09-13-dog", fraction: 0.4, elapsed: 10))
        #expect(runner.mine != nil)
        #expect(runner.other == nil)
        #expect(runner.phase == .running(jobs.job!))

        jobs.take(Job(running: true, stopped: false, kind: "presets", shoot: "2026-09-13-dog",
                      title: "presets for 2026-09-13-dog", fraction: 0.2, elapsed: 4))
        #expect(runner.mine == nil)
        #expect(runner.other != nil)

        // Somebody else's shoot is not this step's job either.
        jobs.take(Job(running: true, stopped: false, kind: "cull", shoot: "2026-09-19",
                      title: "culling 2026-09-19", fraction: 0.1, elapsed: 2))
        #expect(runner.mine == nil)
        #expect(runner.other != nil)
    }

    /// The request behind something of his goes on the engine's list, which
    /// keeps it when he goes to another shoot and starts it in its turn. It
    /// used to wait in the page and was dropped the moment he looked away.
    @Test("a request behind something of his goes on the list, not into the page")
    @MainActor func goesOnTheList() async {
        let jobs = JobModel()
        let runner = StepJobRunner(kinds: ["cull"], shoot: "dog", jobs: jobs)
        jobs.take(Job(running: true, stopped: false, kind: "presets", shoot: "dog",
                      title: "presets for dog", fraction: 0.2, elapsed: 4))
        let added = Box(), ran = Box()
        runner.run(orAdd: { added.value = true }) { ran.value = true }
        #expect(added.value)
        #expect(!ran.value)
        // Nothing is held by the page, so leaving it drops nothing.
        #expect(runner.phase == .idle)
        runner.teardown()
        jobs.take(Job(running: false, stopped: false, kind: "presets", shoot: "dog", code: 0))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!ran.value)
    }

    @Test("the box says where on the list this step's work is, and only this shoot's")
    @MainActor func readsTheList() {
        let runner = StepJobRunner(kinds: ["cull"], shoot: "dog", jobs: JobModel())
        let q = QueueModel()
        runner.list = { q }
        #expect(runner.phase == .idle)
        q.take(QueueState(waiting: [QueueItem(id: 4, kind: "presets", shoot: "cat"),
                                    QueueItem(id: 5, kind: "cull", shoot: "cat"),
                                    QueueItem(id: 6, kind: "cull", shoot: "dog")]))
        #expect(runner.phase == .listed(3))
        #expect(runner.isQueued)
        #expect(runner.listed?.item.id == 6)
        q.take(QueueState(waiting: [QueueItem(id: 6, kind: "cull", shoot: "dog")]))
        #expect(runner.phase == .listed(1))
        #expect(Strings.Step.onTheList(1) == "First in Up Next")
        #expect(Strings.Step.onTheList(2).hasSuffix("in Up Next"))
        q.take(.empty)
        #expect(runner.phase == .idle)
    }

    /// Third on the list is behind the job running and two more, and the
    /// line beside the box said only the first.
    @Test("the line beside the box counts what else is ahead on the list")
    func waitingAhead() {
        #expect(Strings.Step.waitingFor("presets for cat") == "Waiting for presets for cat to finish.")
        #expect(Strings.Step.waitingFor("presets for cat", ahead: 0) == "Waiting for presets for cat to finish.")
        let behind = Strings.Step.waitingFor("presets for cat", ahead: 2)
        #expect(behind.contains("presets for cat"))
        #expect(behind.contains("2 more"))
        #expect(Strings.Step.waitingFor("", ahead: 1).contains("1 more"))
        #expect(behind.hasSuffix("in Up Next."))
        // Named as Up Next names it, never by the engine's title.
        let gather = Job(running: true, stopped: false, kind: "gather", shoot: "2026-09-13-dog",
                         title: "gathering the keepers of 2026-09-13-dog")
        #expect(Strings.Queue.named(gather) == "Build the PhotoLab folder · 2026\u{2011}09\u{2011}13\u{2011}dog")
        #expect(!Strings.Step.waitingFor(Strings.Queue.named(gather)).contains("gathering"))
    }

    @Test("the same work is never put on the list twice for one shoot")
    @MainActor func noSecondCopy() {
        let waiting = QueueState(waiting: [QueueItem(id: 6, kind: "cull", shoot: "dog")])
        #expect(StepsModel.alreadyAsked("cull", shoot: "dog", list: waiting, runningHere: false) != nil)
        #expect(StepsModel.alreadyAsked("presets", shoot: "dog", list: waiting, runningHere: false) == nil)
        #expect(StepsModel.alreadyAsked("cull", shoot: "cat", list: waiting, runningHere: false) == nil)
        // Running now, whether started by hand or off the list.
        #expect(StepsModel.alreadyAsked("cull", shoot: "dog", list: .empty, runningHere: true) != nil)
        let running = QueueState(running: true, kind: "cull", shoot: "dog")
        #expect(StepsModel.alreadyAsked("cull", shoot: "dog", list: running, runningHere: false) != nil)
        // The machine's own homework is not his cull.
        let homework = QueueState(running: true, kind: "cull", shoot: "dog", background: true)
        #expect(StepsModel.alreadyAsked("cull", shoot: "dog", list: homework, runningHere: false) == nil)
    }

    /// After a relaunch the page's settings are read back from the shoot,
    /// which is the last cull started; the cull waiting on the list was put
    /// there with its own, and those are what it runs with.
    @Test("while his cull waits, the held settings are the ones it was put on the list with")
    @MainActor func waitingSettingsAreTheItems() throws {
        let item = try JSONDecoder().decode(QueueItem.self, from: Data(#"""
            {"id": 6, "kind": "cull", "shoot": "2026-09-13-dog", "opts": {"style": "action", "focus": 1.6}}
            """#.utf8))
        #expect(item.options["focus"] == .number(1.6))
        let session = ShootSession(response: try PatchedFixture.shoot("shoot-decided",
                                                                      patchInfo: ["focus": 2.4, "style": "normal"]),
                                   ext: nil, client: StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k")),
                                   pump: ImagePump(budget: .base, loader: { _ in Data() }),
                                   queue: VerdictQueue(sender: { _ in .failure(.offline) }))
        let model = StepsModel(session: session, jobs: JobModel())
        #expect(model.focusSetting == 2.4 && !model.peopleMove)
        model.adoptWaiting(item)
        #expect(model.focusSetting == 1.6 && model.peopleMove)
        // Another kind's options are not the cull's, and an engine that
        // sends none leaves the page as it was.
        model.adoptWaiting(QueueItem(id: 7, kind: "presets", options: ["focus": .number(3.0)]))
        model.adoptWaiting(QueueItem(id: 8, kind: "cull"))
        #expect(model.focusSetting == 1.6 && model.peopleMove)
    }

    /// The list the page reads is only brought up to date by the add's own
    /// answer, so a second click before that answer found nothing on it and
    /// put the same cull on the list again.
    @Test("a double-click on Add to Up Next adds it once")
    @MainActor func addsOnce() async throws {
        SlowList.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowList.self]
        let client = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "k"),
                                  session: URLSession(configuration: config))
        let session = ShootSession(response: try Fixture.decode(ShootResponse.self, "shoot-decided"),
                                   ext: nil, client: client,
                                   pump: ImagePump(budget: .base, loader: { _ in Data() }),
                                   queue: VerdictQueue(sender: { _ in .failure(.offline) }))
        let model = StepsModel(session: session, jobs: JobModel())
        let list = QueueModel(client: client)
        model.list = list
        defer { list.cancelWatching() }

        model.addToTheList(kind: "cull", options: ["focus": .number(1.6)])
        model.addToTheList(kind: "cull", options: ["focus": .number(1.6)])
        #expect(await Self.eventually { SlowList.adds() == 1 })
        try await Task.sleep(for: .milliseconds(400))
        #expect(SlowList.adds() == 1, "the second click is the same add")
        // Once the first is answered, a press is a press again.
        #expect(await Self.eventually { model.added != nil })
        model.addToTheList(kind: "presets", options: [:])
        #expect(await Self.eventually { SlowList.adds() == 2 })
    }

    /// A page that does not put its work on the list (the card page, so far)
    /// holds a request there instead. Polled against a deadline: a fixed
    /// sleep raced the 400 ms watch and failed under load.
    @Test("with no list, a second request waits in the page and can be taken back")
    @MainActor func queuesInThePage() async {
        let jobs = JobModel()
        let runner = StepJobRunner(kinds: ["cull"], shoot: "dog", jobs: jobs)
        jobs.take(Job(running: true, stopped: false, kind: "presets", shoot: "dog",
                      title: "presets for dog", fraction: 0.2, elapsed: 4))

        let ran = Box()
        runner.run { ran.value = true }
        #expect(runner.isQueued)
        #expect(runner.phase == .queued)
        #expect(ran.value == false)

        // It goes the moment the other one does: waited for, not slept on,
        // because the runner looks every 400 ms and a loaded machine made a
        // fixed 900 ms fail five runs in six.
        jobs.take(Job(running: false, stopped: false, kind: "presets", shoot: "dog", code: 0))
        #expect(await Self.eventually { ran.value })
        #expect(!runner.isQueued)

        // And a queued one can be taken back without touching the engine.
        // Another job of his running means the first did not take the slot,
        // and the box stops saying it is starting.
        jobs.take(Job(running: true, stopped: false, kind: "presets", shoot: "dog",
                      title: "presets for dog", fraction: 0.2, elapsed: 4))
        #expect(await Self.eventually { !runner.starting })
        let second = Box()
        runner.run { second.value = true }
        #expect(runner.isQueued)
        runner.cancelQueued()
        #expect(!runner.isQueued)
        jobs.take(Job(running: false, stopped: false, kind: "presets", shoot: "dog", code: 0))
        try? await Task.sleep(for: .milliseconds(600))
        #expect(second.value == false)
    }

    @MainActor static func eventually(within seconds: Double = 10, _ done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    @Test("with nothing running, the request goes straight out")
    @MainActor func runsAtOnce() async {
        let jobs = JobModel()
        let runner = StepJobRunner(kinds: ["cull"], shoot: "dog", jobs: jobs)
        let ran = Box()
        runner.run { ran.value = true }
        #expect(!runner.isQueued)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(ran.value == true)
    }

    /// The engine can take seconds to answer a start: it stands the idle
    /// learning run down first. The button stayed live all that time, and
    /// the press again because it felt slow asked for the same cull twice
    /// and drew the engine's refusal of it beside his own cull.
    @Test("from the press until the job is seen, the box says Starting and a second press does nothing")
    @MainActor func startingHoldsTheBox() async {
        let jobs = JobModel()
        let runner = StepJobRunner(kinds: ["cull"], shoot: "dog", jobs: jobs)
        let answered = Box()
        var posts = 0, added = 0
        runner.run {
            posts += 1
            while !answered.value { try? await Task.sleep(for: .milliseconds(10)) }
        }
        // At once, not a moment later: the second click is the next event.
        #expect(runner.phase == .starting)
        #expect(runner.starting)
        runner.run { posts += 1 }
        runner.run(orAdd: { added += 1 }) { posts += 1 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(posts == 1 && added == 0)
        #expect(runner.phase == .starting)

        // The engine has answered and the poll has not looked yet: still
        // Starting, never the button for a moment in between.
        answered.value = true
        try? await Task.sleep(for: .milliseconds(100))
        #expect(runner.phase == .starting)
        let job = Job(running: true, stopped: false, id: 7, kind: "cull", shoot: "dog",
                      title: "culling dog", fraction: 0.01, elapsed: 1)
        jobs.take(job)
        #expect(runner.phase == .running(job))
        #expect(await Self.eventually { !runner.starting })
    }

    @Test("a start the engine refuses, or one it never shows running, gives the button back")
    @MainActor func startingEnds() async {
        let jobs = JobModel()
        let refused = StepJobRunner(kinds: ["presets"], shoot: "dog", jobs: jobs)
        refused.run { jobs.refusals.set(.job, "there are no photographs in dog any more") }
        // The refusal is on the board: at once, not after the wait for a job.
        #expect(await Self.eventually(within: 1) { refused.phase == .idle })
        jobs.refusals.clear(.job)

        // Answered, and nothing ever seen running: the box does not hold
        // "Starting…" for good.
        let quiet = StepJobRunner(kinds: ["cull"], shoot: "dog", jobs: jobs)
        quiet.run {}
        #expect(quiet.phase == .starting)
        // Two seconds on the runner's own clock, which a full test run on a
        // busy main actor stretched past a 5 s window; "not for good" is
        // what is checked.
        #expect(await Self.eventually(within: 30) { quiet.phase == .idle })

        // Over before the poll saw it running.
        let quick = StepJobRunner(kinds: ["presets"], shoot: "dog", jobs: jobs)
        quick.run { jobs.take(Job(running: false, stopped: false, id: 9, kind: "presets", shoot: "dog", code: 0)) }
        #expect(await Self.eventually(within: 1) { quick.phase == .idle })
    }

    @MainActor final class Box { var value = false }

    /// An engine that takes a quarter of a second to answer an add, and
    /// counts them.
    final class SlowList: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var posts = 0
        static let lock = NSLock()
        static func reset() { lock.withLock { posts = 0 } }
        static func adds() -> Int { lock.withLock { posts } }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let isAdd = request.httpMethod == "POST" && request.url?.path == "/api/queue"
            var body = Data(#"{"queue": [], "running": false}"#.utf8)
            if isAdd {
                let n = Self.lock.withLock { Self.posts += 1; return Self.posts }
                body = Data(#"{"ok": true, "added": {"id": \#(n), "kind": "cull", "shoot": "x"}, "list": {"queue": [{"id": \#(n), "kind": "cull", "shoot": "x"}], "running": false}}"#.utf8)
            }
            let reply = body
            DispatchQueue.global().asyncAfter(deadline: .now() + (isAdd ? 0.25 : 0)) { [self] in
                let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                        headerFields: ["content-type": "application/json"])!
                client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        override func stopLoading() {}
    }
}

// MARK: - the layout that must not move

@Suite("The step pages' geometry")
struct StepLayoutTests {

    /// The whole of FLOW-04 in one assertion: the box a button sits in and the
    /// box a job's progress sits in are the same box.
    @Test("the primary's box is one size, whatever is in it")
    func oneBox() {
        #expect(StepMetric.primaryBox.width == 320)
        #expect(StepMetric.primaryBox.height == 36)
        // Tall enough for a control and its focus ring, and never taller than
        // the bar it lives in.
        #expect(StepMetric.primaryBox.height >= Tokens.Metric.minimumHitTarget)
    }

    /// The action bar's own arithmetic at the three sizes of §4.6. The page is
    /// a 680 pt column; the box is 320 of it; what is left is where a refusal
    /// goes, and it must be wide enough to read a sentence in.
    @Test("a refusal has room to be read beside the button")
    func refusalHasRoom() {
        let leading = StepMetric.column - StepMetric.primaryBox.width - StepMetric.barGap
        #expect(leading >= 320)
        for window in [CGSize(width: 900, height: 620), CGSize(width: 1100, height: 780),
                       CGSize(width: 1512, height: 945)] {
            // The bar never exceeds the column, so it never exceeds the window.
            let usable = window.width - Tokens.Metric.sidebarDefault - 2 * Tokens.Metric.windowMargin
            #expect(min(usable, StepMetric.column) >= StepMetric.primaryBox.width)
        }
    }

    @Test("the seven steps are handed to the shell, and nobody else's are")
    @MainActor func registration() {
        StepRegistry.reset()
        WorkflowSteps.register()
        for id in WorkflowSteps.ids { #expect(StepRegistry.isRegistered(id)) }
        #expect(!StepRegistry.isRegistered("keepers"))
        // Reels has a page: selecting it in the sidebar used to land on nothing.
        #expect(StepRegistry.isRegistered("reels"))
        // And Instagram, in every build: it is the core's, not an extension's.
        #expect(StepRegistry.isRegistered("instagram"))
        #expect(Fallbacks.baseStepIDs.count == 8)
        #expect(Fallbacks.baseStepIDs.firstIndex(of: "instagram") == Fallbacks.baseStepIDs.firstIndex(of: "edit")! + 1)
    }

    @Test("a link with nowhere to go is not drawn")
    @MainActor func noDeadControls() {
        StepSlots.reset()
        #expect(StepSlots.showLearned == nil)
        #expect(StepSlots.storagePanel == nil)
    }
}

// MARK: - recording the keepers at the end

@Suite("Finishing a shoot")
struct FinishTests {

    @Test("both numbers are read out of the engine's own sentence for the buttons")
    func counts() {
        let a = RecordedKeepers.counts(in: "not written: this would replace 154 chosen frames with 3; press it again to confirm")
        #expect(a.0 == 154)
        #expect(a.1 == 3)
        let b = RecordedKeepers.counts(in: "not written: /x/selects.json holds 291 frames chosen for a shoot marked finished, and there are no exports left to redraw it from, so this would replace it with 12 frames")
        #expect(b.0 == 291)
        #expect(b.1 == 12)
        // A sentence with nothing to read is not guessed at.
        #expect(RecordedKeepers.counts(in: "the engine said something else entirely").0 == nil)
        // Today's engine, which names no file and no button.
        let c = RecordedKeepers.counts(in: "Not recorded: this finished shoot's keeper list holds 154 frames "
            + "chosen from exports that cannot be found now, and recording again would replace it with 3 "
            + "frames taken from your marks and the edit folder. Nothing was changed.")
        #expect(c.0 == 154 && c.1 == 3)
        let d = RecordedKeepers.counts(in: "Not recorded: this would replace 154 chosen frames with 3. Nothing was changed.")
        #expect(d.0 == 154 && d.1 == 3)
    }

    /// Only the finished shoot's refusal knows its cause. The other can be his
    /// own changed marks, and was told the frames could not be found.
    @Test("the sheet gives a cause only where the engine knows it")
    func shrinkCause() throws {
        let gone = try #require(RecordedKeepers.body(for: "Not recorded: this finished shoot's keeper list holds 154 "
            + "frames chosen from exports that cannot be found now, and recording again would replace it with 3 "
            + "frames taken from your marks and the edit folder. Nothing was changed."))
        #expect(gone.contains("cannot be found"))
        let fewer = try #require(RecordedKeepers.body(for:
            "Not recorded: this would replace 154 chosen frames with 3. Nothing was changed."))
        #expect(!fewer.contains("cannot be found"))
        #expect(fewer.contains("154") && fewer.contains("only 3"))
        #expect(RecordedKeepers.body(for: "the engine said something else entirely") == nil)
    }

    /// The engine names the file first, and that name is a path through a
    /// folder called after the shoot's date. Every real refusal looks like
    /// this one, so every real refusal used to put the date on the button.
    @Test("the shoot's own date in the path is never mistaken for his frames")
    func countsPastThePath() {
        let out = "/Users/x/Library/Mobile Documents/lib17/shoots/2026-09-13-dog/cull/selects.json"
        let finished = RecordedKeepers.counts(in:
            "not written: \(out) holds 5 frames chosen for a shoot marked finished, and there are no "
            + "exports left to redraw it from, so this would replace it with 3 frames taken from your "
            + "overrides and edit/. Nothing was changed. Press Re-read again to confirm, or delete \(out) by hand.")
        #expect(finished.0 == 5)
        #expect(finished.1 == 3)

        let narrowing = RecordedKeepers.counts(in:
            "not written: this would replace 154 chosen frames with 3; press Re-read again to confirm, "
            + "or delete \(out) by hand")
        #expect(narrowing.0 == 154)
        #expect(narrowing.1 == 3)

        // A refusal the engine has not written yet: its numbers are read, but
        // only once the path is out of the way.
        let other = RecordedKeepers.counts(in: "not written: \(out) would go from 40 frames to 9 frames")
        #expect(other.0 == 40)
        #expect(other.1 == 9)

        // And a sentence that is only a path still says nothing.
        #expect(RecordedKeepers.counts(in: "not written: \(out) is on disk but cannot be read").0 == nil)
    }

    @Test("the words say what happens to his, and never what he would lose")
    func wording() {
        #expect(Strings.Finish.shrinkKeepCount(154) == "Keep 154")
        #expect(Strings.Finish.shrinkUseCount(3) == "Record 3")
        #expect(Strings.Finish.shrinkTitleCounts(154, 3) == "Record 3 keepers instead of 154?")
        #expect(Strings.Finish.finished(154, from: "").contains("the frames you exported"))
        #expect(Strings.Finish.finished(368, from: "the frames you exported and the ones you kept")
            .contains("368 keepers are recorded — the frames you exported and the ones you kept"))
        #expect(Strings.Finish.recordedKeepers(368, from: "the frames you kept") == "368 keepers recorded: the frames you kept")
        #expect(Strings.Finish.finishedOn("2026-09-22").hasPrefix("Finished on "))
        #expect(Strings.Finish.finishedOn("not a day") == Strings.Finish.alreadyFinished)
    }

    /// "only train based on what i've exported": the page says what the cull
    /// learns from apart from what it is checked against, and with an engine
    /// that does not say, it says what it always said.
    @Test("Finish says the cull learns from the frames he exported, apart from the keepers it is checked against")
    func learnsFromExports() throws {
        #expect(Strings.Finish.finished(368, from: "x", taught: 356, taughtFrom: "exported")
            == "Finished. The cull learns from the 356 you exported.")
        #expect(Strings.Finish.finished(153, from: "x", taught: 153, taughtFrom: "recorded")
            .contains("exports cannot be found now, so the cull learns from the 153 keepers recorded"))
        #expect(Strings.Finish.finished(3, from: "x", taught: 0, taughtFrom: "")
            .contains("nothing to learn from this shoot yet"))
        #expect(Strings.Finish.finished(368, from: "x", taught: nil, taughtFrom: "")
            == Strings.Finish.finished(368, from: "x"))
        #expect(Strings.Finish.learnsFrom(356, recorded: false) == "The cull learns only from the 356 you exported")
        #expect(Strings.Finish.keepRawsNote.contains("checked against all of them"))
        #expect(Strings.Finish.keepRawsNote.contains("learns only from the frames you exported"))

        let info = try ShootInfo(fields: Fields([
            "name": .string("2026-09-19"), "path": .string("/x/2026-09-19"),
            "recorded_keepers": .number(368), "taught": .number(356), "taught_from": .string("exported"),
        ]))
        #expect(info.recorded_keepers == 368 && info.taught == 356 && info.taught_from == "exported")
        #expect(info.extra["taught"] == nil, "a field the app reads is not left in extra")
    }

    /// It promised learning "the next time the Mac is idle" with automatic
    /// learning switched off in Settings, and said so again above the
    /// engine's own note that said the same. The line under it is written
    /// from what the engine did.
    @Test("the finished sentence promises no learning the engine did not start")
    func learningLine() throws {
        #expect(!Strings.Finish.finished(154, from: "").lowercased().contains("learn"))
        #expect(!Strings.Finish.finishedNoCount.lowercased().contains("learn"))
        // What it learns from, never when: the line under it says that.
        for (taught, from) in [(356, "exported"), (153, "recorded"), (0, "")] {
            let said = Strings.Finish.finished(368, from: "", taught: taught, taughtFrom: from).lowercased()
            #expect(!said.contains("idle") && !said.contains("next time"))
        }
        func answer(_ json: String) throws -> LearningStart { try Fixture.decodeJSON(LearningStart.self, json) }
        #expect(FinishStep.learningLine(try answer(#"{"ok": true, "running": false, "queued": false, "off": true}"#)) == nil)
        #expect(FinishStep.learningLine(try answer(#"{"ok": true, "running": true, "title": "Learning from 2026-09-19"}"#))
                == Strings.Finish.learningNow)
        let idle = "Learning from it starts once the Mac has been left alone for two minutes."
        #expect(FinishStep.learningLine(try answer(#"{"ok": true, "running": false, "queued": true, "note": "\#(idle)"}"#))
                == idle)
        #expect(FinishStep.learningLine(nil) == nil)
    }
}

// MARK: - the words

@Suite("What the steps say")
struct StepStringsTests {

    /// The sentence over the card page is there whatever he picks under
    /// Check the Copy, Don't check among them, which reads nothing back.
    @Test("the card page's sentence promises no check it may not make")
    func blurbPromisesNoCheck() {
        #expect(!Strings.Import.blurb.lowercased().contains("check"))
        #expect(Strings.Import.blurb.contains("Nothing on the card is changed."))
    }

    /// DESIGN.md §2.13's retired list, over every sentence this crew writes.
    @Test("no retired word is in anything a person reads here")
    func noRetiredWords() {
        let sentences: [String] = [
            Strings.Import.blurb, Strings.Import.check, Strings.Import.checkInFlightNote,
            Strings.Import.checkEndNote, Strings.Import.checkNoneNote, Strings.Import.nothingChanged,
            Strings.Cull.blurb, Strings.Cull.focus, Strings.Cull.focusNote, Strings.Cull.moving,
            Strings.Cull.movingNote, Strings.Cull.stacked(262, into: 0), Strings.Cull.looksAlike,
            Strings.Cull.setAside(863), Strings.Cull.faults(283), Strings.Cull.markedByHim(316, of: 1558),
            Strings.Cull.culledWith(focus: 1.9, moving: true),
            Strings.Cull.againTitle, Strings.Cull.againBody(14, 2, focus: 1.6, moving: true),
            Strings.Presets.blurb, Strings.Presets.willBeEdited(23), Strings.Presets.splitYours(14),
            Strings.Presets.splitAgreed(9), Strings.Presets.splitNotLookedThrough(3),
            Strings.Presets.alsoDropped, Strings.Presets.againTitle, Strings.Presets.againBody(4),
            Strings.Presets.ran(wrote: 285, changed: 83, already: 1), Strings.Presets.writtenFor,
            Strings.Presets.editorNote("dxo"), Strings.Presets.editorNote("lightroom"),
            Strings.Presets.editorNote("rawtherapee"), Strings.Presets.editorNote("darktable"),
            Strings.Edit.blurb(23, editor: "PhotoLab"), Strings.Edit.keepersWithPresets(23), Strings.Edit.folderOfThose,
            Strings.Edit.noPresetsYet(23), Strings.Edit.presetsBeingWritten(23), Strings.Edit.writeThenOpen,
            Strings.Edit.openWhenWritten, Strings.Edit.opensWhenWritten("PhotoLab"),
            Strings.Edit.presetsNotWritten("PhotoLab"),
            Strings.Finish.keepRawsNote, Strings.Finish.finished(154, from: ""), Strings.Finish.shrinkTitle,
            Strings.Finish.shrinkBody(154, 3, exportsGone: true), Strings.Finish.shrinkBody(154, 3, exportsGone: false),
            Strings.Finish.markFinished,
            Strings.Step.stoppedNote, Strings.Step.waitingFor("culling 2026-09-13-dog"),
        ]
        let retired = ["answer key", "bench", "taste", "./pl", "duplicate", "dupe",
                       "veto", "embedding", "auc", "held out", "weights", "probe", "venue"]
        for s in sentences {
            let lower = s.lowercased()
            for word in retired {
                #expect(!lower.contains(word), "\(s) contains \(word)")
            }
        }
    }

    /// The one control label the design leaves the engine's word in is the
    /// editor's own menu path, which is PhotoLab's and is spelled as PhotoLab
    /// spells it. Everywhere else a preset is a preset.
    @Test("a preset is called a preset")
    func presetsAreCalledPresets() {
        #expect(Strings.Presets.title == "Presets")
        #expect(Strings.Edit.keepersWithPresets(23).contains("preset"))
        #expect(!Strings.Presets.write.lowercased().contains("sidecar"))
        #expect(!Strings.Presets.alsoDropped.lowercased().contains("sidecar"))
    }

    /// What the last run did, never what is lying on the disk: a run that
    /// skipped every frame printed "12 presets written onto 368 files".
    @Test("the presets line says what the run did")
    func presetsRan() throws {
        #expect(Strings.Presets.ran(wrote: 285, changed: 83, already: 0)
            == "Wrote a preset onto 285 frames · 83 you had changed in your editor kept your edit.")
        #expect(Strings.Presets.ran(wrote: 0, changed: 0, already: 368) == "Wrote a preset onto 0 frames · 368 already had one.")
        #expect(!Strings.Presets.againBody(4).contains("unless you say otherwise"))
        // Written again, his frames get the new preset too, with his changes on top.
        #expect(Strings.Presets.ran(wrote: 368, changed: 0, already: 0, under: 14)
            == "Wrote a preset onto 368 frames · on the 14 you had changed, your changes stay on top.")
        #expect(Strings.Presets.againBody(14).hasPrefix("Every frame gets its preset written again."))
        #expect(Strings.Presets.againBody(14).contains("14 you have changed"))
        #expect(Strings.Presets.estimate(1) == "About a minute.")
        #expect(Strings.Presets.estimate(2) == "About 2 minutes.")
        // Once written, Return opens the keepers in the editor they are for;
        // writing them again is the toolbar's, and asks first.
        #expect(PresetsStep.primaryWord(written: false, editor: "dxo") == "Write the Presets")
        #expect(PresetsStep.primaryWord(written: true, editor: "dxo") == "Open My Keepers in PhotoLab")
        #expect(PresetsStep.primaryWord(written: true, editor: "lightroom") == "Open My Keepers in Lightroom Classic")
        #expect(Strings.Presets.again.hasSuffix("…"))
        let ran = try Fixture.decodeJSON(PresetsRan.self, #"{"wrote": 5, "changed": 2, "already": 39}"#)
        #expect(ran.wrote == 5 && ran.changed == 2 && ran.already == 39 && ran.under == 0)
        let again = try Fixture.decodeJSON(PresetsRan.self, #"{"wrote": 368, "changed": 0, "already": 0, "under": 14}"#)
        #expect(again.under == 14)
    }

    /// Exports in export/ and edit/edited showed two rows both called "Where
    /// they are", with the path cut where the two differ.
    @Test("each export folder is named for where it is in the shoot")
    func exportFolderLabels() {
        let shoot = "/x/shoots/2026-09-19"
        #expect(StepPathRow.exportLabel(shoot + "/export", shoot: shoot, among: 1) == Strings.Finish.whereTheyAre)
        #expect(StepPathRow.exportLabel(shoot + "/export", shoot: shoot, among: 2) == "In export")
        #expect(StepPathRow.exportLabel(shoot + "/edit/edited", shoot: shoot, among: 2) == "In edit › edited")
        #expect(StepPathRow.exportLabel("/elsewhere/done", shoot: shoot, among: 2) == "In done")
    }

    @Test("the slider's live words are the engine's own five, one or two words each")
    func focusWords() {
        #expect(Strings.Cull.focusWord(1.2) == "lenient")
        #expect(Strings.Cull.focusWord(1.7) == "a little lenient")
        #expect(Strings.Cull.focusWord(1.9) == "normal")
        #expect(Strings.Cull.focusWord(2.2) == "a little strict")
        #expect(Strings.Cull.focusWord(3.0) == "strict")
        // The word is the word for the number printed beside it, which is
        // the knob's position to one decimal.
        #expect(Strings.Cull.focusWord(1.54) == Strings.Cull.focusWord(1.5))
        #expect(Strings.Cull.focusWord(1.83) == Strings.Cull.focusWord(1.8))
    }

    @Test("the settings are held still, and say why, while his cull runs or waits")
    @MainActor func settingsHeld() {
        #expect(CullStep.settingsNote(.idle) == nil)
        #expect(CullStep.settingsNote(.starting) == Strings.Cull.settingsStarting)
        let job = Job(running: true, stopped: false, kind: "cull", fraction: 0.3, elapsed: 9)
        #expect(CullStep.settingsNote(.running(job)) == Strings.Cull.settingsInUse)
        #expect(CullStep.settingsNote(.stopping) == Strings.Cull.settingsInUse)
        #expect(CullStep.settingsNote(.listed(2)) == Strings.Cull.settingsWaiting)
        #expect(CullStep.settingsNote(.queued) == Strings.Cull.settingsWaiting)
    }

    @Test("the cull-again sheet says what it will run with, and a minute is a minute")
    func againSheet() {
        let one = Strings.Cull.againBody(14, 1, focus: 1.6, moving: true)
        #expect(!one.contains("1 minutes"))
        #expect(one.hasSuffix(Strings.Cull.estimate(1)))
        #expect(one.contains("focus 1.6 (a little lenient), for people moving between frames"))
        let seven = Strings.Cull.againBody(368, 7, focus: 1.9, moving: false)
        #expect(seven.contains("Your 368 keepers"))
        #expect(seven.contains("focus 1.9 (normal)."))
        #expect(seven.hasSuffix("About 7 minutes."))
        // The report names a finished run's settings in the same words.
        #expect(Strings.Cull.culledWith(focus: 1.9, moving: false) == "Culled with focus 1.9 (normal).")
    }

    /// The knob follows the hand; the cull is sent, and the page prints, the
    /// value to one decimal.
    @Test("what the slider sends is its value to one decimal")
    func focusRounds() {
        #expect(StepsModel.roundFocus(1.9000000000000001) == 1.9)
        #expect(StepsModel.roundFocus(1.93) == 1.9)
        #expect(StepsModel.roundFocus(1.96) == 2.0)
        #expect(StepsModel.roundFocus(1.2) == 1.2)
        #expect(StepsModel.roundFocus(3.0) == 3.0)
    }
}

// MARK: - reading a captured answer, with a field or two moved

/// The captured answer, changed where a test needs a shape the capture did not
/// have — a shoot with the two-authored counts on it, or a frame he has since
/// marked. It goes through JSON rather than through the model, because the
/// model's own fields are set by the engine and by `ShootSession` and by
/// nothing else, and a test that could reach past that would be testing a door
/// the app does not have.
enum PatchedFixture {
    static func shoot(_ name: String, patchInfo: [String: Any] = [:],
                      overrides: [String: Int] = [:]) throws -> ShootResponse {
        var object = try #require(try JSONSerialization.jsonObject(with: Fixture.data(name)) as? [String: Any])
        if var info = object["info"] as? [String: Any] {
            for (k, v) in patchInfo { info[k] = v }
            object["info"] = info
        }
        if !overrides.isEmpty, var rows = object["rows"] as? [[String: Any]] {
            for i in rows.indices {
                let stem = (rows[i]["stem"] as? String) ?? ""
                if let v = overrides[stem] { rows[i]["override"] = v }
                else if overrides["*"] != nil { rows[i]["override"] = overrides["*"] }
            }
            object["rows"] = rows
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(ShootResponse.self, from: data)
    }
}

// MARK: - a double-click on the primary

@Suite("The progress box and a double-click")
struct DoubleClickTests {

    /// The box changes from the button he pressed to the progress with Stop
    /// in it one request later, which is well inside a double-click.
    @Test("Stop and × ignore the second click of the press that made them")
    func settles() {
        let shown = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(!StepMetric.takesPress(since: shown, now: shown))
        #expect(!StepMetric.takesPress(since: shown, now: shown.addingTimeInterval(0.25)))
        #expect(!StepMetric.takesPress(since: shown, now: shown.addingTimeInterval(0.79)))
        #expect(StepMetric.takesPress(since: shown, now: shown.addingTimeInterval(0.81)))
        // A box that has shown the job since he arrived is pressable at once.
        #expect(StepMetric.takesPress(since: .distantPast))
        // Longer than the Mac's own double-click interval, whatever he set it to
        // in Settings short of the slowest.
        #expect(StepMetric.settle >= 0.5)
    }

    @Test("the box tells what it holds apart from a job moving on")
    func shape() {
        let a = Job(running: true, stopped: false, kind: "cull", fraction: 0.1, elapsed: 3)
        let b = Job(running: true, stopped: false, kind: "cull", fraction: 0.4, elapsed: 30)
        #expect(StepJobPhase.running(a).shape == StepJobPhase.running(b).shape)
        #expect(StepJobPhase.idle.shape != StepJobPhase.running(a).shape)
        #expect(StepJobPhase.queued.shape != StepJobPhase.idle.shape)
        #expect(StepJobPhase.stopping.shape != StepJobPhase.running(a).shape)
        // Starting to running is a change of what the box holds, so Stop
        // still ignores the click that is left of the press that started it.
        #expect(StepJobPhase.starting.shape != StepJobPhase.running(a).shape)
        #expect(StepJobPhase.starting.shape != StepJobPhase.idle.shape)
    }
}

// MARK: - how often an open step page looks at the job

@Suite("A step page's watcher at rest")
struct WatchIntervalTests {

    /// The launch read of the job leaves the last one in place for good, so
    /// a watcher that asked "is there a job" woke twice a second for as long
    /// as Cull, Presets or Reels was open, with nothing to watch.
    @Test("quick only while a job is running, and at rest for one that has ended")
    func interval() {
        let running = Job(running: true, stopped: false, kind: "cull", fraction: 0.4, elapsed: 30)
        let ended = Job(running: false, stopped: false, kind: "cull", code: 0)
        #expect(StepsModel.watchInterval(running) == .milliseconds(500))
        #expect(StepsModel.watchInterval(ended) == .seconds(2))
        #expect(StepsModel.watchInterval(nil) == .seconds(2))
    }
}
