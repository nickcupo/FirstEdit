import AppKit
import Foundation
import Testing
@testable import PipelineKit

/// The host, without a web view: what it decides before anything loads.
@Suite("The extension host")
@MainActor
struct ExtensionHostTests {

    // MARK: - with no extension installed, none of this runs

    @Test("with no extension installed nothing is registered and no step is added")
    func nothingWithoutAnExtension() throws {
        #expect(ExtensionHostRegistration.register(nil, endpoint: nil).isEmpty)
        #expect(ExtensionHostRegistration.registered.isEmpty)
        #expect(ExtPages.steps(nil).isEmpty)

        let info = try ShootInfo(fields: Fields(["name": .string("s"), "path": .string("/s")]))
        let steps = Fallbacks.listSteps(info, nil)
        #expect(steps.map(\.id) == Fallbacks.baseStepIDs)
        #expect(steps.allSatisfy { $0.source == .base })
        // And an endpoint with no configuration behind it adds nothing either.
        let endpoint = EngineHost.Endpoint(base: URL(string: "http://127.0.0.1:9/")!, key: "k")
        #expect(ExtensionHostRegistration.register(nil, endpoint: endpoint).isEmpty)
    }

    @Test("the whole app model runs with ext == nil and nothing reaches for one")
    func appModelWithoutAnExtension() throws {
        let response = try JSONDecoder().decode(
            ShootsResponse.self, from: Fixture.data("shoots"))
        #expect(response.ext == nil)
        let library = Library(preview: response)
        #expect(library.ext == nil)
        #expect(ExtPages.steps(library.ext).isEmpty)
        for row in library.shoots {
            let steps = Fallbacks.listSteps(canCutReels: row.can_cut_reels, ext: library.ext)
            #expect(steps.allSatisfy { $0.source == .base })
            #expect(steps.allSatisfy { !ExtPages.steps(library.ext).contains($0.id) })
        }
    }

    // MARK: - which address a step's page is at

