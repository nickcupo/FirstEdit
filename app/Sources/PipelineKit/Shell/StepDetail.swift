import SwiftUI

/// A step's page. Feature crews write these and register them; the shell
/// never names one.
public protocol StepView: View {
    @MainActor init(session: ShootSession, client: StudioClient, pump: ImagePump)
}

/// Where feature crews hand the shell their views, by id. The ids are the
/// engine's seven step ids, an extension's own step ids, and the three
/// library-wide pages: "library", "learned" and "storage".
///
/// Registration happens once at launch, from each crew's own
/// `<Crew>Registration.register()`, which the integration crew calls from the
/// app delegate. Nothing here has to change for a crew to add a step.
@MainActor
public struct StepRegistry {
    private static var makers: [String: (ShootSession) -> AnyView] = [:]
    private static var libraryMakers: [String: (AppModel) -> AnyView] = [:]

    public static func register(_ id: String, _ make: @escaping @MainActor (ShootSession) -> AnyView) {
        makers[id] = make
    }

    /// A `StepView` type, built with the session's own client and pump.
    public static func register<V: StepView>(_ id: String, _ type: V.Type) {
        makers[id] = { s in AnyView(V(session: s, client: s.client, pump: s.pump)) }
    }

    /// A page that belongs to the library rather than to one shoot.
    public static func registerLibrary(_ id: String, _ make: @escaping @MainActor (AppModel) -> AnyView) {
        libraryMakers[id] = make
    }

    public static func view(_ id: String, _ session: ShootSession) -> AnyView? { makers[id]?(session) }
    public static func libraryView(_ id: String, _ app: AppModel) -> AnyView? { libraryMakers[id]?(app) }
    public static func isRegistered(_ id: String) -> Bool { makers[id] != nil }
    public static var registeredIDs: [String] { makers.keys.sorted() }
    public static var registeredLibraryIDs: [String] { libraryMakers.keys.sorted() }

    /// For tests.
    static func reset() { makers = [:]; libraryMakers = [:] }
}

/// The inspector's contents, by the same ids.
@MainActor
public struct InspectorRegistry {
    private static var makers: [String: (ShootSession) -> AnyView] = [:]
    public static func register(_ id: String, _ make: @escaping @MainActor (ShootSession) -> AnyView) {
        makers[id] = make
    }
    public static func view(_ id: String, _ session: ShootSession) -> AnyView? { makers[id]?(session) }
    /// Whether this step has anything to put in the inspector at all.
    public static func has(_ id: String) -> Bool { makers[id] != nil }
}

/// The detail column: whichever page the sidebar has selected.
///
/// Changing step resets scroll to the top and moves focus to the step's first
/// control (FLOW-03), because each step is its own identity here.
public struct StepDetail: View {
    @Bindable var app: AppModel
    @Bindable var nav: Navigation

    public init(app: AppModel) {
        self.app = app
        self.nav = app.navigation
    }

    public var body: some View {
        Group {
            switch nav.selection {
            case .none:
                ContentUnavailableView(Strings.Steps.pickAShoot, systemImage: Symbols.allShoots)
            case .allShoots:
                StepRegistry.libraryView("library", app) ?? AnyView(LibraryTable(app: app))
            case .learned:
                StepRegistry.libraryView("learned", app)
                    ?? AnyView(PlaceholderPage(title: Strings.Library.learned, symbol: Symbols.learned))
            case .storage:
                StepRegistry.libraryView("storage", app)
                    ?? AnyView(PlaceholderPage(title: Strings.Library.storage, symbol: Symbols.storage))
            case .card(let volume):
                StepRegistry.libraryView("card", app)
                    ?? AnyView(PlaceholderPage(title: volume, symbol: Symbols.memoryCard))
            case .shoot(let name):
                ShootPage(app: app, shoot: name, step: nil)
            case .step(let name, let step):
                ShootPage(app: app, shoot: name, step: step)
            }
        }
        // The crossfade belongs to the **step change**, and to nothing else.
        //
        // This was `.transaction { $0.animation = Motion.step }`, which sets
        // the animation on every update flowing into the subtree rather than
        // on the identity change it was written for. Measured offscreen: an
        // `Animatable` recorder under a plain parent took 0 draws for one
        // value change; under that modifier it took 11, easing over 120 ms.
        // Every step page inherited it — the Cull step's focus slider eased
        // to each new value instead of following the pointer, and the light
        // table animated the caption, the tally and the frame label on every
        // K, D or arrow, which is the opposite of §2.14's "frame to frame by
        // key: no animation" and of `Motion.frameChange = nil`.
        .animation(Motion.step, value: nav.selection)
    }
}

