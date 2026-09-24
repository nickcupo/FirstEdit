import SwiftUI
import AppKit

/// One row of the Activity window: a job this session ran.
public struct ActivityRow: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let what: String
    public let shoot: String
    public let started: Date
    /// Frozen the instant the job stopped, and never recomputed from the wall
    /// clock (DESIGN.md §7.11).
    public let elapsed: Int
    public let outcome: Job.Outcome
    public let log: String
    /// Whether this is a log he has to come here to read: a failure, or a
    /// no the list got while he was away. A no to something he pressed was
    /// said under the button he pressed, and is not news here.
    public let isNews: Bool
    /// The engine's kind of work, and whether it was the machine's own
    /// homework: what `place` is worked out from.
    public let kind: String
    public let background: Bool
    /// From before this session, read back from the engine's record. Its
    /// start carries the day, and it is not news: it was there to be seen
    /// when it happened.
    public let earlier: Bool

    public init(id: UUID, what: String, shoot: String, started: Date,
                elapsed: Int, outcome: Job.Outcome, log: String, fromList: Bool = false,
                kind: String = "", background: Bool = false, earlier: Bool = false) {
        self.id = id; self.what = what; self.shoot = shoot; self.started = started
        self.elapsed = elapsed; self.outcome = outcome; self.log = log
        self.isNews = !earlier && (outcome == .failed || (outcome == .refused && fromList))
        self.kind = kind; self.background = background; self.earlier = earlier
    }

    public init(_ r: JobModel.Record) {
        // The app's word for the work, as the list says it (`Job.what`): the
        // engine's title - "culling 2026-09-19" - put the shoot beside a Shoot
        // column that already says it.
        self.init(id: r.id, what: r.job.what, shoot: r.job.shoot, started: r.started,
                  elapsed: r.elapsed, outcome: r.outcome, log: r.job.log, fromList: r.job.fromList,
                  kind: r.job.kind, background: r.job.background, earlier: r.earlier)
    }

    /// When it started, as the Started column says it: the time for today,
    /// and the day as well for anything before - the history keeps a few
    /// days now, and "23:14" beside this morning's rows would read as today.
    public func startedText(now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(started, inSameDayAs: now) {
            return started.formatted(.dateTime.hour().minute())
        }
        return started.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// Where this work is done, for a double-click on its row: the step
    /// whose button starts it, Finish for the storage work its panel starts,
    /// the shoot's own page for work no one step owns, and the learning page
    /// for the machine's own homework. Without it a failed cull meant going
    /// to the shoot and finding the step by hand.
    public var place: SidebarSelection? {
        // Working out the Instagram cuts is the machine's own homework, but
        // it belongs to the shoot's Instagram step, where its bar is drawn.
        if kind == "instagram-plan", !shoot.isEmpty { return .step(shoot: shoot, step: "instagram") }
        if background { return .learned }
        guard !shoot.isEmpty else { return nil }
        switch kind {
        case "ingest", "cull", "presets": return .step(shoot: shoot, step: kind)
        case "reel": return .step(shoot: shoot, step: "reels")
        case "instagram": return .step(shoot: shoot, step: "instagram")
        case _ where kind.hasPrefix("stor-") || kind.hasPrefix("plan-"):
            return .step(shoot: shoot, step: "done")
        default: return .shoot(shoot)
        }
    }

    /// The shoot, when the name of the work does not already say it: the
    /// engine's own titles sometimes do ("Learning from 2026-09-21").
    var shootAfterWhat: String? {
        shoot.isEmpty || what.contains(shoot) ? nil : shoot
    }

    /// The one line he opened the window to read: the engine's sentence at the
    /// end of the log, for a job that did not simply finish.
    var headline: String? {
        guard outcome == .refused || outcome == .failed || outcome == .stopped else { return nil }
        let lines = log.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.last { !$0.isEmpty && !$0.hasPrefix("$ ") }
    }

    /// The log as he reads it: the command line the engine ran is not his
    /// business until he asks, so it is held back for the Details disclosure,
    /// and the indent the engine puts under it goes with it.
    var readableLog: String {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("$ ") }
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return lines.map { $0.dropFirst(min(indent, $0.count)) }.joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    /// What goes under the headline: the readable log, or nothing when the
    /// headline is all of it. A refused plan's log is its one sentence, and
    /// the window printed it twice, over and under the line.
    var logUnderHeadline: String {
        let body = readableLog
        guard let headline else { return body }
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines == [headline] ? "" : body
    }

    var commands: String {
        log.split(separator: "\n").filter { $0.hasPrefix("$ ") }.joined(separator: "\n")
    }
}

