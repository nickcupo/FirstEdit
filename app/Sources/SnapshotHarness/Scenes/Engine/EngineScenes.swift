import AppKit
import SwiftUI
import PipelineKit

/// The engine-down view for the reasons other than a missing part, which
/// the shell's own `engine-down` scene shows.
final class EngineScenes: SceneProvider {
    override class var scenes: [SnapshotScene] {
        [
            // It crashed twice in a minute, and its last word was its own.
            SnapshotScene(name: "engine-down-error", size: CGSize(width: 1100, height: 780)) { f in
                let app = f.makeApp(selection: .allShoots, state: .failed("Segmentation fault"))
                return .window(AnyView(RootView(app: app)))
            },
            // It started and never said where it was listening.
            SnapshotScene(name: "engine-down-no-port", size: CGSize(width: 1100, height: 780)) { f in
                let app = f.makeApp(selection: .allShoots, state: .failed(Strings.Engine.noPort))
                return .window(AnyView(RootView(app: app)))
            },
        ]
    }
}
