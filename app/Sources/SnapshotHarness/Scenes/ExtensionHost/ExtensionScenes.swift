import AppKit
import SwiftUI
import PipelineKit

/// The extension host's scenes: a step of an added kind, drawn in the whole
/// window, in light and dark; the refusal where the action was taken; and the
/// app's own sheet that anything going out to the world has to pass.
///
/// The pages here are served by the same scheme handler the app uses, from an
/// upstream that is not a socket — one protocol, two implementations, and the
/// host cannot tell which it has.
final class ExtensionScenes: SceneProvider {
    override class var scenes: [SnapshotScene] {
        let size = CGSize(width: 1100, height: 780)
        return [
            SnapshotScene(name: "extension-step", size: size) { f in
                .window(AnyView(RootView(app: SceneExtension.app(f))))
            },
            SnapshotScene(name: "extension-refusal", size: size) { f in
                .window(AnyView(RootView(app: SceneExtension.app(
                    f, refusal: .wentOutside("https://example.invalid/somewhere")))))
            },
            SnapshotScene(name: "extension-pane", size: CGSize(width: 820, height: 560)) { f in
                let model = ExtStepModel()
                model.refuse(.wentOutside("https://example.invalid/somewhere"))
                model.bridge.onNavigation = nil         // as in SceneExtension.app
                let session = f.makeLibrary().cachedSession(for: f.shoot?.info.name ?? "")
                model.bind(session: session!)
                return .window(AnyView(ExtensionScenePage(session: session!, model: model)))
            },
            // The viewer a page gets for free by calling viewFrames: the
            // app's own full-size look, on the app's own surround.
            SnapshotScene(name: "extension-viewer", size: CGSize(width: 1000, height: 720)) { f in
                let library = f.makeLibrary()
                let session = library.cachedSession(for: f.shoot?.info.name ?? "")
                let stems = Array((session?.order ?? []).prefix(8))
                return .window(AnyView(
                    ExtViewer.make(session: session!, stems: stems, startAt: 2,
                                   marking: ExtViewerMarking(
                                       actions: [ExtViewerAction(id: "a", label: "First mark", key: "a"),
                                                 ExtViewerAction(id: "b", label: "Second mark", key: "b")],
                                       marks: stems.count > 2 ? [stems[2]: "a"] : [:]),
                                   close: { _ in })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                ))
            },
            // The two sheets a page can put on screen, both of them the
            // app's own `ExtConfirmSheet` and not a copy of it. Only the
            // first one is dangerous and only the first one is red.
            SnapshotScene(name: "extension-confirm", size: CGSize(width: 620, height: 300)) { _ in
                .window(AnyView(ExtSheetScene(question: ExtQuestion(
                    title: "Send 14 photographs out of First Edit?",
                    body: "They leave this Mac. First Edit cannot take them back afterwards.",
                    confirmLabel: "Send 14 Photographs",
                    kind: .destructive))))
            },
            // A page's alert(): a line under the page that asks for nothing.
            // It was the sheet above with an OK to click, every time.
            SnapshotScene(name: "extension-alert", size: CGSize(width: 820, height: 560)) { f in
                let model = ExtStepModel()
                model.bridge.onNavigation = nil         // as in SceneExtension.app
                let session = f.makeLibrary().cachedSession(for: f.shoot?.info.name ?? "")
                model.bind(session: session!)
                model.said = "Six photographs are ready."
                return .window(AnyView(ExtensionScenePage(session: session!, model: model)))
            },
            SnapshotScene(name: "extension-choice", size: CGSize(width: 620, height: 260)) { _ in
                .window(AnyView(ExtSheetScene(question: ExtQuestion(
                    title: "Start again from the first burst?", body: "",
                    confirmLabel: "OK", kind: .choice))))
            },
        ]
    }
}

/// The pane itself: the host filling it, and the refusal under it when there
/// is one — which is where the action was taken, never an alert.
struct ExtensionScenePage: View {
    let session: ShootSession
    let model: ExtStepModel

    var body: some View {
        ExtensionHost(page: SceneExtension.page(for: session.name),
                      upstream: SceneExtension.upstream,
                      bridge: model.bridge,
                      label: SceneExtension.label)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    ExtRefusalBar(model: model)
                    ExtSaidBar(model: model)
                }
            }
    }
}

/// One of the app's own sheets, on the surface a sheet is drawn on.
///
/// It draws the product's `ExtConfirmSheet` rather than a picture of it, so
/// what is looked at here is what he sees.
struct ExtSheetScene: View {
    let question: ExtQuestion

