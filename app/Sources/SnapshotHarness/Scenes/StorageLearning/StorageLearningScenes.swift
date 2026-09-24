import AppKit
import SwiftUI
import PipelineKit

/// Every screen this crew owns, rendered from fixtures the real engine wrote.
///
/// The only shoot any of these draws a photograph of is `2026-09-13-dog`.
final class StorageLearningScenes: SceneProvider {
    override class var scenes: [SnapshotScene] {
        storage + learning + firstRun + settings
    }

    // MARK: §2.8 — the panel, in four states, and the sheets

    static var storage: [SnapshotScene] {
        [
            scene("storage-here-only", 900, 780) { f in
                StoragePanel(model: f.storageModel("storage", of: "2026-09-13-dog"))
            },
            scene("storage-both", 900, 780) { f in
                StoragePanel(model: f.storageModel("StorageLearning/storage-both",
                                                   of: "2026-09-13-dog"))
            },
            scene("storage-icloud-only", 900, 780) { f in
                StoragePanel(model: f.storageModel("StorageLearning/storage-icloud-only",
                                                   of: "2026-09-13-dog",
                                                   frames: "StorageLearning/storage-frames-icloud"))
            },
            scene("storage-missing", 900, 780) { f in
                StoragePanel(model: f.storageModel("StorageLearning/storage-mixed",
                                                   of: "2026-09-13-dog"))
            },
            // The job the panel started, at the top of the panel while it
            // runs, and the one line after it ends. The panel used to load
            // once and never again, so a finished copy still read "nothing in
            // iCloud" until he left the page.
            scene("storage-job-running", 900, 780) { f in
                StoragePanel(model: StorageModel(
                    shoot: "2026-09-13-dog",
                    storage: f.decode(Storage.self, "storage"),
                    following: Job(running: true, stopped: false, id: 12, kind: "stor-push",
                                   shoot: "2026-09-13-dog",
                                   title: "copying the RAWs of 2026-09-13-dog to iCloud",
                                   stage: "push", label: "copying up: 20 of 54 frames",
                                   fraction: 0.37, elapsed: 41, remaining: 70,
                                   remaining_text: "about 1 minute left")))
            },
            scene("storage-job-ended", 900, 780) { f in
                StoragePanel(model: StorageModel(
                    shoot: "2026-09-13-dog",
                    storage: f.decode(Storage.self, "StorageLearning/storage-both"),
                    ended: .init(title: "checking every original of 2026-09-13-dog", outcome: .done,
                                 line: "54 unchanged · 0 drifted · 0 not recorded yet · 0 gone")))
            },
            // After a copy, which is the ending he meets most: the result
            // in the app's words, and the panel read again under it.
            scene("storage-job-ended-copy", 900, 780) { f in
                StoragePanel(model: StorageModel(
                    shoot: "2026-09-13-dog",
                    storage: f.decode(Storage.self, "StorageLearning/storage-both"),
                    ended: .init(title: "copying the RAWs of 2026-09-13-dog to iCloud", outcome: .done,
                                 line: "54 copied and verified, 0 failed. iCloud still has to upload them, "
                                     + "and Remove the Local RAWs takes none until it has.")))
            },
            scene("storage-library", 900, 700) { f in
                LibraryStorage(app: f.makeApp(selection: .storage),
                               line: f.decode(LibraryLine.self, "storage-library"))
            },
            // The middle rung: the engine's plan verbatim, the button reading
            // the consequence, and Cancel as the default.
            scene("storage-plan-drop", 620, 330) { f in
                PlanSheet(rung: .removesACopy,
                          request: StorageModel.Request("drop"),
                          model: f.storageModel("StorageLearning/storage-both",
                                                of: "2026-09-13-dog",
                                                plan: "StorageLearning/plan-drop",
                                                drawnFor: StorageModel.Request("drop"))) {}
            },
            scene("storage-plan-reclaim", 620, 480) { f in
                PlanSheet(rung: .removesACopy,
                          request: StorageModel.Request("reclaim"),
                          model: f.storageModel("StorageLearning/storage-both",
                                                of: "2026-09-21",
                                                plan: "StorageLearning/plan-reclaim",
                                                drawnFor: StorageModel.Request("reclaim"))) {}
            },
            // The one rung that deletes photographs, with the checkbox ticked
            // and the field still empty: the red button is off.
            scene("storage-expire-gate", 620, 620) { f in
                ExpireSheet(shoot: "2026-09-13-dog",
                            model: f.storageModel("StorageLearning/storage-icloud-only",
                                                  of: "2026-09-13-dog",
                                                  plan: "StorageLearning/plan-expire-originals",
                                                  drawnFor: StorageModel.Request(
                                                      "expire", PlanOptions(originals: true))),
                            includeOnlyCopies: true) {}
            },
            // The same rung before the checkbox is ticked: nothing ceases to
            // exist, so there is nothing to type.
            scene("storage-expire-unticked", 620, 620) { f in
                ExpireSheet(shoot: "2026-09-13-dog",
                            model: f.storageModel("StorageLearning/storage-icloud-only",
                                                  of: "2026-09-13-dog",
                                                  plan: "StorageLearning/plan-expire",
                                                  drawnFor: StorageModel.Request("expire"))) {}
            },
            // What he saw on the day, and what he sees now. Same button, same
            // moment: the learning run going, and him wanting the RAWs on
            // iCloud. Before, this sheet held one red sentence — "a job is
            // already running" — and nothing else.
            //
            // It does not happen any more: the learning run stands down and
            // the list is drawn. The line at the bottom is what he is told
            // about it afterwards.
            scene("storage-plan-push-homework-paused", 620, 420) { f in
                PlanSheet(rung: nil,
                          request: StorageModel.Request("push"),
                          model: StorageModel(
                            shoot: "2026-09-21",
                            storage: f.decode(Storage.self, "StorageLearning/storage-both"),
                            plan: f.decode(Plan.self, "StorageLearning/plan-drop"),
                            drawnFor: StorageModel.Request("push"),
                            paused: "Learning paused; it will pick up when you are finished.")) {}
            },
            // And when what IS in the way is another job of HIS, which is the
            // one case that still has to wait: it says which job, where it
            // has got to, roughly how long is left, and the two things he can
            // do about it.
            scene("storage-plan-push-waiting-on-a-cull", 620, 380) { f in
                PlanSheet(rung: nil,
                          request: StorageModel.Request("push"),
                          model: StorageModel(
                            shoot: "2026-09-21",
                            storage: f.decode(Storage.self, "StorageLearning/storage-both"),
                            busy: Busy(id: 7, kind: "cull", title: "culling 2026-09-13-dog",
                                       shoot: "2026-09-13-dog", stage: "faces",
                                       label: "looking at faces: 240 of 1,157 frames",
                                       fraction: 0.38, elapsed: 154, remaining: 251,
                                       remaining_text: "about 4 minutes left",
                                       wanted: "working out what would go in 2026-09-21"),
                            refusal: "Working out what would go in 2026-09-21 has to wait: "
                                   + "culling 2026-09-13-dog — looking at faces: 240 of 1,157 "
                                   + "frames, about 4 minutes left.")) {}
            },
            // Once he has chosen to wait: the engine has it in the line, and
            // he can still take it back out.
            scene("storage-plan-push-in-the-line", 620, 380) { f in
                PlanSheet(rung: nil,
                          request: StorageModel.Request("push"),
                          model: StorageModel(
                            shoot: "2026-09-21",
                            storage: f.decode(Storage.self, "StorageLearning/storage-both"),
                            busy: Busy(id: 7, kind: "cull", title: "culling 2026-09-13-dog",
                                       shoot: "2026-09-13-dog", stage: "faces",
                                       label: "looking at faces: 240 of 1,157 frames",
                                       fraction: 0.38, elapsed: 154, remaining: 251,
                                       remaining_text: "about 4 minutes left"),
                            refusal: "Working out what would go in 2026-09-21 has to wait: "
                                   + "culling 2026-09-13-dog — looking at faces: 240 of 1,157 "
                                   + "frames, about 4 minutes left.",
                            waitingID: 9)) {}
            },
            scene("storage-replaces-work", 460, 220) { _ in
                ReplacesWorkSheet(title: "Cull this shoot again?",
                                  confirmLabel: "Cull It Again",
                                  note: "The cull reads the frames again and works out its own "
                                      + "shortlist from scratch.",
                                  confirm: {}, close: {})
            },
        ]
    }

