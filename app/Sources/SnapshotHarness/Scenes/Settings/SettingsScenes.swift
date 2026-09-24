import AppKit
import SwiftUI
import PipelineKit

/// The first-run pages, Settings, the Shortcuts window and the sheets that go
/// with them, in the states the StorageLearning scenes do not draw: an engine
/// that has answered, a job in the way of a restart, and so on. Every one is
/// built from values, with no engine and none of his settings.
final class SettingsScenes: SceneProvider {
    override class var scenes: [SnapshotScene] {
        [
            // Page two with nothing found and nothing chosen: where Continue
            // will put the shoots, said before he presses it.
            scene("first-run-2-default", Tokens.Metric.firstRunSheet.width,
                  Tokens.Metric.firstRunSheet.height) { _ in
                FirstRunSheet(world: .init(existingLibrary: { nil }, editors: { [] },
                                           defaultLibrary: URL(fileURLWithPath: "/scratch/photos")),
                              settings: SettingsStore(defaults: scratchDefaults()),
                              picture: PictureModel(preview: false), startingAt: 1) {}
            },
            // Page three with an engine that says the model is missing:
            // Download Now holds Return, and Continue steps aside.
            scene("first-run-3-offer", Tokens.Metric.firstRunSheet.width,
                  Tokens.Metric.firstRunSheet.height) { _ in
                FirstRunSheet(world: .empty, settings: SettingsStore(defaults: scratchDefaults()),
                              picture: PictureModel(preview: false), startingAt: 2) {}
            },
            scene("first-run-3-here", Tokens.Metric.firstRunSheet.width,
                  Tokens.Metric.firstRunSheet.height) { _ in
                FirstRunSheet(world: .empty, settings: SettingsStore(defaults: scratchDefaults()),
                              picture: PictureModel(preview: true), startingAt: 2) {}
            },
            // Page four with PhotoLab the only editor on the Mac: said, not
            // asked. And with two, the choices, the ones here marked.
            scene("first-run-4-photolab", Tokens.Metric.firstRunSheet.width,
                  Tokens.Metric.firstRunSheet.height) { _ in
                FirstRunSheet(world: .init(existingLibrary: { nil },
                                           editors: { [.init(id: "dxo", name: "DxO PhotoLab 10", url: nil)] }),
                              settings: SettingsStore(defaults: scratchDefaults()),
                              picture: PictureModel(preview: true), startingAt: 3) {}
            },
            scene("first-run-4-two", Tokens.Metric.firstRunSheet.width,
                  Tokens.Metric.firstRunSheet.height) { _ in
                FirstRunSheet(world: .init(existingLibrary: { nil },
                                           editors: { [.init(id: "dxo", name: "DxO PhotoLab 10", url: nil),
                                                       .init(id: "lightroom", name: "Lightroom Classic", url: nil)] }),
                              settings: SettingsStore(defaults: scratchDefaults()),
                              picture: PictureModel(preview: true), startingAt: 3) {}
            },
            // Shown again from Settings, on a Mac with only PhotoLab, after he
            // chose Lightroom: his choice is the one shown chosen, and the page
            // does not say keepers open in PhotoLab over it. Its own defaults,
            // so the choice does not reach the other scenes.
            scene("first-run-4-his-choice", Tokens.Metric.firstRunSheet.width,
                  Tokens.Metric.firstRunSheet.height) { _ in
                let store = SettingsStore(defaults: UserDefaults(suiteName: "photopipeline.snapshots.editor") ?? .standard)
                store.editor = "lightroom"
                return FirstRunSheet(world: .init(existingLibrary: { nil },
                                                  editors: { [.init(id: "dxo", name: "DxO PhotoLab 10", url: nil)] }),
                                     settings: store, picture: PictureModel(preview: true), startingAt: 3) {}
            },
            // The way back, as the Cull step and Settings draw it.
            scene("picture-model-offer", 520, 140) { _ in
                PictureModelOffer(PictureModel(preview: false))
                    .padding(Tokens.Metric.windowMargin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            },
            // A new folder chosen while a cull runs, and the restart waiting
            // for it, with Don't Wait beside the line.
            scene("settings-restart-waiting", 520, 460) { f in
                let store = SettingsStore(defaults: scratchDefaults())
                store.libraryFolder = f.library ?? URL(fileURLWithPath: "/nowhere/photos")
                return SettingsView(settings: store, hooks: .init(), tab: .general,
                                    restarter: EngineRestart(preview: .init(
                                        job: "the cull of 2026-09-19",
                                        folder: URL(fileURLWithPath: "/Volumes/Archive/photos"))))
            },
            // Storage with the engine's number in it: the library's, the one
            // every shoot's panel shows for a shoot with none of its own.
            scene("settings-storage-engine", 520, 420) { _ in
                SettingsView(settings: SettingsStore(defaults: scratchDefaults()), hooks: .init(),
                             tab: .storage, engine: EngineSettings(previewRetainDays: 90))
            },
            scene("settings-advanced-model", 520, 520) { _ in
                SettingsView(settings: SettingsStore(defaults: scratchDefaults()),
                             hooks: .init(showLog: {}, showSupportFolder: {}, showFirstRunAgain: {}),
                             tab: .advanced, picture: PictureModel(preview: false))
            },
        ]
    }

    // MARK: -

    static func scene<V: View>(_ name: String, _ w: CGFloat, _ h: CGFloat,
                               _ make: @escaping @MainActor @Sendable (Fixtures) -> V) -> SnapshotScene {
        SnapshotScene(name: name, size: CGSize(width: w, height: h)) { f in .window(AnyView(make(f))) }
    }

    /// Defaults that exist only for the length of a render, so a snapshot
    /// never reads or writes his own settings.
    static func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "photopipeline.snapshots") ?? .standard
    }
}
