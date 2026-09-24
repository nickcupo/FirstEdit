import Testing
@testable import PipelineKit

/// The engine-down page showed him a Python traceback as its explanation.
@Suite("The engine-down page explains in sentences and keeps Python under Details")
@MainActor
struct EngineDownTests {

    @Test("the app's own sentence is shown; a traceback or an exception's line goes under Details")
    func sentence() {
        for own in [Strings.Engine.exited(1), Strings.Engine.noPort] {
            let f = EngineFailure(reason: own)
            #expect(f.sentence == own)
            #expect(f.detail == nil)
            #expect(f.restartHelps)
        }
        let missing = EngineFailure(reason: "Traceback (most recent call last): … ModuleNotFoundError: No module named 'cv2'")
        #expect(missing.sentence == Strings.Engine.missingPart)
        #expect(!missing.restartHelps)
        let crashed = EngineFailure(reason: "KeyError: 'rating'\nline two")
        #expect(crashed.sentence == Strings.Engine.stoppedOnAnError)
        #expect(crashed.detail == "KeyError: 'rating'\nline two")
        #expect(EngineFailure(reason: "").sentence == nil)
    }
}