    // MARK: §2.9 — the learning screen

    static var learning: [SnapshotScene] {
        [
            scene("learning", 1100, 780) { f in
                LearnedView(app: f.makeApp(selection: .learned),
                            model: f.learnedModel("StorageLearning/learned-dog"))
            },
            // §2.9, his library on 23 September: a starting edit IN USE
            // with a newer one held beside it, a version held for harm, and
            // a learner short of evidence - three lines, three symbols.
            scene("learning-in-use-beside-held", 1100, 980) { f in
                LearnedView(app: f.makeApp(selection: .learned),
                            model: f.learnedModel("StorageLearning/learned-in-use-beside-held"))
            },
            // The engine's real first answer: three learners that have
            // learned nothing, and the shoot just finished waiting.
            scene("learning-first-run", 1100, 700) { f in
                LearnedView(app: f.makeApp(selection: .learned),
                            model: f.learnedModel("StorageLearning/learned-first-run"))
            },
            // An engine that sends no learners at all: the empty state.
            scene("learning-empty", 1100, 700) { f in
                LearnedView(app: f.makeApp(selection: .learned),
                            model: f.learnedModel("StorageLearning/learned-empty"))
            },
            // §2.9 while it runs: which shoot, what it is doing now in the
            // engine's own words, how far along, roughly what is left, why
            // stopping it costs nothing, and Stop.
            //
            // What this replaced: the word "Learning…" over a bar that did
            // not move, because the six-minute stretch in the middle of the
            // run reported no stage at all.
            scene("learning-running", 1100, 700) { f in
                LearnedView(app: f.makeApp(selection: .learned),
                            model: f.learnedModel("StorageLearning/learned-running"))
            },
            // The same row in the whole window, with the toolbar's Activity
            // item beside it — the two places he can see it from, together.
            scene("learning-running-in-the-window", 1100, 780) { f in
                StorageLearningRegistration.register()
                let app = f.makeApp(selection: .learned)
                app.jobs.take(Job(running: true, stopped: false, id: 1, kind: "learn-learn",
                                  title: "Learning from 2026-09-21",
                                  stage: "exports",
                                  label: "reading the edits you exported: 144 of 288 frames",
                                  fraction: 0.53, elapsed: 212, remaining: 188,
                                  remaining_text: "about 3 minutes left",
                                  background: true, why: "you finished 2026-09-21"))
                let model = f.learnedModel("StorageLearning/learned-running")
                StepRegistry.registerLibrary("learned") { _ in
                    AnyView(LearnedView(app: app, model: model))
                }
                return RootView(app: app)
            },
            // The toolbar item opened: what is running, where it has got to,
            // why it is safe to stop, and the two ways out of it.
            scene("activity-learning", 360, 250) { _ in
                ActivityPopover(
                    job: Job(running: true, stopped: false, id: 1, kind: "learn-learn",
                             title: "Learning from 2026-09-21", stage: "exports",
                             label: "reading the edits you exported: 144 of 288 frames",
                             fraction: 0.53, elapsed: 212, remaining: 188,
                             remaining_text: "about 3 minutes left",
                             background: true, why: "you finished 2026-09-21"),
                    stop: {}, openLearning: {})
            },
            scene("learning-unreadable", 1100, 620) { f in
                LearnedView(app: f.makeApp(selection: .learned),
                            model: f.learnedModel("StorageLearning/learned-unreadable"))
            },
            // The read-only review: the photographs a held learner would
            // cost him, with what happens to each in words. Keep and Drop
            // are off, and "Use It Anyway" exists here and nowhere else.
            scene("learning-review", 900, 640) { f in
                let model = f.learnedModel("StorageLearning/learned-dog")
                return Group {
                    if let learner = model.learners.first {
                        ReviewModeHost(learner: learner, model: model,
                                       app: f.makeApp(selection: .learned),
                                       pump: f.pump) {}
                    }
                }
            },
            // A run has just landed: the one line saying what it changed,
            // and What Changed beside it. Nothing ever set this banner.
            scene("learning-banner", 1100, 700) { f in
                let l = f.decode(Learned.self, "StorageLearning/learned-in-use-beside-held")!
                return LearnedView(app: f.makeApp(selection: .learned),
                                   model: LearnedModel(preview: l,
                                                       banner: "The cull learned from 2026-09-19. "
                                                           + Strings.Learning.bannerInUseEdit("Your starting edit"),
                                                       bannerLearner: "edit"))
            },
            // The review behind "See the 48": four shoots, grouped by what
            // would change, the costly group first and each change said once.
            scene("learning-review-grouped", 900, 640) { f in
                let model = f.learnedModel("StorageLearning/learned-in-use-beside-held")
                return Group {
                    if let learner = model.learners.first {
                        ReviewModeHost(learner: learner, model: model,
                                       app: f.makeApp(selection: .learned),
                                       pump: f.pump) {}
                    }
                }
            },
            // The whole window at its default size, which is where the
            // sidebar row for this screen was being cut off mid-word.
            scene("learning-in-the-window", 1100, 780) { f in
                StorageLearningRegistration.register()
                let app = f.makeApp(selection: .learned)
                let model = f.learnedModel("StorageLearning/learned-dog")
                StepRegistry.registerLibrary("learned") { _ in
                    AnyView(LearnedView(app: app, model: model))
                }
                return RootView(app: app)
            },
            // And the storage row beside it, in the same window.
            // The panel where he meets it: on Finish, under the exports card,
            // handed over through the same slot the app fills at launch.
            scene("storage-on-finish", 1100, 780) { f in
                StepScenes.prepare()
                let panel = f.storageModel("storage", of: "2026-09-13-dog")
                StepSlots.storagePanel = { _ in AnyView(StoragePanel(model: panel)) }
                return RootView(app: StepScenes.shootApp(f, "shoot-decided", step: "done"))
            },
            // Arriving from a row of the library's Storage page: the same
            // page, with the panel brought into view.
            scene("storage-on-finish-arrived", 1100, 780) { f in
                StepScenes.prepare()
                let panel = f.storageModel("storage", of: "2026-09-13-dog")
                StepSlots.storagePanel = { _ in AnyView(StoragePanel(model: panel)) }
                StorageArrival.ask(for: "2026-09-13-dog")
                return RootView(app: StepScenes.shootApp(f, "shoot-decided", step: "done"))
            },
            scene("storage-in-the-window", 1100, 780) { f in
                StorageLearningRegistration.register()
                let app = f.makeApp(selection: .storage)
                let line = f.decode(LibraryLine.self, "storage-library")
                StepRegistry.registerLibrary("storage") { _ in
                    AnyView(LibraryStorage(app: app, line: line))
                }
                return RootView(app: app)
            },
        ]
    }

