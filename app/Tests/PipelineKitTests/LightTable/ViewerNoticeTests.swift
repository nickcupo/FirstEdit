import Foundation
import Testing
@testable import PipelineKit

/// §2.5.2: one line at a time over the bottom of the photograph. On the last
/// frame after a D the invitation, the strip and the end-of-burst line all
/// stood there together, and a refusal was drawn across the middle of the end
/// line.
@Suite("The one notice over the photograph", .serialized)
@MainActor
struct ViewerNoticeTests {

    @Test("a refusal first, then the end of the burst, then the invitation — before or on the stack it names")
    func mostPressingFirst() throws {
        let m = try ViewerTests.model()
        let stack = try #require(m.stacks.max { $0.count < $1.count })
        #expect(stack.count > 3)
        #expect(m.stackInvitation == stack.count, "entering a burst with a stack of four invites Compare")

        m.goToFrame(stack.start)
        #expect(ViewerNotice.current(m) == .invitation(stack.count))

        // A frame past the stack: he has walked by it, so nothing invites it.
        let past = try #require(m.frames.indices.first { i in
            i >= stack.range.upperBound && i != m.frames.count - 1
        })
        m.goToFrame(past)
        #expect(ViewerNotice.current(m) == nil)

        m.goToFrame(m.frames.count - 1)
        guard case .endOfBurst = ViewerNotice.current(m) else {
            Issue.record("the last frame shows the end of the burst"); return
        }

        m.session.refusals.set(.verdict, "Still opening this frame.")
        #expect(ViewerNotice.current(m) == .refusal, "and a refusal goes over it, not across it")
        m.session.refusals.clear(.verdict)
    }

    /// Before the stack the invitation still does what it says: C goes to
    /// the stack's top frame and opens it. The test above could not show
    /// this, because its stack starts on the burst's first frame.
    @Test("before the stack it names the invitation is up as well, and C is live")
    func invitationBeforeTheStack() throws {
        let m = try KeysTests.model(stackAt: 2)
        let stack = try #require(m.stacks.max { $0.count < $1.count })
        try #require(stack.range.lowerBound > 0, "a frame before the stack to stand on")
        m.goToFrame(0)
        #expect(ViewerNotice.current(m) == .invitation(stack.count))
        #expect(m.canCompare, "the button, the menu row and the segment are live for it")
    }

    /// The strip after D is one of the notices too: on the last frame it
    /// stood over the end-of-burst line, which is where D had just left him.
    @Test("the strip after D stands alone for its three seconds, and the line under it comes back after")
    func theStripIsOneOfThem() async throws {
        let m = try ViewerTests.model()
        try #require(m.frames.count >= 2)
        // D on the frame before the last, which moves him onto the last.
        m.goToFrame(m.frames.count - 2)
        ViewerTests.show(m)
        await ViewerTests.press(m, .drop)
        #expect(m.isLastFrameOfBurst)
        let now = Date()
        m.reasonStripUntil = now.addingTimeInterval(3)
        #expect(ViewerNotice.current(m, at: now) == .reason)
        guard case .endOfBurst = ViewerNotice.current(m, at: now.addingTimeInterval(3.1)) else {
            Issue.record("the end of the burst comes back when the strip goes"); return
        }
        m.session.refusals.set(.verdict, "Still opening this frame.")
        #expect(ViewerNotice.current(m, at: now) == .refusal, "a refusal still comes first")
        m.session.refusals.clear(.verdict)
        m.reasonStripUntil = nil
    }

    /// A refusal is cleared only by its owner (§7.7), and moving is not its
    /// owner. Ranked first wherever he went, a K refused on one frame hid the
    /// end-of-burst line on every frame after it, and on the shoot's last
    /// frame the only Continue to Presets on the screen.
    @Test("a refusal raised on another frame gives way to the end of the burst, and still outranks the invitation")
    func aRefusalLeftBehind() async throws {
        let m = try ViewerTests.model()
        let stack = try #require(m.stacks.max { $0.count < $1.count })
        m.goToFrame(0)
        // A refusal the engine gave about this frame. "Still opening this
        // frame." is not one: moving is what answers it, so it goes with him.
        m.session.refusals.set(.verdict, "The engine could not write that.", at: m.currentStem)
        #expect(m.session.refusals.place(.verdict) == m.currentStem, "it says which frame it was about")
        #expect(ViewerNotice.current(m) == .refusal, "on that frame it comes first")

        m.goToFrame(m.frames.count - 1)
        #expect(!ViewerNotice.refusalIsHere(m))
        guard case .endOfBurst = ViewerNotice.current(m) else {
            Issue.record("on the last frame the end-of-burst line is what he sees"); return
        }
        #expect(m.session.refusals[.verdict] != nil, "and moving did not clear it: that is its owner's")

        m.goToFrame(stack.start)
        if stack.start != 0 {
            #expect(ViewerNotice.current(m) == .refusal, "left standing, it still outranks the invitation")
        }

        m.goToFrame(0)
        #expect(ViewerNotice.current(m) == .refusal, "back on its own frame it comes first again")
        m.session.refusals.clear(.verdict)
        #expect(m.session.refusals.place(.verdict) == nil, "cleared, it is cleared from everywhere")
    }

    @Test("on the shoot's last frame a refusal left behind does not hide Continue to Presets")
    func continueStaysOnTheLastFrame() throws {
        let m = try ViewerTests.model()
        m.goToBurst(m.bursts.count - 1)
        m.goToFrame(0)
        m.session.refusals.set(.verdict, Strings.Verdict.stillOpening, at: m.currentStem)
        m.goToFrame(m.frames.count - 1)
        if m.frames.count > 1 {
            let line = try #require(m.endOfBurstLine)
            #expect(ViewerNotice.current(m) == .endOfBurst(line))
        }
        m.session.refusals.set(.verdict, Strings.Verdict.stillOpening, at: m.currentStem)
        #expect(ViewerNotice.current(m) == .refusal, "one about the last frame itself still comes first")
        m.session.refusals.clear(.verdict)
    }
}
