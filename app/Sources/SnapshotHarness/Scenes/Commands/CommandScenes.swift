import AppKit
import SwiftUI
import PipelineKit

/// The commands crew's scenes: every menu as AppKit was given it, the
/// Keyboard Shortcuts window, and the Activity window.
final class CommandScenes: SceneProvider {

    /// One command host for the whole run, so the menus carry the same
    /// enabled rows and checkmarks every screen would.
    @MainActor
    static func installed(_ f: Fixtures) -> NSMenu {
        if let m = NSApplication.shared.mainMenu,
           m.item(withTitle: CommandTable.frame.title) != nil { return m }
        let app = f.makeApp(selection: f.shoot.map { .step(shoot: $0.info.name, step: "keepers") })
        let host = CommandHost.install(model: app, openActivity: {})
        host.refreshSteps()
        app.navigation.sidebarShown = true
        // What the app registers on Choose Keepers, and nothing else: the
        // light table's rows against a real light table on the fixture shoot.
        // This used to register do-nothing stand-ins for the Shoot menu, the
        // Storage submenu and three View rows that nothing in the app ever
        // registered, so this picture showed them enabled while every one of
        // them was grey in the app.
        if let name = f.shoot?.info.name, let session = app.library.cachedSession(for: name) {
            LightTableCommands.attach(ViewerModel.shared(for: session, navigation: app.navigation),
                                      center: host.center)
        }
        return NSApplication.shared.mainMenu ?? NSMenu()
    }

    @MainActor
    static func menu(_ f: Fixtures, _ title: String) -> NSMenu {
        let main = installed(f)
        let m = main.item(withTitle: title)?.submenu ?? NSMenu(title: title)
        // The real passes: the delegate that keeps one Enter Full Screen, then
        // the validation that greys a row out and turns "Show Sidebar" into
        // "Hide Sidebar".
        m.update()
        for item in m.items { item.submenu?.update() }
        return m
    }

    @MainActor
    static func submenu(_ f: Fixtures, _ menu: String, _ item: String) -> NSMenu {
        let m = self.menu(f, menu)
        let sub = m.item(withTitle: item)?.submenu ?? NSMenu(title: item)
        sub.update()
        return sub
    }

