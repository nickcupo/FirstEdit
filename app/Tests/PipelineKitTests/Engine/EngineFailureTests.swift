import Testing
import Foundation
@testable import PipelineKit

// The engine-down view read him a Python traceback in code font, over a
// Restart the Engine that fails the same way every time when a part of the
// app is missing. The reason is read now: a sentence of his, what would fix
// it, and the engine's own words behind Details.

@Suite("Why the engine is down, in his words")
struct EngineFailureTests {

    @Test("a missing module says the app is not whole, and that Restart is not the fix")
    func aMissingModule() {
        let f = EngineFailure(reason: "ModuleNotFoundError: No module named 'cv2'")
        #expect(f.sentence == Strings.Engine.missingPart)
        #expect(f.detail == "ModuleNotFoundError: No module named 'cv2'")
        #expect(!f.restartHelps)
        #expect(f.sentence?.contains("Traceback") == false)
    }

    @Test("no interpreter at all is the same answer, with the system's reason as the detail")
    func noPython() {
        let none = EngineFailure(reason: Strings.Engine.couldNotStart)
        #expect(none.sentence == Strings.Engine.missingPart)
        #expect(none.detail == nil)
        #expect(!none.restartHelps)
        let why = EngineFailure(reason: Strings.Engine.couldNotStart + " The file “python3” doesn’t exist.")
        #expect(why.detail == "The file “python3” doesn’t exist.")
    }

    @Test("the host's own sentences are shown as they are, in the body font, with Restart")
    func ourOwnSentences() {
        for r in [Strings.Engine.noPort, Strings.Engine.exited(1)] {
            let f = EngineFailure(reason: r)
            #expect(f.sentence == r)
            #expect(f.detail == nil)
            #expect(f.restartHelps)
        }
        let nothing = EngineFailure(reason: "")
        #expect(nothing.sentence == nil)
        #expect(nothing.restartHelps)
    }

    @Test("any other last word is behind Details, under a sentence that says Restart usually helps")
    func anError() {
        let f = EngineFailure(reason: "Segmentation fault")
        #expect(f.sentence == Strings.Engine.stoppedOnAnError)
        #expect(f.detail == "Segmentation fault")
        #expect(f.restartHelps)
    }
}
