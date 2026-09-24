import AppKit
import SwiftUI
import PipelineKit

/// Copy the Card through a whole evening (DESIGN.md §2.6): two cards in, the
/// card's own day in the name, a copy going on while the card comes out, a
/// copy on the list, the result, a copy that did not finish, and a shoot's
/// own record of its copy afterwards.
///
/// The card page's state belongs to the app (`ImportModel`), so each scene
/// puts it there the way a real evening would have left it.
final class ImportStepScenes: SceneProvider {

    static let standard = CGSize(width: 1100, height: 780)
    static let untitled = "/Volumes/Untitled"
    static let second = "/Volumes/Untitled 1"

    override class var scenes: [SnapshotScene] {
        StepScenes.prepare()
        return [
            // Two cards in, and the second chosen in the sidebar: the page is
            // that card's, with its own count and its own day.
            SnapshotScene(name: "card-two-cards-second", size: standard) { f in
                let app = cardApp(f, cards: [untitled, second], selected: second)
                app.importModel.preview(scan: CardScan(photographs: 1_558, day: "2026-09-19"), for: untitled)
                app.importModel.preview(scan: CardScan(photographs: 412, day: "2026-09-20"), for: second)
                return .window(AnyView(RootView(app: app)))
            },
            // The card's day is a shoot already: the name waits for what this
            // one was, and says so without a red rule.
            SnapshotScene(name: "card-day-taken", size: standard) { f in
                let app = cardApp(f, cards: [untitled], selected: untitled)
                app.importModel.preview(scan: CardScan(photographs: 1, day: "2026-09-19"), for: untitled)
                return .window(AnyView(RootView(app: app)))
            },
            // The card's newest photograph is already in a shoot.
            SnapshotScene(name: "card-already-copied", size: standard) { f in
                let app = cardApp(f, cards: [untitled], selected: untitled)
                app.importModel.preview(scan: CardScan(photographs: 1_558, day: "2026-09-19", copiedAs: "2026-09-19"),
                                        for: untitled)
                return .window(AnyView(RootView(app: app)))
            },
            // The extension's kind question, under the name, on the kind of
            // his newest shoot.
            SnapshotScene(name: "card-kind", size: standard) { f in
                let app = cardApp(f, cards: [untitled], selected: untitled, ext: true)
                app.importModel.preview(scan: CardScan(photographs: 1_558, day: "2026-09-23"), for: untitled)
                return .window(AnyView(RootView(app: app)))
            },
            // On the list behind a cull of his.
            SnapshotScene(name: "card-listed", size: standard) { f in
                let app = cardApp(f, cards: [untitled], selected: untitled)
                app.importModel.preview(copy: .init(card: untitled, shoot: "2026-09-23-night", verify: "end",
                                                    id: 7, listed: true))
                app.jobs.take(Job(running: true, stopped: false, id: 6, kind: "cull", shoot: "2026-09-19",
                                  title: "culling 2026-09-19", label: "looking at faces: 612 of 1,558 frames",
                                  fraction: 0.39, elapsed: 201))
                return .window(AnyView(RootView(app: app)))
            },
            // The card came out while it copied.
            SnapshotScene(name: "card-came-out", size: standard) { f in
                let app = cardApp(f, cards: [], selected: untitled,
                                  job: Job(running: true, stopped: false, id: 7, kind: "ingest",
                                           shoot: "2026-09-23-night", title: "copying the card into 2026-09-23-night",
                                           label: "copying: 412 of 1,558 files", fraction: 0.26, elapsed: 96))
                var copy = ImportModel.Copy(card: untitled, shoot: "2026-09-23-night", verify: "in-flight", id: 7)
                copy.cardCameOut = true
                app.importModel.preview(copy: copy)
                return .window(AnyView(RootView(app: app)))
            },
            // It finished, and the card was ejected.
            SnapshotScene(name: "card-copied", size: standard) { f in
                let app = cardApp(f, cards: [], selected: untitled)
                app.importModel.preview(ending: .done, card: untitled, shoot: "2026-09-19", verify: "end", eject: .done)
                return .window(AnyView(RootView(app: app)))
            },
            // It finished, and the cull of the shoot started by itself.
            SnapshotScene(name: "card-copied-culling", size: standard) { f in
                let app = cardApp(f, cards: [], selected: untitled,
                                  job: Job(running: true, stopped: false, id: 8, kind: "cull", shoot: "2026-09-19",
                                           title: "culling 2026-09-19", label: "looking at faces: 61 of 1,558 frames",
                                           fraction: 0.04, elapsed: 12))
                app.importModel.preview(ending: .done, card: untitled, shoot: "2026-09-19", verify: "end", eject: .done)
                return .window(AnyView(RootView(app: app)))
            },
            // It finished with the card still in.
            SnapshotScene(name: "card-copied-still-in", size: standard) { f in
                let app = cardApp(f, cards: [untitled], selected: untitled)
                app.importModel.preview(ending: .done, card: untitled, shoot: "2026-09-19", verify: "end")
                return .window(AnyView(RootView(app: app)))
            },
            // The card came out part way, and is not back.
            SnapshotScene(name: "card-stopped-short", size: standard) { f in
                let app = cardApp(f, cards: [], selected: untitled, halfShoot: true)
                app.importModel.preview(ending: .failed, card: untitled, shoot: "2026-09-23-night", cardCameOut: true)
                return .window(AnyView(RootView(app: app)))
            },
            // He stopped it, with the card still in.
            SnapshotScene(name: "card-stopped-by-him", size: standard) { f in
                let app = cardApp(f, cards: [untitled], selected: untitled, halfShoot: true)
                app.importModel.preview(scan: CardScan(photographs: 1_558, day: "2026-09-23"), for: untitled)
                app.importModel.preview(ending: .stopped, card: untitled, shoot: "2026-09-23-night")
                return .window(AnyView(RootView(app: app)))
            },
            // He put the card back after the copy stopped: it finishes into
            // the shoot it stopped in, taking only what did not arrive.
            SnapshotScene(name: "card-finish-the-copy", size: standard) { f in
                let app = cardApp(f, cards: [untitled], selected: untitled, halfShoot: true)
                var scan = CardScan(photographs: 1_558, day: "2026-09-23")
                scan.contents = try? CardContents(fields: Fields([
                    "path": .string(untitled), "photographs": .integer(1_558), "copied_as": .string("2026-09-23-night"),
                    "held": .integer(412), "stopped": .bool(true)]))
                app.importModel.preview(scan: scan, for: untitled)
                app.importModel.preview(ending: .stopped, card: untitled, shoot: "2026-09-23-night")
                return .window(AnyView(RootView(app: app)))
            },
            // A second camera's card on the same night: a new shoot unless he
            // chooses the night's shoot, which has not been culled.
            SnapshotScene(name: "card-second-card", size: standard) { f in
                let app = cardApp(f, cards: [second], selected: second, halfShoot: true, copied: true)
                app.importModel.preview(scan: CardScan(photographs: 986, day: "2026-09-23"), for: second)
                return .window(AnyView(RootView(app: app)))
            },
            // The night's first card stopped part way: a second camera's card
            // is not offered that shoot, only a new one.
            SnapshotScene(name: "card-second-card-half", size: standard) { f in
                let app = cardApp(f, cards: [second], selected: second, halfShoot: true)
                app.importModel.preview(scan: CardScan(photographs: 986, day: "2026-09-23"), for: second)
                return .window(AnyView(RootView(app: app)))
            },
            // The engine restarted while it copied, and the card is still in.
            SnapshotScene(name: "card-engine-stopped", size: standard) { f in
                let app = cardApp(f, cards: [untitled], selected: untitled, halfShoot: true)
                app.importModel.preview(scan: CardScan(photographs: 1_558, day: "2026-09-23"), for: untitled)
                app.importModel.preview(ending: .failed, card: untitled, shoot: "2026-09-23-night", engineRestarted: true)
                return .window(AnyView(RootView(app: app)))
            },
            // A shoot's own Copy the Card step afterwards.
            SnapshotScene(name: "card-report", size: standard) { f in
                .window(AnyView(RootView(app: StepScenes.shootApp(f, "shoot-decided", step: "ingest"))))
            },
            // The same step for a copy the card was pulled out of: Cull is
            // there, but not the Return key.
            SnapshotScene(name: "card-report-stopped", size: standard) { f in
                .window(AnyView(RootView(app: StepScenes.shootApp(
                    f, "shoot-decided", step: "ingest",
                    patchInfo: ["frames": 412, "ingest": ["state": "stopped", "files": 412, "of": 1_558]]))))
            },
            // A card goes in while he chooses keepers with the sidebar hidden:
            // the line floats over the top of the page, and the photograph
            // stays exactly where it was.
            SnapshotScene(name: "card-notice", size: standard) { f in
                LightTableRegistration.register()
                let app = Demo.app(f)
                app.navigation.sidebarShown = false
                app.importModel.preview(notice: Strings.Import.cardIsIn("Untitled"), card: untitled)
                return .window(AnyView(RootView(app: app)))
            },
            // A card goes in just after the engine restarted: the two lines
            // stack under the burst scrubber rather than print over each
            // other.
            SnapshotScene(name: "card-notice-banner", size: standard) { f in
                LightTableRegistration.register()
                let app = Demo.app(f)
                app.navigation.sidebarShown = false
                app.banner = Strings.Engine.restarted
                app.importModel.preview(notice: Strings.Import.cardIsIn("Untitled"), card: untitled)
                return .window(AnyView(RootView(app: app)))
            },
            // The same page with no card: the photograph to measure against.
            SnapshotScene(name: "card-notice-none", size: standard) { f in
                LightTableRegistration.register()
                let app = Demo.app(f)
                app.navigation.sidebarShown = false
                return .window(AnyView(RootView(app: app)))
            },
        ]
    }

