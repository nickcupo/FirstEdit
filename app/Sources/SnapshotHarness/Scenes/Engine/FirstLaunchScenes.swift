import AppKit
import SwiftUI
import PipelineKit

/// The first launch under the name First Edit (`FirstLaunch`): the alert
/// while the old app is still open, the one when it is opened later, the one
/// when two folders are there and First Edit's has no work in it, and
/// Settings ▸ Advanced in each of the states that put a line under Show the
/// Support Folder. Built from values: no folder is looked at and no setting
/// is read.
final class FirstLaunchScenes: SceneProvider {
    private static let settings = CGSize(width: 520, height: 560)
    private static let old = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support")
        .appendingPathComponent(FirstLaunch.Old.folder)
    private static let new = old.deletingLastPathComponent().appendingPathComponent(FirstLaunch.New.folder)

    @MainActor private static func advanced(_ outcome: SupportMove.Outcome) -> Snapshotted {
        .window(AnyView(SettingsView(
            settings: SettingsStore(defaults: SettingsScenes.scratchDefaults()),
            hooks: .init(showLog: {}, showSupportFolder: {}, showFirstRunAgain: {},
                         supportNote: outcome.note),
            tab: .advanced, picture: PictureModel(preview: true))))
    }

    override class var scenes: [SnapshotScene] {
        [
            // The old app is open: said before any window, and the only
            // button quits.
            SnapshotScene(name: "first-launch-still-open", size: CGSize(width: 300, height: 180)) { _ in
                .window(AnyView(AlertPreview(alert: FirstLaunch.stillOpenAlert())))
            },
            SnapshotScene(name: "first-launch-could-not-move", size: settings) { _ in
                advanced(.couldNotMove(old: old, why: "Permission denied"))
            },
            SnapshotScene(name: "first-launch-two-folders", size: settings) { _ in
                advanced(.both(other: old))
            },
            SnapshotScene(name: "first-launch-not-found", size: settings) { _ in
                advanced(.moved(linked: false, notFound: ["extension/studio_ext.py"], record: "MIGRATED.json"))
            },
            SnapshotScene(name: "first-launch-no-link", size: settings) { _ in
                advanced(.moved(linked: false, notFound: [], record: "MIGRATED.json"))
            },
            // Both folders, and First Edit's lacks what the other has: once,
            // after launch. Continue is the default.
            SnapshotScene(name: "first-launch-two-folders-alert", size: CGSize(width: 300, height: 300)) { _ in
                .window(AnyView(AlertPreview(alert: FirstLaunch.twoFoldersAlert(
                    .init(inUse: new, other: old, missing: ["models", "learned"])))))
            },
            // The old app opened while First Edit runs.
            SnapshotScene(name: "first-launch-old-opened", size: CGSize(width: 300, height: 200)) { _ in
                .window(AnyView(AlertPreview(alert: FirstLaunch.oldOpenedAlert())))
            },
        ]
    }
}

/// An alert as a person sees it, read off the real `NSAlert`: its title, its
/// sentence and its buttons, the first of which Return presses. An `NSAlert`
/// draws its labels through a path an offscreen capture cannot see. Like the
/// real one, a title wraps rather than stopping short, and buttons whose
/// titles do not fit side by side are stacked, the default on top.
struct AlertPreview: View {
    let alert: NSAlert

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(alert.messageText).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(alert.informativeText).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    ForEach(Array(alert.buttons.dropFirst().reversed().enumerated()), id: \.offset) { _, b in
                        Button(b.title) {}.fixedSize().frame(maxWidth: .infinity)
                    }
                    if let go = alert.buttons.first { defaultButton(go).fixedSize().frame(maxWidth: .infinity) }
                }
                VStack(spacing: 8) {
                    if let go = alert.buttons.first { defaultButton(go).frame(maxWidth: .infinity) }
                    ForEach(Array(alert.buttons.dropFirst().enumerated()), id: \.offset) { _, b in
                        Button { } label: { Text(b.title).frame(maxWidth: .infinity) }
                    }
                }
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 260, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func defaultButton(_ b: NSButton) -> some View {
        Button { } label: { Text(b.title).frame(maxWidth: .infinity) }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
    }
}
