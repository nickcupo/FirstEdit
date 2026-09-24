import AppKit
import SwiftUI
import PipelineKit

/// The Instagram step (DESIGN.md §2.17, §4.3): the wall as it opens and while
/// the cuts are worked out, planned with the grid misses first, ticked and
/// left out, at the other shape, the editor in each of its views, a make
/// running, a refusal, nothing exported, and the minimum window.
///
/// The answers are the `instagram-*` fixtures. With `--library`, the pictures
/// are the library's own exports, found by stem, read and never written.
final class InstagramScenes: SceneProvider {

    static let standard = CGSize(width: 1440, height: 900)
    static let minimum = CGSize(width: 900, height: 620)

    override class var scenes: [SnapshotScene] {
        [
            SnapshotScene(name: "instagram", size: standard) { f in
                .window(AnyView(RootView(app: app(f))))
            },
            SnapshotScene(name: "instagram-planning", size: standard) { f in
                .window(AnyView(RootView(app: app(f, fixture: "instagram-planning"))))
            },
            SnapshotScene(name: "instagram-marked", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    m.previewMarks(["TSC05816": .leaveOut, "TSC06383": .leaveOut, "TSC05827": .leaveOut])
                    m.previewRing("TSC05817")
                }))))
            },
            SnapshotScene(name: "instagram-included", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    m.previewMarks(["TSC05816": .include, "TSC06384": .include, "TSC05945": .include,
                                    "TSC06383": .include, "TSC05841": .include])
                }))))
            },
            SnapshotScene(name: "instagram-4x5", size: standard) { f in
                .window(AnyView(RootView(app: app(f, fixture: "instagram-shape"))))
            },
            // The first grid miss, a landscape left whole, at Fit: the strip
            // the profile grid shows is drawn inside the cut.
            SnapshotScene(name: "instagram-editor", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    m.previewEditor(m.order[0], view: .fit)
                }))))
            },
            SnapshotScene(name: "instagram-editor-1to1", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    m.previewEditor("TSC06383", view: .oneToOne)
                }))))
            },
            SnapshotScene(name: "instagram-editor-result", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    m.previewEditor("TSC06383", view: .result)
                }))))
            },
            SnapshotScene(name: "instagram-editor-whole", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    m.previewEditor("TSC05822", view: .fit)
                }))))
            },
            // His own window being dragged: the draft, not saved yet.
            SnapshotScene(name: "instagram-editor-draft", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    m.previewEditor("TSC05901", view: .fit, draft: InstagramManual(cx: 0.52, cy: 0.4, scale: 0.85))
                }))))
            },
            SnapshotScene(name: "instagram-making", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    m.makeJob.preview = making(m)
                }))))
            },
            SnapshotScene(name: "instagram-refused", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    m.makeJob.preview = making(m)
                    // The sentence the engine writes for a shape change while
                    // it makes the copies, as written.
                    m.previewRefusal("The copies are being made at 3:4 right now. Change the shape when they are done.")
                }))))
            },
            SnapshotScene(name: "instagram-stopped", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in m.previewPlanOutcome(.stoppedByHim) }))))
            },
            SnapshotScene(name: "instagram-nothing-exported", size: standard) { f in
                .window(AnyView(RootView(app: app(f, fixture: "instagram-empty"))))
            },
            SnapshotScene(name: "instagram-min", size: minimum) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    m.previewMarks(["TSC05816": .leaveOut])
                    m.previewRing("TSC05809")
                }))))
            },
            SnapshotScene(name: "instagram-planning-min", size: minimum) { f in
                .window(AnyView(RootView(app: app(f, fixture: "instagram-planning"))))
            },
            SnapshotScene(name: "instagram-editor-min", size: minimum) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    m.previewEditor("TSC06383", view: .fit)
                }))))
            },
        ]
    }

    // MARK: - scaffolding

    @MainActor
    static func making(_ m: InstagramModel) -> Job {
        Job(running: true, stopped: false, id: 14, kind: "instagram", shoot: m.session.name,
            title: "making 13 Instagram copies of \(m.session.name)", stage: "instagram",
            label: "making the Instagram copies: 4 of 13 photographs", fraction: 0.31, elapsed: 12)
    }

    /// An app open on the decided shoot's Instagram step, with the step's
    /// answer already in hand.
    @MainActor
    static func app(_ f: Fixtures, fixture: String = "instagram",
                    then: (InstagramModel) -> Void = { _ in }) -> AppModel {
        StepScenes.prepare()
        InstagramModelStore.shared.reset()
        InstagramPictures.reset()
        if let lib = f.library {
            InstagramPictures.loader = { route in try exported(route, in: lib) }
        }
        let app = shootApp(f)
        guard let shoot = app.navigation.shoot,
              let session = app.library.cachedSession(for: shoot),
              let status = f.decode(InstagramStatus.self, fixture) else { return app }
        let m = InstagramModelStore.shared.model(for: session, jobs: app.jobs)
        m.preview(status)
        then(m)
        if let lib = f.library { seed(m, from: lib) }
        return app
    }

    /// `StepScenes.shootApp`, with the Instagram row in the shoot's step
    /// list: a capture from an engine before the step was built in has its
    /// own list without it, and the sidebar draws the engine's list. The
    /// fixture on disk is not touched.
    @MainActor
    static func shootApp(_ f: Fixtures) -> AppModel {
        var data = f.data("shoot-decided")
        if var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var steps = object["steps"] as? [[String: Any]],
           !steps.contains(where: { ($0["id"] as? String) == "instagram" }) {
            let at = (steps.firstIndex { ($0["id"] as? String) == "edit" }).map { $0 + 1 } ?? steps.count
            steps.insert(["id": "instagram", "label": "Instagram", "done": true, "enabled": true,
                          "why_disabled": NSNull(), "source": "base"], at: min(at, steps.count))
            object["steps"] = steps
            if let patched = try? JSONSerialization.data(withJSONObject: object) { data = patched }
        }
        let lib = f.makeLibrary()
        guard let r = try? JSONDecoder().decode(ShootResponse.self, from: data) else {
            return f.makeApp(selection: .allShoots)
        }
        let s = ShootSession(response: r, ext: f.shoots?.ext, client: f.client, pump: f.pump)
        lib.adopt(s)
        let nav = Navigation(selection: .step(shoot: s.name, step: "instagram"))
        let app = AppModel(preview: lib, state: .running(f.endpoint), navigation: nav)
        StepJobs.shared = { app.jobs }
        StepJobs.previewJob = nil
        return app
    }

    /// Every picture the scene draws, decoded now, so a render never races
    /// its own decode.
    @MainActor
    static func seed(_ m: InstagramModel, from lib: URL) {
        let pictures = InstagramPictures.store(for: m.session.client)
        for frame in m.wall {
            let route = ImageRoute.exported(shoot: m.session.name, stem: frame.stem, px: 400, version: frame.export_mtime)
            if let data = try? exported(route, in: lib), let image = try? Downsampler.decode(data, maxPixel: 400) {
                pictures.put(image, shoot: m.session.name, stem: frame.stem, version: frame.export_mtime, px: 400)
            }
        }
        guard let e = m.editor, let frame = m.frames[e.stem] else { return }
        let px: Int? = e.view == .oneToOne ? nil : 2400
        let route = ImageRoute.exported(shoot: m.session.name, stem: frame.stem, px: px, version: frame.export_mtime)
        if let data = try? exported(route, in: lib), let image = try? Downsampler.decode(data, maxPixel: px) {
            pictures.put(image, shoot: m.session.name, stem: frame.stem, version: frame.export_mtime, px: px)
        }
    }

    /// `/exported/` off the disk: the shoot's own export of that stem, or —
    /// the fixtures' stems are the scratch library's, and the app is open on
    /// another shoot — the first shoot in the library that has one.
    nonisolated static func exported(_ route: ImageRoute, in lib: URL) throws -> Data {
        guard case .exported(let shoot, let stem, _, _) = route else { throw CocoaError(.fileNoSuchFile) }
        let shoots = lib.appendingPathComponent("shoots")
        let fm = FileManager.default
        let named = [shoot] + ((try? fm.contentsOfDirectory(atPath: shoots.path))?.sorted() ?? [])
        for s in named {
            let dir = shoots.appendingPathComponent("\(s)/export")
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            if let file = files.sorted().first(where: {
                $0.hasPrefix(stem) && ["jpg", "jpeg"].contains(($0 as NSString).pathExtension.lowercased())
            }) {
                return try Data(contentsOf: dir.appendingPathComponent(file))
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
