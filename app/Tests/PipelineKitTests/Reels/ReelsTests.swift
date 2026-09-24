import AppKit
import Foundation
import Testing
@testable import PipelineKit

/// The Reels step (DESIGN.md §2.6): what the lister really sends about one
/// burst, what the step sends back, and the three behaviours that are easy to
/// lose — a click toggles and a double-click opens, a burst not exported
/// whole is called a draft, and the wait on PhotoLab does not cut from the
/// frames that were already there.
@Suite("Reels")
struct ReelsTests {

    // MARK: - what the lister sends

    @Test("GET /api/reel/options about one burst lists every frame of it")
    func decodesOneBurst() throws {
        let o = try Fixture.decode(ReelOptions.self, "reel-options-burst")
        #expect(o.cuts.count == 203 && o.sequences.count == 203)
        #expect(o.frames.count == 13)
        let first = try #require(o.frames.first)
        #expect(first.stem == "TSC06264")
        #expect(!first.exported)
        #expect(first.visible)
        #expect(first.rating == 2)
        #expect(o.frames.filter(\.exported).count == 3)
        let b93 = try #require(o.cuts.first { $0.burst == "93" })
        #expect(b93.frames == 13 && b93.exported == 3)
        #expect(b93.lands_on == "TSC06272")
        #expect(o.reels.map(\.name).contains("2026-09-19-loop41.mp4"))
        #expect(o.sources.count == 4)
        // The names filed in his shoot never reach a public fixture.
        #expect(o.tags?.map(\.name).allSatisfy { $0.hasPrefix("name ") } == true)
        #expect(!o.reel_dir.contains("/Users/"))
        // No engine sends further things for the crop to follow yet.
        #expect(o.follow.isEmpty)
    }

    @Test("the watch about the same burst counts the same three exports the lister does")
    func watchAboutOneBurst() throws {
        let w = try Fixture.decode(ReelWatch.self, "reel-watch-burst")
        #expect(w.burst == "93" && w.jpegs == 3)
        #expect(try burst93().frames.filter(\.exported).count == w.jpegs)
    }

    @Test("a further thing to follow sent without an id is left out, not the whole answer")
    @MainActor func badFollowIsSkipped() throws {
        let o = try Fixture.decodeJSON(ReelOptions.self, """
            {"sequences": [], "cuts": [], "frames": [], "sources": [], "exports_found": 0,
             "exports_dir": "", "reels": [], "reel_dir": "", "source": "raw",
             "follow": [{"label": "no id"}, {"id": "thing", "label": "The thing"}]}
            """)
        #expect(o.follow.map(\.id) == ["thing"])
    }

