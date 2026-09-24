import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// D, then a digit: the reason belongs to the frame he dropped (DESIGN.md
/// §2.5.3), which Drop has already moved him off.
@Suite("A reason after D goes on the frame he dropped", .serialized)
@MainActor
struct ReasonAfterDropTests {

    @Test("4 pressed while the strip is up labels the dropped frame and leaves the next one alone")
    func labelsTheDroppedFrame() async throws {
        let log = WriteLog()
        let m = try BurstCrossingTests.model(log: log)
        m.goToFrame(0)
        let dropped = try #require(m.currentStem)
        ViewerTests.show(m)

        await ViewerTests.press(m, .drop)
        // Held up for the test: its three seconds are wall time, and a full
        // run on a busy machine can spend them between two presses.
        m.reasonStripUntil = Date().addingTimeInterval(60)
        let next = try #require(m.currentStem)
        #expect(next != dropped, "Drop moves on")
        #expect(m.reasonTarget() == dropped)

        await ViewerTests.press(m, .reason(4))
        #expect(m.session.rows[dropped]?.label == DropReason.forKey(4)?.rawValue,
                "the frame he dropped got no reason")
        #expect(m.session.rows[next]?.label.isEmpty == true, "the next frame was labelled")
        #expect(VerdictValue.his(m.session.rows[next]!) == .unmarked,
                "the next frame, which he had not judged, was put out")
        #expect(m.reasonTarget() == nil, "the question was answered")
    }

    @Test("once the strip has gone, a digit is about the frame on screen again")
    func afterTheStrip() async throws {
        let m = try BurstCrossingTests.model()
        m.goToFrame(0)
        ViewerTests.show(m)
        await ViewerTests.press(m, .drop)
        let here = try #require(m.currentStem)
        m.reasonStripUntil = Date().addingTimeInterval(-1)
        ViewerTests.show(m)
        await ViewerTests.press(m, .reason(4))
        #expect(m.session.rows[here]?.label == DropReason.forKey(4)?.rawValue)
    }

    @Test("a Keep after D closes the question, so a digit after it is not about the dropped frame")
    func keepCloses() async throws {
        let m = try BurstCrossingTests.model()
        m.goToFrame(0)
        ViewerTests.show(m)
        await ViewerTests.press(m, .drop)
        ViewerTests.show(m)
        await ViewerTests.press(m, .keep)
        #expect(m.reasonTarget() == nil)
    }
}
