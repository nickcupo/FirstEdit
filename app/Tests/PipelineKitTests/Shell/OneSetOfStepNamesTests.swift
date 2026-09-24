import Foundation
import Testing
@testable import PipelineKit

/// The seven base steps have one set of names (DESIGN.md §2.4): the engine's
/// sentence-case labels, with Finish called "Done", showed once a shoot was
/// opened and the app's own before it, so the last step changed name the
/// moment he opened a shoot.
@Suite("The steps go by one set of names")
@MainActor
struct OneSetOfStepNamesTests {

    @Test("an open shoot's base steps carry the app's names, not the engine's")
    func openShoot() throws {
        let r = try Fixture.decode(ShootResponse.self, "shoot-bursts")
        // The engine now sends the app's names as well (studio.py's step
        // labels); whatever it sends, the app's own are the ones shown.
        let session = ShootSession(response: r, ext: nil, client: LiveCountsTests.client(),
                                   pump: ImagePump(budget: .base, loader: { _ in Data() }),
                                   queue: VerdictQueue(sender: { _ in .failure(.offline) }))
        for step in session.steps where step.source == .base {
            #expect(step.label == Fallbacks.baseLabel(step.id))
        }
        #expect(session.steps.first { $0.id == "done" }?.label == Strings.Steps.done)
        // What the engine says about the step is kept.
        let engineDone = try #require(r.steps.first { $0.id == "done" })
        let appDone = try #require(session.steps.first { $0.id == "done" })
        #expect(appDone.enabled == engineDone.enabled && appDone.done == engineDone.done)
    }

    @Test("a shoot opened before the library's list is renamed the extension's way when the list lands")
    func openedEarly() throws {
        let r = try Fixture.decode(ShootResponse.self, "shoot-bursts")
        let session = ShootSession(response: r, ext: nil, client: LiveCountsTests.client(),
                                   pump: ImagePump(budget: .base, loader: { _ in Data() }),
                                   queue: VerdictQueue(sender: { _ in .failure(.offline) }))
        #expect(session.steps.first { $0.id == "done" }?.label == Strings.Steps.done)
        let lib = Library(preview: try LastPlaceTests.shoots())
        lib.adopt(session)
        let withExt = try ShootsResponse(fields: Fields([
            "shoots": .array([]), "ready": .bool(true),
            "ext": .object(["kind": .string("x"), "labels": .object(["done": .string("Wrap Up")])]),
        ]))
        lib.take(withExt)
        #expect(session.steps.first { $0.id == "done" }?.label == "Wrap Up")
        // Every other base step keeps the app's name.
        #expect(session.steps.first { $0.id == "cull" }?.label == Fallbacks.baseLabel("cull"))
    }

    @Test("an extension's own step keeps its label, and a base step it names is named its way")
    func extensionNames() {
        let ext = ExtConfig(kind: "", labels: ["done": "Wrap Up"])
        let own = StepState(id: "share", label: "Share It", done: false, enabled: true, source: .extensionProvided)
        #expect(own.namedByTheApp(ext).label == "Share It")
        let done = StepState(id: "done", label: "Done", done: false, enabled: true)
        #expect(done.namedByTheApp(ext).label == "Wrap Up")
        #expect(done.namedByTheApp(nil).label == Strings.Steps.done)
    }
}
