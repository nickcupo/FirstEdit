import AppKit

// The Dock, while a long job runs (NAT-07).
//
// A real progress bar drawn into the Dock tile, and a Dock menu that says what
// is running and can stop it — so the answer to "is the cull done yet" is on
// screen while First Edit is hidden behind PhotoLab.
//
// The badge is only for a failure, until he looks at Activity (DESIGN.md §2.7).
// A red "38 %" sat on top of the bar for the length of every job: red on the
// Dock means "needs you", and it said again what the bar under it said.

@MainActor
public enum DockProgress {
    private static let tileView = DockTileView()
    private static var showing = false

    /// Call it with the job on every poll. Nothing is drawn while nothing runs.
    public static func show(_ job: Job?) {
        guard let job, job.running else { clear(); return }
        showFraction(job.fraction, running: true, title: JobWords.titled(job))
    }

    /// The same tile, drawn for a fraction that is not one job's.
    ///
    /// The list of work uses this: §2.7 says the Dock shows the queue's
    /// overall progress and not the running job's, because a bar that fills
    /// and drops back to nothing four times in an evening says the machine
    /// restarted four times. `count` is what is still waiting, and it goes on
    /// the Dock menu so the answer to "how much is left" is there while
    /// First Edit is hidden behind PhotoLab.
    public static func showFraction(_ fraction: Double, running: Bool,
                                    title: String = "", count: Int = 0) {
        let tile = NSApplication.shared.dockTile
        guard running else { clear(); return }
        tileView.fraction = max(0, min(1, fraction))
        if !showing {
            tile.contentView = tileView
            showing = true
        }
        listTitle = title
        listWaiting = count
        tile.display()
    }

    /// What the tile is currently about, for the Dock menu. Kept because the
    /// menu is built on demand, long after the poll that drew the bar.
    private static var listTitle = ""
    private static var listWaiting = 0

    /// The bar goes the instant the job stops: a Dock icon that still shows
    /// 38% of a cull an hour later is a lie. A failure's badge stays; it is
    /// news until he has looked (`sawTheFailures`).
    public static func clear() {
        let tile = NSApplication.shared.dockTile
        listTitle = ""
        listWaiting = 0
        guard showing else { return }
        tile.contentView = nil
        tile.display()
        showing = false
    }

    // MARK: - the badge: a failure he has not looked at

    /// Failures already badged or already seen, by the engine's number, kind
    /// and shoot, so the poll seeing the same failed job again - or the
    /// list's record of it - is one failure, and one he has looked at does
    /// not come back.
    private static var known: Set<String> = []
    private static var unseen: Set<String> = []
    /// What the badge says while a failure is waiting to be looked at.
    public static let failureBadge = "!"

    /// The Activity window, where a failure is read (`watchActivity`).
    private static weak var activityWindow: NSWindow?
    private static var becameKey: NSObjectProtocol?

    /// Whether Activity is in front of him now, so a failure that lands in it
    /// is news he is already reading. Not merely open: open behind PhotoLab,
    /// minimized, or in a hidden app is exactly when the badge is needed,
    /// and a window that existed counted as "in front of him" all night.
    /// The app is active and the window is his key window, or on screen and
    /// not covered. Replaced in tests.
    static var activityInFront: @MainActor () -> Bool = {
        guard NSApplication.shared.isActive, let w = activityWindow, w.isVisible, !w.isMiniaturized
        else { return false }
        return w.isKeyWindow || w.occlusionState.contains(.visible)
    }

    /// A piece of his work failed. Badged until he looks at Activity - unless
    /// it is in front of him, and the failure with it. The machine's own
    /// homework failing is not news, here as anywhere.
    public static func noteFailure(id: Int, kind: String, shoot: String) {
        let key = "\(id)|\(kind)|\(shoot)"
        guard !known.contains(key) else { return }
        known.insert(key)
        guard !activityInFront() else { return }
        unseen.insert(key)
        NSApplication.shared.dockTile.badgeLabel = failureBadge
    }

