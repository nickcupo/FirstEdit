import Foundation
import Testing
@testable import PipelineKit

/// §2.8 — what the panel draws, and the plan → token → apply round trip.
@Suite("Storage, and the three-rung ladder")
struct StorageTests {

    @Test("every state the engine can report has a glyph pair, a count and the engine's own sentence")
    func everyStateDraws() throws {
        for name in ["storage-both", "storage-icloud-only", "storage-mixed"] {
            let s = try StorageFixture.decode(Storage.self, name)
            #expect(!s.line.isEmpty, "\(name) has no line")
            for state in s.presentStates {
                let cells = try #require(s.glyphs[state], "\(name)/\(state) has no glyphs")
                #expect(cells.count == 2, "the pair is always this Mac then iCloud")
                #expect(s.words[state]?.isEmpty == false, "\(name)/\(state) has no sentence")
                #expect((s.states[state] ?? 0) > 0)
            }
        }
    }

    @Test("the four states the panel is drawn in are the four the engine produced")
    func fourStates() throws {
        let here = try Fixture.decode(Storage.self, "storage")
        #expect(here.presentStates == ["here_only"])
        #expect(here.line.contains("one copy"))

        let both = try StorageFixture.decode(Storage.self, "storage-both")
        #expect(both.presentStates == ["both"])
        #expect(both.states["both"] == 54)
        #expect(both.glyphs["both"] == [.full, .full])

        let up = try StorageFixture.decode(Storage.self, "storage-icloud-only")
        #expect(up.presentStates == ["icloud_only"])
        #expect(up.glyphs["icloud_only"] == [.none, .full])
        #expect(up.archive.here == 0 && up.archive.up == 54)

        let bad = try StorageFixture.decode(Storage.self, "storage-mixed")
        #expect(bad.presentStates == ["icloud_only", "missing"])
        #expect(bad.states["missing"] == 5)
        #expect(bad.glyphs["missing"] == [.none, .gone])
        #expect(bad.archive.lost == 5)
    }

    @Test("the panel shows the states in the engine's order and never sorts them itself")
    func theEnginesOrder() throws {
        let s = try StorageFixture.decode(Storage.self, "storage-mixed")
        // `both` comes before `missing` in the engine's own order, and
        // `presentStates` never re-sorts by count, name or anything else.
        #expect(s.order.firstIndex(of: "icloud_only")! < s.order.firstIndex(of: "missing")!)
        #expect(s.presentStates == s.order.filter { (s.states[$0] ?? 0) > 0 })
    }

    @Test("a plan the engine drew: its label, its counts and its list are its own")
    func aPlanIsTheEngines() throws {
        let drop = try StorageFixture.decode(Plan.self, "plan-drop")
        #expect(drop.what == "drop")
        #expect(drop.counts["frames"] == 54)
        #expect(drop.label == "Remove 54 originals and free 1.3 GB")
        #expect(drop.ready && drop.isApplicable)
        #expect(drop.token?.count == 64)
        #expect(drop.lines.contains { $0.contains("54 frames verified in iCloud") })

        let reclaim = try StorageFixture.decode(Plan.self, "plan-reclaim")
        #expect(reclaim.label.hasPrefix("Take back "))
        #expect(reclaim.counts["files"] == 14)
    }

    @Test("expire: the frames with no other copy are not in it until the box is ticked")
    func expireIsTwoPlans() throws {
        let unticked = try StorageFixture.decode(Plan.self, "plan-expire")
        #expect(unticked.doomed == 0, "nothing ceases to exist until the box is ticked")
        #expect(!unticked.ready, "and there is nothing to apply")
        #expect(unticked.protectedKeepers == 14)

        let ticked = try StorageFixture.decode(Plan.self, "plan-expire-originals")
        #expect(ticked.doomed == 40)
        #expect(ticked.label == "Destroy 40 photographs")
        #expect(ticked.protectedKeepers == 14, "his keepers are protected in both")
        #expect(ticked.ready && ticked.isApplicable)
        #expect(!ticked.names.isEmpty, "the doomed names are the engine's own")
    }

