import SwiftUI
import Testing
// Not @testable on purpose: this file is the public surface the six wave-one
// crews compile against, and it must be reachable from outside the module.
import PipelineKit

/// Every interface DESIGN.md §5.0 promises, named once.
///
/// It asserts almost nothing at runtime. Its job is to fail to *compile* the
/// day a signature drifts, because six crews are writing against these names
/// and the first they would otherwise hear of a change is a merge.
@Suite("The interfaces six crews compile against")
@MainActor
struct InterfaceTests {

    @Test("Engine, API, Images, Design, State and Shell are all reachable from outside the module")
    func surface() async throws {
        // Engine ───────────────────────────────────────────────────────────
        let host: EngineHost = EngineHost(bundle: .main, support: URL(fileURLWithPath: "/tmp/nowhere"),
                                          settings: SettingsStore(defaults: UserDefaults(suiteName: "interfaces")!))
        let _: URL = host.logURL
        let _: AsyncStream<EngineHost.State> = host.states
        let state: EngineHost.State = await host.state
        #expect(state == .stopped)
        let endpoint = EngineHost.Endpoint(base: URL(string: "http://127.0.0.1:9/")!, key: "k")
        let _: (URL, String) = (endpoint.base, endpoint.key)
        if false {
            _ = try await host.start()
            _ = try await host.restart()
            await host.stop()
        }

        // API ──────────────────────────────────────────────────────────────
        let client = StudioClient(endpoint: endpoint)
        let _: URLRequest = client.imageRequest(.thumb(shoot: "s", stem: "f"))
        if false {
            _ = try await client.get(Routes.shoots())
            _ = try await client.get(Routes.shoot("s", full: true))
            _ = try await client.get(Routes.shootLight("s"))
            _ = try await client.get(Routes.job())
            _ = try await client.get(Routes.storage("s"))
            _ = try await client.get(Routes.storageFrames("s"))
            _ = try await client.get(Routes.storagePlan("s", what: "drop", opts: .none))
            _ = try await client.get(Routes.storageLibrary())
            _ = try await client.get(Routes.reelOptions("s", burst: nil, src: nil))
            _ = try await client.get(Routes.reelWatch("s", burst: "1"))
            _ = try await client.get(Routes.cards())
            _ = try await client.get(Routes.update(force: false))
            _ = try await client.get(Routes.learned())
            _ = try await client.get(Routes.ext("x"))
            _ = try await client.post(Routes.rating, RatingBody(name: "s", file: "f", rating: 5))
            _ = try await client.post(Routes.review, ReviewBody(name: "s"))
            _ = try await client.post(Routes.kind, KindBody(name: "s"))
            _ = try await client.post(Routes.label, LabelBody(name: "s", file: "f", label: "blur"))
            _ = try await client.post(Routes.open, OpenBody(name: "s", what: "photolab"))
            _ = try await client.post(Routes.cull, CullBody(name: "s"))
            _ = try await client.post(Routes.presets, PresetsBody(name: "s"))
            _ = try await client.post(Routes.selects, SelectsBody(name: "s"))
            _ = try await client.post(Routes.ingest, IngestBody(card: "c", name: "n", verify: "while"))
            _ = try await client.post(Routes.reel, ReelBody(["format": .string("cut")]))
            _ = try await client.post(Routes.spread, SpreadBody(name: "s", burst: "1"))
            _ = try await client.post(Routes.setup, EmptyBody())
            _ = try await client.post(Routes.jobStop, EmptyBody())
            _ = try await client.post(Routes.updateDownload, EmptyBody())
            _ = try await client.post(Routes.updateInstall, EmptyBody())
            _ = try await client.post(Routes.storageRetain, RetainBody(name: "s", days: 30))
            _ = try await client.post(Routes.storageCheck, StorageCheckBody(name: "s"))
            _ = try await client.post(Routes.storageApply, ApplyBody(name: "s", what: "drop", token: "t"))
            _ = try await client.post(Routes.learnedRun, LearnedRunBody())
            _ = try await client.post(Routes.learnedBack, LearnedActionBody(learner: "l"))
            _ = try await client.post(Routes.learnedStop, LearnedActionBody(learner: "l"))
            _ = try await client.post(Routes.learnedUseAnyway, LearnedActionBody(learner: "l"))
        }
        let _: StudioError = .refused("as the engine wrote it")
        #expect(StudioError.refused("x").sentence == "x")

        // Images ───────────────────────────────────────────────────────────
        let pump = ImagePump(client: client, budget: .automatic)
        let key = ImagePump.Key(shoot: "s", stem: "f", tier: .full(px: 2048))
        let _: CGImage? = pump.cached(key)
        await pump.prefetch([key], priority: .utility)
        await pump.cancelPrefetch(keeping: [key])
        let _: ImagePump.Report = await pump.report()
        let _: any View = FrameImageView(shoot: "s", stem: "f", fit: .fit(inset: 8),
                                         showing: .aPhotograph, pump: pump,
                                         onDisplay: { _, _ in })
        let _: [Showing] = [.aThumbnail, .aPhotograph]

        // Design ───────────────────────────────────────────────────────────
        let _: CGFloat = Tokens.Metric.toolbar
        let _: CGFloat = Tokens.Metric.scrubber
        let _: CGFloat = Tokens.Metric.controlBar
        let _: CGFloat = Tokens.Metric.filmstrip
        let _: CGSize = Tokens.Metric.verdictButton
        let _: CGFloat = Tokens.Metric.verdictClearGap
        let _: CGFloat = Tokens.Metric.column
        let _: Color = Tokens.Palette.viewerBackground
        let _: Animation = Tokens.Motion.step(.easeInOut(duration: 0.12))
        let _: [String] = [Tokens.Sym.keep, Tokens.Sym.drop, Tokens.Sym.undo,
                           Tokens.Sym.compare, Tokens.Sym.nextBurst, Tokens.Sym.fullImage]
        let _: any View = RefusalRow("that frame isn't the one on screen.", owner: .verdict)
        let _: any View = PathRow(URL(fileURLWithPath: "/tmp"))

        // State ────────────────────────────────────────────────────────────
        let library = Library()
        let _: [ShootRowOK] = library.shoots
        let _: [ShootRowBroken] = library.broken
        let _: [String] = library.cards
        let _: ExtConfig? = library.ext
        let _: Bool = library.ready
        let _: UpdateInfo = library.update
        await library.refresh()
        if false { _ = try await library.session(for: "s") }

        let jobs = JobModel()
        let _: Job? = jobs.job
        let _: Bool = jobs.isRunning
        await jobs.start { }
        await jobs.stop()

        let nav = Navigation()
        nav.selection = .step(shoot: "s", step: "keepers")
        nav.step = "keepers"
        nav.viewerMode = .allBursts
        nav.inspectorShown = true
        #expect(nav.shoot == "s")

        let settings = SettingsStore(defaults: UserDefaults(suiteName: "interfaces")!)
        settings.viewerBackground = .black
        #expect(settings.viewerBackground == .black)

        // Shell ────────────────────────────────────────────────────────────
        StepRegistry.register("a-step") { session in AnyView(Text(session.name)) }
        StepRegistry.register("another-step", AStepView.self)
        #expect(StepRegistry.isRegistered("a-step"))
        #expect(StepRegistry.isRegistered("another-step"))
    }
}

/// A step view exactly as a feature crew writes one.
struct AStepView: StepView {
    let session: ShootSession
    let client: StudioClient
    let pump: ImagePump
    init(session: ShootSession, client: StudioClient, pump: ImagePump) {
        self.session = session; self.client = client; self.pump = pump
    }
    var body: some View { Text(session.name) }
}
