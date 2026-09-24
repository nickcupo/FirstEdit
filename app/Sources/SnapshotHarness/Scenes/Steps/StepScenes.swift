import AppKit
import SwiftUI
import PipelineKit

/// The workflow steps' scenes (DESIGN.md §5.2): each step before and after its
/// action, each step mid-job, the cull's report, and the two sheets.
///
/// Everything is drawn in the real window — sidebar, unified toolbar, the
/// bottom action bar — because the thing being checked is where the controls
/// are, and a view rendered on its own cannot answer that.
final class StepScenes: SceneProvider {

    static let standard = CGSize(width: 1100, height: 780)

    override class var scenes: [SnapshotScene] {
        prepare()
        return [
            // Copy the Card, with a card in and a name typed.
            SnapshotScene(name: "steps-copy-the-card", size: standard) { f in
                .window(AnyView(RootView(app: cardApp(f, cards: ["/Volumes/SONY-A6500"]))))
            },
            SnapshotScene(name: "steps-copy-the-card-no-card", size: standard) { f in
                .window(AnyView(RootView(app: cardApp(f, cards: []))))
            },
            SnapshotScene(name: "steps-copy-the-card-running", size: standard) { f in
                let app = cardApp(f, cards: ["/Volumes/SONY-A6500"],
                                  job: Job(running: true, stopped: false, kind: "ingest",
                                           shoot: "2026-09-22-lake", title: "copying the card into 2026-09-22-lake",
                                           stage: "copy", label: "copying: 412 of 1,157 frames",
                                           fraction: 0.356, elapsed: 74))
                return .window(AnyView(RootView(app: app)))
            },

            // Cull, before and after, and mid-run.
            SnapshotScene(name: "steps-cull-before", size: standard) { f in
                .window(AnyView(RootView(app: shootApp(f, "shoot-not-culled", step: "cull"))))
            },
            // A new shoot starting from his last shoot's settings, as the
            // engine answers for a shoot no cull was asked of yet.
            SnapshotScene(name: "steps-cull-before-as-last-time", size: standard) { f in
                .window(AnyView(RootView(app: shootApp(f, "shoot-not-culled", step: "cull",
                                                       patchInfo: ["style": "action", "focus": 1.6,
                                                                   "cull_from": "2026-09-19"]))))
            },
            // The capture is from before the engine kept what a finished cull
            // ran with; an engine that keeps it sends this beside the results.
            SnapshotScene(name: "steps-cull-report", size: standard) { f in
                .window(AnyView(RootView(app: shootApp(f, "shoot-decided", step: "cull", patchInfo: ranWith))))
            },
            // The report with Settings for Cull Again opened, which is shut
            // until he opens it.
            SnapshotScene(name: "steps-cull-report-settings", size: standard) { f in
                let app = shootApp(f, "shoot-decided", step: "cull", patchInfo: ranWith)
                if case .step(let name, _) = app.navigation.selection,
                   let s = app.library.cachedSession(for: name) {
                    StepsModelStore.shared.model(for: s, jobs: app.jobs).cullSettingsShown = true
                }
                return .window(AnyView(RootView(app: app)))
            },
            SnapshotScene(name: "steps-cull-running", size: standard) { f in
                let app = shootApp(f, "shoot-not-culled", step: "cull",
                                   job: Job(running: true, stopped: false, kind: "cull",
                                            shoot: "ducksAndDeadlifts", title: "culling ducksAndDeadlifts",
                                            stage: "faces", label: "looking at faces: 61 of 98 frames",
                                            fraction: 0.42, elapsed: 53,
                                            remaining: 240, remaining_text: "about 4 minutes left"))
                return .window(AnyView(RootView(app: app)))
            },
            // A cull asked for behind his presets is on the list, second
            // after a gather, which is where the Cull page puts it — never a
            // wait held on the page, which leaving the page used to drop.
            // It was put there at 1.6 with people moving, and the held
            // controls say so rather than what the shoot last said.
            SnapshotScene(name: "steps-cull-queued", size: standard) { f in
                let app = shootApp(f, "shoot-not-culled", step: "cull",
                                   job: Job(running: true, stopped: false, kind: "presets",
                                            shoot: "2026-09-13-dog", title: "presets for 2026-09-13-dog",
                                            stage: "presets", label: "reading the light: 3 of 6 scenes",
                                            fraction: 0.5, elapsed: 21))
                let list = QueueModel()
                list.take(QueueState(
                    waiting: [QueueItem(id: 4, kind: "gather", shoot: "2026-09-13-dog"),
                              QueueItem(id: 5, kind: "cull", shoot: "ducksAndDeadlifts",
                                        options: ["focus": .number(1.6), "style": .string("action")])],
                    listed: 3, running: true, kind: "presets", shoot: "2026-09-13-dog"))
                Queues.shared = { list }
                return .window(AnyView(RootView(app: app)))
            },
            // A cull that ran out of memory: said beside Cull It, in the
            // alarm colour, with the way to its log - not the page as it was
            // before he pressed it.
            SnapshotScene(name: "steps-cull-failed", size: standard) { f in
                let app = shootApp(f, "shoot-not-culled", step: "cull")
                ended(app, kind: "cull", title: "culling ducksAndDeadlifts",
                      log: "$ pipeline/cull.py ducksAndDeadlifts\n  looking at faces … 61\n"
                        + "Traceback (most recent call last):\n  File \"pipeline/cull.py\", line 900\nMemoryError")
                return .window(AnyView(RootView(app: app)))
            },

            // The primary while something of his is running: it says where
            // pressing it goes. ⌥ says the same thing with nothing running,
            // which is how he stacks an evening up from the step pages
            // without going to the Activity window at all.
            SnapshotScene(name: "steps-cull-adds-to-the-list", size: standard) { f in
                let app = shootApp(f, "shoot-not-culled", step: "cull",
                                   job: Job(running: true, stopped: false, kind: "presets",
                                            shoot: "2026-09-13-dog", title: "presets for 2026-09-13-dog",
                                            stage: "presets", label: "reading the light: 3 of 6 scenes",
                                            fraction: 0.5, elapsed: 21))
                Queues.shared = { queueModel(f) }
                return .window(AnyView(RootView(app: app)))
            },
            SnapshotScene(name: "steps-cull-option-held", size: CGSize(width: 900, height: 140)) { _ in
                Queues.reset()
                return .window(AnyView(
                    StepActionBar {
                        Text(Strings.Cull.estimate(4)).font(.callout).foregroundStyle(.secondary)
                    } box: {
                        StepPrimary(Strings.Cull.run, wouldWait: false, doItNow: {}, addToTheList: {})
                            .environment(\.stepOptionKey, true)
                    }))
            },

            // Presets: the honest split, and afterwards.
            SnapshotScene(name: "steps-presets", size: standard) { f in
                .window(AnyView(RootView(app: shootApp(f, "shoot-decided", step: "presets"))))
            },
            // After a run, as today's engine reports it: what the run did,
            // not what is lying on the disk.
            SnapshotScene(name: "steps-presets-ran", size: standard) { f in
                .window(AnyView(RootView(app: shootApp(f, "shoot-decided", step: "presets",
                                                       patchInfo: ["presets_ran": ["wrote": 285, "changed": 83,
                                                                                   "already": 0]]))))
            },
            // After Write Them Again: every frame written, his own edited
            // frames under his changes.
            SnapshotScene(name: "steps-presets-rewritten", size: standard) { f in
                .window(AnyView(RootView(app: shootApp(f, "shoot-decided", step: "presets",
                                                       patchInfo: ["presets_ran": ["wrote": 368, "changed": 0,
                                                                                   "already": 0, "under": 14]]))))
            },
            SnapshotScene(name: "steps-presets-running", size: standard) { f in
                let app = shootApp(f, "shoot-decided", step: "presets",
                                   job: Job(running: true, stopped: false, kind: "presets",
                                            shoot: "2026-09-13-dog", title: "presets for 2026-09-13-dog",
                                            stage: "presets", label: "reading the light: 2 of 6 scenes",
                                            fraction: 0.31, elapsed: 18,
                                            remaining: 40, remaining_text: "about a minute left"))
                return .window(AnyView(RootView(app: app)))
            },
            // The presets written again, and failing: the failure first,
            // then what the last good run left.
            SnapshotScene(name: "steps-presets-failed", size: standard) { f in
                let app = shootApp(f, "shoot-decided", step: "presets")
                ended(app, kind: "presets", title: "presets for ducksAndDeadlifts",
                      log: "$ pipeline/presets.py ducksAndDeadlifts\nTraceback (most recent call last):\n"
                        + "  File \"pipeline/presets.py\", line 88\nOSError: [Errno 28] No space left on device")
                return .window(AnyView(RootView(app: app)))
            },
            SnapshotScene(name: "steps-presets-refused", size: standard) { f in
                let app = shootApp(f, "shoot-decided", step: "presets")
                app.jobs.refusals.set(.job, "a job is already running")
                return .window(AnyView(RootView(app: app)))
            },

            // Edit in PhotoLab.
            SnapshotScene(name: "steps-edit", size: standard) { f in
                .window(AnyView(RootView(app: shootApp(f, "shoot-decided", step: "edit",
                                                       patchInfo: ["export_dirs": exportDirs(f)]))))
            },
            // Before any preset is written, and while they are: Open is not
            // the thing to press, because PhotoLab would keep a record of the
            // folder from before its presets were there.
            SnapshotScene(name: "steps-edit-no-presets", size: standard) { f in
                .window(AnyView(RootView(app: shootApp(f, "shoot-decided", step: "edit",
                                                       patchInfo: ["presets": 0, "sidecars": 0]))))
            },
            SnapshotScene(name: "steps-edit-presets-running", size: standard) { f in
                let app = shootApp(f, "shoot-decided", step: "edit",
                                   job: Job(running: true, stopped: false, kind: "presets",
                                            shoot: "2026-09-13-dog", title: "presets for 2026-09-13-dog",
                                            stage: "presets", label: "reading the light: 2 of 6 scenes",
                                            fraction: 0.31, elapsed: 18),
                                   patchInfo: ["presets": 0, "sidecars": 0])
                return .window(AnyView(RootView(app: app)))
            },

            // Finish, before and after.
            SnapshotScene(name: "steps-finish", size: standard) { f in
                .window(AnyView(RootView(app: shootApp(f, "shoot-decided", step: "done"))))
            },
            SnapshotScene(name: "steps-finish-finished", size: standard) { f in
                // A shoot the engine reports as finished, with the keeper set
                // it froze — not a flag flipped on the view.
                .window(AnyView(RootView(app: shootApp(
                    f, "shoot-decided", step: "done",
                    // Fourteen kept, twelve exported: the answer key holds all
                    // fourteen and the cull learns from the twelve.
                    patchInfo: ["finished": true, "finished_on": "2026-09-22", "keepers": 14, "exported": 12,
                                "recorded_keepers": 14, "taught": 12, "taught_from": "exported",
                                "recorded_from": "the frames you exported and the ones you kept",
                                "export_dirs": exportDirs(f)]))))
            },

            // The two sheets, as the words and the button order a person sees.
            SnapshotScene(name: "steps-cull-again-sheet", size: CGSize(width: 560, height: 260)) { _ in
                .window(AnyView(SheetPreview(
                    title: Strings.Cull.againTitle,
                    message: Strings.Cull.againBody(14, 1, focus: 1.6, moving: true),
                    other: Strings.Cull.againConfirm(adds: false),
                    defaultButton: Strings.Cull.cancel)))
            },
            // The same question with ⌥ held or his work running: the press
            // puts the re-cull in Up Next, and the button says so.
            SnapshotScene(name: "steps-cull-again-sheet-adds", size: CGSize(width: 560, height: 260)) { _ in
                .window(AnyView(SheetPreview(
                    title: Strings.Cull.againTitle,
                    message: Strings.Cull.againBody(14, 1, focus: 1.6, moving: true),
                    other: Strings.Cull.againConfirm(adds: true),
                    defaultButton: Strings.Cull.cancel)))
            },
            SnapshotScene(name: "steps-presets-again-sheet", size: CGSize(width: 560, height: 260)) { _ in
                .window(AnyView(SheetPreview(
                    title: Strings.Presets.againTitle,
                    message: Strings.Presets.againBody(4),
                    other: Strings.Cull.cancel,
                    defaultButton: Strings.Presets.againConfirm)))
            },
            SnapshotScene(name: "steps-finish-shrink-sheet", size: CGSize(width: 560, height: 280)) { _ in
                // The engine's own sentence, read by the same code the app
                // reads it with — so the picture shows what the sheet and its
                // buttons really say, not two numbers typed in here.
                shrinkSheet("Not recorded: this finished shoot's keeper list holds 154 frames chosen "
                    + "from exports that cannot be found now, and recording again would replace it with "
                    + "3 frames taken from your marks and the edit folder. Nothing was changed.")
            },
            // The other refusal, whose cause the engine does not know.
            SnapshotScene(name: "steps-finish-shrink-sheet-fewer", size: CGSize(width: 560, height: 280)) { _ in
                shrinkSheet("Not recorded: this would replace 154 chosen frames with 3. Nothing was changed.")
            },

            // The one thing §5.2 asks a snapshot to prove: the primary's box
            // is in the same place with a button in it and with a job in it.
            SnapshotScene(name: "steps-action-bar-idle", size: CGSize(width: 900, height: 140)) { _ in
                .window(AnyView(ActionBarPreview(phase: .idle)))
            },
            // From the press until the engine has started it: no Stop yet,
            // and nothing to press twice.
            SnapshotScene(name: "steps-action-bar-starting", size: CGSize(width: 900, height: 140)) { _ in
                .window(AnyView(ActionBarPreview(phase: .starting)))
            },
            SnapshotScene(name: "steps-action-bar-running", size: CGSize(width: 900, height: 140)) { _ in
                .window(AnyView(ActionBarPreview(phase: .running(
                    Job(running: true, stopped: false, kind: "cull", shoot: "2026-09-13-dog",
                        title: "culling 2026-09-13-dog", stage: "faces",
                        label: "looking at faces: 61 of 98 frames", fraction: 0.42, elapsed: 53,
                        remaining: 240, remaining_text: "about 4 minutes left")))))
            },
            SnapshotScene(name: "steps-action-bar-refused", size: CGSize(width: 900, height: 140)) { _ in
                .window(AnyView(ActionBarPreview(phase: .idle, refusal:
                    "this would replace 154 chosen frames with 3, and there are no exports left to redraw it from")))
            },
        ]
    }

