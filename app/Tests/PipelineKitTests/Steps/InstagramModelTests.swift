import Foundation
import Testing
@testable import PipelineKit

/// The Instagram step's model (DESIGN.md §2.17): what Make writes, when the
/// cuts are asked for, the wall's order, the editor's saves and undo.
@Suite("The Instagram step", .serialized)
@MainActor
struct InstagramModelTests {

    // MARK: - what Make writes

    @Test("with nothing ticked, Make writes every cut on screen that is not already made as shown")
    func nothingTicked() throws {
        let m = try InstagramScaffold.model()
        let expected = m.order.filter { s in
            let f = m.frames[s]!
            return f.state == .planned && !f.copy_current
        }
        #expect(m.makeSet == expected)
        #expect(m.makeSet.count == 13)
        // Never one exported again (made or not), nor one not worked out, nor
        // one made as shown. One made at the other shape is made again.
        for s in ["TSC05809", "TSC05817", "TSC05845", "TSC05901"] {
            #expect(!m.makeSet.contains(s))
        }
        #expect(m.makeSet.contains("TSC05945"))
        #expect(m.makeWord == "Make 13 Copies")
        #expect(m.makeLine == "Makes 13 — every one not made yet. 1 is already made as shown. "
                + "3 still being worked out are not included.")
    }

    @Test("leaving some out makes all but those")
    func leftOut() throws {
        let m = try InstagramScaffold.model()
        for s in m.makeSet.prefix(3) { m.set(s, .leaveOut) }
        #expect(m.makeSet.count == 10)
        #expect(m.makeLine?.hasPrefix("Makes 10 — all but the 3 you left out.") == true)
    }

    @Test("ticking some makes only those, and a tick on one made as shown or not worked out makes nothing of it")
    func ticked() throws {
        let m = try InstagramScaffold.model()
        m.set("TSC05816", .include)          // planned, not made
        m.set("TSC05901", .include)          // made as shown
        m.set("TSC05845", .include)          // not worked out yet
        m.set("TSC05945", .include)          // made at 4:5, cut at 3:4
        m.set("TSC06383", .leaveOut)         // a leave-out beside ticks changes nothing
        #expect(m.makeSet == m.order.filter { ["TSC05816", "TSC05945"].contains($0) })
        #expect(m.makeWord == "Make 2 Copies")
        #expect(m.makeLine == "Makes 2 — the ones you included. 1 is already made as shown. "
                + "1 still being worked out is not included.")
    }

    @Test("when Make would make nothing, the line says why")
    func whyNothing() throws {
        let m = try InstagramScaffold.model()
        for s in m.order { m.set(s, .leaveOut) }
        #expect(m.makeSet.isEmpty)
        #expect(m.makeLine == Strings.Instagram.allLeftOut)

        let n = try InstagramScaffold.model()
        n.set("TSC05845", .include)
        n.set("TSC05817", .include)          // exported again: its cut is worked out again first
        #expect(n.makeLine == Strings.Instagram.stillWorking)

        let o = try InstagramScaffold.model()
        o.set("TSC05901", .include)
        #expect(o.makeLine == Strings.Instagram.allMade(1))
        #expect(o.makeLine == "It is made as shown. A cut you change is made again at once.")

        let e = try InstagramScaffold.model("instagram-empty")
        #expect(e.makeSet.isEmpty)
        #expect(e.makeLine?.hasPrefix("Nothing is exported yet.") == true)
    }

    @Test("Make N Copies sends exactly the make set, in the wall's order")
    func makeBody() throws {
        let m = try InstagramScaffold.model()
        var sent: [[String]] = []
        m.sendMake = { _, stems in sent.append(stems) }
        m.set("TSC05822", .leaveOut)
        m.make()
        #expect(sent == [m.makeSet])
        #expect(!sent[0].contains("TSC05822"))
        #expect(sent[0].first == "TSC05824")
        // Nothing to make: nothing is sent.
        for s in m.order { m.set(s, .leaveOut) }
        m.make()
        #expect(sent.count == 1)
        // The body the route is sent.
        let body = InstagramMakeBody(name: m.name, stems: ["TSC05816", "TSC05945"])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        #expect(json?["stems"] as? [String] == ["TSC05816", "TSC05945"])
        #expect(json?["name"] as? String == m.name)
        #expect(json?["all"] == nil && json?["ratio"] == nil)
    }

    @Test("a click on the box includes, and a second click takes it back to unmarked")
    func tickSemantics() throws {
        let m = try InstagramScaffold.model()
        m.toggleInclude("TSC05816")
        #expect(m.mark("TSC05816") == .include)
        m.toggleInclude("TSC05816")
        #expect(m.mark("TSC05816") == nil)
        m.set("TSC05816", .leaveOut)
        m.toggleInclude("TSC05816")
        #expect(m.mark("TSC05816") == .include)
    }

    // MARK: - working out the cuts

    @Test("the cuts are asked for once when the step opens, and not again for five seconds")
    func asksOnce() async throws {
        let (m, calls) = try InstagramScaffold.live(answer: InstagramPlanAnswer(planning: false))
        m.appeared()
        await InstagramScaffold.settle()
        #expect(calls.plans == 1)
        #expect(m.plan == .wanted)
        m.tick()
        await InstagramScaffold.settle()
        #expect(calls.plans == 1)
        InstagramScaffold.later(m, by: 4)
        m.tick()
        await InstagramScaffold.settle()
        #expect(calls.plans == 1)
        InstagramScaffold.later(m, by: 2)
        m.tick()
        await InstagramScaffold.settle()
        #expect(calls.plans == 2)
    }

    @Test("nothing is asked while the copies of this shoot are being made")
    func notWhileMaking() async throws {
        let (m, calls) = try InstagramScaffold.live(answer: InstagramPlanAnswer(planning: false))
        m.makeJob.preview = Job(running: true, stopped: false, kind: "instagram", shoot: m.name,
                                title: "making 9 Instagram copies")
        m.appeared()
        await InstagramScaffold.settle()
        InstagramScaffold.later(m, by: 30)
        m.tick()
        await InstagramScaffold.settle()
        #expect(calls.plans == 0)
    }

    @Test("a job of his in the slot is waited for, and the cuts are asked for again when it is done")
    func waitsForHisJob() async throws {
        let waiting = InstagramPlanAnswer(planning: false,
                                          waiting_for: InstagramWaitingFor(title: "culling 2026-09-21", kind: "cull"))
        let (m, calls) = try InstagramScaffold.live(answer: waiting)
        m.appeared()
        await InstagramScaffold.settle()
        #expect(calls.plans == 1)
        #expect(m.plan == .waiting("culling 2026-09-21"))
        m.jobs.take(Job(running: true, stopped: false, id: 40, kind: "cull", shoot: "2026-09-21",
                        title: "culling 2026-09-21"))
        InstagramScaffold.later(m, by: 60)
        m.tick()
        await InstagramScaffold.settle()
        #expect(calls.plans == 1)
        #expect(m.plan == .waiting("culling 2026-09-21"))
        // His job ends: the slot is free, and the step asks again.
        calls.answer = InstagramPlanAnswer(planning: true, id: 41, count: 4)
        m.jobs.take(Job(running: false, stopped: false, id: 40, kind: "cull", shoot: "2026-09-21",
                        title: "culling 2026-09-21", code: 0))
        m.tick()
        await InstagramScaffold.settle()
        #expect(calls.plans == 2)
    }

    @Test("a pass he stopped is not asked for again until he says so")
    func stoppedByHim() async throws {
        let (m, calls) = try InstagramScaffold.live(answer: InstagramPlanAnswer(planning: true, id: 12, count: 4))
        m.appeared()
        await InstagramScaffold.settle()
        #expect(calls.plans == 1)
        m.jobs.take(Job(running: true, stopped: false, id: 12, kind: "instagram-plan", shoot: m.name,
                        label: "working out the cuts: 1 of 4 photographs", fraction: 0.25, background: true))
        m.tick()
        #expect(m.plan == .running(label: "working out the cuts: 1 of 4 photographs", fraction: 0.25))
        m.jobs.take(Job(running: false, stopped: true, id: 12, kind: "instagram-plan", shoot: m.name,
                        code: -15, background: true))
        m.tick()
        await InstagramScaffold.settle()
        #expect(m.plan == .stopped)
        InstagramScaffold.later(m, by: 60)
        m.tick()
        await InstagramScaffold.settle()
        #expect(calls.plans == 1)
        // Work Out the Rest asks at once.
        m.askAgain()
        await InstagramScaffold.settle()
        #expect(calls.plans == 2)
    }

    @Test("a pass that failed is not asked for again until Try Again")
    func failedPass() async throws {
        let (m, calls) = try InstagramScaffold.live(answer: InstagramPlanAnswer(planning: true, id: 12, count: 4))
        m.appeared()
        await InstagramScaffold.settle()
        m.jobs.take(Job(running: false, stopped: false, id: 12, kind: "instagram-plan", shoot: m.name,
                        log: "$ python instagram.py\nTraceback (most recent call last):\nMemoryError",
                        code: 1, background: true))
        m.tick()
        await InstagramScaffold.settle()
        guard case .failed = m.plan else { Issue.record("the plan should read failed, not \(m.plan)"); return }
        InstagramScaffold.later(m, by: 60)
        m.tick()
        await InstagramScaffold.settle()
        #expect(calls.plans == 1)
        m.askAgain()
        await InstagramScaffold.settle()
        #expect(calls.plans == 2)
    }

    @Test("a pass stood down for his own press is asked for again when that is done")
    func standDownResumes() async throws {
        let (m, calls) = try InstagramScaffold.live(answer: InstagramPlanAnswer(planning: true, id: 12, count: 4))
        m.appeared()
        await InstagramScaffold.settle()
        m.jobs.take(Job(running: true, stopped: false, id: 12, kind: "instagram-plan", shoot: m.name,
                        background: true))
        m.tick()
        // His make takes the slot: the poll never sees the pass end on its own.
        m.jobs.take(Job(running: true, stopped: false, id: 13, kind: "instagram", shoot: m.name,
                        title: "making 3 Instagram copies"))
        m.tick()
        #expect(m.plan == .waiting("making 3 Instagram copies"))
        m.jobs.take(Job(running: false, stopped: false, id: 13, kind: "instagram", shoot: m.name, code: 0))
        InstagramScaffold.later(m, by: 6)
        m.tick()
        await InstagramScaffold.settle()
        #expect(calls.plans == 2)
    }

    /// The wall of a pass, with the engine's shape and pass as given.
    static func wall(_ s: InstagramStatus, ratio: String, planning: InstagramProgress?) -> InstagramStatus {
        InstagramStatus(shoot: s.shoot, folder: s.folder, folder_exists: s.folder_exists, ratio: ratio,
                        landscape: s.landscape, planning: planning, frames: s.frames)
    }

    @Test("changing the shape during a pass is not his Stop, whichever the app hears first")
    func shapeDuringAPass() async throws {
        for pollFirst in [false, true] {
            let (m, calls) = try InstagramScaffold.live(fixture: "instagram-planning",
                                                        answer: InstagramPlanAnswer(planning: true, id: 9, count: 5))
            m.appeared()
            await InstagramScaffold.settle()
            m.jobs.take(Job(running: true, stopped: false, id: 8, kind: "instagram-plan", shoot: m.name,
                            background: true))
            m.tick()
            #expect(calls.plans == 0)
            // The engine stands the pass down, writes 4:5 and starts the pass
            // again in the same request: its answer is a wall with pass 9.
            let again = InstagramProgress(id: 9, label: "working out the cuts: 0 of 5 photographs", fraction: 0)
            calls.status = Self.wall(calls.status, ratio: "4:5", planning: again)
            let stood = Job(running: false, stopped: true, id: 8, kind: "instagram-plan", shoot: m.name,
                            code: -15, background: true, stoodDown: true)
            if pollFirst {
                m.jobs.take(stood)
                m.tick()
                await InstagramScaffold.settle()
                m.choose(ratio: "4:5")
            } else {
                m.choose(ratio: "4:5")
                await InstagramScaffold.settle()
                m.jobs.take(stood)
                m.tick()
            }
            await InstagramScaffold.settle()
            #expect(m.planOutcome == .none, "poll first: \(pollFirst)")
            #expect(m.plan == .running(label: again.label, fraction: 0), "poll first: \(pollFirst)")
            m.jobs.take(Job(running: true, stopped: false, id: 9, kind: "instagram-plan", shoot: m.name,
                            label: "working out the cuts: 2 of 5 photographs", fraction: 0.4, background: true))
            InstagramScaffold.later(m, by: 30)
            m.tick()
            await InstagramScaffold.settle()
            #expect(m.plan == .running(label: "working out the cuts: 2 of 5 photographs", fraction: 0.4))
            #expect(m.ratio == "4:5")
        }
    }

    @Test("a pass stood down that the engine did not start again is asked for by the step")
    func standDownNotRestarted() async throws {
        let (m, calls) = try InstagramScaffold.live(fixture: "instagram-planning",
                                                    answer: InstagramPlanAnswer(planning: true, id: 9, count: 5))
        m.appeared()
        await InstagramScaffold.settle()
        m.jobs.take(Job(running: true, stopped: false, id: 8, kind: "instagram-plan", shoot: m.name,
                        background: true))
        m.tick()
        calls.status = Self.wall(calls.status, ratio: "4:5", planning: nil)
        m.choose(ratio: "4:5")
        await InstagramScaffold.settle()
        m.jobs.take(Job(running: false, stopped: true, id: 8, kind: "instagram-plan", shoot: m.name,
                        code: -15, background: true, stoodDown: true))
        m.tick()
        await InstagramScaffold.settle()
        #expect(m.planOutcome == .none)
        #expect(m.plan != .stopped)
        #expect(calls.plans == 1)
    }

    @Test("a pass stood down for something off Up Next is waited out and asked for again, never read as his Stop")
    func standDownForTheList() async throws {
        let (m, calls) = try InstagramScaffold.live(answer: InstagramPlanAnswer(planning: true, id: 12, count: 3))
        m.appeared()
        await InstagramScaffold.settle()
        #expect(calls.plans == 1)
        m.jobs.take(Job(running: true, stopped: false, id: 12, kind: "instagram-plan", shoot: m.name,
                        background: true))
        m.tick()
        m.jobs.take(Job(running: false, stopped: true, id: 12, kind: "instagram-plan", shoot: m.name,
                        code: -15, background: true, stoodDown: true))
        m.tick()
        m.jobs.take(Job(running: true, stopped: false, id: 14, kind: "cull", shoot: "2026-09-21",
                        title: "culling 2026-09-21"))
        m.tick()
        #expect(m.plan == .waiting("culling 2026-09-21"))
        m.jobs.take(Job(running: false, stopped: false, id: 14, kind: "cull", shoot: "2026-09-21", code: 0))
        InstagramScaffold.later(m, by: 6)
        m.tick()
        await InstagramScaffold.settle()
        #expect(m.plan != .stopped)
        #expect(calls.plans == 2)
    }

    @Test("the make line says still being worked out only while something is working them out")
    func makeLineSaysWhatIsHappening() throws {
        let m = try InstagramScaffold.model()
        #expect(m.plan == .wanted)
        #expect(m.makeLine?.contains("3 still being worked out are not included.") == true)
        for o in [InstagramPlanOutcome.stoppedByHim, .failed("It failed.")] {
            m.previewPlanOutcome(o)
            #expect(m.makeLine?.contains("3 not worked out yet are not included.") == true, "\(o)")
            #expect(m.makeLine?.contains("still being worked out") == false, "\(o)")
        }
        // Only those chosen: the greyed primary's line.
        for s in m.order where m.frames[s]?.isPlanned == true { m.set(s, .leaveOut) }
        #expect(m.makeSet.isEmpty)
        #expect(m.makeLine == "These cuts are not worked out yet.")
        m.previewPlanOutcome(.none)
        #expect(m.makeLine == "Still working out these cuts.")
    }

    // MARK: - the wall's order

    @Test("the order stays put while a pass fills the wall in, and takes the engine's when it ends")
    func orderIsStable() async throws {
        let (m, calls) = try InstagramScaffold.live(fixture: "instagram-planning",
                                                    answer: InstagramPlanAnswer(planning: true, id: 12, count: 4))
        m.appeared()
        await InstagramScaffold.settle()
        let before = m.order
        // The pass works one out that the profile grid would cut: the engine
        // puts it first.
        var planned = try InstagramScaffold.status("instagram")
        let running = InstagramProgress(id: 12, label: "working out the cuts: 5 of 7 photographs", fraction: 0.71)
        let filling = InstagramScaffold.withMiss(planned, "TSC05835", planning: running)
        planned = InstagramScaffold.withMiss(planned, "TSC05835")
        #expect(filling.frames.map(\.stem).prefix(1) == ["TSC05835"])
        calls.status = filling
        m.load()
        await InstagramScaffold.settle()
        // Nothing moves under his eyes: a photograph exported meanwhile goes at the end.
        #expect(Array(m.order.prefix(before.count)) == before)
        #expect(m.order.dropFirst(before.count).elementsEqual(
            filling.frames.map(\.stem).filter { !before.contains($0) }))
        #expect(m.frames["TSC05835"]?.gridMiss == true)
        // The pass ends: the wall takes the engine's order once.
        calls.status = planned
        m.jobs.take(Job(running: false, stopped: false, id: 12, kind: "instagram-plan", shoot: m.name,
                        code: 0, background: true))
        m.tick()
        await InstagramScaffold.settle()
        #expect(m.order == planned.frames.map(\.stem))
        #expect(m.order.first == "TSC05835")
    }

    @Test("when a pass ends and the wall takes the engine's order, the wall follows the ringed photograph")
    func resortFollowsTheRing() async throws {
        let (m, calls) = try InstagramScaffold.live(fixture: "instagram-planning",
                                                    answer: InstagramPlanAnswer(planning: false))
        m.appeared()
        await InstagramScaffold.settle()
        m.perform(.next)
        m.perform(.next)
        m.perform(.next)
        let ringed = try #require(m.ring)
        let reveals = m.revealRequests
        calls.status = InstagramScaffold.withMiss(try InstagramScaffold.status("instagram"), "TSC05835")
        m.jobs.take(Job(running: false, stopped: false, id: 8, kind: "instagram-plan", shoot: m.name,
                        code: 0, background: true))
        m.tick()
        await InstagramScaffold.settle()
        #expect(m.order.first == "TSC05835")
        #expect(m.ring == ringed)
        #expect(m.revealRequests > reveals)
    }

    @Test("a pass that ends unheard by the job poll is seen from the wall, which then takes the engine's order")
    func passEndsUnheard() async throws {
        let (m, calls) = try InstagramScaffold.live(fixture: "instagram-planning",
                                                    answer: InstagramPlanAnswer(planning: false))
        m.appeared()
        await InstagramScaffold.settle()
        let planned = InstagramScaffold.withMiss(try InstagramScaffold.status("instagram"), "TSC05835")
        calls.status = planned
        m.load()
        await InstagramScaffold.settle()
        #expect(m.order.first == "TSC05835")
    }

    @Test("a stem the answer adds goes at the end, and one it drops goes")
    func addsAndDrops() throws {
        let m = try InstagramScaffold.model()
        let s = try InstagramScaffold.status("instagram")
        var frames = s.frames.filter { $0.stem != "TSC05816" }
        frames.insert(InstagramFrame(stem: "TSC05800", state: .unplanned), at: 0)
        m.adopt(InstagramStatus(shoot: s.shoot, frames: frames), resort: false)
        #expect(!m.order.contains("TSC05816"))
        #expect(m.order.last == "TSC05800")
    }

    // MARK: - the editor

    @Test("the tile shows the new cut the moment the editor closes, before the answer comes back")
    func tileTakesTheCutAtOnce() async throws {
        let (m, calls) = try InstagramScaffold.live(answer: InstagramPlanAnswer(planning: false))
        let gate = InstagramGate()
        let answer = try Fixture.decode(InstagramCropAnswer.self, "instagram-crop")
        m.sendCrop = { body in
            calls.crops.append(body)
            await gate.wait()
            return answer
        }
        let stem = "TSC05901"
        let was = try #require(m.frames[stem])
        m.open(stem)
        m.setDraft(InstagramManual(cx: 0.52, cy: 0.4, scale: 0.85))
        let drawn = try #require(m.editor?.rect)
        #expect(drawn == PixelRect(380, 134, 3400, 4533))      // the contract's worked example
        m.perform(.close)
        // At once: the tile is the draft, marked his, before any answer.
        #expect(m.editor == nil)
        #expect(m.frames[stem]?.cut?.rect == drawn)
        #expect(m.frames[stem]?.adjusted == true)
        #expect(m.frames[stem]?.other?.rect == PixelRect(380, 275, 3400, 4250))
        #expect(m.frames[stem] != was)
        await InstagramScaffold.settle()
        #expect(calls.crops.count == 1)
        // What is sent is the window drawn, as fractions the engine keeps.
        let sent = try #require(calls.crops.first?.manual)
        #expect(sent == InstagramWindow.kept(InstagramWindow.fromRect(drawn, w: 4000, h: 6000, want: 0.75)))
        #expect(InstagramWindow.windowOf(PixelSize(4000, 6000), want: 0.75, sent) == drawn)
        #expect(calls.crops.first?.mode == "crop")
        // The answer replaces it.
        await gate.open()
        await InstagramScaffold.settle()
        #expect(m.frames[stem] == answer.frame)
        #expect(m.saved?.text == Strings.Instagram.savedAndMade)
    }

    @Test("a refused save puts the cut back as it was and says why")
    func refusedSave() async throws {
        let (m, _) = try InstagramScaffold.live(answer: InstagramPlanAnswer(planning: false))
        m.sendCrop = { _ in throw StudioError.refused("TSC05901 has not been worked out yet.") }
        let was = try #require(m.frames["TSC05901"])
        m.open("TSC05901")
        m.nudge(dx: 1, dy: 0)
        m.closeEditor()
        #expect(m.frames["TSC05901"] != was)
        await InstagramScaffold.settle()
        #expect(m.frames["TSC05901"] == was)
        #expect(m.undoStack.isEmpty)
        #expect(m.note == "TSC05901 has not been worked out yet.")
    }

    @Test("Whole, Automatic and his window are each saved as the engine reads them")
    func saveBodies() async throws {
        let (m, calls) = try InstagramScaffold.live(answer: InstagramPlanAnswer(planning: false))
        // A landscape left whole, cut instead.
        m.open("TSC05822")
        m.perform(.cutOrWhole)
        #expect(m.editor?.mode == "crop")
        #expect(m.editor?.rect == m.frames["TSC05822"]?.auto)
        m.perform(.next)                       // saved on the way to the next
        await InstagramScaffold.settle()
        #expect(calls.crops.last == InstagramCropBody(name: m.name, stem: "TSC05822", mode: "crop"))
        #expect(m.frames["TSC05822"]?.mode_by == "you")
        #expect(m.frames["TSC05822"]?.cut?.rect == m.frames["TSC05822"]?.auto)
        #expect(m.frames["TSC05822"]?.adjusted == false)
        // His window, back to the automatic one.
        m.open("TSC06383")
        m.perform(.automatic)
        m.perform(.close)
        await InstagramScaffold.settle()
        #expect(calls.crops.last == InstagramCropBody(name: m.name, stem: "TSC06383", mode: "crop", auto: true))
        #expect(m.frames["TSC06383"]?.adjusted == false)
        #expect(m.frames["TSC06383"]?.cut?.rect == m.frames["TSC06383"]?.auto)
        // A portrait left whole.
        m.open("TSC06384")
        m.perform(.cutOrWhole)
        m.perform(.close)
        await InstagramScaffold.settle()
        #expect(calls.crops.last == InstagramCropBody(name: m.name, stem: "TSC06384", mode: "whole"))
        #expect(m.frames["TSC06384"]?.isWhole == true)
        // Looked at and left alone: nothing is sent.
        let n = calls.crops.count
        m.open("TSC05827")
        m.perform(.next)
        m.perform(.close)
        await InstagramScaffold.settle()
        #expect(calls.crops.count == n)
    }

    @Test("a window moved and then left whole keeps the window, so the tile's faint line is the editor's")
    func wholeKeepsTheWindow() async throws {
        let (m, calls) = try InstagramScaffold.live(answer: InstagramPlanAnswer(planning: false))
        let stem = "TSC06384"
        let size = try #require(m.frames[stem]?.frame)
        m.open(stem)
        m.setDraft(InstagramManual(cx: 0.5, cy: 0.3, scale: 0.7))
        let moved = try #require(m.editor?.manual)
        let faint = InstagramWindow.windowOf(size, want: m.want, moved)
        m.perform(.cutOrWhole)
        #expect(m.draftOther == faint)
        m.perform(.close)
        await InstagramScaffold.settle()
        #expect(calls.crops.last == InstagramCropBody(name: m.name, stem: stem, mode: "whole", manual: moved))
        #expect(m.frames[stem]?.isWhole == true)
        #expect(m.frames[stem]?.other?.rect == faint)
        // Automatic, then Whole: his window goes, and the faint line is the
        // automatic cut.
        m.open("TSC06383")
        #expect(m.frames["TSC06383"]?.manual != nil)
        m.perform(.automatic)
        m.perform(.cutOrWhole)
        m.perform(.close)
        await InstagramScaffold.settle()
        #expect(calls.crops.last == InstagramCropBody(name: m.name, stem: "TSC06383", mode: "whole", auto: true))
        #expect(m.frames["TSC06383"]?.manual == nil)
        #expect(m.frames["TSC06383"]?.other?.rect == m.frames["TSC06383"]?.auto)
    }

    @Test("the editor walks the wall's order, and the keys size and move the cut inside the frame")
    func editorMoves() throws {
        let m = try InstagramScaffold.model()
        m.open(m.order[0])
        m.perform(.previous)
        #expect(m.editor?.stem == m.order[0])          // stops at the start
        m.perform(.next)
        #expect(m.editor?.stem == m.order[1])
        m.open("TSC05901")
        for _ in 0..<80 { m.perform(.smaller) }
        let small = try #require(m.editor?.manual)
        #expect(abs(small.scale - InstagramWindow.leastScale) < 0.001)
        for _ in 0..<400 { m.perform(.nudge(dx: -1, dy: -1)) }
        let r = try #require(m.editor?.rect)
        #expect(r.x == 0 && r.y == 0)                   // pushed back inside, as the engine keeps it
        #expect(m.editor?.dirty == true)
    }

    @Test("an unplanned photograph opens, but its cut cannot be changed until it is worked out")
    func unplannedInEditor() throws {
        let m = try InstagramScaffold.model()
        m.open("TSC05845")
        #expect(m.editor != nil)
        #expect(!m.canEdit)
        m.perform(.larger)
        m.perform(.cutOrWhole)
        #expect(m.editor?.dirty == false)
    }

    // MARK: - undo

    @Test("undo takes back a mark, and redo puts it back")
    func undoMark() throws {
        let m = try InstagramScaffold.model()
        m.set("TSC05816", .include)
        m.set("TSC05817", .leaveOut)
        #expect(m.rowTitle(.undo) == "Undo Leave Out 05817")
        m.perform(.undo)
        #expect(m.mark("TSC05817") == nil)
        #expect(m.rowTitle(.undo) == "Undo Include 05816")
        #expect(m.rowTitle(.redo) == "Redo Leave Out 05817")
        m.perform(.redo)
        #expect(m.mark("TSC05817") == .leaveOut)
    }

    @Test("undo of a cut sends the cut that was there before, and a draft is thrown away first")
    func undoCut() async throws {
        let (m, calls) = try InstagramScaffold.live(answer: InstagramPlanAnswer(planning: false))
        let stem = "TSC05901"
        let before = try #require(m.frames[stem])
        m.open(stem)
        m.setDraft(InstagramManual(cx: 0.52, cy: 0.4, scale: 0.85))
        m.go(by: 1)
        await InstagramScaffold.settle()
        #expect(m.rowTitle(.undo) == "Undo Cut 05901")
        // A draft on the next photograph is thrown away by the first undo.
        m.nudge(dx: 1, dy: 0)
        #expect(m.editor?.dirty == true)
        m.perform(.undo)
        #expect(m.editor?.dirty == false)
        #expect(calls.crops.count == 1)
        // The second takes back the saved cut, with `restore`.
        m.perform(.undo)
        await InstagramScaffold.settle()
        #expect(calls.crops.count == 2)
        #expect(calls.crops.last?.restore == InstagramCutRecord(mode: "crop", mode_by: "run", manual: nil))
        #expect(m.frames[stem]?.cut?.rect == before.cut?.rect)
        m.perform(.redo)
        await InstagramScaffold.settle()
        #expect(calls.crops.last?.restore?.manual == calls.crops.first?.manual)
        #expect(calls.crops.last?.restore?.mode == "crop")
        // `manual: null` is sent when there is none, so the engine removes his window.
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(InstagramCutRecord(mode: "crop", mode_by: "run", manual: nil))) as? [String: Any]
        #expect(json?.keys.contains("manual") == true)
        #expect(json?["manual"] is NSNull)
    }

    @Test("undo in the editor takes him to the photograph it changes, as Q does in Choose Keepers")
    func undoGoesToThePhotograph() async throws {
        let (m, calls) = try InstagramScaffold.live(answer: InstagramPlanAnswer(planning: false))
        let stem = "TSC05901"
        m.open(stem)
        m.setDraft(InstagramManual(cx: 0.52, cy: 0.4, scale: 0.85))
        m.go(by: 1)
        await InstagramScaffold.settle()
        let next = try #require(m.editor?.stem)
        #expect(next != stem)
        // The cut saved on the one before is taken back, and the editor goes there.
        m.perform(.undo)
        await InstagramScaffold.settle()
        #expect(calls.crops.last?.stem == stem && calls.crops.last?.restore != nil)
        #expect(m.editor?.stem == stem)
        #expect(m.editor?.rect == m.frames[stem]?.cut?.rect)
        #expect(m.ring == stem)
        // A mark as well: include moves on, and undo comes back to it.
        m.perform(.include)
        #expect(m.editor?.stem == next)
        m.perform(.undo)
        #expect(m.editor?.stem == stem && m.mark(stem) == nil)
        // Redo waits while a draft is open: it would take the editor away from it.
        m.nudge(dx: 1, dy: 0)
        #expect(!m.canPerform(.redo))
        m.perform(.redo)
        #expect(m.editor?.stem == stem && m.editor?.dirty == true && m.mark(stem) == nil)
    }

    // MARK: - the menu's rows

    @Test("each row names what it does here")
    func rowTitles() throws {
        let m = try InstagramScaffold.model()
        m.ring = "TSC05901"
        #expect(m.rowTitle(.include) == "Include 05901")
        #expect(m.rowTitle(.leaveOut) == "Leave Out 05901")
        #expect(m.rowTitle(.clear) == "Clear the Mark")
        #expect(m.rowTitle(.next) == "Next Photograph")
        #expect(m.rowTitle(.open(.fit)) == "Adjust the Cut")
        m.open("TSC05945")
        #expect(m.rowTitle(.open(.fit)) == "Back to the Photographs")
        #expect(m.rowTitle(.include) == "Include 05945")
        #expect(m.canPerform(.oneToOne))
        m.closeEditor()
        #expect(!m.canPerform(.oneToOne))
    }
}