    // MARK: §2.10 — first run, with nothing installed

    static var firstRun: [SnapshotScene] {
        (0..<FirstRunSheet.pages).map { page in
            scene("first-run-\(page + 1)",
                  Tokens.Metric.firstRunSheet.width,
                  Tokens.Metric.firstRunSheet.height) { _ in
                FirstRunSheet(world: .empty, settings: SettingsStore(defaults: scratchDefaults()),
                              startingAt: page) {}
            }
        } + [
            // The same page with a library already on the Mac. The folder is
            // a made-up path: a scene never looks at a real one.
            scene("first-run-2-found", Tokens.Metric.firstRunSheet.width,
                  Tokens.Metric.firstRunSheet.height) { _ in
                FirstRunSheet(world: .init(
                                existingLibrary: { (URL(fileURLWithPath: "/scratch/photos"), 7) },
                                editors: { [.init(id: "dxo", name: "DxO PhotoLab", url: nil)] }),
                              settings: SettingsStore(defaults: scratchDefaults()),
                              startingAt: 1) {}
            },
        ]
    }

    // MARK: §2.11 — Settings

    static var settings: [SnapshotScene] {
        SettingsView.Tab.allCases.map { tab in
            scene("settings-\(tab.rawValue)", 520, 420) { _ in
                SettingsView(settings: SettingsStore(defaults: scratchDefaults()),
                             hooks: .init(openLearning: {}, showLog: {},
                                          showSupportFolder: {}, extensionFolder: nil,
                                          showFirstRunAgain: {}),
                             tab: tab)
            }
        } + [
            // The library folder with a library under it: the line that says
            // where the engine will look and how many shoots are there. Only
            // drawn when `--library` names a scratch clone, because the count
            // in it is counted off a disk.
            scene("settings-library", 520, 420) { f in
                let store = SettingsStore(defaults: scratchDefaults())
                store.libraryFolder = f.library ?? URL(fileURLWithPath: "/nowhere/photos")
                return SettingsView(settings: store,
                                    hooks: .init(), tab: .general)
            },
        ]
    }

