import AppKit
import SwiftUI
import PipelineKit

/// The foundation's scenes (DESIGN.md §5.0): the shell, the sidebar, the
/// library table and the engine-down view.
final class ShellScenes: SceneProvider {
    override class var scenes: [SnapshotScene] {
        let size = CGSize(width: 1100, height: 780)
        return [
            // The whole window with the smallest culled shoot selected and its
            // steps open in the sidebar.
            SnapshotScene(name: "shell", size: size) { f in
                let name = f.shoot?.info.name
                let app = f.makeApp(selection: name.map { .shoot($0) } ?? .allShoots)
                app.navigation.finishedExpanded = true
                return .window(AnyView(RootView(app: app)))
            },
            // A shoot's own page with another shoot's cull running: the
            // toolbar's status item in full, beside a title with room.
            SnapshotScene(name: "shell-job", size: size) { f in
                let name = f.shoot?.info.name
                let app = f.makeApp(selection: name.map { .shoot($0) } ?? .allShoots)
                app.jobs.take(Job(running: true, stopped: false, id: 7, kind: "cull",
                                  shoot: "2026-09-21-night", title: "culling 2026-09-21-night",
                                  stage: "faces", label: "judging faces: 512 of 1,558 frames",
                                  fraction: 0.33, elapsed: 360, remaining: 720,
                                  remaining_text: "about 12 minutes left"))
                return .window(AnyView(RootView(app: app)))
            },
            SnapshotScene(name: "shell-step", size: size) { f in
                let name = f.shoot?.info.name ?? ""
                let app = f.makeApp(selection: .step(shoot: name, step: "keepers"))
                return .window(AnyView(RootView(app: app)))
            },
            // The line after the engine was restarted, over the page.
            SnapshotScene(name: "shell-banner", size: size) { f in
                LightTableRegistration.register()
                let name = f.shoot?.info.name ?? ""
                let app = f.makeApp(selection: .step(shoot: name, step: "keepers"))
                app.banner = Strings.Engine.restarted
                return .window(AnyView(RootView(app: app)))
            },
            // The same page with no line over it: where "Back where you left
            // off" sits on its own, to measure the two above against.
            SnapshotScene(name: "shell-resume", size: size) { f in
                LightTableRegistration.register()
                let name = f.shoot?.info.name ?? ""
                let app = f.makeApp(selection: .step(shoot: name, step: "keepers"))
                return .window(AnyView(RootView(app: app)))
            },
            // The restart line and a card's line at once: "Back where you
            // left off" goes under both, where both used to hide it.
            SnapshotScene(name: "shell-banner-card", size: size) { f in
                LightTableRegistration.register()
                let name = f.shoot?.info.name ?? ""
                let app = f.makeApp(selection: .step(shoot: name, step: "keepers"))
                app.banner = Strings.Engine.restarted
                app.importModel.preview(notice: Strings.Import.cardIsIn("Untitled"), card: ImportStepScenes.untitled)
                return .window(AnyView(RootView(app: app)))
            },
            // Launch, reopened where he left off: a long library, and the
            // shoot he quit from finished and last in it, so the sidebar has
            // to open the Finished section and scroll to show it selected.
            SnapshotScene(name: "shell-reopened", size: size) { f in
                let name = f.shoot?.info.name ?? ""
                let app = f.makeApp(selection: .allShoots, response: Self.longLibrary(f, last: name))
                app.navigation.restore(.step(shoot: name, step: "presets"), finished: true)
                return .window(AnyView(RootView(app: app)))
            },
            // All Shoots when the list could not be read: the engine's
            // sentence and a way to ask again, not a spinner for ever.
            SnapshotScene(name: "library-unreadable", size: size) { f in
                let lib = Library(client: f.client, pump: f.pump)
                lib.refusals.set(.library, "the engine did not answer in time")
                let app = AppModel(preview: lib, state: .running(f.endpoint), navigation: Navigation(selection: .allShoots))
                return .window(AnyView(RootView(app: app)))
            },
            // A library command refused once the list is up: the sidebar's foot.
            SnapshotScene(name: "sidebar-refusal", size: CGSize(width: 260, height: 780)) { f in
                let app = f.makeApp(selection: .allShoots)
                app.library.refusals.set(.library, "that shoot's folder is not there any more")
                return .window(AnyView(NavigationStack { SidebarView(app: app) }))
            },
            // A new library folder waiting for a cull to end, said at the foot
            // of the sidebar with Don't Wait, where he sees it from any page.
            // It was said only in Settings, and the engine restarted on
            // another library with Settings closed and no word anywhere.
            SnapshotScene(name: "library-restart-waiting", size: size) { f in
                let app = f.makeApp(selection: .allShoots)
                return .window(AnyView(RootView(app: app, restarter: EngineRestart(preview: .init(
                    job: "the cull of 2026-09-19", folder: URL(fileURLWithPath: "/Volumes/Archive/photos"))))))
            },
            // The same wait once the cull is done, held while he is in Choose
            // Keepers so it never lands between two presses; and the line the
            // window shows once it has happened.
            SnapshotScene(name: "sidebar-restart-held", size: CGSize(width: 260, height: 780)) { f in
                let app = f.makeApp(selection: .allShoots)
                return .window(AnyView(NavigationStack {
                    SidebarView(app: app, restarter: EngineRestart(preview: .init(
                        job: "the cull of 2026-09-19", folder: URL(fileURLWithPath: "/Volumes/Archive/photos"),
                        forChoosing: true)))
                }))
            },
            SnapshotScene(name: "library-restarted", size: size) { f in
                let app = f.makeApp(selection: .allShoots)
                app.banner = Strings.Settings.restartedAfter("the cull of 2026-09-19", "/Volumes/Archive/photos")
                return .window(AnyView(RootView(app: app)))
            },
            // All Shoots: the library as a table.
            SnapshotScene(name: "library", size: size) { f in
                .window(AnyView(RootView(app: f.makeApp(selection: .allShoots))))
            },
            // The sidebar on its own, with every section open.
            SnapshotScene(name: "sidebar", size: CGSize(width: 260, height: 780)) { f in
                let app = f.makeApp(selection: f.shoot.map { .shoot($0.info.name) })
                app.navigation.finishedExpanded = true
                return .window(AnyView(NavigationStack { SidebarView(app: app) }))
            },
            // The sidebar with nothing in it. This was a blank column with no
            // word on it, and it is what he was looking at while all seven of
            // his shoots sat on the disk one folder away.
            // The folder is one that is not there, so a snapshot never looks in
            // his real library to draw it.
            SnapshotScene(name: "sidebar-empty", size: CGSize(width: 260, height: 780)) { f in
                let nothing = try? ShootsResponse(fields: Fields(["shoots": .array([]), "ready": .bool(true)]))
                let app = f.makeApp(selection: .allShoots, response: nothing)
                app.engineLibrary = { URL(fileURLWithPath: "/Volumes/Archive/photos", isDirectory: true) }
                return .window(AnyView(NavigationStack { SidebarView(app: app) }))
            },
            // An empty folder he has just started a library in, from this
            // sidebar: said as new, as Settings and the welcome say it, not as
            // a folder where nothing could be found. The folder is a scratch
            // one the scene makes, holding only the engine's empty shoots/.
            SnapshotScene(name: "sidebar-new-library", size: CGSize(width: 260, height: 780)) { f in
                let nothing = try? ShootsResponse(fields: Fields(["shoots": .array([]), "ready": .bool(true)]))
                let app = f.makeApp(selection: .allShoots, response: nothing)
                let started = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("photopipeline-snapshot-new-library", isDirectory: true)
                try? FileManager.default.createDirectory(at: started.appendingPathComponent("shoots"),
                                                         withIntermediateDirectories: true)
                app.engineLibrary = { started }
                return .window(AnyView(NavigationStack { SidebarView(app: app) }))
            },
            // The empty library as the page draws it: with no card, and with
            // a card in.
            SnapshotScene(name: "library-empty", size: size) { f in
                let nothing = try? ShootsResponse(fields: Fields(["shoots": .array([]), "ready": .bool(true)]))
                return .window(AnyView(RootView(app: f.makeApp(selection: .allShoots, response: nothing))))
            },
            SnapshotScene(name: "library-empty-card", size: size) { f in
                let nothing = try? ShootsResponse(fields: Fields(["shoots": .array([]), "ready": .bool(true),
                                                                  "cards": .array([.string("/Volumes/EOS_DIGITAL")])]))
                return .window(AnyView(RootView(app: f.makeApp(selection: .allShoots, response: nothing))))
            },
            // A library with one shoot whose decisions file will not read.
            // The broken shoot's own page, after a click on its red row.
            SnapshotScene(name: "shoot-broken", size: size) { f in
                .window(AnyView(RootView(app: f.makeApp(selection: .shoot("a-broken-shoot"),
                                                        response: f.shootsBroken))))
            },
            SnapshotScene(name: "library-broken", size: size) { f in
                .window(AnyView(RootView(app: f.makeApp(selection: .allShoots, response: f.shootsBroken))))
            },
            SnapshotScene(name: "engine-down", size: size) { f in
                let why = "Traceback (most recent call last): … ModuleNotFoundError: No module named 'cv2'"
                let app = f.makeApp(selection: .allShoots, state: .failed(why))
                return .window(AnyView(RootView(app: app)))
            },
            SnapshotScene(name: "engine-starting", size: size) { f in
                .window(AnyView(RootView(app: f.makeApp(selection: .allShoots, state: .starting))))
            },
            SnapshotScene(name: "refusal", size: CGSize(width: 520, height: 160)) { _ in
                .window(AnyView(
                    VStack(alignment: .leading) {
                        RefusalRow("that list was drawn for something else. Ask for it again.",
                                   owner: .storage, detail: "GET /api/storage/plan → 200")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ))
            },
        ]
    }

    /// The fixture library, its first shoot copied eighteen times over and the
    /// named one moved to the end, finished.
    @MainActor
    static func longLibrary(_ f: Fixtures, last name: String) -> ShootsResponse? {
        guard var top = (try? JSONSerialization.jsonObject(with: f.data("shoots"))) as? [String: Any],
              let rows = top["shoots"] as? [[String: Any]], let first = rows.first
        else { return f.shoots }
        var out: [[String: Any]] = (1...18).map { i in
            var r = first
            r["name"] = String(format: "2026-08-%02d", i)
            r["finished"] = false
            return r
        }
        var mine = rows.first { ($0["name"] as? String) == name } ?? first
        mine["name"] = name
        mine["finished"] = true
        out.append(mine)
        top["shoots"] = out
        guard let d = try? JSONSerialization.data(withJSONObject: top) else { return f.shoots }
        return try? JSONDecoder().decode(ShootsResponse.self, from: d)
    }
}
