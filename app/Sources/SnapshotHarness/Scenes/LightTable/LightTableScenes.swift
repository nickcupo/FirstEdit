import AppKit
import SwiftUI
import PipelineKit

/// The light table's scenes (DESIGN.md §4.3, §5.1).
///
/// Every one of them is built from the captured fixtures of the real server,
/// with the columns the server does not send yet — `stack`, `stack_top`,
/// `face_x`, `face_y` — injected here rather than faked in the app, so what the
/// snapshot shows is what the app will draw the day those columns land.
///
/// Pictures come off the scratch clone of the dog shoot when `--library` is
/// given; without it the geometry is still exactly right and the frames are
/// empty boxes.
final class LightTableScenes: SceneProvider {
    override class var scenes: [SnapshotScene] {
        let size = CGSize(width: 1100, height: 780)
        return [
            // The whole window: sidebar, toolbar, scrubber, viewer, control
            // bar, filmstrip. This is the screen his hours go into.
            SnapshotScene(name: "lighttable", size: size) { f in
                LightTableRegistration.register()
                let app = Demo.app(f)
                return .window(AnyView(RootView(app: app)))
            },

            // The same window with the inspector opened by hand: Keep and Drop
            // stand where they stood with it shut, or as near as the column
            // allows, and the bar gives up Compare and the arrows first
            // (§2.5.2).
            SnapshotScene(name: "lighttable-inspector", size: size) { f in
                LightTableRegistration.register()
                let app = Demo.app(f)
                if !app.navigation.inspectorShown { app.navigation.toggleInspector() }
                // As the light table leaves it below 1280 pt, before he
                // opens the inspector by hand.
                app.navigation.sidebarShown = false
                return .window(AnyView(RootView(app: app)))
            },

            // The four bands on their own, at the size the arithmetic of
            // §2.5.1 is tabulated for.
            SnapshotScene(name: "lighttable-table", size: CGSize(width: 1100, height: 780)) { f in
                .window(AnyView(Demo.table(f)))
            },
            SnapshotScene(name: "lighttable-narrow", size: CGSize(width: 900, height: 620)) { f in
                // Below 1100 pt of content width the two side captions move
                // to a lane above the cluster; the cluster itself does not
                // shift, and nothing is drawn on the photograph.
                .window(AnyView(Demo.table(f)))
            },

            // The control bar alone, at the three widths that matter.
            SnapshotScene(name: "control-bar", size: CGSize(width: 1100, height: 56)) { f in
                .window(AnyView(ControlBar(model: Demo.model(f))))
            },
            SnapshotScene(name: "control-bar-minimum", size: CGSize(width: 900, height: 80)) { f in
                .window(AnyView(ControlBar(model: Demo.model(f))))
            },
            // The narrowest column the bar can be handed: the 900 pt minimum
            // window with the inspector opened by hand. It sheds Undo,
            // Compare and the two step arrows rather than drawing any of them
            // where the pointer cannot reach (§2.5.2), and Drop, the frame's
            // label, Keep and Next Burst are all whole and inside.
            SnapshotScene(name: "control-bar-inspector",
                          size: CGSize(width: Tokens.Metric.minimumWindow.width - Tokens.Metric.inspector,
                                       height: 80)) { f in
                .window(AnyView(ControlBar(model: Demo.model(f))))
            },

            // Compare: the whole reason the close calls stop being guesses.
            SnapshotScene(name: "compare-2", size: size) { f in
                let m = Demo.model(f)
                m.openCompare(on: Array(Demo.stackFrames(m).prefix(2)))
                return .window(AnyView(Demo.table(f, model: m)))
            },
            SnapshotScene(name: "compare-4", size: size) { f in
                let m = Demo.model(f)
                m.openCompare(on: Array(Demo.stackFrames(m).prefix(4)))
                return .window(AnyView(Demo.table(f, model: m)))
            },

            SnapshotScene(name: "all-bursts", size: size) { f in
                let m = Demo.model(f)
                m.mode = .allBursts
                return .window(AnyView(Demo.table(f, model: m)))
            },

            // Full Image: 94 % of the window, against 30.1 % on the stage today.
            // Drawn over the whole light table, as the app draws it, so the
            // stage underneath standing down is part of what is rendered.
            SnapshotScene(name: "full-image", size: size) { f in
                let m = Demo.model(f)
                m.setFullImage(true)
                return .window(AnyView(Demo.table(f, model: m)))
            },
            // The same with the pointer moved: the HUD up, the caption said
            // once in its pill and the cluster alone under it, with no lane.
            SnapshotScene(name: "full-image-hud", size: size) { f in
                let m = Demo.model(f)
                m.setFullImage(true)
                return .window(AnyView(FullImageOverlay(model: m, hudUntil: .distantFuture)))
            },
            // A K refused in Full Image, with the HUD down: said over the
            // photograph's bottom edge, where the stage's notices cannot be
            // seen under the overlay.
            SnapshotScene(name: "full-image-refusal", size: size) { f in
                let m = Demo.model(f)
                m.setFullImage(true)
                m.session.refusals.set(.verdict, "Still opening this frame.", at: m.currentStem)
                return .window(AnyView(FullImageOverlay(model: m)))
            },

            // The end of a burst: what he did, and the one frame he did not
            // mark, offered rather than assumed.
            SnapshotScene(name: "end-of-burst", size: size) { f in
                let m = Demo.model(f)
                m.goToFrame(m.frames.count - 1)
                return .window(AnyView(Demo.table(f, model: m)))
            },

            // The last frame of the shoot: the line that offers Presets, and
            // Next Burst reading On to Presets, which is where N goes there.
            SnapshotScene(name: "end-of-shoot", size: size) { f in
                let m = Demo.model(f)
                m.goToBurst(m.bursts.count - 1)
                m.goToFrame(m.frames.count - 1)
                return .window(AnyView(Demo.table(f, model: m)))
            },

            // The bar on a frame he has already kept, and on one he put out:
            // what he decided is shown between Drop and Keep in the
            // filmstrip's own marks.
            SnapshotScene(name: "control-bar-kept", size: CGSize(width: 1100, height: 56)) { f in
                let m = Demo.model(f)
                if let i = m.frames.firstIndex(where: { m.session.rows[$0].map(VerdictValue.his) == .kept }) {
                    m.goToFrame(i)
                }
                return .window(AnyView(ControlBar(model: m)))
            },
            SnapshotScene(name: "control-bar-out", size: CGSize(width: 1100, height: 56)) { f in
                let m = Demo.model(f)
                if let i = m.frames.firstIndex(where: { m.session.rows[$0].map(VerdictValue.his) == .out }) {
                    m.goToFrame(i)
                }
                return .window(AnyView(ControlBar(model: m)))
            },

            // D on the burst's last frame: the strip asking why, alone, where
            // the end-of-burst line comes back when its three seconds are up.
            SnapshotScene(name: "reason-strip", size: size) { f in
                let m = Demo.model(f)
                m.goToFrame(m.frames.count - 1)
                m.reasonStripUntil = Date().addingTimeInterval(60)
                return .window(AnyView(Demo.table(f, model: m)))
            },

            // The three refusals of §2.5.4, each where the action was taken:
            // the first of the viewer's notices, over Drop and Keep. The one
            // that says the frame is still opening is on the burst's last
            // frame, where the end-of-burst line would otherwise be — it
            // used to be drawn across the middle of that line.
            SnapshotScene(name: "refusal-not-on-screen", size: size) { f in
                let m = Demo.model(f)
                m.session.refusals.set(.verdict, "That frame isn't the one on screen.")
                return .window(AnyView(Demo.table(f, model: m)))
            },
            SnapshotScene(name: "refusal-no-pixels", size: size) { f in
                let m = Demo.model(f)
                m.session.refusals.set(.verdict,
                    "This frame's pixels are not on this Mac — its RAW is archived, or its rendering was taken back. Nothing can be decided here.")
                return .window(AnyView(Demo.table(f, model: m)))
            },
            SnapshotScene(name: "refusal-still-opening", size: size) { f in
                let m = Demo.model(f)
                m.goToFrame(m.frames.count - 1)
                m.session.refusals.set(.verdict, "Still opening this frame.", at: m.currentStem)
                return .window(AnyView(Demo.table(f, model: m)))
            },
            // The same refusal raised on the burst's first frame, and he has
            // walked on to its last: the end-of-burst line is what he sees,
            // not a line about a frame he has left.
            SnapshotScene(name: "refusal-left-behind", size: size) { f in
                let m = Demo.model(f)
                m.session.refusals.set(.verdict, "Still opening this frame.", at: m.currentStem)
                m.goToFrame(m.frames.count - 1)
                return .window(AnyView(Demo.table(f, model: m)))
            },

            // The same window on a burst he shot the camera turned on its end.
            // The shoot has both, and the bar, the strip and the cluster have
            // to read the same either way up — which is the whole of his
            // "the bottom bar looks weird if a photo was taken portrait".
            SnapshotScene(name: "lighttable-portrait", size: size) { f in
                LightTableRegistration.register()
                let app = Demo.app(f, portrait: true)
                return .window(AnyView(RootView(app: app)))
            },
            SnapshotScene(name: "lighttable-portrait-minimum",
                          size: Tokens.Metric.minimumWindow) { f in
                LightTableRegistration.register()
                let app = Demo.app(f, portrait: true)
                return .window(AnyView(RootView(app: app)))
            },

            // The same window on a landscape burst, for the comparison that
            // says whether anything moved when the frame turned.
            SnapshotScene(name: "lighttable-minimum", size: Tokens.Metric.minimumWindow) { f in
                LightTableRegistration.register()
                let app = Demo.app(f)
                return .window(AnyView(RootView(app: app)))
            },

            // The same window with another shoot's cull running, and then
            // with a job that was refused: the toolbar's status item beside
            // the title, which is where the subtitle's count gets cut first.
            SnapshotScene(name: "lighttable-job", size: Tokens.Metric.minimumWindow) { f in
                LightTableRegistration.register()
                let app = Demo.app(f)
                app.jobs.take(Demo.runningCull)
                return .window(AnyView(RootView(app: app)))
            },
            SnapshotScene(name: "lighttable-job-ended", size: Tokens.Metric.minimumWindow) { f in
                LightTableRegistration.register()
                let app = Demo.app(f)
                app.jobs.take(Demo.refusedPresets)
                return .window(AnyView(RootView(app: app)))
            },

            // A portrait burst in the filmstrip: a 3:2 cell, a 2:3 picture.
            SnapshotScene(name: "filmstrip-portrait", size: CGSize(width: 1100, height: 96)) { f in
                let m = Demo.model(f, portrait: true)
                return .window(AnyView(Filmstrip(model: m, token: 1)
                    .frame(height: Tokens.Metric.filmstrip)
                    .background(Color(nsColor: .windowBackgroundColor))))
            },

            // A stack in the filmstrip: a bracket, a badge, and nothing hidden.
            SnapshotScene(name: "filmstrip-stack", size: CGSize(width: 1100, height: 96)) { f in
                let m = Demo.model(f)
                m.goToFrame(min(2, max(0, m.frames.count - 1)))
                return .window(AnyView(Filmstrip(model: m, token: 0)
                    .frame(height: Tokens.Metric.filmstrip)
                    .background(Color(nsColor: .windowBackgroundColor))))
            },

            // Increase Contrast: thicker badges, thicker ring, a bordered bar.
            SnapshotScene(name: "lighttable-contrast", size: size) { f in
                .window(AnyView(Demo.table(f).increaseContrast(true)))
            },

            // "eyes closed 131" clicked in the cull's report: the light table
            // on those frames alone, the line saying which and where (§2.6).
            SnapshotScene(name: "lighttable-looking-through", size: size) { f in
                let m = Demo.model(f)
                let report = CullReport(rows: m.session.order.compactMap { m.session.rows[$0] })
                if let first = report.reasons.first, let stems = report.framesByReason[first.word] {
                    m.lookThrough(ViewerModel.FrameList(name: first.word, stems: stems))
                    if stems.count > 2 { m.perform(.nextFrame) }
                }
                return .window(AnyView(Demo.table(f, model: m)))
            },

            // A reason pressed on a frame he kept: the question, and the same
            // digit again as its answer (§2.5.3).
            SnapshotScene(name: "reason-on-kept", size: CGSize(width: 420, height: 190)) { f in
                .window(AnyView(ReasonOnKeptSheet(model: Demo.model(f), reason: .blur)))
            },

            // The inspector, where his and the cull's never merge.
            SnapshotScene(name: "frame-inspector", size: CGSize(width: 300, height: 560)) { f in
                .window(AnyView(FrameInspector(model: Demo.model(f))))
            },
        ]
    }
}

