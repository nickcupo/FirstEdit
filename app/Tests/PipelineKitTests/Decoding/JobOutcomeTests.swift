import Testing
import Foundation
@testable import PipelineKit

// Refused and Failed are different things, drawn differently: a refusal is
// the engine saying no on purpose, in the ordinary text colour; a failure is
// a crash, in the alarm colour. Every real traceback ends on the exception's
// own line, so reading the last line as the engine's sentence drew every
// crash as a calm grey "Refused: MemoryError".

@Suite("How a job ended")
struct JobOutcomeTests {

    static func ended(code: Int, log: String) -> Job {
        Job(running: false, stopped: false, id: 3, kind: "cull", shoot: "2026-09-19",
            title: "culling 2026-09-19", log: log, code: code)
    }

    @Test("a Python crash is Failed, not Refused")
    func aTracebackIsAFailure() {
        let j = Self.ended(code: 1, log: """
        $ pipeline/cull.py 2026-09-19
        looking at faces: 612 of 1,558 frames
        Traceback (most recent call last):
          File "pipeline/cull.py", line 900, in <module>
            main()
          File "pipeline/cull.py", line 880, in main
            decode(frames)
        MemoryError
        """)
        #expect(j.crashed)
        #expect(j.outcome == .failed)
        #expect(j.refusalSentence == nil)
    }

    @Test("an exception line alone is a crash, with or without its message")
    func anExceptionLineIsAFailure() {
        for last in ["MemoryError", "OSError: [Errno 28] No space left on device",
                     "json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)"] {
            let j = Self.ended(code: 1, log: "$ pipeline/presets.py 2026-09-19\n\(last)")
            #expect(j.outcome == .failed, "\(last)")
            #expect(j.refusalSentence == nil)
        }
    }

    @Test("a job killed by a signal failed, even though it ended on a progress line")
    func aKilledJobFailed() {
        let j = Self.ended(code: -9, log: "$ pipeline/cull.py 2026-09-19\nlooking at faces: 612 of 1,558 frames")
        #expect(j.crashed)
        #expect(j.outcome == .failed)
        #expect(j.refusalSentence == nil)
        #expect(Self.ended(code: 137, log: "$ x\nlooking at faces").outcome == .failed)
    }

    @Test("the engine's own sentence is still a refusal")
    func aSentenceIsARefusal() {
        // `SystemExit('sentence')`: the sentence and nothing else.
        let j = Self.ended(code: 1, log: """
        $ pipeline/presets.py 2026-09-19
        No editor found on this Mac: install DxO PhotoLab, then write the presets again.
        """)
        #expect(!j.crashed)
        #expect(j.outcome == .refused)
        #expect(j.refusalSentence == "No editor found on this Mac: install DxO PhotoLab, then write the presets again.")
    }

    @Test("a traceback from an earlier command in the same job is not this one's ending")
    func onlyTheLastCommandCounts() {
        let j = Self.ended(code: 1, log: """
        $ pipeline/first.py
        Traceback (most recent call last):
          File "x", line 1
        ValueError: bad
        $ pipeline/cull.py 2026-09-19
        2026-09-19 has no photographs in it.
        """)
        #expect(j.outcome == .refused)
        #expect(j.refusalSentence == "2026-09-19 has no photographs in it.")
    }

    @Test("a job that exited with nothing to say failed")
    func silenceIsAFailure() {
        #expect(Self.ended(code: 2, log: "$ pipeline/cull.py 2026-09-19").outcome == .failed)
        #expect(Self.ended(code: 0, log: "$ pipeline/cull.py 2026-09-19").outcome == .done)
    }

    @Test("the step's page says a job failed, stopped or refused, and nothing after one that finished")
    @MainActor func theStepSaysHowItEnded() {
        // A crash had no line at all beside Cull It: the page went back to
        // "About a minute." as if he had never pressed it.
        #expect(JobEndedNote.says(Self.ended(code: 1, log: "$ pipeline/cull.py x\nMemoryError")))
        #expect(JobEndedNote.says(Self.ended(code: -9, log: "$ pipeline/cull.py x")))
        #expect(JobEndedNote.says(Self.ended(code: 1, log: "$ pipeline/presets.py x\nNo editor found on this Mac.")))
        #expect(JobEndedNote.says(Job(running: false, stopped: true, kind: "cull", code: -15)))
        #expect(!JobEndedNote.says(Self.ended(code: 0, log: "$ pipeline/presets.py x\n12 presets written")))
        #expect(!JobEndedNote.says(Job(running: true, stopped: false, kind: "cull")))
        #expect(JobEndedNote(nil) == nil)
    }

    @Test("sentences are not mistaken for exception names")
    func sentencesAreNotExceptions() {
        #expect(!Job.isExceptionLine("The cull found an Error in 3 frames"))
        #expect(!Job.isExceptionLine("Nothing to do: every frame has a verdict"))
        #expect(Job.isExceptionLine("cv2.error: OpenCV(4.10.0) error: (-215:Assertion failed)"))
        #expect(Job.isExceptionLine("KeyError: 'id'"))
        #expect(Job.isExceptionLine("subprocess.CalledProcessError: Command '[...]' returned 1"))
    }
}