    // MARK: - the scenes' own scaffolding

    /// The open shoot's step saw its own job end, with this log and exit 1.
    @MainActor static func ended(_ app: AppModel, kind: String, title: String, log: String) {
        guard case .step(let shoot, _) = app.navigation.selection,
              let s = app.library.cachedSession(for: shoot) else { return }
        let m = StepsModelStore.shared.model(for: s, jobs: app.jobs)
        let runner = kind == "presets" ? m.presetsJob : m.cullJob
        runner.noteEnded(Job(running: false, stopped: false, id: 3, kind: kind, shoot: shoot,
                             title: title, log: log, elapsed: 140, code: 1))
    }

    /// What the cull on disk ran with, as `cull.py` records it once it has
    /// written its results.
    static let ranWith: [String: Any] = ["cull_ran_with": ["focus": 1.9, "style": "action"]]

    /// Once, before any scene is built: the steps are registered with the
    /// shell, the links go somewhere harmless, and the editor is pretended to
    /// be installed so a picture does not change with what is in
    /// /Applications on the machine that rendered it.
    /// A list with the captured shape on it, so a step page can be
    /// photographed with something really waiting behind the button.
    static func queueModel(_ f: Fixtures) -> QueueModel {
        let q = QueueModel()
        q.take(f.queue ?? .empty)
        return q
    }