/// Where the step goes in the list: after Edit in every build, and in an
/// extension's own list that does not name it (DESIGN.md §2.4, §2.17).
@Suite("The Instagram step's place among the steps")
@MainActor
struct InstagramPlaceTests {
    @Test("an extension's own list gets Instagram after Edit, else before Reels, else before Finish")
    func insertion() {
        #expect(Fallbacks.withInstagram(["ingest", "cull", "edit", "reels", "done"])
                == ["ingest", "cull", "edit", "instagram", "reels", "done"])
        #expect(Fallbacks.withInstagram(["ingest", "cull", "a-step", "reels", "done"])
                == ["ingest", "cull", "a-step", "instagram", "reels", "done"])
        #expect(Fallbacks.withInstagram(["cull", "a-step", "done"]) == ["cull", "a-step", "instagram", "done"])
        // A list that names it keeps its own place for it.
        #expect(Fallbacks.withInstagram(["cull", "instagram", "edit", "done"]) == ["cull", "instagram", "edit", "done"])
    }

    @Test("the fallback list has it after Edit, with an extension's list or without")
    func fallback() throws {
        let r = try Fixture.decode(ShootResponse.self, "shoot")
        let plain = Fallbacks.listSteps(r.info, nil).map(\.id)
        #expect(plain == ["ingest", "cull", "keepers", "presets", "edit", "instagram", "reels", "done"])
        let ext = ExtConfig(kind: "a-kind", steps: ["ingest", "cull", "keepers", "presets", "edit", "a-step", "done"])
        let ids = Fallbacks.listSteps(r.info, ext).map(\.id)
        #expect(ids.firstIndex(of: "instagram") == ids.firstIndex(of: "edit").map { $0 + 1 })
        #expect(Fallbacks.baseLabel("instagram") == "Instagram")
        #expect(Symbols.step("instagram") == "crop")
    }

    @Test("its jobs are found on its step")
    func jobsGoToTheStep() {
        #expect(Notifications.step(for: Job(running: false, stopped: false, kind: "instagram", shoot: "s", code: 0))
                == "instagram")
    }
}

