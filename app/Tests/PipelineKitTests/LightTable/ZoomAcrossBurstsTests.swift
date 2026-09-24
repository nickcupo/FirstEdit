import Foundation
import Testing
@testable import PipelineKit

/// Decision 4: a new burst opens at Fit (DESIGN.md §2.5.7). The zoom is held
/// from frame to frame of one burst, and let go on arriving in another.
@Suite("A new burst opens at Fit", .serialized)
@MainActor
struct ZoomAcrossBurstsTests {

    @Test("1:1 is held from frame to frame of one burst")
    func heldInsideABurst() async throws {
        let m = try BurstCrossingTests.model()
        ViewerTests.show(m)
        m.perform(.oneToOne)
        await BurstCrossingTests.settle()
        #expect(m.zoom.state == .factor(1))
        m.perform(.nextFrame)
        await BurstCrossingTests.settle()
        #expect(m.zoom.state == .factor(1), "the focus check was dropped between two frames of one moment")
    }

    @Test("every way into another burst goes back to Fit")
    func everyWayInIsFit() async throws {
        let m = try BurstCrossingTests.model()
        let start = m.burstIndex
        ViewerTests.show(m)

        // N.
        m.perform(.oneToOne)
        m.perform(.nextBurst)
        await BurstCrossingTests.settle()
        #expect(m.burstIndex == start + 1)
        #expect(m.zoom.isFit, "N carried 1:1 into the next burst")

        // P.
        m.perform(.oneToOne)
        m.perform(.previousBurst)
        await BurstCrossingTests.settle()
        #expect(m.burstIndex == start)
        #expect(m.zoom.isFit, "P carried 1:1 into the burst before")

        // ← off the first frame.
        m.goToFrame(0)
        m.perform(.oneToOne)
        m.perform(.previousFrame)
        await BurstCrossingTests.settle()
        if start > 0 { #expect(m.zoom.isFit, "← off the first frame carried 1:1 back") }

        // The scrubber or a cover.
        m.perform(.oneToOne)
        await BurstCrossingTests.settle()
        m.goToBurst(start + 1)
        #expect(m.zoom.isFit, "a jump to another burst carried 1:1 with it")

        // → off the last frame.
        m.goToBurst(start)
        m.goToFrame(m.frames.count - 1)
        ViewerTests.show(m)
        m.perform(.oneToOne)
        m.perform(.nextFrame)
        await BurstCrossingTests.settle()
        #expect(m.burstIndex == start + 1)
        #expect(m.zoom.isFit, "→ off the last frame carried 1:1 into the next burst")
    }
}