extension Job {
    /// One name for a piece of work wherever it is named — the list, the
    /// history, the toolbar and its popover: his word for the kind of work
    /// (`Strings.Queue.what`), and the engine's own title, first letter up,
    /// only for work the app has no word for. The same cull was "Cull" on
    /// the list, "culling 2026-09-13-dog" in the history beside a Shoot
    /// column that said it again, and a lowercase headline in the popover.
    public var what: String {
        if let mine = Strings.Queue.what(kind) { return mine }
        return (title.isEmpty ? kind : title).capitalizedFirst
    }

    /// The shoot, when `what` does not already name it.
    public var shootAfterWhat: String? {
        shoot.isEmpty || what.contains(shoot) ? nil : shoot
    }
}

/// This session's jobs — kind, shoot, started, elapsed, outcome — with the
/// selected job's log. The log finally has a home instead of a disclosure
/// inside a card (DESIGN.md §2.7, ⌥⌘L).
///
/// Nothing here is a second place a job is reported. Progress stays where the
/// button was, on the step that started it; this window is for afterwards,
/// when the question is "what did it say".
public struct ActivityWindow: View {
    private let rows: [ActivityRow]
    private let logURL: URL?
    private let isRunning: Bool
    private let stop: (() -> Void)?
    /// The list of work: what is going to happen. It sits above the history,
    /// which is what happened, because that is one question asked in two
    /// directions and this is the one window that answers it.
    private let queue: QueueState
    private let queueRefusal: String?
    private let move: (IndexSet, Int) -> Void
    private let removeFromQueue: (Int) -> Void
    private let clearQueue: () -> Void
    private let holdQueue: (Bool) -> Void
    /// The rows already on screen the last time this window closed, and how
    /// to say which those are now. A failure he has read is not the thing to
    /// open on again.
    private let read: Set<ActivityRow.ID>
    private let markRead: ([ActivityRow.ID]) -> Void
    /// Takes the main window to a page, for Show the Step.
    private let show: ((SidebarSelection) -> Void)?
    @State private var selection: ActivityRow.ID?
    @State private var commandsShown = false

    public init(jobs: JobModel, logURL: URL?, queue: QueueModel? = nil,
                show: ((SidebarSelection) -> Void)? = nil) {
        self.show = show
        self.rows = jobs.history.map(ActivityRow.init)
        self.read = jobs.readInActivity
        self.markRead = { jobs.readInActivity.formUnion($0) }
        self.logURL = logURL
        self.isRunning = jobs.isRunning
        self.stop = { Task { await jobs.stop() } }
        self.queue = queue?.state ?? .empty
        self.queueRefusal = queue?.refusals[.list]
        self.move = { s, d in Task { await queue?.move(from: s, to: d) } }
        self.removeFromQueue = { id in Task { await queue?.remove(id) } }
        self.clearQueue = { Task { await queue?.clear() } }
        self.holdQueue = { held in Task { await queue?.hold(held) } }
    }

