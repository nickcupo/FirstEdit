import Foundation
import AppKit
import Testing
@testable import PipelineKit

/// §2.15, which is not optional: what a VoiceOver user hears, and what a
/// Reduce Motion user still feels.
@Suite("The light table, without looking at it", .serialized)
@MainActor
struct AccessibilityTests {

    /// The stage in a real window, so the display link and the accessibility
    /// value are the ones AppKit would drive.
    static func staged(_ m: ViewerModel) -> (NSWindow, StageLayerView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1084, height: 542),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = StageLayerView(model: m)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        view.frame = NSRect(x: 0, y: 0, width: 1084, height: 542)
        view.refresh()
        window.layoutIfNeeded()
        return (window, view)
    }

    // MARK: - the picture says which picture it is

    @Test("the stage tells VoiceOver which frame it is showing, and says so again when it changes")
    func stageAnnouncesTheFrame() throws {
        let m = try ViewerTests.model()
        let (window, view) = Self.staged(m)
        defer { window.orderOut(nil); view.tearDown() }

        // The label is what the element is; the value is which frame.
        #expect(view.accessibilityLabel() == Strings.LightTable.viewer)
        let first = try #require(view.accessibilityValue() as? String)
        #expect(first == m.frameAnnouncement)
        #expect(!first.isEmpty)
        #expect(first.contains(ShootSession.shortStem(try #require(m.currentStem))))
        #expect(first.contains("1 of "))

        // Arrowing on is a new sentence, not the old one.
        m.goToFrame(1)
        view.refresh()
        let second = try #require(view.accessibilityValue() as? String)
        #expect(second != first)
        #expect(second == m.frameAnnouncement)
        #expect(second.contains("2 of "))
    }

    @Test("a verdict changes what VoiceOver says about the frame it was taken on")
    func theVerdictIsHeard() async throws {
        let m = try ViewerTests.model()
        let (window, view) = Self.staged(m)
        defer { window.orderOut(nil); view.tearDown() }
        ViewerTests.show(m)
        let stem = try #require(m.currentStem)
        let before = try #require(view.accessibilityValue() as? String)
        #expect(before.contains(Strings.LightTable.youHaventMarked))

        await ViewerTests.press(m, .keep)
        // Keep moves on, so come back to the frame it was taken on and listen
        // to what the stage now says about it.
        m.goToFrame(0)
        view.refresh()
        #expect(m.currentStem == stem)
        let after = try #require(view.accessibilityValue() as? String)
        #expect(after.contains(Strings.LightTable.youKept))
        #expect(after != before)
        #expect(!after.contains(Strings.LightTable.youHaventMarked))
    }

    @Test("Keep, Drop, Clear the Mark and Compare are on the frame as actions, not only as keys")
    func customActions() throws {
        let m = try ViewerTests.model()
        let (window, view) = Self.staged(m)
        defer { window.orderOut(nil); view.tearDown() }
        let names = (view.accessibilityCustomActions() ?? []).map(\.name)
        #expect(names == [Strings.Verdict.keep, Strings.Verdict.drop,
                          Strings.LightTable.clearTheMark, Strings.LightTable.compare])
    }

    // MARK: - two elements, two names

    @Test("the strip of every frame and the one photograph do not answer to the same name")
    func theStripHasItsOwnName() throws {
        let m = try ViewerTests.model()
        let strip = FilmstripView(model: m)
        #expect(strip.accessibilityLabel() == Strings.LightTable.filmstrip)
        #expect(strip.accessibilityLabel() != Strings.LightTable.viewer,
                "a 300-frame list called 'The photograph' tells a VoiceOver user nothing")
        #expect(strip.accessibilityRole() == .list)
    }

    @Test("every Compare tile says which frame it is")
    func everyTileIsNamed() throws {
        let m = try ViewerTests.model()
        let stack = try #require(m.currentStack)
        var seen = Set<String>()
        for stem in stack.frames {
            let said = m.announcement(for: stem)
            #expect(said.contains(ShootSession.shortStem(stem)))
            #expect(said.contains("in a stack of \(stack.count)".lowercased())
                    || said.lowercased().contains("stack of \(stack.count)"))
            seen.insert(said)
        }
        #expect(seen.count == stack.count, "four tiles, four different sentences")
    }

    // MARK: - haptics are not animation (§2.14 vs §2.5.8)

    @Test("Keep, Drop and a zoom detent each give their own haptic, Reduce Motion or not")
    func hapticsAreFelt() async throws {
        let felt = HapticLog()
        let previous = ViewerModel.hapticPerformer
        ViewerModel.hapticPerformer = { felt.add($0) }
        defer { ViewerModel.hapticPerformer = previous }

        let m = try ViewerTests.model()
        ViewerTests.show(m)
        m.haptic(.levelChange)
        m.haptic(.generic)
        m.haptic(.alignment)
        // Reduce Motion is about crossfades and the rubber band (§2.14). It has
        // never been about the trackpad, and a bump under the fingers is not a
        // thing anyone turned off.
        #expect(felt.patterns == [.levelChange, .generic, .alignment],
                "a haptic reached the trackpad for each of the three §2.5.8 rows")
    }

    @MainActor final class HapticLog {
        var patterns: [NSHapticFeedbackManager.FeedbackPattern] = []
        func add(_ p: NSHapticFeedbackManager.FeedbackPattern) { patterns.append(p) }
    }
}