    /// The Activity window, from the moment it has one. Looking at it - it
    /// becoming his key window, on opening or on coming back to it from
    /// PhotoLab - is looking at every failure the badge was for.
    static func watchActivity(_ w: NSWindow) {
        guard activityWindow !== w else { return }
        if let becameKey { NotificationCenter.default.removeObserver(becameKey) }
        activityWindow = w
        // Posted on the main thread, where a window becomes key; answered
        // there and then.
        becameKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: w, queue: nil
        ) { _ in
            MainActor.assumeIsolated { DockProgress.sawTheFailures() }
        }
        if NSApplication.shared.isActive && w.isKeyWindow { sawTheFailures() }
    }

    /// Whether a failure is waiting to be looked at.
    public static var hasUnseenFailure: Bool { !unseen.isEmpty }

    /// He looked at Activity, where the failures are: the badge goes.
    public static func sawTheFailures() {
        guard !unseen.isEmpty else { return }
        unseen.removeAll()
        NSApplication.shared.dockTile.badgeLabel = nil
    }

    /// For tests.
    static func forgetFailures() {
        known.removeAll()
        unseen.removeAll()
        activityInFront = { false }
        NSApplication.shared.dockTile.badgeLabel = nil
    }

    public static func percent(_ job: Job) -> Int {
        Int((max(0, min(1, job.fraction)) * 100).rounded())
    }

    /// The Dock menu: what is running, and Stop. Returned to the app delegate
    /// from `applicationDockMenu(_:)`. With nothing running, a held list and
    /// Continue - a Stop from this menu holds the list, so the way to let it
    /// go is beside it - and, while a failure is badged, the way to it.
    public static func dockMenu(center: CommandCenter = .shared,
                                list: QueueState? = nil) -> NSMenu? {
        guard let job = center.job, job.running else { return restingMenu(list ?? Queues.state) }
        let m = NSMenu()
        let title = NSMenuItem(title: Words.Dock.running(JobWords.titled(job), shoot: job.shoot,
                                                         percent: percent(job)),
                               action: nil, keyEquivalent: "")
        title.isEnabled = false
        m.addItem(title)
        let stop = NSMenuItem(title: Words.Shoot.stopJob, action: #selector(DockActions.stop(_:)),
                              keyEquivalent: "")
        stop.target = DockActions.shared
        m.addItem(stop)
        // And what is behind it, so the answer to "how much is left" is on
        // the Dock too, with the way to the list beside it.
        if listWaiting > 0 {
            m.addItem(.separator())
            let waiting = NSMenuItem(title: Strings.Queue.waitingSpoken(listWaiting),
                                     action: nil, keyEquivalent: "")
            waiting.isEnabled = false
            m.addItem(waiting)
            let show = NSMenuItem(title: Strings.Queue.title,
                                  action: #selector(DockActions.showTheList(_:)), keyEquivalent: "")
            show.target = DockActions.shared
            m.addItem(show)
        }
        return m
    }

    /// Nothing running: a held list with Continue, and Show Activity while a
    /// failure is badged. Nothing at all when there is neither.
    static func restingMenu(_ list: QueueState) -> NSMenu? {
        let held = list.held && !list.waiting.isEmpty
        guard held || hasUnseenFailure else { return nil }
        let m = NSMenu()
        if held {
            let title = NSMenuItem(title: Strings.StatusItem.held(list.waiting.count), action: nil,
                                   keyEquivalent: "")
            title.isEnabled = false
            m.addItem(title)
            let go = NSMenuItem(title: Strings.Queue.letGo, action: #selector(DockActions.letGo(_:)),
                                keyEquivalent: "")
            go.target = DockActions.shared
            m.addItem(go)
            let show = NSMenuItem(title: Strings.Queue.title,
                                  action: #selector(DockActions.showTheList(_:)), keyEquivalent: "")
            show.target = DockActions.shared
            m.addItem(show)
        } else {
            let show = NSMenuItem(title: Strings.StatusItem.showActivity,
                                  action: #selector(DockActions.showTheList(_:)), keyEquivalent: "")
            show.target = DockActions.shared
            m.addItem(show)
        }
        return m
    }
}

/// The Dock menu's own target. The Dock's menu is not in the responder chain,
/// so it needs a real object to send to.
@MainActor
final class DockActions: NSObject {
    static let shared = DockActions()
    @objc func stop(_ sender: Any?) {
        CommandCenter.shared.run(CommandTable.ID.stopJob)
    }

    @objc func showTheList(_ sender: Any?) {
        Queues.showTheList?()
    }

    @objc func letGo(_ sender: Any?) {
        guard let list = Queues.shared?() else { return }
        Task { await list.hold(false) }
    }
}

/// The app's icon with a determinate bar across the bottom of it. Public so
/// the snapshot harness draws this and not a copy of it.
public final class DockTileView: NSView {
    public var fraction: Double = 0 { didSet { needsDisplay = true } }

    public override init(frame: NSRect) { super.init(frame: frame) }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    public override func draw(_ dirty: NSRect) {
        let b = bounds
        NSApplication.shared.applicationIconImage?.draw(in: b, from: .zero,
                                                        operation: .sourceOver, fraction: 1)
        // A bar the width of the icon, an eighth of its height, sitting on the
        // bottom edge with a margin, in the system accent so it reads as this
        // Mac's progress and not as a brand colour.
        let height = (b.height * 0.11).rounded()
        let inset = (b.width * 0.10).rounded()
        let track = NSRect(x: b.minX + inset, y: b.minY + inset,
                           width: b.width - inset * 2, height: height)
        let radius = height / 2

        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let filled = NSRect(x: track.minX, y: track.minY,
                            width: max(height, track.width * fraction), height: height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()

        NSColor.white.withAlphaComponent(0.8).setStroke()
        let edge = NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        edge.lineWidth = 1
        edge.stroke()
    }
}