// MARK: - scaffolding

/// What the model sent, and what it is answered.
@MainActor
final class InstagramCalls {
    var plans = 0
    var crops: [InstagramCropBody] = []
    var answer: InstagramPlanAnswer
    var status: InstagramStatus
    init(answer: InstagramPlanAnswer, status: InstagramStatus) { self.answer = answer; self.status = status }
}

/// Holds an answer back until the test lets it go.
actor InstagramGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        isOpen = true
        for w in waiting { w.resume() }
        waiting.removeAll()
    }
}

@MainActor
enum InstagramScaffold {
    static func session() throws -> ShootSession {
        let c = StudioClient(endpoint: .init(base: URL(string: "http://127.0.0.1:9/")!, key: "t"))
        let r = try Fixture.decode(ShootResponse.self, "shoot-decided")
        return ShootSession(response: r, ext: nil, client: c, pump: ImagePump(client: c))
    }

    static func status(_ name: String = "instagram") throws -> InstagramStatus {
        try Fixture.decode(InstagramStatus.self, name)
    }

    /// A model holding a fixture's wall, asking nothing of anyone.
    static func model(_ fixture: String = "instagram") throws -> InstagramModel {
        let m = InstagramModel(session: try session(), jobs: JobModel())
        m.ticksByItself = false
        m.sendCrop = { _ in InstagramCropAnswer(frame: nil) }
        m.adopt(try status(fixture), resort: true)
        return m
    }