    /// For the snapshot harness and previews: the same window, from rows.
    public init(rows: [ActivityRow], logURL: URL? = nil, isRunning: Bool = false,
                queue: QueueState = .empty, read: Set<ActivityRow.ID> = []) {
        self.show = nil
        self.rows = rows
        self.read = read
        self.markRead = { _ in }
        self.logURL = logURL
        self.isRunning = isRunning
        self.stop = nil
        self.queue = queue
        self.queueRefusal = nil
        self.move = { _, _ in }
        self.removeFromQueue = { _ in }
        self.clearQueue = {}
        self.holdQueue = { _ in }
    }

    /// The table's heading and two rows.
    static let tableMinimum: CGFloat = 92

    /// Its heading (28), its rows (24 each) and the 16 points the table puts
    /// above and below them, as it lays them out (`NSTableView.rect(ofRow:)`
    /// in `activity-list`); six rows at most, then it scrolls.
    private var tableHeight: CGFloat {
        max(Self.tableMinimum, 28 + 16 + 24 * CGFloat(min(rows.count, 6)))
    }
    /// Five lines of the log.
    static let logMinimum: CGFloat = 96
    /// Every part at its least, with room for a refusal over the list: the
    /// parts at 440 came to more than 440, so the list's heading ran into
    /// the title bar and the buttons fell off the bottom.
    static let minimumHeight: CGFloat = 480

    /// The displays crew replaces this with `"activity.\(ScreenKey)"`, so the
    /// window reopens on the screen it was last used on (DESIGN-displays §5.2).
    nonisolated(unsafe) public static var autosaveName = "activity"

