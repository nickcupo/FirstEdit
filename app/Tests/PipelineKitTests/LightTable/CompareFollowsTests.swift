import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// Compare opens on what he asked for and closes when he leaves the burst
/// (DESIGN.md §2.5.12).
@Suite("Compare opens on what he chose and follows him", .serialized)
@MainActor
struct CompareFollowsTests {

    @Test("N while comparing leaves Compare, so the next K is about the burst he is in")
    func nLeavesCompare() async throws {
        let m = try BurstCrossingTests.model()
        let start = m.burstIndex
        await ViewerTests.press(m, .compare)
        #expect(m.mode == .compare)
        await ViewerTests.press(m, .nextBurst)
        #expect(m.burstIndex == start + 1)
        #expect(m.mode == .single, "Compare stayed open on the burst he had left")
        #expect(m.compareSelection.isEmpty)
    }

    /// Decision 4: ⇧K closes Compare and moves past the stack (§2.5.12).
    @Test("⇧K decides the whole stack, closes Compare and lands on the first frame after it")
    func keepOnlyMovesPast() async throws {
        let m = try ViewerTests.model()
        await ViewerTests.press(m, .compare)
        let set = m.compareSelection
        let last = try #require(set.compactMap { m.frames.firstIndex(of: $0) }.max())
        try #require(last + 1 < m.frames.count, "the stack burst has frames after its stack")
        for stem in set { m.didDisplayTile(stem) }

        await ViewerTests.press(m, .keepOnly)
        #expect(m.mode == .single, "Compare stayed open on tiles that were all decided")
        #expect(m.compareSelection.isEmpty)
        #expect(m.frameIndex == last + 1)
        #expect(m.session.rows[m.currentStem!].map(VerdictValue.his) == .unmarked)
        // Nothing but the stack was decided on the way.
        #expect(set.allSatisfy { m.session.rows[$0].map(VerdictValue.his) != .unmarked })
    }

    @Test("a ⇧K refused by the engine leaves Compare open on the same tiles")
    func refusedKeepOnlyStays() async throws {
        let m = try ViewerTests.modelAllSeen()
        let i = try #require(m.bursts.firstIndex { $0.frames.count >= 3 })
        m.goToBurst(i)
        m.compareSelection = Array(m.frames.prefix(2))
        await ViewerTests.press(m, .compare)
        let set = m.compareSelection
        for stem in set { m.didDisplayTile(stem) }
        let at = m.frameIndex
        await ViewerTests.press(m, .keepOnly)
        #expect(m.mode == .compare)
        #expect(m.compareSelection == set)
        #expect(m.frameIndex == at)
    }

    @Test("a set that ends the burst leaves him on its last frame, or goes on where K goes on")
    func keepOnlyAtTheEnd() async throws {
        for goesOn in [false, true] {
            let m = try BurstCrossingTests.model()
            let name = "keepOnlyAtTheEnd.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            m.settings = SettingsStore(defaults: defaults)
            m.settings.afterLastFrameGoesOn = goesOn
            let start = m.burstIndex
            let n = m.frames.count
            m.compareSelection = [m.frames[n - 2], m.frames[n - 1]]
            await ViewerTests.press(m, .compare)
            for stem in m.compareSelection { m.didDisplayTile(stem) }
            await ViewerTests.press(m, .keepOnly)
            await BurstCrossingTests.settle()
            #expect(m.mode == .single)
            if goesOn {
                #expect(m.burstIndex == start + 1, "K goes on from here, and so does ⇧K")
                #expect(m.bursts[start].seen)
            } else {
                #expect(m.burstIndex == start)
                #expect(m.frameIndex == n - 1)
                #expect(!m.bursts[start].seen, "nothing recorded the burst as been through")
            }
        }
    }