/// One shoot's page: its session, loaded once, and the step that is selected.
struct ShootPage: View {
    let app: AppModel
    let shoot: String
    let step: String?
    @State private var session: ShootSession?
    @State private var refusal: String?

    var body: some View {
        Group {
            if let broken = app.library.broken.first(where: { $0.name == shoot }) {
                // The red row is clickable, and it opened a page with the
                // engine's refusal alone — no file, no Show the File, which
                // were only in All Shoots. The row's page is the row's way in.
                BrokenShootLine(row: broken)
                    .padding(Tokens.Metric.windowMargin)
                    .frame(maxWidth: Tokens.Metric.column, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if let session {
                if let step {
                    stepView(step, session)
                        .id("\(shoot)/\(step)")
                } else {
                    ShootOverview(app: app, session: session)
                        .id(shoot)
                }
            } else if let refusal {
                VStack { RefusalRow(refusal, owner: .library) }
                    .padding(Tokens.Metric.windowMargin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if let cached = app.library.cachedSession(for: shoot) {
                Color.clear.onAppear { session = cached }
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: shoot) {
            session = app.library.cachedSession(for: shoot)
            guard session == nil, !app.library.broken.contains(where: { $0.name == shoot }) else { return }
            do {
                session = try await app.library.session(for: shoot)
                refusal = nil
            } catch let e as StudioError {
                refusal = e.sentence
            } catch {}
        }
    }

    @ViewBuilder
    private func stepView(_ id: String, _ s: ShootSession) -> some View {
        if let v = StepRegistry.view(id, s) {
            v
        } else {
            let state = s.steps.first { $0.id == id }
            PlaceholderPage(title: state?.label ?? Fallbacks.baseLabel(id), symbol: Symbols.step(id),
                            note: state?.enabled == false ? (state?.why_disabled?.asSentence ?? Strings.Steps.notYet)
                                                          : Strings.Steps.notBuiltYet)
        }
    }
}

/// A page nobody has registered yet. It names itself and says so plainly.
struct PlaceholderPage: View {
    let title: String
    let symbol: String
    var note: String = Strings.Steps.notBuiltYet

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(note)
        }
    }
}

/// A shoot selected without a step: what it is, in the engine's own counts.
/// His number and the cull's are two lines under two names, never one.
///
/// The counts are the ones the sidebar and the title show beside it — the
/// library's row, read again at each N, and the open session's bursts — not
/// the session's `info`, which is read when the shoot is opened and after a
/// job: after an hour of K and N the page said 369 kept while the row next to
/// it said 368.
struct ShootOverview: View {
    let app: AppModel
    let session: ShootSession

    var body: some View {
        let i = session.info
        let row = app.library.row(named: i.name)
        let bursts = app.bursts(for: i.name) ?? (i.seen, i.bursts)
        Form {
            Section {
                LabeledContent(Strings.Overview.frames) { Text("\(row?.frames ?? i.frames)").countStyle() }
                LabeledContent(Strings.Overview.youKept) {
                    Text("\(row?.kept ?? i.kept)").countStyle().foregroundStyle(Tokens.Palette.kept)
                }
                LabeledContent(Strings.Overview.youPutOut) { Text("\(row?.dropped ?? i.dropped)").countStyle() }
                LabeledContent(Strings.Overview.cullPutForward) {
                    Text("\(row?.cull_picks ?? i.cull_picks)").countStyle().foregroundStyle(.secondary)
                }
                LabeledContent(Strings.Overview.bursts) {
                    Text(Strings.Overview.beenThrough(bursts.seen, bursts.of)).countStyle()
                }
            }
            Section {
                LabeledContent(Strings.Overview.folder) { PathRow(URL(fileURLWithPath: i.path)) }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: Tokens.Metric.column)
        .frame(maxWidth: .infinity)
        .navigationTitle(i.name)
    }
}