    @Test("the button that deletes photographs opens only on the typed number")
    func theTypedNumber() throws {
        let plan = try StorageFixture.decode(Plan.self, "plan-expire-originals")
        func gate(_ typed: String, current: Bool = true, busy: Bool = false) -> ExpireGate {
            ExpireGate(plan: plan, listIsCurrent: current, typed: typed, busy: busy)
        }
        #expect(!gate("").isOpen)
        #expect(!gate("4").isOpen)
        #expect(!gate("400").isOpen)
        #expect(!gate("39").isOpen)
        #expect(gate("40").isOpen)
        #expect(gate(" 40 ").isOpen, "a stray space is not a different number")
        #expect(!gate("40", current: false).isOpen, "a list that is not this list never opens it")
        #expect(!gate("40", busy: true).isOpen, "and never twice at once")
        #expect(gate("40").confirmLabel == "Destroy 40 photographs")
        #expect(gate("40").isAnAction, "the engine's label is an action, and is drawn in red")
        // And a list with nothing in it is a sentence, not a warning.
        #expect(!ExpireGate(plan: nil, listIsCurrent: true, typed: "").isAnAction)
    }

    @Test("the keepers-protected count is the one the list was drawn against")
    func protectedIsFrozen() throws {
        let unticked = try StorageFixture.decode(Plan.self, "plan-expire")
        let ticked = try StorageFixture.decode(Plan.self, "plan-expire-originals")
        // Ticking the box was once measured to drop this to zero while the
        // label still claimed it. Each list carries its own, and the gate
        // reads it off the list it is gating.
        #expect(ExpireGate(plan: unticked, listIsCurrent: true, typed: "").protectedKeepers == 14)
        #expect(ExpireGate(plan: ticked, listIsCurrent: true, typed: "").protectedKeepers == 14)
    }

    @Test("a plan with no token and a plan that refused can never be applied")
    func noTokenNoApply() throws {
        let undrawn = try Fixture.decode(Plan.self, "storage-plan-undrawn")
        #expect(undrawn.token == nil)
        #expect(!undrawn.isApplicable)
        #expect(undrawn.error?.isEmpty == false)
        #expect(!ExpireGate(plan: undrawn, listIsCurrent: true, typed: "").isOpen)

        let refused = try Fixture.decode(Plan.self, "storage-plan-drop")
        #expect(!refused.ready)
        #expect(!refused.isApplicable, "a token on a list with nothing in it is still not a licence")
    }

    @Test("GET /api/storage/frames, in the state where half of them are gone")
    func frames() throws {
        let f = try StorageFixture.decode(StorageFrames.self, "storage-frames-icloud")
        #expect(f.rows.count == 54)
        #expect(f.rows.allSatisfy { $0.cells.count == 2 })
        #expect(f.rows.contains { $0.state == "icloud_only" })
        #expect(f.rows.allSatisfy { !$0.words.isEmpty })
    }

    @Test("the library-wide page says only what the engine said")
    func libraryLine() throws {
        let l = try StorageFixture.decode(LibraryLine.self, "storage-library")
        #expect(l.root == "/scratch/photos")
        #expect(l.free_text.hasSuffix("B"))
        #expect(l.reclaimable_text.hasSuffix("B"))
    }

    @Test("no fixture of this crew's carries a home folder into a public repository")
    func noHomeFolders() throws {
        for name in StorageFixture.names {
            let text = String(decoding: try StorageFixture.data(name), as: UTF8.self)
            #expect(!text.contains("/Users/"), "\(name) holds a home folder")
            #expect(!text.contains(NSHomeDirectory()), "\(name) holds this machine's home")
        }
    }
}

/// A button that can do nothing on this shoot is off, and says why, from the
/// engine's own counts — rather than starting a dry run to come back with
/// "has no archive manifest".
@Suite("A storage button that can do nothing says why")
struct StorageActionGateTests {

    @Test("a finished shoot that was never archived: only the copy up and the cache are live")
    func neverArchived() throws {
        // The engine's answer for a shoot on this Mac only, made finished.
        var json = try JSONSerialization.jsonObject(with: Fixture.data("storage")) as! [String: Any]
        var retain = json["retain"] as! [String: Any]
        retain["finished"] = "2026-09-22"; retain["age_days"] = 1; retain["due_in_days"] = 364
        json["retain"] = retain
        let s = try JSONDecoder().decode(Storage.self, from: JSONSerialization.data(withJSONObject: json))
        let g = StorageActionGate(storage: s)
        #expect(g.reason(.push) == nil)
        #expect(g.size(.push) == s.archive.todo_text, "the engine's own figure for what would go up")
        #expect(g.reason(.pull) == Strings.Storage.nothingInICloud)
        #expect(g.reason(.drop) == Strings.Storage.dropNothingUp)
        #expect(g.reason(.expire) == Strings.Storage.nothingInICloud)
        #expect(g.reason(.reclaim) == nil)
        #expect(g.size(.pull).isEmpty, "a button that is off carries no figure")
    }