    // MARK: -

    private static func scene<V: View>(_ name: String, _ w: CGFloat, _ h: CGFloat,
                                       rendered: Bool = false,
                                       _ make: @escaping @MainActor @Sendable (Fixtures) -> V)
        -> SnapshotScene {
        SnapshotScene(name: name, size: CGSize(width: w, height: h)) { f in
            rendered ? .rendered(AnyView(make(f))) : .window(AnyView(make(f)))
        }
    }

    /// Defaults that exist only for the length of a render, so a snapshot
    /// never reads or writes his own settings.
    private static func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "photopipeline.snapshots") ?? .standard
    }
}

// MARK: - what a scene builds from

extension Fixtures {
    /// A storage panel that already has its answer and no engine behind it.
    @MainActor
    func storageModel(_ name: String, of shoot: String, frames: String? = nil,
                      plan: String? = nil,
                      drawnFor: StorageModel.Request? = nil) -> StorageModel {
        StorageModel(shoot: shoot,
                     storage: decode(Storage.self, name),
                     plan: plan.flatMap { decode(Plan.self, $0) },
                     drawnFor: drawnFor,
                     frames: frames.flatMap { decode(StorageFrames.self, $0)?.rows })
    }

    @MainActor
    func learnedModel(_ name: String) -> LearnedModel {
        LearnedModel(preview: decode(Learned.self, name)
            ?? (try! JSONDecoder().decode(Learned.self, from: Data(#"{"learners": []}"#.utf8))))
    }
}
