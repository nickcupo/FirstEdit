import AppKit
import SwiftUI

/// The list of work, on screen: what is happening now with its progress, then
/// what is waiting, in his order.
///
/// It lives in the Activity window (⌥⌘L), above the history, because those
/// are the two halves of the same question — what is going to happen, and
/// what happened. Nothing here is a second place a running job is reported:
/// the progress of the job he pressed a button for stays where the button
/// was, on that step. This is the list.
public struct QueueList: View {
    let state: QueueState
    let move: (IndexSet, Int) -> Void
    let remove: (Int) -> Void
    let clear: () -> Void
    let hold: (Bool) -> Void
    let stop: (() -> Void)?
    /// The engine's refusal of something he asked the list to do.
    let refusal: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The waiting row he picked, by the engine's id: what ⌥⌘↑, ⌥⌘↓, Do
    /// Next and Delete act on.
    @State private var selection: Int?
    /// Each row's own height as it was laid out, by id. A row whose reason
    /// wraps is taller than any constant, and a list sized from constants
    /// scrolled its last line away.
    @State private var measured: [Int: CGFloat] = [:]
    /// The whole list's height as the list itself laid it out, headings,
    /// insets and footer included, once it has (`ListHeightProbe`). The rows
    /// added up with guessed insets came out a few points short of this on
    /// every list, so even three rows showed a scroller.
    @State private var laidOut: CGFloat?
    @State private var confirmingClear = false

