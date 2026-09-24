import Foundation
import Testing
@testable import PipelineKit

/// The Finished section was collapsed at every launch, so a library whose
/// shoots were all finished showed a lone heading over nothing, and his choice
/// to keep it open was forgotten.
@Suite("The Finished section opens when there is nothing else, and remembers him", .serialized)
@MainActor
struct FinishedSectionTests {

    @Test("open when nothing is in progress, closed beside work in progress, until he chooses")
    func defaults() {
        let nav = Navigation(selection: .allShoots)
        #expect(nav.finishedOpen(nothingInProgress: true))
        #expect(!nav.finishedOpen(nothingInProgress: false))
        nav.chooseFinished(false)
        #expect(!nav.finishedOpen(nothingInProgress: true))
        nav.chooseFinished(true)
        #expect(nav.finishedOpen(nothingInProgress: false))
    }

    @Test("his choice outlives the launch")
    func remembered() {
        let (s, done) = LastPlaceTests.store(); defer { done() }
        func launch() -> AppModel {
            AppModel(engine: EngineHost(bundle: .main, support: URL(fileURLWithPath: "/tmp/nowhere"), settings: s),
                     memory: s)
        }
        let first = launch()
        #expect(s.finishedExpanded == nil)
        first.navigation.chooseFinished(false)
        #expect(s.finishedExpanded == false)
        let second = launch()
        #expect(!second.navigation.finishedOpen(nothingInProgress: true))
    }
}