    /// The folders the captured shoot's exports were found in, as today's
    /// engine lists them. A fixture captured before `export_dirs` has only
    /// the comma-joined sentence, which is split here and nowhere else.
    @MainActor static func shrinkSheet(_ sentence: String) -> Snapshotted {
        let counts = RecordedKeepers.counts(in: sentence)
        let both = counts.0.flatMap { had in counts.1.map { (had, $0) } }
        return .window(AnyView(SheetPreview(
            title: both.map { Strings.Finish.shrinkTitleCounts($0.0, $0.1) } ?? Strings.Finish.shrinkTitle,
            message: RecordedKeepers.body(for: sentence) ?? sentence,
            other: counts.1.map(Strings.Finish.shrinkUseCount) ?? Strings.Finish.shrinkUse,
            defaultButton: counts.0.map(Strings.Finish.shrinkKeepCount) ?? Strings.Finish.shrinkKeep)))
    }

    static func exportDirs(_ f: Fixtures) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: f.data("shoot-decided")) as? [String: Any],
              let info = object["info"] as? [String: Any] else { return [] }
        if let dirs = info["export_dirs"] as? [String], !dirs.isEmpty { return dirs }
        let said = info["export_where"] as? String ?? ""
        let parts = said.components(separatedBy: ", ").filter { $0.hasPrefix("/") }
        return parts.isEmpty ? [(info["path"] as? String ?? "/x") + "/export"] : parts
    }

    static func prepare() {
        Queues.reset()
        WorkflowSteps.register()
        StepSlots.showLearned = {}
        StepSlots.showStep = { _, _ in }
        StepSlots.showActivity = {}
        Editors.pretend("dxo", at: URL(fileURLWithPath: "/Applications/DxO PhotoLab 8.app"))
    }

    static func session(_ f: Fixtures, _ name: String, patchInfo: [String: Any] = [:]) -> ShootSession? {
        var data = f.data(name)
        if !patchInfo.isEmpty,
           var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var info = object["info"] as? [String: Any] {
            for (k, v) in patchInfo { info[k] = v }
            object["info"] = info
            if let patched = try? JSONSerialization.data(withJSONObject: object) { data = patched }
        }
        guard let r = try? JSONDecoder().decode(ShootResponse.self, from: data) else { return nil }
        return ShootSession(response: r, ext: f.shoots?.ext, client: f.client, pump: f.pump)
    }

    /// An app with one shoot open at one step, and whatever job is running.
    static func shootApp(_ f: Fixtures, _ fixture: String, step: String,
                         job: Job? = nil, queue: Bool = false,
                         patchInfo: [String: Any] = [:]) -> AppModel {
        let lib = f.makeLibrary()
        guard let s = session(f, fixture, patchInfo: patchInfo) else {
            return f.makeApp(selection: .allShoots)
        }
        lib.adopt(s)
        let nav = Navigation(selection: .step(shoot: s.name, step: step))
        let app = AppModel(preview: lib, state: .running(f.endpoint), navigation: nav)
        StepJobs.shared = { app.jobs }
        StepJobs.previewJob = nil
        let model = StepsModelStore.shared.model(for: s, jobs: app.jobs)
        model.showPreviewJob(job)
        if queue { model.cullJob.run {} }
        return app
    }

    /// The card page, which belongs to the library rather than to a shoot.
    static func cardApp(_ f: Fixtures, cards: [String], job: Job? = nil) -> AppModel {
        let response = patched(f, cards: cards)
        let lib = response.map { Library(preview: $0, client: f.client, pump: f.pump) } ?? f.makeLibrary()
        let nav = Navigation(selection: .card(cards.first ?? ""))
        let app = AppModel(preview: lib, state: .running(f.endpoint), navigation: nav)
        StepJobs.shared = { app.jobs }
        StepJobs.previewJob = job
        return app
    }

    /// `/api/shoots` with a card in it. The fixtures were captured from a Mac
    /// with nothing plugged in, and the card picker is half the page.
    static func patched(_ f: Fixtures, cards: [String]) -> ShootsResponse? {
        guard var object = try? JSONSerialization.jsonObject(with: f.data("shoots")) as? [String: Any] else {
            return nil
        }
        object["cards"] = cards
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(ShootsResponse.self, from: data)
    }
}

