import AppKit
import SwiftUI
import PipelineKit

/// Check for Updates… and the sidebar's "Update to … available ›" (§7.9):
/// the sheet in each answer it can give, and the footer that opens it.
final class UpdateScenes: SceneProvider {
    private static let sheet = CGSize(width: 420, height: 190)

    @MainActor private static func info(newer: Bool, staged: Bool = false) -> UpdateInfo {
        (try? UpdateInfo(fields: Fields([
            "newer": .bool(newer), "current": .string("0.1.2"), "latest": .string(newer ? "0.2.0" : "0.1.2"),
            "url": .string("https://github.com/x/a.dmg"), "staged": .bool(staged),
        ])))!
    }

    @MainActor private static func sheet(_ info: UpdateInfo?, refusal: String? = nil,
                                         actionRefusal: String? = nil, job: Job? = nil) -> Snapshotted {
        let updates = UpdateCoordinator()
        updates.preview(info, refusal: refusal, actionRefusal: actionRefusal)
        let jobs = JobModel()
        if let job { jobs.take(job) }
        return .window(AnyView(UpdateSheet(updates: updates, jobs: jobs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)))
    }

    override class var scenes: [SnapshotScene] {
        [
            SnapshotScene(name: "update-latest", size: sheet) { _ in
                sheet(info(newer: false))
            },
            SnapshotScene(name: "update-available", size: sheet) { _ in
                sheet(info(newer: true))
            },
            // What this build's engine actually says: there is no release yet.
            SnapshotScene(name: "update-refused", size: sheet) { _ in
                sheet(nil, refusal: "GitHub answered 404 when asked for the latest release")
            },
            SnapshotScene(name: "update-downloading", size: sheet) { _ in
                sheet(info(newer: true), job: Job(running: true, stopped: false, id: 4, kind: "update",
                                                  title: "downloading version 0.2.0", fraction: 0.42))
            },
            SnapshotScene(name: "update-download-refused", size: CGSize(width: 420, height: 220)) { _ in
                sheet(info(newer: true), actionRefusal: "A cull is running; the download waits for it")
            },
            // Downloaded, with his cull still running: Install waits for it.
            SnapshotScene(name: "update-staged-busy", size: CGSize(width: 420, height: 220)) { _ in
                sheet(info(newer: true, staged: true),
                      job: Job(running: true, stopped: false, id: 5, kind: "cull", shoot: "2026-09-19",
                               title: "culling 2026-09-19", fraction: 0.3))
            },
            // The footer, which is now a button that opens the sheet.
            SnapshotScene(name: "update-footer", size: CGSize(width: 1100, height: 780)) { f in
                let app = f.makeApp(selection: .allShoots)
                app.updates.preview(info(newer: true))
                app.updates.sheetShown = false
                return .window(AnyView(RootView(app: app)))
            },
        ]
    }
}