    /// The same jobs a session leaves behind: one that finished, one he
    /// stopped, and a plan that refused on purpose.
    @MainActor
    static var jobRows: [ActivityRow] {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return [
            ActivityRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                        what: "Cull", shoot: "2026-09-13-dog",
                        started: start, elapsed: 184, outcome: .done,
                        log: """
                        $ pipeline/cull.py /photos/shoots/2026-09-13-dog
                          reading the frames … 54
                          looking at faces … 41 found
                          judging the pictures … 54
                          put forward 23 of 54. set aside 19.
                          stacked 13 frames that look alike into 6 stacks.
                        """),
            ActivityRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                        what: "Write the presets", shoot: "2026-09-13-dog",
                        started: start.addingTimeInterval(400), elapsed: 12, outcome: .stopped,
                        log: "$ pipeline/presets.py /photos/shoots/2026-09-13-dog\n  stopped."),
            ActivityRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                        what: Strings.Queue.what("plan-drop") ?? "",
                        shoot: "2026-09-13-dog",
                        started: start.addingTimeInterval(900), elapsed: 2, outcome: .refused,
                        log: """
                        $ pipeline/archive.py drop /photos/shoots/2026-09-13-dog
                          2026-09-13-dog has no archive manifest: nothing was ever pushed.
                        """),
        ]
    }

    /// The same view, under Increase Contrast, by giving the hosting view the
    /// system's own high-contrast appearance.
    /// The content view on its own: a menu is not a window and should not be
    /// drawn with a title bar around it.
    @MainActor
    static func content(_ view: AnyView) -> Snapshotted {
        .appKit(NSHostingView(rootView: view))
    }

    @MainActor
    static func highContrast<V: View>(_ view: V, size: CGSize, dark: Bool = false) -> NSView {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .accessibilityHighContrastDarkAqua
                                                   : .accessibilityHighContrastAqua)
        return host
    }

    override class var scenes: [SnapshotScene] {
        [
            // Every menu, open, from the table they are built out of.
            SnapshotScene(name: "menus-frame-view", size: CGSize(width: 820, height: 560)) { f in
                content(AnyView(MenuWall(menus: [
                    (CommandTable.frame.title, menu(f, CommandTable.frame.title), 340),
                    (CommandTable.view.title, menu(f, CommandTable.view.title), 320),
                ])))
            },
            SnapshotScene(name: "menus-go-shoot", size: CGSize(width: 780, height: 440)) { f in
                content(AnyView(MenuWall(menus: [
                    (CommandTable.go.title, menu(f, CommandTable.go.title), 320),
                    (CommandTable.shoot.title, menu(f, CommandTable.shoot.title), 300),
                ])))
            },
            SnapshotScene(name: "menus-file-edit-window", size: CGSize(width: 1040, height: 400)) { f in
                content(AnyView(MenuWall(menus: [
                    (CommandTable.file.title, menu(f, CommandTable.file.title), 320),
                    (CommandTable.edit.title, menu(f, CommandTable.edit.title), 260),
                    (CommandTable.window.title, menu(f, CommandTable.window.title), 240),
                ])))
            },
            SnapshotScene(name: "menus-app-help", size: CGSize(width: 720, height: 360)) { f in
                content(AnyView(MenuWall(menus: [
                    (Strings.App.name, menu(f, Strings.App.name), 280),
                    (CommandTable.help.title, menu(f, CommandTable.help.title), 280),
                ])))
            },
            // The destructive pair, in a section of their own at the bottom,
            // with no key equivalent beside either of them.
            SnapshotScene(name: "menu-storage", size: CGSize(width: 460, height: 320)) { f in
                content(AnyView(MenuWall(menus: [
                    (Words.Shoot.storage,
                     submenu(f, CommandTable.shoot.title, Words.Shoot.storage), 320),
                ])))
            },
            SnapshotScene(name: "menu-why-it-is-out", size: CGSize(width: 420, height: 300)) { f in
                content(AnyView(MenuWall(menus: [
                    (Words.Frame.whyItIsOut,
                     submenu(f, CommandTable.frame.title, Words.Frame.whyItIsOut), 280),
                ])))
            },

            // Edit ▸ Find Burst… (⌘F), on burst 7 of 288, before he has typed
            // anything: the words, the field and the buttons of the alert the
            // app builds. An `NSAlert` draws its labels through a path an
            // offscreen capture cannot see, so the sheet is drawn from them.
            SnapshotScene(name: "find-burst", size: CGSize(width: 300, height: 230)) { _ in
                let (alert, field) = FindBurst.alert(current: 6, bursts: 288)
                return .window(AnyView(FindBurstPreview(alert: alert, field: field)))
            },

            // Help ▸ Keyboard Shortcuts: a real window, built from the same
            // table the menus are.
            SnapshotScene(name: "shortcuts", size: CGSize(width: 660, height: 700)) { _ in
                .window(AnyView(ShortcutsWindow.view()))
            },
            SnapshotScene(name: "shortcuts-contrast", size: CGSize(width: 660, height: 700)) { _ in
                .appKit(highContrast(ShortcutsWindow.view().forcingIncreaseContrast(),
                                     size: CGSize(width: 660, height: 700)))
            },

            // ⌥⌘L, after a session with three jobs in it — one done, one he
            // stopped, and a plan that refused on purpose.
            SnapshotScene(name: "activity", size: CGSize(width: 820, height: 640)) { _ in
                .window(AnyView(ActivityWindow(rows: jobRows,
                                               logURL: URL(fileURLWithPath: "/tmp/studio.log"))))
            },
            SnapshotScene(name: "activity-running", size: CGSize(width: 820, height: 640)) { _ in
                .window(AnyView(ActivityWindow(rows: jobRows,
                                               logURL: URL(fileURLWithPath: "/tmp/studio.log"),
                                               isRunning: true)))
            },
            SnapshotScene(name: "activity-empty", size: CGSize(width: 640, height: 520)) { _ in
                // The log exists whether or not a job has: the engine opens it
                // at launch, so the empty state still has its one button. And
                // the list above it says what a list is for, which is the one
                // place the whole idea is explained.
                .window(AnyView(ActivityWindow(rows: [],
                                               logURL: URL(fileURLWithPath: "/tmp/studio.log"))))
            },

            // The evening he asked for: a cull running off the list, the
            // presets and a check behind it, and one row whose shoot changed
            // under it and says so before he walks away.
            SnapshotScene(name: "activity-list", size: CGSize(width: 820, height: 640)) { f in
                .window(AnyView(ActivityWindow(rows: jobRows,
                                               logURL: URL(fileURLWithPath: "/tmp/studio.log"),
                                               isRunning: true,
                                               queue: f.queue ?? .empty)))
            },
            // Held, with the line that says what holding means.
            SnapshotScene(name: "queue-held", size: CGSize(width: 640, height: 360)) { f in
                let q = f.queue ?? .empty
                return .window(AnyView(QueueList(state: QueueState(
                    waiting: q.waiting, held: true, listed: q.listed, fraction: q.fraction,
                    pass: q.pass, done: q.done, skipped: q.skipped))
                    .frame(width: 640)))
            },
            // Afterwards: nothing waiting, and the one thing the list could
            // not do, with the engine's reason under it. He walked away from
            // four and has to be able to come back and read which.
            SnapshotScene(name: "queue-skipped", size: CGSize(width: 640, height: 300)) { f in
                let q = f.queue ?? .empty
                let stale = q.waiting.first { !$0.ready }
                return .window(AnyView(QueueList(state: QueueState(
                    listed: 3, fraction: 1, pass: 2,
                    done: [QueueDone(id: 1, kind: "cull", shoot: "2026-09-13-dog"),
                           QueueDone(id: 2, kind: "presets", shoot: "2026-09-13-dog")],
                    skipped: [QueueSkipped(id: 3, kind: stale?.kind ?? "gather",
                                           shoot: stale?.shoot ?? "2026-01-01-scratch",
                                           whyNot: stale?.whyNot ?? "")]))
                    .frame(width: 640)))
            },
            // The list with nothing on it: the one place the whole idea is
            // explained, in his evening's own terms.
            SnapshotScene(name: "queue-empty", size: CGSize(width: 640, height: 260)) { f in
                .window(AnyView(QueueList(state: f.queueEmpty ?? .empty).frame(width: 640)))
            },
            // The toolbar's Activity item with a list behind the job.
            SnapshotScene(name: "toolbar-activity-list", size: CGSize(width: 420, height: 90)) { f in
                let j = f.job ?? Job(running: true, stopped: false)
                return .window(AnyView(
                    ActivityToolbarItem(job: Job(running: true, stopped: false, id: j.id,
                                                 kind: j.kind, shoot: j.shoot, title: j.title,
                                                 stage: j.stage, label: j.label,
                                                 fraction: 0.38, elapsed: j.elapsed,
                                                 remaining_text: "about 4 minutes left"),
                                        waiting: (f.queue ?? .empty).count,
                                        stop: {}, openLearning: {}, showTheList: {})
                        .padding(Tokens.Metric.windowMargin)))
            },

            // The same item after a job ended while he was looking, and with
            // the list held and nothing running.
            SnapshotScene(name: "toolbar-activity-ended", size: CGSize(width: 420, height: 90)) { _ in
                .window(AnyView(
                    ActivityToolbarItem(.ended(Job(running: false, stopped: false, kind: "presets",
                                                   shoot: "2026-09-19", title: "presets for 2026-09-19",
                                                   log: "Traceback (most recent call last):\nMemoryError",
                                                   code: 1)),
                                        stop: {}, openLearning: {}, showTheList: {})
                        .padding(Tokens.Metric.windowMargin)))
            },
            SnapshotScene(name: "toolbar-activity-held", size: CGSize(width: 420, height: 90)) { f in
                .window(AnyView(
                    ActivityToolbarItem(.list(held: true), waiting: max(1, (f.queue ?? .empty).count),
                                        stop: {}, openLearning: {}, showTheList: {})
                        .padding(Tokens.Metric.windowMargin)))
            },
            SnapshotScene(name: "toolbar-popover-held", size: CGSize(width: 340, height: 200)) { f in
                .window(AnyView(
                    UpNextPopover(held: true, waiting: (f.queue ?? .empty).count,
                                  upNext: (f.queue ?? .empty).waiting, letGo: {}, showTheList: {})))
            },

            // The Dock tile, at the size the Dock draws it.
            SnapshotScene(name: "dock-progress", size: CGSize(width: 220, height: 220)) { _ in
                let v = DockTilePreview(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
                return .appKit(v)
            },

        ]
    }
}