    @Test("a shoot not finished yet is copied up the same night; its local RAWs stay until Finish")
    func notFinished() throws {
        let s = try Fixture.decode(Storage.self, "storage")
        #expect(!s.retain.finished)
        #expect(StorageActionGate(storage: s).reason(.push) == nil)
        #expect(StorageActionGate(storage: s).size(.push) == s.archive.todo_text)
        // Once every frame is up and checked, as after that copy, Remove the
        // Local RAWs still says why it waits.
        var json = try JSONSerialization.jsonObject(with: StorageFixture.data("storage-both")) as! [String: Any]
        var retain = json["retain"] as! [String: Any]
        retain["finished"] = ""
        json["retain"] = retain
        let up = try JSONDecoder().decode(Storage.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!up.retain.finished)
        #expect(StorageActionGate(storage: up).reason(.drop) == Strings.Storage.dropNotFinished)
        #expect(StorageActionGate(storage: up).size(.drop).isEmpty)
    }

    @Test("two copies of every frame: nothing to copy up or bring back; the local copy can go")
    func bothCopies() throws {
        let g = StorageActionGate(storage: try StorageFixture.decode(Storage.self, "storage-both"))
        #expect(g.reason(.push) == Strings.Storage.pushNothing)
        #expect(g.reason(.pull) == Strings.Storage.pullNothing)
        #expect(g.reason(.drop) == nil)
        #expect(g.reason(.expire) == Strings.Storage.expireNotDue(365),
                "the retention lock has not run out, and the reason names how long is left")
    }

    @Test("in iCloud only: it can be brought back, and its cache taken back, since iCloud holds every original")
    func iCloudOnly() throws {
        let g = StorageActionGate(storage: try StorageFixture.decode(Storage.self, "storage-icloud-only"))
        #expect(g.reason(.pull) == nil)
        #expect(g.reason(.drop) == Strings.Storage.dropNothingHere)
        // The engine does not refuse an archived shoot's cache
        // (tests/test_reclaim.py): every frame it was made from is in iCloud.
        #expect(g.reason(.reclaim) == nil)
    }

    @Test("with frames found nowhere, the cache refuses for the engine's reason, which counts only those")
    func missingRefusesTheCache() throws {
        let s = try StorageFixture.decode(Storage.self, "storage-mixed")
        #expect(StorageActionGate(storage: s).reason(.reclaim) == Strings.Storage.reclaimRefused)
        #expect(s.cache.refusals == ["5 of 54 culled frames have no original on this Mac or in iCloud "
                                     + "(TSC04313, TSC04314, TSC04315, TSC04316, ...): "
                                     + "the cache holds the only copy of those frames"],
                "not 54 of 54 and 'none can be found' under a line counting 1.1 GB in iCloud")
    }
}

/// The sheet shows the command's own list, which the engine sends without
/// the one line it says to a typist (`plan_words`, tested in
/// tests/test_studio_api.py): there is no --apply for him to add in an app
/// with a button.
@Suite("The plan sheet speaks to him, not to a terminal")
struct PlanWordsTests {

    @Test("the captured plans carry no line to a terminal")
    func noApplyHint() throws {
        for name in StorageFixture.names where name.hasPrefix("plan-") {
            let plan = try StorageFixture.decode(Plan.self, name)
            #expect(!plan.lines.contains { $0.contains("Add --apply") }, "\(name)")
        }
    }

    @Test("the title says what the list is of: a copy up goes nowhere")
    func titles() {
        #expect(Strings.Storage.planTitle(for: "push") != Strings.Storage.planTitle(for: "drop"))
        #expect(Strings.Storage.planTitle(for: "pull") != Strings.Storage.planTitle(for: "drop"))
        #expect(!Strings.Storage.planTitle(for: "push").contains("go"))
        #expect(Strings.Storage.planTitle(for: "reclaim") == Strings.Storage.planTitle(for: "expire"))
    }
}

/// The library pages scroll across the whole pane; only their rows are held
/// to the column.
@Suite("The library pages scroll wherever the pointer is")
struct ColumnFormTests {

    @Test("the margins centre the 680 pt column, and vanish where the pane is narrower")
    func margins() {
        #expect(ColumnForm.margin(in: 900) == 110)
        #expect(ColumnForm.margin(in: 1920) == 620)
        #expect(ColumnForm.margin(in: 600) == 0)
    }

    @Test("no library page narrows its Form, and so its scroll view, to the column")
    func noNarrowForm() throws {
        for name in ["LearnedView.swift", "LibraryStorage.swift"] {
            let text = try #require(SafetyTests.sources.first { $0.name == name }?.text)
            #expect(text.contains(".columnForm()"), "\(name) holds its column with content margins")
            #expect(!text.contains(".frame(maxWidth: Tokens.Metric.column)"), "\(name) narrows its scroll view")
        }
    }