    @Test("a declared page template is expanded with the shoot, escaped for where it lands")
    func pageTemplates() {
        let engine = URL(string: "http://127.0.0.1:8795/")!
        let config = ExtConfig(kind: "a-kind", steps: ["cull", "a-step", "done"],
                               labels: ["a-step": "A Step"],
                               pages: ["a-step": "http://127.0.0.1:9931/pages/{shoot}/grid?for={shoot}"])
        let url = ExtPages.upstream(step: "a-step", shoot: "2026-09-13 dog",
                                    config: config, engine: engine)
        #expect(url?.absoluteString ==
                "http://127.0.0.1:9931/pages/2026-09-13%20dog/grid?for=2026-09-13%20dog")
        #expect(ExtPages.origin(of: url!).absoluteString == "http://127.0.0.1:9931/")
    }

    @Test("without a page map a declared step falls back to the engine's own route")
    func pageFallback() {
        let engine = URL(string: "http://127.0.0.1:8795/")!
        let config = ExtConfig(kind: "a-kind", steps: ["cull", "a-step", "done"])
        let url = ExtPages.upstream(step: "a-step", shoot: "a shoot", config: config, engine: engine)
        #expect(url?.absoluteString == "http://127.0.0.1:8795/ext/a-step?shoot=a%20shoot")
        // One of the engine's own seven is never the extension's.
        #expect(ExtPages.upstream(step: "cull", shoot: "s", config: config, engine: engine) == nil)
        #expect(ExtPages.upstream(step: "never-declared", shoot: "s", config: config, engine: engine) == nil)
    }

    @Test("a page that names somewhere off this Mac is not served at all")
    func pagesStayLocal() {
        let engine = URL(string: "http://127.0.0.1:8795/")!
        for template in ["https://example.invalid/{shoot}", "file:///etc/passwd",
                         "http://192.168.1.4:9931/{shoot}", "javascript:alert(1)"] {
            let config = ExtConfig(kind: "a-kind", steps: ["a-step"], pages: ["a-step": template])
            #expect(ExtPages.upstream(step: "a-step", shoot: "s", config: config, engine: engine) == nil,
                    "\(template) should not be served")
        }
    }

    @Test("the extension's own steps are the ones that are not the engine's seven")
    func declaredSteps() {
        let config = ExtConfig(kind: "a-kind",
                               steps: ["ingest", "cull", "a-step", "done"],
                               every: ["another-step", "cull"],
                               pages: ["a-step": "/a", "a-third-step": "/c"])
        #expect(ExtPages.steps(config) == ["a-step", "another-step", "a-third-step"])
        #expect(ExtPages.claims(step: "cull", config: config) == false)
        #expect(ExtPages.claims(step: "a-third-step", config: config))
    }

    // MARK: - the custom scheme

    @Test("the scheme keeps the path and query and swaps only the origin")
    func schemeURLs() {
        let origin = URL(string: "http://127.0.0.1:9931/")!
        let page = URL(string: "http://127.0.0.1:9931/pages/a%20shoot/grid?for=a%20shoot#top")!
        let address = ExtSchemeHandler.schemeURL(for: page)
        #expect(address?.scheme == "pipeline-ext")
        #expect(address?.host == "page")
        #expect(address?.port == nil)
        #expect(address?.path == "/pages/a shoot/grid")

        // A subresource resolves against that address exactly as it would
        // upstream — relative, root-relative and same-origin absolute alike.
        for (asked, expected) in [
            ("look.css", "http://127.0.0.1:9931/pages/a%20shoot/look.css"),
            ("/deeper/picture.svg", "http://127.0.0.1:9931/deeper/picture.svg"),
            ("../up.js", "http://127.0.0.1:9931/pages/up.js"),
            ("pipeline-ext://page/x.json?a=1", "http://127.0.0.1:9931/x.json?a=1"),
        ] {
            let sub = URL(string: asked, relativeTo: address!)!
            let back = ExtSchemeHandler.upstreamURL(for: sub.absoluteURL, origin: origin)
            #expect(back?.absoluteString == expected, "\(asked)")
        }
    }

    @Test("anything that is not this handler's is refused rather than proxied")
    func schemeRefusals() throws {
        let origin = URL(string: "http://127.0.0.1:9931/")!
        #expect(ExtSchemeHandler.upstreamURL(for: URL(string: "https://example.invalid/x")!, origin: origin) == nil)
        #expect(ExtSchemeHandler.upstreamURL(for: URL(string: "pipeline-ext://elsewhere/x")!, origin: origin) == nil)
        // Whatever is asked for, what comes out is rooted at the origin this
        // handler speaks for and is never somewhere else.
        for asked in ["pipeline-ext://page/../../../up", "pipeline-ext://page/a/./b/../c",
                      "pipeline-ext://page//evil.invalid/x", "pipeline-ext://page/%2e%2e/x"] {
            let back = try #require(ExtSchemeHandler.upstreamURL(for: URL(string: asked)!, origin: origin))
            #expect(back.scheme == "http")
            #expect(back.host == "127.0.0.1")
            #expect(back.port == 9931)
            #expect(back.absoluteString.hasPrefix("http://127.0.0.1:9931/"), "\(asked)")
        }
        // A name with a literal percent in it goes across as itself.
        let odd = URL(string: "pipeline-ext://page/pages/100%25%20done.json")!
        #expect(ExtSchemeHandler.upstreamURL(for: odd, origin: origin)?.absoluteString
                == "http://127.0.0.1:9931/pages/100%25%20done.json")
    }

    // MARK: - the look that is injected

    @Test("the injected variables follow the appearance the pane is drawn in")
    func appearanceFollowsTheApp() {
        let light = ExtAppearance.current(NSAppearance(named: .aqua)!)
        let dark = ExtAppearance.current(NSAppearance(named: .darkAqua)!)
        #expect(!light.isDark)
        #expect(dark.isDark)
        #expect(light != dark)

        func value(_ a: ExtAppearance, _ name: String) -> String? {
            a.variables.first { $0.name == name }?.value
        }
        // The two appearances do not agree about the colour of text or of the
        // surface under it — which is the whole point.
        #expect(value(light, "pp-text") != value(dark, "pp-text"))
        #expect(value(light, "pp-background") != value(dark, "pp-background"))
        #expect(value(light, "pp-appearance") == "light")
        #expect(value(dark, "pp-appearance") == "dark")
        // The system font, never a brand one.
        #expect(value(light, "pp-font")?.hasPrefix("-apple-system") == true)
        // Every value is a real CSS value, not a Swift description.
        for v in light.variables {
            #expect(!v.value.contains("NSColor"), "\(v.name)")
            #expect(!v.value.isEmpty, "\(v.name)")
        }
        #expect(light.stylesheet.contains("color-scheme: light"))
        #expect(dark.stylesheet.contains("color-scheme: dark"))
    }

    @Test("Increase Contrast and Reduce Motion reach the page")
    func accessibilityReachesThePage() {
        let plain = ExtAppearance.current(NSAppearance(named: .aqua)!,
                                          reduceMotion: false, increaseContrast: false)
        let reduced = ExtAppearance.current(NSAppearance(named: .aqua)!,
                                            reduceMotion: true, increaseContrast: true)
        #expect(plain != reduced)
        #expect(reduced.script.contains("reduceMotion"))
        #expect(reduced.variables.contains { $0.name == "pp-reduce-motion" && $0.value == "1" })
        #expect(reduced.variables.contains { $0.name == "pp-increase-contrast" && $0.value == "1" })
    }

    @Test("what goes into the page is quoted, so a value can never be code")
    func quotingIsSafe() {
        #expect(ExtJS.quote("a\"b") == "\"a\\\"b\"")
        #expect(ExtJS.quote("</script>").contains("\\u003c"))
        #expect(!ExtJS.quote("</script>").contains("</"))
        #expect(ExtJS.quote("one\ntwo") == "\"one\\ntwo\"")
        #expect(ExtJS.quote("\u{2028}") == "\"\\u2028\"")
    }

    // MARK: - per-shoot state

    @Test("pipeline.state is per shoot, survives the page, and two shoots never meet")
    func stateIsPerShoot() throws {
        let defaults = try #require(UserDefaults(suiteName: "extension.state.tests"))
        defaults.removePersistentDomain(forName: "extension.state.tests")
        let store = ExtStateStore(defaults: defaults)

        store.set(shoot: "one", key: "sort", value: "by time")
        store.set(shoot: "two", key: "sort", value: "by name")
        #expect(store.get(shoot: "one", key: "sort") == "by time")
        #expect(store.get(shoot: "two", key: "sort") == "by name")

        // A name with a dot in it cannot read another shoot's answer.
        store.set(shoot: "a", key: "b.c", value: "x")
        #expect(store.get(shoot: "a.b", key: "c") == nil)

        store.set(shoot: "one", key: "sort", value: nil)
        #expect(store.get(shoot: "one", key: "sort") == nil)
        #expect(store.get(shoot: "two", key: "sort") == "by name")

        store.clear(shoot: "two")
        #expect(store.get(shoot: "two", key: "sort") == nil)
        defaults.removePersistentDomain(forName: "extension.state.tests")
    }

    // MARK: - what the page asks the app for

    @Test("the confirmation is the app's own sheet and it answers what he said")
    func confirmationIsTheAppsOwn() async throws {
        let model = ExtStepModel(state: ExtStateStore(defaults: scratchDefaults()))
        let asked = Task { await model.confirmDestructive(title: "Let go of it?", body: "It cannot be undone.",
                                                          confirmLabel: "Let Go") }
        // The sheet appears; nothing is decided until he decides it.
        try await waitUntil { model.question != nil }
        #expect(model.question?.title == "Let go of it?")
        #expect(model.question?.confirmLabel == "Let Go")
        model.answer(false)
        #expect(await asked.value == false)
        #expect(model.question == nil)

        let again = Task { await model.confirmDestructive(title: "t", body: "", confirmLabel: "Do It") }
        try await waitUntil { model.question != nil }
        model.answer(true)
        #expect(await again.value == true)
    }

    @Test("a second question while one is on screen waits its turn, never swapped under his hand nor answered for him")
    func oneQuestionAtATime() async throws {
        let model = ExtStepModel(state: ExtStateStore(defaults: scratchDefaults()))
        let first = Task { await model.confirmDestructive(title: "first", body: "", confirmLabel: "Do It") }
        try await waitUntil { model.question != nil }
        let second = Task { await model.confirmDestructive(title: "second", body: "", confirmLabel: "Do It") }
        let third = Task { await model.pageAsked("third") }
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.question?.title == "first")
        model.answer(true)
        #expect(await first.value == true)
        try await waitUntil { model.question?.title == "second" }
        model.answer(false)
        #expect(await second.value == false)
        try await waitUntil { model.question?.title == "third" }
        model.answer(true)
        #expect(await third.value == true)
        #expect(model.question == nil)
    }

    @Test("a page's own alert is a line under the page that asks for nothing, and goes by itself")
    func anAlertAsksNothing() async throws {
        let model = ExtStepModel(state: ExtStateStore(defaults: scratchDefaults()))
        let lingers = ExtStepModel.saidLingers
        ExtStepModel.saidLingers = .milliseconds(60)
        defer { ExtStepModel.saidLingers = lingers }
        // The page goes on at once: nothing waits for an OK.
        await model.pageSaid("Six photographs are ready.")
        #expect(model.said == "Six photographs are ready.")
        #expect(model.question == nil, "no sheet")
        #expect(model.refusal == nil, "and not the alarm colour's bar")
        // A full parallel run can hold the main actor for seconds at a time.
        try await waitUntil(.seconds(30)) { model.said == nil }

        // His next click on the page and the next thing the page asks each
        // take it down.
        await model.pageSaid("Saved.")
        model.bridge.onPressed?()
        #expect(model.said == nil)
        await model.pageSaid("Saved.")
        let asked = Task { await model.pageAsked("Start again?") }
        try await waitUntil { model.question != nil }
        #expect(model.said == nil)
        model.answer(false)
        _ = await asked.value
    }

    @Test("a line said just before the page loads again stays up; one said earlier goes with the page")
    func anAlertOutlivesItsReload() async throws {
        let model = ExtStepModel(state: ExtStateStore(defaults: scratchDefaults()))
        // `alert('Published'); location.reload()`: the sheet made the reload
        // wait for OK, and the line went the moment the reload began.
        await model.pageSaid("Published.")
        model.bridge.onNavigation?()
        #expect(model.said == "Published.")
        // Said earlier than that, it was about the page that has gone.
        try await Task.sleep(for: ExtStepModel.saidTogether + .milliseconds(100))
        model.bridge.onNavigation?()
        #expect(model.said == nil)
    }

    @Test("two lines said together are shown together, not the second over the first")
    func twoAlertsTogether() async throws {
        let model = ExtStepModel(state: ExtStateStore(defaults: scratchDefaults()))
        await model.pageSaid("One.")
        await model.pageSaid("Two.")
        #expect(model.said == "One.\nTwo.")
        for n in 3...6 { await model.pageSaid("\(n).") }
        #expect(model.said == "4.\n5.\n6.", "the newest few, not a page of them")
        // A line said once the last is old starts afresh.
        try await Task.sleep(for: ExtStepModel.saidTogether + .milliseconds(100))
        await model.pageSaid("Later.")
        #expect(model.said == "Later.")
    }

    @Test("a page's own confirm is an ordinary question with two plain answers")
    func aConfirmIsOrdinary() async throws {
        let model = ExtStepModel(state: ExtStateStore(defaults: scratchDefaults()))
        let asked = Task { await model.pageAsked("Start again from the first burst?") }
        try await waitUntil { model.question != nil }
        let q = try #require(model.question)
        #expect(q.kind == .choice)
        #expect(q.title == "Start again from the first burst?")
        #expect(q.confirmLabel == Strings.Extensions.ok)
        model.answer(true)
        #expect(await asked.value == true)

        // No is still no.
        let again = Task { await model.pageAsked("Again?") }
        try await waitUntil { model.question != nil }
        model.answer(false)
        #expect(await again.value == false)
    }

    @Test("only confirmDestructive asks the destructive way")
    func onlyOneKindIsDangerous() async throws {
        let model = ExtStepModel(state: ExtStateStore(defaults: scratchDefaults()))
        let asked = Task { await model.confirmDestructive(title: "Send 14 photographs out?",
                                                          body: "They leave this Mac.",
                                                          confirmLabel: "Send 14 Photographs") }
        try await waitUntil { model.question != nil }
        #expect(model.question?.kind == .destructive)
        model.answer(false)
        _ = await asked.value

        // A line the page says while a question is up does not swap the
        // sheet under his hand, and it does not answer the question for him.
        let question = Task { await model.confirmDestructive(title: "Send them?", body: "",
                                                             confirmLabel: "Send") }
        try await waitUntil { model.question != nil }
        await model.pageSaid("and another thing")
        #expect(model.said == "and another thing")
        #expect(model.question?.title == "Send them?")
        #expect(model.question?.kind == .destructive)
        model.answer(false)
        #expect(await question.value == false)
    }

    @Test("viewFrames opens the app's own viewer at the frame the page named, and answers when it closes")
    func viewFramesOpensTheViewer() async throws {
        let model = ExtStepModel(state: ExtStateStore(defaults: scratchDefaults()))
        #expect(model.viewing == nil)
        let asked = Task { await model.viewFrames(["TSC04313", "TSC04314", "TSC04315"], startAt: 2) }
        try await waitUntil { model.viewing != nil }
        let look = try #require(model.viewing)
        #expect(look.stems.count == 3 && look.startAt == 2)
        let done = ExtViewerResult(index: 1, stem: "TSC04314", marks: [:])
        model.lookEnded(look.id, done)
        #expect(await asked.value == done)
        #expect(model.viewing == nil)
        // A second end of the same look has nothing to answer.
        model.lookEnded(look.id, done)
    }

    @Test("a second look while one is open ends the first where it began, and only the second is open")
    func aSecondLookEndsTheFirst() async throws {
        let model = ExtStepModel(state: ExtStateStore(defaults: scratchDefaults()))
        let first = Task { await model.viewFrames(["A", "B"], startAt: 1, marks: ["A": "x"]) }
        try await waitUntil { model.viewing != nil }
        let firstLook = try #require(model.viewing)
        let second = Task { await model.viewFrames(["C"], startAt: 0) }
        #expect(await first.value == ExtViewerResult(index: 1, stem: "B", marks: ["A": "x"]))
        try await waitUntil { model.viewing?.id != firstLook.id && model.viewing != nil }
        // The first viewer going away late does not end the second.
        model.lookEnded(firstLook.id, ExtViewerResult(index: 0, stem: "A", marks: [:]))
        #expect(model.viewing?.stems == ["C"])
        let secondLook = try #require(model.viewing)
        model.lookEnded(secondLook.id, secondLook.unchanged)
        #expect(await second.value.stem == "C")
    }

    @Test("a page's marks: an id and a label each, one key each, four at the most")
    func marksAreParsed() {
        let raw: [Any] = [
            ["id": "a", "label": "First", "key": "A"],
            ["id": "b", "label": "Second", "key": "a"],            // key taken: none
            ["label": "no id"], ["id": "c"],                       // left out, not the list
            ["id": "a", "label": "again"],                         // an id once
            ["id": "d", "label": "Fourth", "key": "→"],           // not a letter: none
            ["id": "e", "label": "Fifth", "key": "e"],
            ["id": "f", "label": "Sixth", "key": "f"],
        ]
        let actions = ExtViewerAction.parse(raw)
        #expect(actions.map(\.id) == ["a", "b", "d", "e"])
        #expect(actions.map(\.key) == ["a", "", "", "e"])
        #expect(ExtViewerAction.parse("nonsense").isEmpty)
        // A mark naming nothing on offer is dropped; a key toggles its own mark.
        let m = ExtViewerMarking(actions: actions, marks: ["S1": "a", "S2": "zzz"])
        #expect(m.marks == ["S1": "a"])
        #expect(ExtViewerMarking.toggled(m.marks, stem: "S1", action: "a") == [:])
        #expect(ExtViewerMarking.toggled(m.marks, stem: "S1", action: "b") == ["S1": "b"])
        #expect(ExtViewerMarking.toggled(m.marks, stem: "S2", action: "e") == ["S1": "a", "S2": "e"])
    }

    @Test("a refusal lands where the action was and is the host's own sentence")
    func refusalsLandOnThePane() {
        let model = ExtStepModel(state: ExtStateStore(defaults: scratchDefaults()))
        #expect(model.refusal == nil)
        model.refuse(.wentOutside("https://example.invalid/"))
        #expect(model.refusal?.sentence == Strings.Extensions.wentOutside)
        #expect(model.refusal?.detail == "https://example.invalid/")
        model.clearRefusal()
        #expect(model.refusal == nil)
    }

    @Test("where each step's page was is kept per shoot and step, and the top is nothing to go back to")
    func placesArePerPage() {
        ExtPlaces.forget()
        ExtPlaces.note(shoot: "a", step: "s", x: 0, y: 900)
        #expect(ExtPlaces.scrolled(shoot: "a", step: "s") == CGPoint(x: 0, y: 900))
        #expect(ExtPlaces.scrolled(shoot: "b", step: "s") == nil)
        #expect(ExtPlaces.scrolled(shoot: "a", step: "t") == nil)
        ExtPlaces.note(shoot: "a", step: "s", x: 0, y: 0)
        #expect(ExtPlaces.scrolled(shoot: "a", step: "s") == nil)
        ExtPlaces.forget()
    }

    @Test("a refusal goes when the page loads again and at the next thing the page asks of the app")
    func refusalsGo() async throws {
        let model = ExtStepModel(state: ExtStateStore(defaults: scratchDefaults()))
        model.refuse(.wentOutside("https://example.invalid/"))
        model.bridge.onNavigation?()
        #expect(model.refusal == nil)
        model.refuse(.wentOutside("https://example.invalid/"))
        let asked = Task { await model.confirmDestructive(title: "Send them?", body: "", confirmLabel: "Send") }
        try await waitUntil { model.question != nil }
        #expect(model.refusal == nil)
        model.answer(false)
        _ = await asked.value
    }

    @Test("the shim names the three bridges and nothing else")
    func theShimIsTheContract() {
        let shim = ExtBridge.shim
        #expect(shim.contains("viewFrames"))
        #expect(shim.contains("confirmDestructive"))
        #expect(shim.contains("state"))
        #expect(shim.contains("messageHandlers"))
        // It cannot be replaced by the page, and the key is nowhere in it.
        #expect(shim.contains("writable: false"))
        #expect(!shim.lowercased().contains("studio-key"))
    }
}

@MainActor
func scratchDefaults() -> UserDefaults {
    let name = "extension.tests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// Waits for something the main actor is about to do, without a sleep in the
/// test's own body pretending to be a guarantee.
@MainActor
func waitUntil(_ timeout: Duration = .seconds(5),
               _ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline { throw WaitedTooLong() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct WaitedTooLong: Error {}
