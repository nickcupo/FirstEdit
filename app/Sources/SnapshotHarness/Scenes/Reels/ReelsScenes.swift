import AppKit
import SwiftUI
import PipelineKit

/// The Reels step (DESIGN.md §2.6, §5.8): with and without exports, the frame
/// grid with frames taken out, a timelapse, waiting on PhotoLab, mid-cut, and
/// refused.
///
/// The options are the lister's real answer about one burst,
/// `reel-options-burst`. With `--library`, the tiles are the engine's own
/// reel thumbnails off that library's disk and the player is handed a reel
/// that library really holds.
final class ReelsScenes: SceneProvider {

    static let standard = CGSize(width: 1440, height: 900)

    override class var scenes: [SnapshotScene] {
        [
            SnapshotScene(name: "reels", size: standard) { f in
                .window(AnyView(RootView(app: app(f))))
            },
            SnapshotScene(name: "reels-no-exports", size: standard) { f in
                .window(AnyView(RootView(app: app(f, patch: withoutExports))))
            },
            SnapshotScene(name: "reels-frames-left-out", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    let stems = m.frames.map(\.stem)
                    for s in stems.prefix(3) { m.toggle(s) }
                    if stems.count > 6 { m.toggle(stems[6]) }
                }))))
            },
            SnapshotScene(name: "reels-too-few", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    for s in m.frames.map(\.stem).dropFirst(2) { m.toggle(s) }
                }))))
            },
            SnapshotScene(name: "reels-timelapse", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in m.choose(format: .timelapse) }))))
            },
            SnapshotScene(name: "reels-waiting-for-photolab", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    guard let b = m.chosenBurst else { return }
                    var w = ReelWait(burst: b.burst, baseline: b.exported, target: b.frames, request: m.request)
                    _ = w.saw(b.exported + 4)
                    _ = w.saw(b.exported + 4)       // a pause: the line says when it will cut
                    m.previewWait(w)
                }))))
            },
            // Trimmed to frames 4–9 before he pressed: the line says the
            // reel is six of them and that Cut Now is his once they are in.
            SnapshotScene(name: "reels-waiting-trimmed", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    guard let b = m.chosenBurst, m.frames.count > 8 else { return }
                    m.startHere(m.frames[3].stem)
                    m.endHere(m.frames[8].stem)
                    var w = ReelWait(burst: b.burst, baseline: b.exported, target: b.frames, request: m.request)
                    _ = w.saw(b.exported + 4)
                    _ = w.saw(b.exported + 4)
                    m.previewWait(w)
                }))))
            },
            SnapshotScene(name: "reels-writing-presets", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    guard let b = m.chosenBurst else { return }
                    m.previewWait(ReelWait(burst: b.burst, baseline: b.exported, target: b.frames,
                                           request: m.request, ready: false))
                }))))
            },
            // Twenty-five minutes into editing the burst: the wait still
            // watches, once a minute, and says so. It used to stop at twenty.
            SnapshotScene(name: "reels-waiting-slowly", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    guard let b = m.chosenBurst else { return }
                    var w = ReelWait(burst: b.burst, baseline: b.exported, target: b.frames, request: m.request)
                    for _ in 0..<55 { _ = w.saw(b.exported) }
                    m.previewWait(w)
                }))))
            },
            SnapshotScene(name: "reels-cutting", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    m.reelJob.preview = Job(running: true, stopped: false, kind: "reel", shoot: m.session.name,
                                            title: "cutting burst \(m.burst ?? "") as a cut",
                                            stage: "frames", label: "cutting the reel: 9 of 13 frames",
                                            fraction: 0.62, elapsed: 21)
                }))))
            },
            // Space on a tile: the same export the tile shows, at the
            // viewer's size, not the camera's JPEG or the unedited RAW.
            SnapshotScene(name: "reels-large", size: CGSize(width: 1000, height: 720)) { f in
                var model: ReelsModel?
                _ = app(f, then: { model = $0 })
                guard let m = model, let first = m.frames.first(where: \.visible) else {
                    return .window(AnyView(Text("No reel frames in this library.")))
                }
                m.openLarge(first.stem)
                return .window(AnyView(
                    ExtViewer.make(session: m.session, stems: m.look?.stems ?? [first.stem],
                                   startAt: m.look?.start ?? 0,
                                   source: .reel(thumbs: ReelThumbs.store(for: m.session.client),
                                                 src: m.source.isEmpty ? nil : m.source,
                                                 exported: Set(m.frames.filter(\.exported).map(\.stem))),
                                   marking: m.lookMarking, close: { _ in })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                ))
            },
            SnapshotScene(name: "reels-refused", size: standard) { f in
                .window(AnyView(RootView(app: app(f, then: { m in
                    // A sentence `_b_reel` really writes, shown as written.
                    m.jobs.refusals.set(.job, "that is not a frame name")
                }))))
            },
        ]
    }

    // MARK: - scaffolding

    /// An app open on this shoot's Reels step, with the lister's answer
    /// already in hand.
    @MainActor
    static func app(_ f: Fixtures, patch: (inout [String: Any]) -> Void = { _ in },
                    then: (ReelsModel) -> Void = { _ in }) -> AppModel {
        StepScenes.prepare()
        ReelsModelStore.shared.reset()
        ReelsModelStore.shared.memory = .none       // no render is drawn from the last one
        ReelThumbs.reset()
        if let lib = f.library {
            ReelThumbs.loader = { route in try thumb(route, in: lib) }
        }
        let app = StepScenes.shootApp(f, "shoot-decided", step: "reels")
        guard let shoot = app.navigation.shoot,
              let session = app.library.cachedSession(for: shoot),
              let options = options(f, patch: patch) else { return app }
        let m = ReelsModelStore.shared.model(for: session, jobs: app.jobs)
        m.preview(options, burst: burst(f))
        then(m)
        return app
    }

    /// Which burst the fixture's frames are of. The lister does not repeat
    /// the burst's name beside its frames, so it is found from the shoot's
    /// rows by the first frame's stem.
    static func burst(_ f: Fixtures) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: f.data("reel-options-burst")) as? [String: Any],
              let frames = o["frames"] as? [[String: Any]],
              let first = frames.first?["stem"] as? String else { return nil }
        return burstOf(first, f)
    }

    static func burstOf(_ stem: String, _ f: Fixtures) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: f.data("shoot-decided")) as? [String: Any],
              let rows = o["rows"] as? [[String: Any]] else { return nil }
        for r in rows where ((r["file"] as? String) ?? "").hasPrefix(stem + ".") {
            if let b = r["burst"] { return "\(b)" }
        }
        return nil
    }

    /// The captured answer, with the scratch paths pointed back at the library
    /// the pictures are drawn from, so the player has a real reel to show.
    static func options(_ f: Fixtures, patch: (inout [String: Any]) -> Void) -> ReelOptions? {
        var data = f.data("reel-options-burst")
        if let lib = f.library, var text = String(data: data, encoding: .utf8) {
            text = text.replacingOccurrences(of: "/scratch/photos", with: lib.path)
            data = Data(text.utf8)
        }
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        patch(&object)
        guard let patched = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(ReelOptions.self, from: patched)
    }

    /// The same shoot as if nothing had been through PhotoLab yet.
    static func withoutExports(_ o: inout [String: Any]) {
        o["exports_found"] = 0
        o["exports_dir"] = ""
        o["sources"] = [Any]()
        o["reels"] = [Any]()
        for key in ["sequences", "cuts"] {
            o[key] = (o[key] as? [[String: Any]])?.map { var b = $0; b["exported"] = 0; return b }
        }
        o["frames"] = (o["frames"] as? [[String: Any]])?.map { var r = $0; r["exported"] = false; return r }
    }

    /// `/reelthumb` off the disk: the thumbnail the engine made for the reel
    /// grid, then the cull's own.
    nonisolated static func thumb(_ route: ImageRoute, in lib: URL) throws -> Data {
        guard case .reelThumb(let shoot, let stem, _, let px) = route else { throw CocoaError(.fileNoSuchFile) }
        let cull = lib.appendingPathComponent("shoots/\(shoot)/cull")
        for d in ["reelthumbs/\(px)", "reelthumbs", "thumbs", "large"] {
            if let data = try? Data(contentsOf: cull.appendingPathComponent("\(d)/\(stem).jpg")) { return data }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