    /// The card page, with these cards in and this one chosen.
    static func cardApp(_ f: Fixtures, cards: [String], selected: String, job: Job? = nil,
                        ext: Bool = false, halfShoot: Bool = false, copied: Bool = false) -> AppModel {
        let response = patched(f, cards: cards, ext: ext, halfShoot: halfShoot, copied: copied)
        let lib = response.map { Library(preview: $0, client: f.client, pump: f.pump) } ?? f.makeLibrary()
        let app = AppModel(preview: lib, state: .running(f.endpoint), navigation: Navigation(selection: .card(selected)))
        StepJobs.shared = { app.jobs }
        StepJobs.previewJob = job
        return app
    }

    /// `/api/shoots` with these cards in, an extension that asks its
    /// question when wanted, and a shoot a copy stopped part way into - or,
    /// `copied`, the same night's shoot with its first card all there.
    static func patched(_ f: Fixtures, cards: [String], ext: Bool, halfShoot: Bool,
                        copied: Bool = false) -> ShootsResponse? {
        guard var object = try? JSONSerialization.jsonObject(with: f.data("shoots")) as? [String: Any] else {
            return nil
        }
        object["cards"] = cards
        var shoots = object["shoots"] as? [[String: Any]] ?? []
        if ext {
            let kind = shoots.first?["kind"] as? String ?? "redacted"
            object["ext"] = ["kind": kind, "steps": [], "labels": [:], "every": [],
                             "ask": ["question": "Is this one of the extension's shoots?", "yes": "Yes", "no": "No",
                                     "blurb": "Its own steps are added to the shoot."]]
        }
        if halfShoot, var half = shoots.first {
            half["name"] = "2026-09-23-night"
            half["path"] = "/scratch/photos/shoots/2026-09-23-night"
            half["raw"] = "/scratch/photos/shoots/2026-09-23-night/raw"
            half["frames"] = copied ? 1_558 : 412
            half["culled"] = false
            half["ingest"] = copied ? ["state": "done", "files": 1_558, "proof": "hashed on the way in and read back"]
                                    : ["state": "stopped", "files": 412, "of": 1_558]
            shoots.insert(half, at: 0)
        }
        object["shoots"] = shoots
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(ShootsResponse.self, from: data)
    }
}