    var body: some View {
        ExtConfirmSheet(question: question) { _ in }
            .background(Color(nsColor: .windowBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 24, y: 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - an extension, for the picture

/// A library that has an extension installed, and a page with no socket
/// behind it.
///
/// It is what a real extension is on the other side of the host: the same
/// `pipeline-ext://` load, the same injected variables, the same bridges,
/// the same sidebar row. Nothing here names anything of his, and nothing here
/// is in the app.
@MainActor
enum SceneExtension {
    static let step = "a-step"
    static let label = "An Added Step"
    static let origin = URL(string: "http://127.0.0.1:9931/")!
    static let upstream: any ExtUpstream = ScenePages()

    static func page(for shoot: String) -> URL {
        var c = URLComponents(url: origin, resolvingAgainstBaseURL: true)!
        c.path = "/pages/grid"
        c.queryItems = [URLQueryItem(name: "shoot", value: shoot)]
        return c.url!
    }

    /// The fixtures with an extension spliced in: the library declares one,
    /// the shoot lists its step where the extension put it, and the step's
    /// page is registered before anything draws.
    static func app(_ f: Fixtures, refusal: ExtHostError? = nil) -> AppModel {
        let model = ExtStepModel()
        if let refusal {
            // The refusal a click on the loaded page drew. Here it is set
            // before the page loads, and a load clears what the last one was
            // refused, so this scene's page does not.
            model.refuse(refusal)
            model.bridge.onNavigation = nil
        }
        StepRegistry.register(step) { session in
            model.bind(session: session)
            return AnyView(ExtensionScenePage(session: session, model: model))
        }
        let shoots = withExtension(f.data("shoots"))
        let shootName = f.shoot?.info.name ?? ""
        let library = (try? JSONDecoder().decode(ShootsResponse.self, from: shoots))
            .map { Library(preview: $0, client: f.client, pump: f.pump) }
            ?? f.makeLibrary()
        if let response = try? JSONDecoder().decode(
            ShootResponse.self, from: withSteps(f.data("shoot-decided"))) {
            library.adopt(ShootSession(response: response, ext: library.ext,
                                       client: f.client, pump: f.pump))
        }
        let nav = Navigation(selection: .step(shoot: shootName, step: step))
        return AppModel(preview: library, state: .running(f.endpoint), navigation: nav)
    }

    static func withExtension(_ data: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return data
        }
        object["ext"] = [
            "kind": "a-kind",
            "ask": ["question": "", "yes": "", "no": "", "blurb": "", "badge": "", "other_badge": ""],
            "steps": ["ingest", "cull", "keepers", "presets", "edit", step, "reels", "done"],
            "labels": [step: label],
            "every": [step],
            "pages": [step: "http://127.0.0.1:9931/pages/grid?shoot={shoot}"],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }

    static func withSteps(_ data: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return data
        }
        func row(_ id: String, _ label: String, _ done: Bool) -> [String: Any] {
            ["id": id, "label": label, "done": done, "enabled": true, "source": "base"]
        }
        object["steps"] = [
            row("ingest", "Copy the Card", true),
            row("cull", "Cull", true),
            row("keepers", "Choose Keepers", false),
            row("presets", "Presets", false),
            row("edit", "Edit in PhotoLab", false),
            ["id": step, "label": label, "done": false, "enabled": true, "source": "extension"],
            row("reels", "Reels", false),
            row("done", "Finish", false),
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }
}

struct ScenePages: ExtUpstream {
    func load(_ request: ExtRequest) async throws -> ExtResponse {
        switch request.url.path {
        case "/pages/grid":
            return .html(Self.grid)
        case "/pages/look.css":
            return ExtResponse(status: 200, headers: ["Content-Type": "text/css"],
                               body: Data(Self.css.utf8))
        default:
            return ExtResponse(status: 404, headers: ["Content-Type": "text/plain; charset=utf-8"],
                               body: Data("no such page".utf8))
        }
    }

    /// Every colour, size and space on this page is one the host injected, so
    /// the picture shows whether the seam is visible.
    static let css = """
    .page { padding: var(--pp-space-window); max-width: var(--pp-column); }
    h1 { font-size: var(--pp-text-title); font-weight: 600; margin: 0 0 var(--pp-space-label); }
    p.note { color: var(--pp-text-secondary); font-size: var(--pp-text-callout);
             margin: 0 0 var(--pp-space-group); }
    .cards { display: grid; grid-template-columns: repeat(3, 1fr); gap: var(--pp-space-related); }
    .card { border: 1px solid var(--pp-separator); border-radius: var(--pp-radius);
            background: var(--pp-background-secondary); padding: var(--pp-space-related);
            display: flex; flex-direction: column; gap: var(--pp-space-label); }
    .card .name { font-family: var(--pp-font-mono); font-size: var(--pp-text-footnote);
                  color: var(--pp-text-secondary); }
    .thumb { aspect-ratio: 3 / 2; border-radius: 4px;
             background: var(--pp-control); border: 1px solid var(--pp-separator); }
    .row { display: flex; align-items: center; gap: var(--pp-space-related);
           margin-top: var(--pp-space-group); }
    button { font: inherit; font-size: var(--pp-text-body); min-height: var(--pp-hit-target);
             padding: 0 12px; border-radius: var(--pp-radius);
             border: 1px solid var(--pp-separator); background: var(--pp-control);
             color: var(--pp-control-text); }
    button.go { background: var(--pp-accent); color: var(--pp-accent-text); border-color: transparent; }
    """

    static let grid = """
    <!doctype html>
    <html><head><link rel="stylesheet" href="look.css"></head>
    <body><div class="page">
      <h1>An Added Step</h1>
      <p class="note">Six frames are ready. Click one to look at it full size.</p>
      <div class="cards">
        <div class="card"><div class="thumb"></div><span class="name">04313</span></div>
        <div class="card"><div class="thumb"></div><span class="name">04319</span></div>
        <div class="card"><div class="thumb"></div><span class="name">04326</span></div>
        <div class="card"><div class="thumb"></div><span class="name">04330</span></div>
        <div class="card"><div class="thumb"></div><span class="name">04331</span></div>
        <div class="card"><div class="thumb"></div><span class="name">04344</span></div>
      </div>
      <div class="row">
        <button class="go">Send These Six</button>
        <button>Choose Again</button>
      </div>
    </div></body></html>
    """
}