/// The fixture, with the in-flight columns put in.
@MainActor
enum Demo {
    private static var cached: [String: ShootSession] = [:]

    /// `shoot-decided`, plus: a stack of four in the biggest burst, a face on
    /// every frame, and a handful of his own verdicts so the marks, the tally
    /// and the bracket all have something to draw.
    static func response(_ f: Fixtures) -> ShootResponse {
        let data = f.data("shoot-decided")
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var rows = obj["rows"] as? [[String: Any]] else {
            return (try? JSONDecoder().decode(ShootResponse.self, from: data))!
        }
        // The biggest burst on the dog shoot, by the key the engine writes.
        var counts: [String: [Int]] = [:]
        for (i, r) in rows.enumerated() {
            let key = "\(r["scene"] as? String ?? "")/\(r["burst"] as? String ?? "")"
            counts[key, default: []].append(i)
        }
        let biggest = counts.max { $0.value.count < $1.value.count }?.value ?? []
        for (n, i) in biggest.enumerated() {
            rows[i]["face_x"] = 0.46 + Double(n) * 0.01
            rows[i]["face_y"] = 0.34
            if n < 4 {
                rows[i]["stack"] = "s1"
                rows[i]["stack_top"] = n == 1 ? "1" : "0"
            }
            // His own presses: two kept, one out with a reason, the rest left.
            if n == 1 { rows[i]["override"] = 5 }
            if n == 3 { rows[i]["override"] = 3 }
            if n == 4 { rows[i]["override"] = 2; rows[i]["label"] = "blur" }
        }
        obj["rows"] = rows
        guard let remade = try? JSONSerialization.data(withJSONObject: obj),
              let decoded = try? JSONDecoder().decode(ShootResponse.self, from: remade) else {
            return (try? JSONDecoder().decode(ShootResponse.self, from: data))!
        }
        return decoded
    }