    public var body: some View {
        VStack(spacing: 0) {
            // What is going to happen, first: this is the window he opens to
            // stack an evening up, and the history under it is what came of
            // the last one.
            // As tall as its rows. It is laid out first, and the history
            // under it gives way - the log, then the table - down to their
            // minimums; only then does the list scroll. A fixed cap of 320
            // scrolled a list of four in a window with room to spare.
            QueueList(state: queue, move: move, remove: removeFromQueue,
                      clear: clearQueue, hold: holdQueue, stop: stop, refusal: queueRefusal)
                .layoutPriority(2)
            Divider()
            if rows.isEmpty {
                // One line, not a panel: an empty history took half the
                // window from the list above it, and said "Nothing has run"
                // under a job that was running.
                Text(queue.running ? Strings.Activity.historyComing : Strings.Activity.noHistory)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.Metric.windowMargin)
                    .padding(.vertical, Tokens.Metric.relatedGap)
                    .accessibilityIdentifier("activity.noHistory")
                Spacer(minLength: 0)
            } else {
                // The table is as tall as it needs to be and no taller; the
                // log gets the rest, because the sentence he came to read is
                // usually the last line of it.
                table
                Divider()
                log
            }
            Divider()
            footer
        }
        // The least that holds every part at its own least - the list's
        // heading and two rows, the table's heading and two rows, a few
        // lines of log and the buttons under it - so none of them is cut
        // off at the window's smallest.
        .frame(minWidth: 560, minHeight: Self.minimumHeight)
        .navigationTitle(Strings.Job.activity)
        .background(ActivityWindowChrome())
        // The log under the table is the selected row's, and a row is always
        // selected: the log of a row nobody had highlighted read as nobody's.
        // It opens on what he came to read (`firstToRead`, on the table); a
        // new row is picked when he was following the newest, and a row he
        // picked to read stays picked.
        .onChange(of: rows.last?.id) { old, newest in
            if selection == nil || selection == old { selection = newest }
        }
    }

    /// Outcome second, at a width of its own, with the shoot inside the Work
    /// cell and the start to the minute: five columns with ideal widths
    /// summing past the window's 720 pt cut Outcome — the one column he
    /// opened the window to read — to "Stopp" and "Refus" behind a
    /// horizontal scroller.
    private var table: some View {
        // Outcome second, beside what it is about: it is the column he opens
        // this window to read, and last it was cut off at the window's own
        // default width. The widths, with the space between columns, add up
        // to less than the window's least (560), so nothing scrolls sideways.
        Table(rows, selection: $selection) {
            TableColumn(Strings.Queue.workColumn) { r in
                HStack(spacing: Tokens.Metric.relatedGap) {
                    Text(r.what).lineLimit(1).layoutPriority(1)
                    if let shoot = r.shootAfterWhat {
                        Text(shoot).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn(Strings.Job.outcome) { r in OutcomeLabel(outcome: r.outcome) }
                .width(Self.outcomeWidth)
            TableColumn(Strings.Job.started) { r in
                Text(r.startedText()).monospacedDigit().lineLimit(1)
            }
            .width(min: 56, ideal: rows.contains { $0.earlier } ? 96 : 64, max: 110)
            TableColumn(Strings.Job.elapsed) { r in
                Text(Duration.seconds(r.elapsed), format: .time(pattern: .minuteSecond)).monospacedDigit()
            }
            .width(min: 56, ideal: 64, max: 90)
        }
        // As tall as its rows up to six, and no taller: it took 180 points
        // for three rows and left the empty ones to the log's cost.
        .frame(minHeight: Self.tableMinimum, idealHeight: tableHeight, maxHeight: tableHeight)
        // Before the log: when the list grows, the log gives way first.
        .layoutPriority(1)
        .alternatingRowBackgrounds(.disabled)
        .onAppear { if selection == nil { selection = Self.firstToRead(rows, read: read) } }
        // Everything that had ended while the window was open has been in
        // front of him.
        .onDisappear { markRead(rows.filter { $0.outcome != .running }.map(\.id)) }
        // A row is a way back to where the work is done: a double-click, or
        // Show the Step on its menu, with its log to copy beside it. Rows had
        // neither, so after a failure he went to the shoot, found the step
        // and pressed again from memory.
        .contextMenu(forSelectionType: ActivityRow.ID.self) { ids in
            if let r = row(ids) {
                if let place = r.place, show != nil {
                    Button(Self.showTitle(place)) { show?(place) }
                }
                Button(Strings.Job.copyLog) { Self.copy(r.log) }
                    .disabled(r.log.isEmpty)
            }
        } primaryAction: { ids in
            if let place = row(ids)?.place { show?(place) }
        }
    }

    private func row(_ ids: Set<ActivityRow.ID>) -> ActivityRow? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return rows.first { $0.id == id }
    }

    /// Named for where it goes.
    static func showTitle(_ place: SidebarSelection) -> String {
        switch place {
        case .learned: return Strings.Job.showWhatItHasLearned
        case .step: return Strings.Job.showTheStep
        default: return Strings.Job.showTheShoot
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The widest outcome word with its symbol, and no wider.
    static let outcomeWidth: CGFloat = 100

    private var selected: ActivityRow? {
        let id = selection ?? Self.firstToRead(rows, read: read)
        return rows.first { $0.id == id }
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let r = selected, let line = r.headline {
                // The sentence he opened the window for, above the rest of
                // the log rather than somewhere at the bottom of it.
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.relatedGap) {
                    OutcomeLabel(outcome: r.outcome).fixedSize()
                    Text(line)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
                .padding(.horizontal, Tokens.Metric.windowMargin)
                .padding(.vertical, Tokens.Metric.relatedGap)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
                    if let body = selected?.logUnderHeadline, !body.isEmpty {
                        Text(body)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let commands = selected?.commands, !commands.isEmpty {
                        DisclosureGroup(Strings.Shell.details, isExpanded: $commandsShown) {
                            Text(commands)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.footnote)
                    }
                }
                .padding(.horizontal, Tokens.Metric.windowMargin)
                .padding(.vertical, Tokens.Metric.relatedGap)
            }
        }
        .frame(minHeight: Self.logMinimum, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.Job.activity)
    }

    private var footer: some View {
        HStack(spacing: Tokens.Metric.relatedGap) {
            // Nothing has run: there is no log of a job to copy, and a greyed
            // button is just a thing in the way. The engine's own log file is
            // still there, and still worth reaching.
            if !rows.isEmpty {
                Button(Strings.Job.copyLog) { Self.copy(selectedLog) }
                    .disabled(selectedLog.isEmpty)
            }
            if logURL != nil {
                Button(Strings.Job.showLogFile) {
                    guard let logURL else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                }
            }
            Spacer()
            if isRunning {
                // The same ⌘. as Shoot ▸ Stop What Is Running, on the window that is
                // showing him what it is doing.
                Button(Strings.Job.stop) { stop?() }
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
        .padding(.horizontal, Tokens.Metric.windowMargin)
        .padding(.vertical, Tokens.Metric.relatedGap)
        .background(.bar)
    }

    /// Copy the Log copies the whole of it, the command line included.
    private var selectedLog: String { selected?.log ?? "" }

    /// The row whose log is shown before he picks one, and picked for him so
    /// the table says whose log it is.
    ///
    /// First the newest failure - or no the list got while he was away -
    /// that he has not had in front of him in this window: that is what the
    /// banner and Show the Log send him here to read, and the list has
    /// usually started its next piece by the time he arrives. Then what is
    /// running. Then the newest. It picked the newest failure or refusal
    /// whenever there was one, so after a no he had already read under the
    /// button that raised it, opening the window to watch the cull showed
    /// him that old sentence again and left the cull unpicked.
    static func firstToRead(_ rows: [ActivityRow], read: Set<ActivityRow.ID> = []) -> ActivityRow.ID? {
        (rows.last { $0.isNews && !read.contains($0.id) }
            ?? rows.last { $0.outcome == .running }
            ?? rows.last)?.id
    }

    static func word(_ o: Job.Outcome) -> String {
        switch o {
        // Only a record the history closed without seeing how: the engine
        // finished it and started the next between two looks.
        case .idle: return Strings.Activity.ended
        case .running: return Strings.Job.running
        case .done: return Strings.Job.done
        case .stopped: return Strings.Job.stopped
        case .refused: return Strings.Job.refused
        case .failed: return Strings.Job.failed
        }
    }
}

/// A word and a symbol, never colour alone. **Refused is in the ordinary text
/// colour**: a plan that says no on purpose did not fail, and dressing it in
/// red teaches him to distrust a perfectly good answer (DESIGN.md §2.7).
struct OutcomeLabel: View {
    let outcome: Job.Outcome

    var body: some View {
        Label {
            Text(ActivityWindow.word(outcome))
        } icon: {
            Image(systemName: Self.symbol(outcome)).symbolRenderingMode(.hierarchical)
        }
        .foregroundStyle(Self.tint(outcome))
        .accessibilityLabel(ActivityWindow.word(outcome))
    }

    /// The same symbol and colour in the toolbar's status item.
    static func symbol(_ outcome: Job.Outcome) -> String {
        switch outcome {
        case .idle: return "circle.dotted"
        case .running: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle"
        case .stopped: return "stop.circle"
        case .refused: return "hand.raised"
        case .failed: return Symbols.brokenShoot
        }
    }

    static func tint(_ outcome: Job.Outcome) -> Color {
        switch outcome {
        case .failed: return Tokens.Palette.alarm
        case .done: return Tokens.Palette.kept
        default: return .primary
        }
    }
}

/// The window's own AppKit settings: the saved frame, under a name the
/// displays crew can change so it comes back on the screen it was on.
struct ActivityWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Chrome() }
    func updateNSView(_ v: NSView, context: Context) {}

    final class Chrome: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            let name = ActivityWindow.autosaveName
            if w.frameAutosaveName != name { w.setFrameAutosaveName(name) }
            // The failures the Dock's badge was for are read here: it goes
            // when this window becomes his key window, and one that lands
            // while it is in front of him is never badged. Not when the view
            // merely exists - open behind PhotoLab or minimized, it is not
            // in front of anyone (`DockProgress.activityInFront`).
            DockProgress.watchActivity(w)
        }
    }
}