    @Test("⇧K on a ⌘-click set with a gap lands on the first frame in the gap he has not marked, and past the set once it is marked")
    func keepOnlyWithAGap() async throws {
        let m = try BurstCrossingTests.model()
        m.settings = LookThroughTests.settings(goesOn: false)
        let i = try #require(m.bursts.firstIndex { $0.frames.count >= 6 })
        m.goToBurst(i)
        let f = m.frames
        try #require([1, 2, 4].allSatisfy { m.session.rows[f[$0]].map(VerdictValue.his) == .unmarked })

        m.compareSelection = [f[0], f[3]]
        await ViewerTests.press(m, .compare)
        for stem in m.compareSelection { m.didDisplayTile(stem) }
        await ViewerTests.press(m, .keepOnly)
        await BurstCrossingTests.settle()
        #expect(m.mode == .single)
        #expect(m.frameIndex == 1, "⇧K went past frames 1 and 2, which he has not judged")

        // The gap marked, the same set lands after it, as a stack does.
        for _ in 0..<2 {
            ViewerTests.show(m)
            await ViewerTests.press(m, .keep)
        }
        await m.allSettled()
        #expect(m.frameIndex == 3)
        m.compareSelection = [f[0], f[3]]
        await ViewerTests.press(m, .compare)
        for stem in m.compareSelection { m.didDisplayTile(stem) }
        await ViewerTests.press(m, .keepOnly)
        await BurstCrossingTests.settle()
        #expect(m.frameIndex == 4)
    }

    @Test("a ⌘-click set is what C opens, and it is not called similar")
    func chosenSet() async throws {
        let m = try ViewerTests.model()
        let pick = [m.frames[0], m.frames[m.frames.count - 1]]
        m.compareSelection = pick
        #expect(m.canCompare)
        await ViewerTests.press(m, .compare)
        #expect(m.mode == .compare)
        #expect(m.compareSelection == pick, "C threw the ⌘-click set away")
        #expect(!m.comparingAStack)
    }

    @Test("a plain click elsewhere puts down a ⌘-click set, so C opens the stack he is standing in")
    func plainClickDropsTheSet() async throws {
        let m = try ViewerTests.model()
        let stack = try #require(m.currentStack?.frames)
        let elsewhere = Array(m.frames.filter { !stack.contains($0) }.suffix(2))
        m.compareSelection = elsewhere
        m.goToFrame(try #require(m.frames.firstIndex(of: stack[1])))
        #expect(m.compareSelection.isEmpty)
        await ViewerTests.press(m, .compare)
        #expect(m.compareSelection == stack, "C opened a set he had clicked past")
        #expect(m.compareFocus == stack[1])
    }

    @Test("Esc with nothing else to leave puts down a ⌘-click set")
    func escDropsTheSet() async throws {
        let m = try ViewerTests.model()
        m.compareSelection = [m.frames[0], m.frames[m.frames.count - 1]]
        #expect(m.key(KeyMap.Press(key: .escape)))
        await ViewerTests.press(m, .fit)
        #expect(m.compareSelection.isEmpty)
        #expect(m.mode == .single)
    }

    @Test("a ⌘-click in the strip builds the set, and a plain click there puts it down")
    func stripDropsTheSet() throws {
        let m = try ViewerTests.model()
        let strip = FilmstripView(model: m)
        strip.frame = NSRect(x: 0, y: 0, width: 1100, height: 96)
        strip.refresh()
        m.goToFrame(0)
        strip.press(2, clicks: 1, modifiers: .command)
        #expect(m.compareSelection == [m.frames[0], m.frames[2]])
        strip.press(3, clicks: 1, modifiers: [])
        #expect(m.compareSelection.isEmpty,
                "the next ⌘-click would have built a set out of the one he put down")
        #expect(m.frameIndex == 3)
    }

    @Test("past the stack the invitation has gone and C offers nothing; inside it C opens it and C again goes back")
    func invitation() async throws {
        let m = try ViewerTests.model()
        let stack = try #require(m.currentStack?.frames)
        #expect(m.stackInvitation == stack.count)
        m.goToFrame(m.frames.count - 1)
        #expect(m.currentStack == nil || m.currentStack?.frames != stack)
        #expect(m.stackInvitation == nil, "past the stack its C could only bounce")
        #expect(!m.canCompare)
        m.goToFrame(try #require(m.frames.firstIndex(of: stack[0])))
        await ViewerTests.press(m, .compare)
        #expect(m.mode == .compare)
        #expect(m.compareSelection == stack)
        #expect(m.comparingAStack)
        // And C again goes back.
        await ViewerTests.press(m, .compare)
        #expect(m.mode == .single)
    }

    @Test("a click on a tile moves the frame and the bar, not only the ring")
    func clickTile() async throws {
        let m = try ViewerTests.model()
        await ViewerTests.press(m, .compare)
        let third = m.compareSelection[2]
        m.focusTile(third)
        #expect(m.compareFocus == third)
        #expect(m.currentStem == third)
        #expect(m.positionText == Strings.LightTable.comparedPosition(3, m.compareSelection.count))
    }
}