    static func session(_ f: Fixtures) -> ShootSession {
        if let s = cached["session"] { return s }
        let r = response(f)
        let s = ShootSession(response: r, ext: nil, client: f.client, pump: f.pump)
        cached["session"] = s
        return s
    }

    /// The one demo model, **put back the way it started on every ask**.
    ///
    /// There is one `ViewerModel` per session and the scenes below reach into
    /// it — Compare opens on a stack, All Bursts changes the mode, Full Image
    /// turns itself on, three scenes set a refusal. None of that was ever put
    /// back, so in a whole-set render every scene after `full-image` drew the
    /// light table with no control bar and no filmstrip, and the three refusal
    /// scenes leaked their sentence into everything after them. Each scene got
    /// the right picture on its own and the wrong one in the batch, which is
    /// the worst way for this to be wrong.
    static func model(_ f: Fixtures, portrait: Bool = false) -> ViewerModel {
        let s = session(f)
        let m = ViewerModel.shared(for: s)
        m.setFullImage(false)
        m.mode = .single
        m.compareSelection = []
        for owner in [RefusalOwner.verdict, .navigation] { s.refusals.clear(owner) }
        if portrait {
            // The biggest burst he shot with the camera on its end. The dog
            // shoot has sixteen such frames and they are real ones, so the
            // strip and the bar are drawn against the aspect they will meet.
            if let i = s.bursts.firstIndex(where: { b in
                b.frames.count > 3 && b.frames.allSatisfy { stem in
                    guard let r = s.rows[stem], let w = r.dw, let h = r.dh else { return false }
                    return w < h
                }
            }) {
                m.goToBurst(i)
            }
            return m
        }
        // The burst with the stack in it, which is the one worth looking at.
        if let i = s.bursts.firstIndex(where: { b in
            b.frames.contains { s.rows[$0]?.stack != nil }
        }) {
            m.goToBurst(i)
        }
        return m
    }