    /// A model on screen, whose engine is `calls`, on a clock the test moves.
    static func live(fixture: String = "instagram", answer: InstagramPlanAnswer) throws
        -> (InstagramModel, InstagramCalls) {
        let calls = InstagramCalls(answer: answer, status: try status(fixture))
        let m = InstagramModel(session: try session(), jobs: JobModel())
        m.ticksByItself = false
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        clock[ObjectIdentifier(m)] = start
        m.now = { [weak m] in m.flatMap { clock[ObjectIdentifier($0)] } ?? start }
        m.fetch = { _ in calls.status }
        m.askPlan = { _ in calls.plans += 1; return calls.answer }
        m.sendCrop = { body in
            calls.crops.append(body)
            return InstagramCropAnswer(frame: nil)
        }
        m.sendShape = { _ in calls.status }
        m.adopt(calls.status, resort: true)
        return (m, calls)
    }

    private static var clock: [ObjectIdentifier: Date] = [:]

    static func later(_ m: InstagramModel, by seconds: TimeInterval) {
        let k = ObjectIdentifier(m)
        clock[k] = (clock[k] ?? Date()).addingTimeInterval(seconds)
    }

    /// Lets the model's tasks run to their next wait.
    static func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    /// The same wall, with one frame's cut losing the subject in the grid,
    /// and the engine's order for it: the misses first.
    static func withMiss(_ s: InstagramStatus, _ stem: String,
                         planning: InstagramProgress? = nil) -> InstagramStatus {
        var frames = s.frames
        guard let i = frames.firstIndex(where: { $0.stem == stem }) else { return s }
        var f = frames.remove(at: i)
        f.cut?.grid_ok = false
        frames.insert(f, at: 0)
        return InstagramStatus(shoot: s.shoot, folder: s.folder, folder_exists: s.folder_exists, ratio: s.ratio,
                               landscape: s.landscape, planning: planning, frames: frames)
    }
}