/// The Dock tile as `DockProgress` draws it, on the Dock's own background:
/// the real `DockTileView`, not a copy of its drawing, which could not catch
/// a change to the real one. No badge: the Dock draws that, and only for a
/// failure (DESIGN.md §2.7).
final class DockTilePreview: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let tile = DockTileView()
        tile.fraction = 0.38
        tile.frame = bounds.insetBy(dx: 26, dy: 26)
        tile.autoresizingMask = [.width, .height]
        addSubview(tile)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0.20, alpha: 1).setFill()
        bounds.fill()
    }
}

/// The Find Burst sheet as a person sees it, read off the real `NSAlert`:
/// its title, its sentence, the number in its field and its two buttons, the
/// first of which Return presses.
struct FindBurstPreview: View {
    let alert: NSAlert
    let field: NSTextField

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(alert.messageText).font(.headline)
            Text(alert.informativeText).font(.callout).foregroundStyle(.secondary)
            TextField(field.placeholderString ?? "", text: .constant(field.stringValue))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                ForEach(Array(alert.buttons.dropFirst().reversed().enumerated()), id: \.offset) { _, b in
                    Button(b.title) {}.frame(maxWidth: .infinity)
                }
                if let go = alert.buttons.first {
                    Button(go.title) {}
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!go.isEnabled)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 260, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
