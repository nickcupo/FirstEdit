import Foundation
import AppKit
import SwiftUI
import Testing
@testable import PipelineKit

/// Decision 4: on a kept frame, pressing a reason's digit twice puts it out
/// (DESIGN.md §2.5.3). Return and Esc still leave it kept.
@Suite("A reason on a kept frame, answered from the keyboard", .serialized)
@MainActor
struct ReasonOnKeptTests {

    /// A frame he kept, on screen, with the question a 4 on it asks.
    static func asked(log: WriteLog = WriteLog()) async throws -> (ViewerModel, String) {
        let m = try BurstCrossingTests.model(log: log)
        ViewerTests.show(m)
        let stem = try #require(m.currentStem)
        await ViewerTests.press(m, .keep)
        await m.allSettled()
        m.goToFrame(try #require(m.frames.firstIndex(of: stem)))
        ViewerTests.show(m)
        #expect(m.session.rows[stem].map(VerdictValue.his) == .kept)
        await ViewerTests.press(m, .reason(DropReason.blur.key))
        #expect(m.reasonNeedingConfirmation == .blur, "a reason on a kept frame did not ask")
        return (m, stem)
    }

    static func sheet(_ m: ViewerModel) -> NSWindow {
        let w = KeyPathTests.window()
        let host = NSHostingView(rootView: ReasonOnKeptSheet(model: m, reason: .blur))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
        w.contentView = host
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }
        return w
    }

    static let fourCode: UInt16 = 21

    @Test("the same digit again puts it out, with its reason")
    func secondDigitPutsItOut() async throws {
        let (m, stem) = try await Self.asked()
        let w = Self.sheet(m)
        defer { w.close() }
        let four = KeyPathTests.key("4", keyCode: Self.fourCode, in: w)
        m.currentEvent = { four }
        #expect(w.performKeyEquivalent(with: four), "4 did not reach Put It Out")
        await KeyPathTests.settle()
        await m.allSettled()
        let row = try #require(m.session.rows[stem])
        #expect(VerdictValue.his(row) == .out)
        #expect(row.label == DropReason.blur.rawValue)
        #expect(m.reasonNeedingConfirmation == nil)
    }

    @Test("the digit that asked, still held down, is not the answer")
    func heldDigitIsNotAnAnswer() async throws {
        let (m, stem) = try await Self.asked()
        let w = Self.sheet(m)
        defer { w.close() }
        let held = KeyPathTests.key("4", keyCode: Self.fourCode, in: w, repeat: true)
        m.currentEvent = { held }
        _ = w.performKeyEquivalent(with: held)
        await KeyPathTests.settle()
        #expect(m.session.rows[stem].map(VerdictValue.his) == .kept, "a held 4 put a kept frame out")
        #expect(m.reasonNeedingConfirmation == .blur, "the question went away unanswered")
    }

    @Test("another digit does not answer it; Return leaves it kept")
    func otherKeysLeaveItKept() async throws {
        let (m, stem) = try await Self.asked()
        let w = Self.sheet(m)
        defer { w.close() }
        let five = KeyPathTests.key("5", keyCode: 23, in: w)
        m.currentEvent = { five }
        #expect(!w.performKeyEquivalent(with: five))
        await KeyPathTests.settle()
        #expect(m.session.rows[stem].map(VerdictValue.his) == .kept)

        let enter = KeyPathTests.key("\r", keyCode: 36, in: w)
        m.currentEvent = { enter }
        #expect(w.performKeyEquivalent(with: enter))
        await KeyPathTests.settle()
        #expect(m.reasonNeedingConfirmation == nil)
        #expect(m.session.rows[stem].map(VerdictValue.his) == .kept)
    }

    @Test("a click is an answer; a repeat of a key is not")
    func whatCountsAsAnAnswer() {
        #expect(ReasonOnKeptSheet.isAnAnswer(nil))
        let w = KeyPathTests.window()
        defer { w.close() }
        #expect(ReasonOnKeptSheet.isAnAnswer(KeyPathTests.key("4", keyCode: Self.fourCode, in: w)))
        #expect(!ReasonOnKeptSheet.isAnAnswer(KeyPathTests.key("4", keyCode: Self.fourCode, in: w, repeat: true)))
        #expect(Strings.LightTable.reasonOnKeptAgain(4).contains("4"))
    }
}