    public init(state: QueueState,
                move: @escaping (IndexSet, Int) -> Void = { _, _ in },
                remove: @escaping (Int) -> Void = { _ in },
                clear: @escaping () -> Void = {},
                hold: @escaping (Bool) -> Void = { _ in },
                stop: (() -> Void)? = nil,
                refusal: String? = nil,
                selected: Int? = nil) {
        self.state = state
        self.move = move
        self.remove = remove
        self.clear = clear
        self.hold = hold
        self.stop = stop
        self.refusal = refusal
        self._selection = State(initialValue: selected)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let r = refusal, !r.isEmpty {
                RefusalRow(r, owner: .list)
                    .padding(.horizontal, Tokens.Metric.windowMargin)
                    .padding(.bottom, Tokens.Metric.relatedGap)
            }
            if state.hasAnything {
                rows
            } else {
                empty
            }
            // What the list could not do, after the fact. It is here and not
            // only in the notification he may have missed: he walked away
            // from four things, and "three happened and one did not, and
            // this is why" has to be somewhere he can go and read it.
            if !state.skipped.isEmpty {
                skipped
            }
        }
        .accessibilityIdentifier("queue.list")
    }

    // MARK: - the top line

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            controls
            // What held it, on a line of its own that wraps: his Hold, or a
            // Stop he pressed, or the engine stopping under a job. It sat
            // in an overlay a fixed 15 points down, which a second line ran
            // out of and into the rows.
            if state.held {
                Text(Strings.Queue.heldLine(state.heldAfter))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("queue.heldNote")
            }
        }
        .padding(.horizontal, Tokens.Metric.windowMargin)
        .padding(.top, Tokens.Metric.relatedGap)
        .padding(.bottom, Tokens.Metric.relatedGap)
    }

    private var controls: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.relatedGap) {
            Text(Strings.Queue.title)
                .font(.headline)
            if state.count > 0 {
                Text("\(state.count)")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Strings.Queue.waitingSpoken(state.count))
            }
            Spacer(minLength: Tokens.Metric.relatedGap)
            // Clear first and Hold last, a gap apart: Hold is the one he
            // reaches for when the phone rings, and it sat 16 points from a
            // Clear that wiped six carefully ordered pieces of work with no
            // question and no way back. It asks now, whenever it would take
            // more than one, and takes nothing that is running.
            Button(Strings.Queue.clear) {
                if state.waiting.count > 1 { confirmingClear = true } else { clear() }
            }
            .controlSize(.small)
            .disabled(state.waiting.isEmpty)
            .accessibilityIdentifier("queue.clear")
            .confirmationDialog(Strings.Queue.clearQuestion(state.waiting.count),
                                isPresented: $confirmingClear) {
                Button(Strings.Queue.clearConfirm, role: .destructive, action: clear)
                Button(Strings.Queue.keepThem, role: .cancel) {}
            } message: {
                Text(Strings.Queue.clearNote)
            }
            // Never greyed: an empty list can be held, so an evening can be
            // lined up while he is still culling and none of it starts
            // until he continues. It was greyed until something was on it,
            // and the first thing he added started at once.
            Button(state.held ? Strings.Queue.letGo : Strings.Queue.hold) { hold(!state.held) }
                .controlSize(.small)
                .padding(.leading, Tokens.Metric.windowMargin)
                .accessibilityIdentifier("queue.hold")
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            if state.done.isEmpty && state.skipped.isEmpty {
                Text(Strings.Queue.emptyTitle)
                    .font(.callout)
                // What the list is for, said only where he has never used
                // it. After a pass, the interesting thing on this screen is
                // what it did, and an explanation of the idea underneath is
                // in the way.
                Text(Strings.Queue.emptyBody)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // What the pass came to, by outcome, then each piece with the
                // same word, symbol and colour as the history: "4 finished"
                // over a failed cull said nothing was wrong.
                summaryLine
                    .font(.callout)
                    .accessibilityLabel(Strings.Queue.summary(state.tally))
                    .accessibilityIdentifier("queue.summary")
                ForEach(state.doneWorstFirst) { d in
                    QueueDoneRow(item: d)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Tokens.Metric.windowMargin)
        .padding(.bottom, Tokens.Metric.relatedGap)
        .accessibilityIdentifier("queue.empty")
    }

    /// "1 failed, 1 refused, 2 done", with only the failures in the alarm
    /// colour. The whole line went red over a pass with one failure in it,
    /// done and refused included.
    private var summaryLine: Text {
        Strings.Queue.summaryParts(state.tally).enumerated().reduce(Text("")) { line, part in
            let piece = Text(part.element.text)
                .foregroundStyle(part.element.failed ? Tokens.Palette.alarm : Color.primary)
            return part.offset == 0 ? piece : line + Text(", ") + piece
        }
    }

    /// What the list passed over, and why. The heading is ours; every reason
    /// under it is the engine's sentence, printed as it wrote it.
    private var skipped: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            Text(Strings.Queue.skippedHeading)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(state.skipped) { s in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Image(systemName: Symbols.refusal)
                            .symbolRenderingMode(.hierarchical)
                            .imageScale(.small)
                            .accessibilityHidden(true)
                        Text(s.what).font(.callout)
                        if !s.shoot.isEmpty {
                            Text(s.shoot).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Text(s.whyNot)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.leading, 20)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Tokens.Metric.windowMargin)
        .padding(.vertical, Tokens.Metric.relatedGap)
        .accessibilityIdentifier("queue.skipped")
    }

    // MARK: - the rows

    @ViewBuilder private var rows: some View {
        List(selection: $selection) {
            if let now = state.runningItem {
                Section(Strings.Queue.runningNow) {
                    QueueRunningRow(item: now, state: state, stop: stop)
                        .selectionDisabled()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            measured[Self.runningKey] = $0
                        }
                        .background(ListHeightProbe { laidOut = $0 })
                }
            }
            if !state.waiting.isEmpty {
                Section {
                    ForEach(Array(state.waiting.enumerated()), id: \.element.id) { i, item in
                        QueueWaitingRow(item: item, place: i + 1, of: state.waiting.count,
                                        remove: { remove(item.id) },
                                        moveUp: moveUp(i), moveDown: moveDown(i), doNext: doNext(i))
                            .tag(item.id)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                measured[item.id] = $0
                            }
                            .background { if i == 0 { ListHeightProbe { laidOut = $0 } } }
                    }
                    .onMove { source, destination in move(source, destination) }
                } footer: {
                    if state.waiting.count > 1 {
                        Text(Strings.Queue.reorderHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        // Delete takes the picked row off, the way it does in every list on
        // the Mac.
        .onDeleteCommand { if let id = selection { remove(id); selection = nil } }
        .background { shortcuts }
        // Asked for, not left to the `List`.
        //
        // A `List` inside a `VStack` reports an ideal height of its own that
        // has nothing to do with how many rows it holds, and the history
        // under it asks for everything that is left — so a list of two ended
        // up showing one and a half and scrolling the rest, which is the one
        // thing a list he filled must not do. The height is the list's own,
        // as it laid its rows out, and it goes first: the history under it
        // gives way before the list does. It scrolls only when the window
        // has no more room.
        .frame(minHeight: min(wanted, Self.row * 2), idealHeight: wanted, maxHeight: wanted)
        .layoutPriority(1)
    }

    /// ⌥⌘↑ and ⌥⌘↓ move the picked row, ⌥⌘Home sends it to the top. Not
    /// ⇧⌥⌘↑: AppKit matches an arrow with or without ⇧, so that one moved
    /// the row up one place as often as it sent it to the top. Buttons
    /// with no size and no look, because a key equivalent is what the window
    /// answers before the list's own arrow keys can take the press.
    private var shortcuts: some View {
        ZStack {
            Button(Strings.Queue.moveUp) { act { moveUp($0) } }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button(Strings.Queue.moveDown) { act { moveDown($0) } }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button(Strings.Queue.doNext) { act { doNext($0) } }
                .keyboardShortcut(.home, modifiers: [.command, .option])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Runs what `which` makes of the picked row's place, if it makes one.
    private func act(_ which: (Int) -> (() -> Void)?) {
        guard let id = selection, let i = state.waiting.firstIndex(where: { $0.id == id }) else { return }
        which(i)?()
    }

    private func moveUp(_ i: Int) -> (() -> Void)? {
        i > 0 ? { move(IndexSet(integer: i), i - 1) } : nil
    }
    private func moveDown(_ i: Int) -> (() -> Void)? {
        i < state.waiting.count - 1 ? { move(IndexSet(integer: i), i + 2) } : nil
    }
    private func doNext(_ i: Int) -> (() -> Void)? {
        i > 0 ? { move(IndexSet(integer: i), 0) } : nil
    }

    /// Room for every row: the list's own height once it has laid itself
    /// out, and until then an estimate from the rows. There is no cap of its
    /// own; the window is the limit (`ActivityWindow`).
    var wanted: CGFloat { laidOut ?? estimated }

    /// Each row the height it was laid out at, once it has been, and before
    /// that the estimate for its kind; with the list's headings, gaps,
    /// footer and insets as measured off the rendered list
    /// (`activity-list-long-reasons`).
    var estimated: CGFloat {
        // "Happening now" has a heading; the waiting rows have none, only
        // the gap between the two sections.
        let headings: CGFloat = (state.runningItem != nil ? Self.heading : 0)
            + (state.runningItem != nil && !state.waiting.isEmpty ? Self.sectionGap : 0)
        let running: CGFloat = state.runningItem == nil ? 0
            : measured[Self.runningKey].map { $0 + Self.rowChrome } ?? Self.runningRow
        let rows = state.waiting.reduce(CGFloat.zero) { sum, item in
            sum + (measured[item.id].map { $0 + Self.rowChrome } ?? (item.ready ? Self.row : Self.staleRow))
        }
        let footer: CGFloat = state.waiting.count > 1 ? Self.footer : 0
        return headings + running + rows + footer + Self.padding
    }

    static let row: CGFloat = 45
    static let staleRow: CGFloat = 73
    static let runningRow: CGFloat = 62
    // Read off the list's own rows (`NSTableView.rect(ofRow:)`) in
    // `activity-list-long-reasons`: the section heading, the gap between the
    // sections, the footer line, and the inset above the first row and
    // below the last.
    static let heading: CGFloat = 28
    static let sectionGap: CGFloat = 20
    static let footer: CGFloat = 28
    static let padding: CGFloat = 20
    /// What the list puts around a row's own content: its insets and its
    /// separator. A row measured at 36.75 is drawn 45 tall.
    static let rowChrome: CGFloat = 8.25
    /// The running row's key among the measured heights; no engine id is
    /// negative.
    static let runningKey = -1
}

/// How tall the `List` it sits in has to be to show every row without
/// scrolling: the bottom of its last row, and under it the same inset the
/// list leaves above its first.
///
/// Read from the list's own table, because SwiftUI does not say: its scroll
/// geometry is never reported for a `List` on the Mac, and rows added up
/// with guessed insets were a few points short on every list - enough for
/// a scroller over three rows. Placed in a row's background, so it is inside
/// the list it measures. Where there is no table to read, it says nothing
/// and the estimate stands.
struct ListHeightProbe: NSViewRepresentable {
    let report: @MainActor (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ v: Probe, context: Context) {
        v.report = report
        v.measureSoon()
    }

    static func dismantleNSView(_ v: Probe, coordinator: ()) { v.detach() }

    @MainActor final class Probe: NSView {
        var report: (@MainActor (CGFloat) -> Void)?
        private weak var table: NSTableView?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { measureSoon() }
        }

        /// After the list has finished the pass that is laying it out now,
        /// so the rows it reads are the rows on screen.
        func measureSoon() {
            DispatchQueue.main.async { [weak self] in self?.measure() }
        }

        private func measure() {
            guard window != nil, let t = enclosingScrollView?.documentView as? NSTableView else { return }
            if t !== table { watch(t) }
            let n = t.numberOfRows
            guard n > 0 else { return }
            let top = t.rect(ofRow: 0).minY
            let h = (t.rect(ofRow: n - 1).maxY + top).rounded(.up)
            // Said every time, not only when it changed: the list keeps one
            // number, and the same number again changes nothing.
            if h > 0 { report?(h) }
        }

        /// A row wrapping to another line, or one added or taken away,
        /// changes the table's frame; each change is read again.
        private func watch(_ t: NSTableView) {
            detach()
            table = t
            t.postsFrameChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: t, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.measureSoon() }
            }
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            table = nil
        }
    }
}

/// One piece of a finished pass: what it was, whose shoot, and how it ended,
/// in the history's own word and symbol.
struct QueueDoneRow: View {
    let item: QueueDone

    var body: some View {
        HStack(spacing: 6) {
            Text(item.what).font(.callout)
            if !item.shoot.isEmpty {
                Text(item.shoot)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Tokens.Metric.relatedGap)
            OutcomeLabel(outcome: item.ended)
                .font(.callout)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("queue.done.\(item.id)")
    }
}

/// What is happening now: its name, its shoot, the engine's own stage words,
/// a bar, and Stop.
struct QueueRunningRow: View {
    let item: QueueItem
    let state: QueueState
    let stop: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Metric.relatedGap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.what).font(.callout)
                    if !item.shoot.isEmpty {
                        Text(item.shoot)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                // The engine's stage words and what is left. Both are its
                // own; nothing here turns seconds into English.
                if !state.whereItHasGot.isEmpty {
                    Text(state.whereItHasGot)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                ProgressView(value: min(max(state.jobFraction, 0), 1))
                    .progressViewStyle(.linear)
                    .animation(reduceMotion ? nil : Motion.progress(over: QueueModel.busyInterval),
                               value: state.jobFraction)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let stop {
                Button(Strings.Job.stop, action: stop)
                    .controlSize(.small)
                    .accessibilityIdentifier("queue.stopRunning")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        [item.what, item.shoot, state.whereItHasGot].filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

/// One thing waiting: what it is, whose shoot, what it will do — and, when it
/// has gone stale, that it will be skipped and the engine's reason.
struct QueueWaitingRow: View {
    let item: QueueItem
    let place: Int
    let of: Int
    let remove: () -> Void
    let moveUp: (() -> Void)?
    let moveDown: (() -> Void)?
    let doNext: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.relatedGap) {
            Image(systemName: item.ready ? "line.3.horizontal" : Symbols.refusal)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.what)
                        .font(.callout)
                        // Colour is never the only signal: a row that will be
                        // skipped carries the refusal symbol as well.
                        .foregroundStyle(item.ready ? .primary : .secondary)
                    if !item.shoot.isEmpty {
                        Text(item.shoot)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if item.ready {
                    if !item.does.isEmpty {
                        Text(item.does)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !item.kept {
                        Text(Strings.Queue.wontBeKept)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // Put back by the engine after it stopped under it, so
                    // the row says why it is first and held.
                    if item.interrupted {
                        Text(Strings.Queue.interruptedNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    // It says so here, in his list, before he walks away —
                    // rather than going quiet and being explained afterwards.
                    // The heading is ours; the reason is the engine's, and is
                    // printed as it wrote it.
                    // Not red: nothing has gone wrong. The engine looked
                    // and said not yet, which is a refusal, and a refusal is
                    // in the ordinary colour (§2.7). The symbol and the words
                    // carry it.
                    Text(Strings.Queue.cannotRun)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !item.whyNot.isEmpty {
                        Text(item.whyNot)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // To the top in one click, under the pointer. There whether or
            // not it shows, so a row never shifts when the pointer arrives.
            Button { doNext?() } label: {
                Image(systemName: "arrow.up.to.line")
                    .imageScale(.small)
                    .frame(width: Tokens.Metric.minimumHitTarget,
                           height: Tokens.Metric.minimumHitTarget - 8)
            }
            .buttonStyle(.borderless)
            .opacity(hovering && doNext != nil ? 1 : 0)
            .disabled(doNext == nil)
            .help(Strings.Queue.doNext)
            .accessibilityHidden(true)
            .accessibilityIdentifier("queue.doNext.\(item.id)")
            Button(action: remove) {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .frame(width: Tokens.Metric.minimumHitTarget,
                           height: Tokens.Metric.minimumHitTarget - 8)
            }
            .buttonStyle(.borderless)
            .help(Strings.Queue.remove)
            .accessibilityLabel("\(Strings.Queue.remove): \(item.what)")
            .accessibilityIdentifier("queue.remove.\(item.id)")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if let doNext { Button(Strings.Queue.doNext, action: doNext) }
            if let moveUp { Button(Strings.Queue.moveUp, action: moveUp) }
            if let moveDown { Button(Strings.Queue.moveDown, action: moveDown) }
            Divider()
            Button(Strings.Queue.remove, action: remove)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
        // A drag is not the only way to reorder: a picked row moves with
        // ⌥⌘↑ and ⌥⌘↓ (QueueList), and VoiceOver offers the same moves -
        // only the ones that can do something, so the first row offers no
        // Move Up.
        .accessibilityActions {
            if let doNext { Button(Strings.Queue.doNext, action: doNext) }
            if let moveUp { Button(Strings.Queue.moveUp, action: moveUp) }
            if let moveDown { Button(Strings.Queue.moveDown, action: moveDown) }
            Button(Strings.Queue.remove, action: remove)
        }
    }

    private var spoken: String {
        var parts = [Strings.Queue.position(place, of: of), item.what]
        if !item.shoot.isEmpty { parts.append(item.shoot) }
        if item.ready {
            if !item.does.isEmpty { parts.append(item.does) }
            if item.interrupted { parts.append(Strings.Queue.interruptedNote) }
        } else {
            parts.append(Strings.Queue.cannotRun)
            if !item.whyNot.isEmpty { parts.append(item.whyNot) }
        }
        return parts.joined(separator: ". ")
    }
}