    @Test("the storage panel, which Finish's own scroll view holds, never measures the pane it is in")
    func panelSizesToItsRows() throws {
        // Inside a scroll view a geometry reader has no height of its own,
        // and the panel under it came out a 10 pt sliver on Finish.
        let text = try #require(SafetyTests.sources.first { $0.name == "StoragePanel.swift" }?.text)
        #expect(!text.contains(".columnForm()"))
        #expect(!text.contains("GeometryReader"))
    }
}

/// "Use this for new shoots too" starts from what the engine says new shoots
/// are given, instead of unticked on every visit.
@Suite("The retention default is read, not forgotten")
struct RetentionDefaultTests {

    private func retain(_ extra: [String: Any]) throws -> Retain {
        var json = try JSONSerialization.jsonObject(with: Fixture.data("storage")) as! [String: Any]
        var r = json["retain"] as! [String: Any]
        for (k, v) in extra { r[k] = v }
        json["retain"] = r
        return try JSONDecoder().decode(Storage.self, from: JSONSerialization.data(withJSONObject: json)).retain
    }

    @Test("ticked when this shoot's number is the library's")
    func sameNumber() throws {
        #expect(try retain(["days": 90, "source": "shoot", "library_days": 90]).isLibraryDefault)
        #expect(try !retain(["days": 30, "source": "shoot", "library_days": 90]).isLibraryDefault)
        #expect(try !retain(["days": 365, "source": "default", "library_days": NSNull()]).isLibraryDefault)
    }

    @Test("an engine that does not send the library's number: only a shoot taking it is known to")
    func olderEngine() throws {
        #expect(try retain(["source": "library"]).isLibraryDefault)
        #expect(try !retain(["source": "shoot"]).isLibraryDefault)
    }
}

/// The figure beside Take Back the Cache is the one it takes.
@Suite("The cache has one name and one figure")
struct CacheWordsTests {

    @Test("the panel's row is the engine's figure for what the button would take")
    func sameFigure() throws {
        let panel = try #require(SafetyTests.sources.first { $0.name == "StoragePanel.swift" }?.text)
        #expect(panel.contains("LabeledContent(Strings.Storage.canTakeBackNow) { Text(c.bytes_text)"))
        #expect(!panel.contains("rebuildable_text"), "a figure the button does not take is not beside it")
        let s = try Fixture.decode(Storage.self, "storage")
        #expect(StorageActionGate(storage: s).size(.reclaim) == s.cache.bytes_text
                || s.cache.bytes_text == "0 B")
    }

    @Test("the one noun is cache, on the heading, the row, the library page and the reasons")
    func oneNoun() {
        for label in [Strings.Storage.cacheHeading, Strings.Storage.reclaimable,
                      Strings.Storage.cacheRefusedHeading, Strings.Storage.reclaim] {
            #expect(label.lowercased().contains("cache"), "\(label)")
            #expect(!label.contains("Rendering") && !label.contains("derived"), "\(label)")
        }
    }
}

/// A frame found nowhere is an alarm with a next step, said once.
@Suite("A missing frame says what to press next")
struct MissingFrameTests {

    @Test("the footnote names the button that is on the panel, by the name it has there")
    func namesTheButton() {
        #expect(Strings.Storage.missingNext.hasPrefix(Strings.Storage.check))
    }

    @Test("the engine's words for it are not shouted beside the red glyph that already is the alarm")
    func notShouted() throws {
        let s = try StorageFixture.decode(Storage.self, "storage-mixed")
        let words = try #require(s.words["missing"])
        #expect(!words.contains("NOT FOUND"))
    }
}

/// One name for each place, on the panel and in Shoot ▸ Storage.
@Suite("The storage actions have one name each")
struct StorageNameTests {

    @Test("the panel and the menu call each action the same, and the rung that deletes names iCloud")
    func oneName() {
        #expect(Strings.Storage.push == Words.Shoot.copyUp)
        #expect(Strings.Storage.pull == Words.Shoot.bringBack)
        #expect(Strings.Storage.reclaim == Words.Shoot.takeBackCache)
        #expect(Strings.Storage.drop == Words.Shoot.removeLocal)
        #expect(Strings.Storage.expire == Words.Shoot.letGo)
        #expect(Strings.Storage.expire.contains("iCloud") && !Strings.Storage.expire.contains("Archived"))
        // The lock's footnote names the button it governs by that name.
        #expect(Strings.Storage.retentionIsALock.contains(Strings.Storage.expire))
    }
}