    @Test("a frame from an older lister, with no `visible`, can still be shown")
    func olderFrame() throws {
        let f = try Fixture.decodeJSON(ReelFrame.self, #"{"stem": "TSC1", "exported": true}"#)
        #expect(f.visible && f.exported && f.rating == nil)
    }

    @Test("whatever else the crop can follow is the extension's, and comes after the three")
    @MainActor func followFromTheExtension() throws {
        let o = try Fixture.decodeJSON(ReelOptions.self, """
            {"sequences": [], "cuts": [], "frames": [], "sources": [], "exports_found": 0,
             "exports_dir": "", "reels": [], "reel_dir": "", "source": "raw",
             "follow": [{"id": "thing", "label": "The thing"}, {"id": "people", "label": "dup"}]}
            """)
        let m = model()
        m.preview(o, burst: nil)
        #expect(m.followChoices.map(\.id) == ["action", "people", "none", "thing"])
        #expect(m.followChoices.last?.label == "The thing")
    }

    // MARK: - the list

    @Test("by number is numeric order, best first is the lister's own order")
    func order() throws {
        let o = try Fixture.decode(ReelOptions.self, "reel-options-burst")
        let byNumber = ReelsModel.ordered(o.cuts, by: .number).map(\.burst)
        #expect(byNumber.prefix(3).allSatisfy { Int($0) != nil })
        #expect(byNumber == byNumber.sorted { Int($0)! < Int($1)! })
        #expect(ReelsModel.ordered(o.cuts, by: .best).map(\.burst) == o.cuts.map(\.burst))
        #expect(ReelsModel.matching(o.cuts, " 93 ").map(\.burst).contains("93"))
        #expect(ReelsModel.matching(o.cuts, "").count == o.cuts.count)
    }

    // MARK: - choosing frames

    @Test("a click takes a frame out and puts it back; a frame with no picture cannot go in")
    @MainActor func toggling() throws {
        let m = model()
        m.preview(try burst93(), burst: "93")
        #expect(m.chosen.count == 13 && m.usable.count == 13)
        m.toggle("TSC06264")
        #expect(!m.isIn("TSC06264") && m.chosen.count == 12)
        m.toggle("TSC06264")
        #expect(m.isIn("TSC06264") && m.chosen.count == 13)
        m.toggle("NOT-A-FRAME")
        #expect(m.chosen.count == 13)
    }

    @Test("under three frames there is nothing to cut, and the page says why")
    @MainActor func tooFew() throws {
        let m = model()
        m.preview(try burst93(), burst: "93")
        #expect(m.canCut && m.whyNot == nil)
        for s in m.frames.map(\.stem).dropFirst(2) { m.toggle(s) }
        #expect(!m.canCut)
        #expect(m.whyNot == Strings.Reels.needThree)
    }

    @Test("a burst not exported whole is a draft, whichever frames are ticked")
    @MainActor func draft() throws {
        let m = model()
        m.preview(try burst93(), burst: "93")
        #expect(m.isDraft)
        for f in m.frames where !f.exported { m.toggle(f.stem) }
        #expect(m.chosen.count == 3)
        #expect(m.isDraft)          // the engine decides over the whole burst
    }

    @Test("the burst survives a change of format, and so do the frames he took out")
    @MainActor func formatKeepsTheBurst() throws {
        let m = model()
        m.preview(try burst93(), burst: "93")
        m.toggle("TSC06265")
        m.choose(format: .loop)
        #expect(m.burst == "93" && !m.isIn("TSC06265"))
        m.choose(format: .timelapse)
        #expect(m.follow == ReelFollowBase.people && m.speed == 12)
        m.choose(format: .cut)
        #expect(m.follow == ReelFollowBase.action && m.speed == 8)
    }

    @Test("Space and a double-click open the frames there is a picture of, from the one asked")
    @MainActor func openLarge() throws {
        let m = model()
        m.preview(try burst93(), burst: "93")
        m.openLarge("TSC06266")
        #expect(m.look?.start == 2)
        #expect(m.look?.stems.count == 13)
        m.moveCursor(by: 1)
        #expect(m.cursor == "TSC06267")
        m.moveCursor(by: -100)
        #expect(m.cursor == "TSC06264")
    }

    @Test("D leaves the frame the keys are on out and moves on, E puts one in and moves on, X puts one back and stays — the first frame before the keys are on any")
    @MainActor func keysMark() throws {
        let m = model()
        m.preview(try burst93(), burst: "93")
        #expect(m.key(.init("d")))
        #expect(!m.isIn("TSC06264") && m.cursor == "TSC06265")
        #expect(m.key(.init("d")))
        #expect(!m.isIn("TSC06265") && m.cursor == "TSC06266")
        // S goes back, as ← does; E puts it in and goes on.
        #expect(m.key(.init("s")))
        #expect(m.cursor == "TSC06265")
        #expect(m.key(.init("e")))
        #expect(m.isIn("TSC06265") && m.cursor == "TSC06266")
        // X is back as it started, which on a reel is in, and the keys stay.
        m.moveCursor(by: -2)
        #expect(m.key(.init("x")))
        #expect(m.isIn("TSC06264") && m.cursor == "TSC06264")
        // A held D leaves one frame out.
        #expect(m.key(.init("d")))
        #expect(m.key(.init("d", isARepeat: true)))
        #expect(!m.isIn("TSC06264") && m.isIn("TSC06265") && m.cursor == "TSC06265")
        let empty = model()
        #expect(!empty.mark(.leaveOut))
    }

    @Test("Q takes back the last change on its frame, ⇧⌘Z does it again, and Edit ▸ Undo names it")
    @MainActor func undoOnReels() throws {
        let m = model()
        m.preview(try burst93(), burst: "93")
        #expect(!m.canUndo && m.undoName == nil)
        m.key(.init("d"))
        m.key(.init("d"))
        #expect(m.undoName == Words.Edit.undoNamed(Strings.Reels.leaveOutNamed("06265")))
        #expect(m.key(.init("q")))
        #expect(m.isIn("TSC06265") && !m.isIn("TSC06264") && m.cursor == "TSC06265")
        #expect(m.key(.init("u")))
        #expect(m.isIn("TSC06264") && m.cursor == "TSC06264")
        #expect(!m.canUndo)
        #expect(m.key(.init("z", command: true, shift: true)))
        #expect(!m.isIn("TSC06264"))
        // Put Them All Back is one change, and one Q takes it back.
        m.putAllBack()
        #expect(m.isIn("TSC06264"))
        m.undo()
        #expect(!m.isIn("TSC06264"))
        // A change that changed nothing is not kept.
        let depth = m.undoStack.count
        m.leaveAllOut()
        m.leaveAllOut()
        #expect(m.undoStack.count == depth + 1)
        // A new change lets the redo go.
        m.undo()
        #expect(m.canRedo)
        m.key(.init("e"))
        #expect(!m.canRedo)
    }

    @Test("R and W walk the bursts as N and P do, Esc is taken and does nothing, and Keepers' own keys are not the page's")
    @MainActor func burstsAndTheRest() throws {
        let m = model()
        m.preview(try burst93(), burst: "93")
        let list = m.shownBursts.map(\.burst)
        let i = try #require(list.firstIndex(of: "93"))
        #expect(m.key(.init("r")))
        #expect(m.burst == list[i + 1])
        #expect(m.key(.init("w")))
        #expect(m.burst == "93")
        #expect(m.key(.init(key: .escape)))
        #expect(m.burst == "93")
        for k in ["c", "g", "z", "1", "h"] { #expect(!m.key(.init(k)), "\(k) is not the page's") }
        #expect(!m.key(.init(key: .return)), "Return is Cut It's")
    }

    // MARK: - what is sent

    @Test("the body carries only the names `_b_reel` reads, and only when they mean something")
    func request() {
        let all = ["a", "b", "c", "d"]
        let whole = ReelsModel.request(format: .cut, burst: "93", tag: "", chosen: all, usable: all,
                                       speed: 8, follow: "action", size: .w1080, ramp: true, source: "")
        #expect(whole["format"] == .string("cut"))
        #expect(whole["burst"] == .string("93"))
        #expect(whole["fps"] == .integer(8))
        #expect(whole["ramp"] == .bool(true))
        #expect(whole["frames"] == nil)          // every frame is what it takes untold
        #expect(whole["exports"] == nil)
        #expect(whole["name"] == nil)            // added by whoever sends it

        let some = ReelsModel.request(format: .sequence, burst: "93", tag: "", chosen: ["a", "c", "d"],
                                      usable: all, speed: 10, follow: "none", size: .native, ramp: true,
                                      source: "/x/export")
        #expect(some["frames"] == .array([.string("a"), .string("c"), .string("d")]))
        #expect(some["ramp"] == nil)             // only a cut slows into anything
        #expect(some["size"] == .string("native"))
        #expect(some["exports"] == .string("/x/export"))

        let day = ReelsModel.request(format: .timelapse, burst: "93", tag: "", chosen: all, usable: all,
                                     speed: 12, follow: "people", size: .w1080, ramp: true, source: "/x")
        #expect(day["burst"] == nil && day["tag"] == nil && day["frames"] == nil && day["exports"] == nil)
        let one = ReelsModel.request(format: .timelapse, burst: nil, tag: "name 1", chosen: [], usable: [],
                                     speed: 12, follow: "people", size: .w1080, ramp: false, source: "")
        #expect(one["tag"] == .string("name 1"))
    }

    @Test("every value the step can send is one `_b_reel` accepts")
    func acceptedValues() {
        // The engine's own lists, read from pipeline/studio.py's _b_reel.
        #expect(Set(ReelFormat.allCases.map(\.rawValue)) == ["sequence", "cut", "loop", "boomerang", "timelapse"])
        #expect(Set(ReelSize.allCases.map(\.rawValue)) == ["1080", "1440", "2160", "native"])
        #expect(ReelFollowBase.ids.allSatisfy { ["action", "people", "none"].contains($0) })
    }

    // MARK: - waiting on PhotoLab

    @Test("frames exported before he pressed the button are not an export that has finished")
    func waitIgnoresWhatWasThere() {
        var w = ReelWait(burst: "93", baseline: 3)
        for _ in 0..<10 { #expect(!step(&w, 3)) }
        #expect(!w.arriving && !w.settled)
    }

    @Test("a count that reaches the whole burst cuts the reel at the next poll")
    func waitCutsWhenComplete() {
        var w = ReelWait(burst: "93", baseline: 3, target: 13)
        #expect(!step(&w, 5))
        #expect(!step(&w, 13))
        #expect(w.arriving && w.complete && w.cutsIn == nil)
        #expect(step(&w, 13))
        #expect(w.settled && w.seen == 13)
    }

    @Test("a count that stops short of the burst waits forty-five seconds for a slow frame, and says when it will cut")
    func waitHoldsForASlowFrame() {
        var w = ReelWait(burst: "93", baseline: 3, target: 13)
        #expect(!step(&w, 9))
        // Ten seconds of nothing was how long the page waited, and one frame
        // under PhotoLab's heaviest noise reduction takes longer than that.
        #expect(!step(&w, 9) && !step(&w, 9))
        #expect(w.cutsIn == .seconds(35))
        for _ in 3..<ReelWait.quietPolls { #expect(!step(&w, 9)) }
        #expect(ReelWait.interval * ReelWait.quietPolls == .seconds(45))
        #expect(!step(&w, 12))                      // the slow one came, and the clock starts again
        #expect(w.cutsIn == nil && w.seen == 12)
        for _ in 1..<ReelWait.quietPolls { #expect(!step(&w, 12)) }
        #expect(step(&w, 12))
        #expect(w.settled && !w.complete)
    }

    @Test("a reel is never cut from fewer than three exports")
    func waitNeedsThree() {
        var w = ReelWait(burst: "1", baseline: 0)
        #expect(!step(&w, 2))
        for _ in 0..<5 { #expect(!step(&w, 2)) }
    }

    @Test("the wait starts from the engine's count over every folder, not the lister's count of one")
    @MainActor func waitStartsFromTheWatch() async throws {
        let m = model()
        // "Pictures from" is one folder, and the lister counted none of burst
        // 93 in it. The watch counts every folder, and finds the three.
        m.preview(try burst93(patch: { b in b["exported"] = 0 }), burst: "93")
        #expect(m.chosenBurst?.exported == 0)
        var spread: [String] = []
        m.countExports = { _, b in b == "93" ? 3 : nil }
        m.startSpread = { _, b in spread.append(b) }
        await m.finishInPhotoLab()?.value
        let w = try #require(m.wait)
        #expect(w.baseline == 3 && !w.ready)
        #expect(spread == ["93"])
        // Started from the lister's 0, three exports already there were "new"
        // and the reel was cut from them. From the watch's 3 they are not.
        var fromWatch = w
        fromWatch.begin()
        for _ in 0..<5 { #expect(!step(&fromWatch, 3)) }
        var fromLister = ReelWait(burst: "93", baseline: 0)
        _ = step(&fromLister, 3)
        var cut = false
        for _ in 0..<ReelWait.quietPolls { cut = step(&fromLister, 3) || cut }
        #expect(cut)
        m.stopWaiting()
    }

    @Test("with no answer from the engine there is no wait and no spread, and the page says so")
    @MainActor func waitNeedsTheCount() async throws {
        let m = model()
        m.preview(try burst93(), burst: "93")
        var spread = 0
        m.countExports = { _, _ in nil }
        m.startSpread = { _, _ in spread += 1 }
        await m.finishInPhotoLab()?.value
        #expect(m.wait == nil && spread == 0)
        #expect(m.waitNote == Strings.API.offline)
    }

    @Test("the count is only watched once the presets are written, and a spread that did not finish ends the wait")
    @MainActor func waitFollowsTheSpread() async throws {
        func pressed() async throws -> ReelsModel {
            let m = model()
            m.preview(try burst93(), burst: "93")
            m.countExports = { _, _ in 3 }
            m.startSpread = { _, _ in }
            await m.finishInPhotoLab()?.value
            #expect(m.wait?.ready == false)
            return m
        }
        func ended(code: Int?, stopped: Bool = false, log: String = "") -> Job {
            Job(running: false, stopped: stopped, kind: "spread", shoot: "2026-09-13-dog", log: log, code: code)
        }
        // Before the presets are written, exports are not counted at all.
        var early = ReelWait(burst: "93", baseline: 3, ready: false)
        #expect(!step(&early, 9) && early.seen == 3)

        let done = try await pressed()
        done.spreadEnded(ended(code: 0))
        #expect(done.wait?.ready == true && done.waitNote == nil)
        done.stopWaiting()

        // Refusals are the engine's own sentence, shown as written.
        let refused = try await pressed()
        refused.spreadEnded(ended(code: 1, log: "$ spread\nnothing to gather: the RAWs are not on this disk"))
        #expect(refused.wait == nil)
        #expect(refused.waitNote == "\(Strings.Step.refusedNote): nothing to gather: the RAWs are not on this disk")

        let failed = try await pressed()
        failed.spreadEnded(ended(code: 1, log: "Traceback (most recent call last):"))
        #expect(failed.wait == nil && failed.waitNote == Strings.Reels.spreadFailed)

        let stopped = try await pressed()
        stopped.spreadEnded(ended(code: nil, stopped: true))
        #expect(stopped.wait == nil && stopped.waitNote == Strings.Step.stoppedNote)
    }

    @Test("a wait with nothing new keeps watching, more slowly, for as long as the app is open")
    @MainActor func waitKeepsWatching() async throws {
        // Every 5 s for two minutes, every 30 s until ten, then every minute.
        #expect(ReelWait.slowing(afterIdle: 0) == 1 && ReelWait.slowing(afterIdle: 23) == 1)
        #expect(ReelWait.slowing(afterIdle: 24) == 6 && ReelWait.slowing(afterIdle: 39) == 6)
        #expect(ReelWait.slowing(afterIdle: 40) == 12 && ReelWait.slowing(afterIdle: 5_000) == 12)
        var w = ReelWait(burst: "93", baseline: 3)
        for _ in 0..<24 { _ = step(&w, 3) }
        #expect(w.slowing == 6 && w.idleSeconds == 120)
        for _ in 0..<16 { _ = step(&w, 3) }
        #expect(w.slowing == 12 && w.idleSeconds == 600)
        // Twenty-five minutes in, the line says it is still looking, and how often.
        for _ in 0..<15 { _ = step(&w, 3) }
        #expect(w.idleSeconds == 1_500)
        #expect(ReelsCentre.waitLine(w).hasSuffix(Strings.Reels.slower(minutes: 25, every: 60)))
        // An export puts it back to every 5 s.
        _ = step(&w, 4)
        #expect(w.slowing == 1 && !ReelsCentre.waitLine(w).contains(Strings.Reels.slower(minutes: 25, every: 60)))

        // The page goes on past what used to be twenty minutes, and an
        // export made then still cuts the reel.
        let m = model()
        m.preview(try burst93(), burst: "93")
        m.pollInterval = .milliseconds(1)
        // What PhotoLab has written so far, changed by the test while the
        // wait holds the closure that reads it.
        final class Exported { var n = 3 }
        let exported = Exported()
        var asked = 0
        m.countExports = { _, _ in asked += 1; return exported.n }
        var sent: [String: JSONValue]?
        m.sendReel = { _, body in sent = body }
        m.startWaiting(burst: "93", baseline: 3, target: 13)
        for _ in 0..<8000 where (m.wait?.idle ?? 0) < 250 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(m.wait?.idle ?? 0 >= 250, "past 240 polls with nothing new it is still waiting")
        #expect(m.waitNote == nil && sent == nil)
        exported.n = 13
        for _ in 0..<2000 where sent == nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(sent?["burst"] == .string("93"))
        #expect(asked > 250)
    }

    @Test("opening another shoot's reels leaves this shoot's wait going, and the same shoot opened afresh takes it over")
    @MainActor func waitBelongsToItsShoot() throws {
        let store = ReelsModelStore(memory: .none)
        let c = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "t"))
        func session(_ fixture: String) throws -> ShootSession {
            let r = try Fixture.decode(ShootResponse.self, fixture)
            return ShootSession(response: r, ext: nil, client: c, pump: ImagePump(client: c))
        }
        let jobs = JobModel()
        let dog = store.model(for: try session("shoot-decided"), jobs: jobs)
        dog.pollInterval = .seconds(60)
        dog.startWaiting(burst: "93", baseline: 3, target: 13)
        // His export in PhotoLab still cuts the reel while he looks elsewhere.
        _ = store.model(for: try session("shoot-not-culled"), jobs: jobs)
        #expect(dog.wait?.burst == "93")
        // The shoot re-read: the new page's model watches the same count.
        let again = store.model(for: try session("shoot-decided"), jobs: jobs)
        #expect(again !== dog)
        #expect(dog.wait == nil)
        #expect(again.wait?.burst == "93" && again.wait?.target == 13 && again.waitNote == nil)
        // One still writing presets cannot follow its job, and says it stopped.
        again.previewWait(ReelWait(burst: "94", baseline: 0, ready: false))
        let third = store.model(for: try session("shoot-decided"), jobs: jobs)
        #expect(third.wait == nil && third.waitNote == Strings.Reels.waitLost("94"))
        store.reset()
    }

    // MARK: - keeping up

    @Test("coming back to the page asks the lister again rather than showing what it said before")
    @MainActor func returnReloads() async throws {
        let m = model()
        var asked = 0
        let answer = try burst93()
        m.fetchOptions = { _, _, _ in asked += 1; return answer }
        m.burst = "93"
        m.load()
        for _ in 0..<200 where m.options == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(asked == 1)
        m.load()                    // nothing changed, and nothing is asked
        #expect(asked == 1)
        m.appeared()                // he came back: ask again
        for _ in 0..<200 where asked < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(asked == 2)
        m.stopObserving()
    }

    @Test("a reel cut again under the same name is a different reel to the player")
    func recutReloads() {
        let url = URL(fileURLWithPath: "/x/reels/2026-09-19-cut93.mp4")
        #expect(ReelPlayer.identity(url, "3400000|2026-09-20 15:16")
                != ReelPlayer.identity(url, "3500000|2026-09-20 15:40"))
        #expect(ReelPlayer.identity(url, "a") == ReelPlayer.identity(url, "a"))
    }

    @Test("a tile's picture is asked for again once the frame is exported")
    @MainActor func thumbFollowsTheExport() async {
        var loads = 0
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .representation(using: .png, properties: [:])!
        let counter = ReelThumbLoads()
        let t = ReelThumbs(load: { _ in await counter.bump(); return png })
        _ = await t.image(shoot: "s", stem: "TSC1", src: nil)
        _ = await t.image(shoot: "s", stem: "TSC1", src: nil)
        loads = await counter.n
        #expect(loads == 1)
        #expect(t.cached(shoot: "s", stem: "TSC1", src: nil, version: "exported") == nil)
        _ = await t.image(shoot: "s", stem: "TSC1", src: nil, version: "exported")
        loads = await counter.n
        #expect(loads == 2)
    }

    // MARK: - the click

    @Test("a click toggles at once; a double-click leaves the tick as it was and opens the frame")
    @MainActor func clicks() throws {
        var toggles = 0, opens = 0
        let v = TileClicks.ClickView()
        v.toggle = { toggles += 1 }
        v.open = { opens += 1 }
        v.mouseDown(with: try click(1))
        #expect(toggles == 1 && opens == 0)
        v.mouseDown(with: try click(2))
        #expect(toggles == 2 && opens == 1)     // back where it was, and open
        v.mouseDown(with: try click(3))
        #expect(toggles == 2 && opens == 2)     // a third click only opens
    }

    // MARK: - scaffolding

    /// `#expect` cannot call a mutating method; this is the same call.
    func step(_ w: inout ReelWait, _ n: Int) -> Bool { w.saw(n) }

    @MainActor func model() -> ReelsModel {
        let c = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "t"))
        let r = try! Fixture.decode(ShootResponse.self, "shoot-decided")
        let s = ShootSession(response: r, ext: nil, client: c, pump: ImagePump(client: c))
        return ReelsModel(session: s, jobs: JobModel())
    }

    func burst93() throws -> ReelOptions { try Fixture.decode(ReelOptions.self, "reel-options-burst") }

    /// The same answer with burst 93's own entry changed, as the lister would
    /// send it about one folder.
    func burst93(patch: (inout [String: Any]) -> Void) throws -> ReelOptions {
        var o = try #require(try JSONSerialization.jsonObject(with: Fixture.data("reel-options-burst")) as? [String: Any])
        for key in ["cuts", "sequences"] {
            var list = try #require(o[key] as? [[String: Any]])
            for i in list.indices where "\(list[i]["burst"] ?? "")" == "93" { patch(&list[i]) }
            o[key] = list
        }
        return try JSONDecoder().decode(ReelOptions.self, from: JSONSerialization.data(withJSONObject: o))
    }

    func click(_ n: Int) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: n, pressure: 1))
    }
}

/// Counts the loads a thumbnail store makes, from whichever task makes them.
actor ReelThumbLoads {
    var n = 0
    func bump() { n += 1 }
}