    static func stackFrames(_ m: ViewerModel) -> [String] {
        m.currentStack?.frames ?? Array(m.frames.prefix(4))
    }

    /// The four bands, without the window's own toolbar.
    static func table(_ f: Fixtures, model m: ViewerModel? = nil) -> some View {
        ChooseKeepersStep(model: m ?? model(f))
    }

    /// Another shoot's cull, a third of the way through.
    static let runningCull = Job(running: true, stopped: false, id: 7, kind: "cull",
                                 shoot: "2026-09-21-night", title: "culling 2026-09-21-night",
                                 stage: "faces", label: "judging faces: 512 of 1,558 frames",
                                 fraction: 0.33, elapsed: 360, remaining: 720,
                                 remaining_text: "about 12 minutes left")

    /// A presets run the engine turned down, with its one sentence.
    static let refusedPresets = Job(running: false, stopped: false, id: 8, kind: "presets",
                                    shoot: "2026-09-19", title: "presets for 2026-09-19",
                                    log: "$ python presets.py 2026-09-19\nthere are no keepers to write presets for",
                                    code: 2)

    static func app(_ f: Fixtures, portrait: Bool = false) -> AppModel {
        let library = f.makeLibrary()
        library.adopt(session(f))
        let nav = Navigation(selection: .step(shoot: session(f).name, step: "keepers"))
        LightTableRegistration.register(navigation: nav)
        _ = model(f, portrait: portrait)
        return AppModel(preview: library, state: .running(f.endpoint), navigation: nav)
    }
}