/// A sheet's words and its button order, laid out the way macOS lays an alert
/// out. The alert itself is a window of AppKit's own and cannot be captured
/// with the rest of the screen; this is what it says, which is what a person
/// reading these pictures is checking.
struct SheetPreview: View {
    let title: String
    let message: String
    let other: String
    let defaultButton: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "app.badge.checkmark")
                .font(.system(size: 42))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Spacer()
                Button(other) {}
                // Drawn the way an alert draws its default button, so the
                // picture says which one Return presses. In these three
                // sheets that is never the button that costs him something.
                Button(defaultButton) {}
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        // An alert is the width AppKit gives it and as tall as its words need;
        // it is not the width of the window behind it. Saying so here also
        // keeps a long sentence from asking for a window taller than any
        // display — the same trap as the action bar's, and the reason nothing
        // in this preview may size itself from the outside in.
        .frame(width: 420, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The action bar on its own, at the three states that have to leave the
/// primary's box in exactly the same place.
struct ActionBarPreview: View {
    let phase: StepJobPhase
    var refusal: String?

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
            StepActionBar {
                VStack(alignment: .leading, spacing: 4) {
                    if let refusal { RefusalRow(refusal, owner: .job) }
                    if case .running(let job) = phase { JobTiming(job) }
                }
            } box: {
                JobInPlace(phase: phase, stop: {}, cancelQueue: {}) {
                    Button(Strings.Cull.run) {}
                        .primaryActionStyle()
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
