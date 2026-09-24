import Foundation
import Testing
@testable import PipelineKit

/// App-wide habits are asked once, not once per visit or once per shoot.
@Suite("Choices he makes once", .serialized)
@MainActor
struct RememberedChoicesTests {

    static func store() -> (SettingsStore, () -> Void) {
        let name = "remembered-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (SettingsStore(defaults: d), { d.removePersistentDomain(forName: name) })
    }

    @Test("how a copy is checked and whether the card is ejected come back as he left them")
    func copying() {
        let (s, done) = Self.store(); defer { done() }
        #expect(StepsModel.VerifyChoice(settings: s) == .whileCopying)
        #expect(s.ejectAfterCopying == false)
        s.copyCheck = StepsModel.VerifyChoice.againAtTheEnd.rawValue
        s.ejectAfterCopying = true
        #expect(StepsModel.VerifyChoice(settings: s) == .againAtTheEnd)
        #expect(s.ejectAfterCopying)
        // A value from some other build is not a choice.
        s.copyCheck = "sometimes"
        #expect(StepsModel.VerifyChoice(settings: s) == .whileCopying)
    }

    @Test("Don't check is for one card: the next copy checks again, the way he last chose to")
    func dontCheckIsNotCarried() {
        let (s, done) = Self.store(); defer { done() }
        StepsModel.VerifyChoice.dont.remember(in: s)
        #expect(StepsModel.VerifyChoice(settings: s) == .whileCopying)
        StepsModel.VerifyChoice.againAtTheEnd.remember(in: s)
        StepsModel.VerifyChoice.dont.remember(in: s)
        #expect(StepsModel.VerifyChoice(settings: s) == .againAtTheEnd)
        // Stored by an earlier build of this branch, it is still not taken up.
        s.copyCheck = StepsModel.VerifyChoice.dont.rawValue
        #expect(StepsModel.VerifyChoice(settings: s) == .whileCopying)
    }

    @Test("a new shoot starts on the editor he chose, and on DxO when he chose none it knows")
    func editor() {
        let (s, done) = Self.store(); defer { done() }
        #expect(StepsModel.defaultEditor(s) == "dxo")
        s.editor = "darktable"
        #expect(StepsModel.defaultEditor(s) == "darktable")
        s.editor = "/Applications/Something.app"
        #expect(StepsModel.defaultEditor(s) == "dxo")
    }
}
