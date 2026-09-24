import SwiftUI

/// The three-rung ladder of §2.8, chosen by what cannot be undone.
///
/// | Rung | What it does | What the sheet is |
/// |---|---|---|
/// | `replacesWork` | Replaces the machine's own work | Names what is kept. Cancel is the default. No red. |
/// | `removesACopy` | Removes a copy, keeps a checked one | The engine's plan verbatim. The button reads the consequence. Red, and **not** the default. |
/// | `deletesPhotographs` | Deletes photographs | All of that, plus the checkbox, the names, the frozen keeper count and the typed number. |
///
/// Nothing on any of them is a count this app worked out.
public enum Rung: Sendable, Hashable {
    case replacesWork
    case removesACopy
    case deletesPhotographs

    /// Only the two lower rungs are red, and neither is ever the default
    /// button: on them Return presses nothing, and Escape cancels.
    var isDestructive: Bool { self != .replacesWork }
}

/// The sheet for the two lower rungs. It shows **the engine's own plan
/// verbatim** in a monospaced list and never parses a line of it.
public struct PlanSheet: View {
    /// `nil` is not on the ladder: the same sheet, the same engine list, and
    /// none of the ladder's weight — because nothing it does takes anything
    /// away. Copying up and bringing back are planned like everything else.
    let rung: Rung?
    let request: StorageModel.Request
    let model: StorageModel
    /// A fresh list is drawn every time this opens, so a spent one can never
    /// be the thing on screen.
    let close: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    @State private var typed = ""
    @State private var includeOnlyCopies = false
    @FocusState private var typingFocused: Bool

    public init(rung: Rung?, request: StorageModel.Request, model: StorageModel,
                includeOnlyCopies: Bool = false,
                close: @escaping () -> Void) {
        self.rung = rung
        self.request = request
        self.model = model
        self.close = close
        _includeOnlyCopies = State(initialValue: includeOnlyCopies)
    }

    /// What is on screen, and what the options currently say. They are only
    /// ever read together.
    private var current: StorageModel.Request {
        rung == .deletesPhotographs
            ? StorageModel.Request(request.what,
                                   PlanOptions(keepers: request.options.keepers,
                                               originals: includeOnlyCopies ? true : nil,
                                               after: request.options.after))
            : request
    }

    private var plan: Plan? { model.hasPlan(for: current) ? model.plan : nil }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.groupGap) {
            title
            if model.wasRedrawn {
                Label(Strings.Storage.redrawn, systemImage: Symbols.refusal)
                    .font(.callout)
                    .foregroundStyle(Tokens.Palette.fault)
            }
            // The job in the way, when there is one: which job, how far
            // along, how long is left, and the two things he can do. This is
            // the exact place that used to say "a job is already running" and
            // stop there.
            if let b = model.busy[.storage], let m = model.refusals[.storage] {
                BusyNotice(sentence: m, busy: b, waiting: model.waitingID != nil,
                           wait: { Task { await model.waitForTurn(current) } },
                           stopTheOther: { Task { await model.stopTheJobInTheWay() } },
                           dontWait: { Task { await model.dontWait() } })
            } else if let m = model.refusals[.storage] {
                RefusalRow(m, owner: .storage)
            }
            if let paused = model.paused {
                PausedNote(paused)
            }
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            buttons
        }
        .padding(Tokens.Metric.windowMargin)
        // A short list gets a short sheet. The height is the plan's, not a
        // number chosen once for the longest one there could be.
        .frame(minWidth: 560, idealWidth: 620, minHeight: 300, idealHeight: 520)
        .task(id: current) { await model.draw(current) }
        .accessibilityIdentifier("storage.plan.\(request.what)")
    }

    // MARK: what it says

    @ViewBuilder private var title: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            Text(headline).font(.title3)
            if rung == .deletesPhotographs {
                Text(Strings.Storage.letGoBody)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headline: String {
        guard rung == .deletesPhotographs else { return Strings.Storage.planTitle(for: request.what) }
        // The number in the title is the list's own, and it is the number he
        // has to type. Before a list exists the sheet says what it is doing
        // rather than a count nobody drew.
        guard let p = plan, p.doomed > 0 else { return Strings.Storage.planTitle(for: request.what) }
        return Strings.Storage.letGoTitle(p.doomed)
    }

    @ViewBuilder private var content: some View {
        if model.busy[.storage] != nil {
            // Nothing is being worked out: a job of his is in the way and the
            // notice above says which. A spinner saying "Working out what
            // would go…" under a message saying it has not started is the
            // screen telling him two different things at once.
            EmptyView()
        } else if model.isDrawing || plan == nil {
            HStack(spacing: Tokens.Metric.relatedGap) {
                ProgressView().controlSize(.small)
                Text(Strings.Storage.drawing).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Tokens.Metric.groupGap)
        } else if let p = plan {
            VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
                if rung == .deletesPhotographs {
                    gate(p)
                }
                if !p.why.isEmpty {
                    Text(p.why).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                PlanLines(plan: p)
                if !p.refusals.isEmpty {
                    refusals(p)
                }
                // The number is typed after the names have been read, just
                // above the button it opens — not before the list, where he
                // was asked for a count of photographs he had not seen yet.
                if rung == .deletesPhotographs {
                    typeTheNumber(p)
                }
            }
        }
    }

    /// The one rung that deletes photographs: a separate, unticked checkbox,
    /// and the keepers-protected count **frozen at the value this list was
    /// drawn against**. The field that has to match is under the list.
    ///
    /// Ticking the checkbox draws the list again, and the button is off until
    /// the new one lands — the fixed bug was a protected count that silently
    /// dropped to zero while the label still claimed it.
    @ViewBuilder private func gate(_ p: Plan) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
            Toggle(Strings.Storage.includeOnlyCopies, isOn: $includeOnlyCopies)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("storage.includeOnlyCopies")
            if p.protectedKeepers > 0 {
                Label(Strings.Storage.protectedKeepers(p.protectedKeepers), systemImage: Symbols.hisKeep)
                    .font(.callout)
                    .foregroundStyle(Tokens.Palette.kept)
            }
        }
    }

    /// The field that has to match the list's own count. Return in it presses
    /// nothing: there is no default button on this rung, so the typed number
    /// can neither delete anything nor close the sheet and throw itself away.
    @ViewBuilder private func typeTheNumber(_ p: Plan) -> some View {
        if p.doomed > 0 {
            LabeledContent(Strings.Storage.typeToConfirm(p.doomed)) {
                TextField("", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .focused($typingFocused)
                    .monospacedDigit()
                    .accessibilityLabel(Strings.Storage.typeToConfirm(p.doomed))
                    .accessibilityIdentifier("storage.typed")
            }
            .padding(.top, Tokens.Metric.relatedGap)
        }
    }

    private func refusals(_ p: Plan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Strings.Storage.refusedHeading).font(.subheadline).foregroundStyle(.secondary)
            ForEach(Array(p.refusals.enumerated()), id: \.offset) { _, line in
                Text(line).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: the two buttons

    private var buttons: some View {
        HStack(spacing: Tokens.Metric.relatedGap) {
            // Escape cancels, on every sheet. Return never deletes anything
            // in this app: on the two rungs that take something away it
            // presses nothing at all, so a number typed in the field above is
            // not thrown away with the sheet by the key that ends typing.
            Button(Strings.Storage.cancel, action: close)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: Tokens.Metric.destructiveClearance)
            if model.applying {
                ProgressView().controlSize(.small)
            }
            Button(role: isDestructive ? .destructive : nil) {
                Task {
                    if await model.apply(current, typed: typed.isEmpty ? nil : typed) { close() }
                }
            } label: {
                // The red is written on the label, not left to the role and
                // the tint. Both of those are drawn by AppKit's *emphasised*
                // colours, which a window that is not key does not get — so
                // on a background window, and in every snapshot this project
                // takes, the one button that destroys something looked
                // exactly like Cancel. The role and the tint stay, for the
                // system's own treatment where it applies; the colour is
                // stated as well so it is there whatever the window is doing.
                // …and a button that is off still has to look off: stating
                // the colour takes the system's dimming off the label, so the
                // label dims itself.
                if let red = confirmColour {
                    Text(confirmLabel).foregroundStyle(red)
                } else {
                    Text(confirmLabel)
                }
            }
            .tint(isDestructive ? Tokens.Palette.alarm : nil)
            // Copying up and bringing back take nothing away (rung == nil),
            // so there Return is the button he came for, not a trip to the
            // mouse. Off the ladder only.
            .keyboardShortcut(rung == nil ? .defaultAction : nil)
            .disabled(!canConfirm)
            .accessibilityIdentifier("storage.confirm")
        }
    }

    /// The button reads the consequence, in the engine's own words, because
    /// the engine is what printed the number on it.
    private var confirmLabel: String {
        // A job of his is in the way, so no list has been drawn. "There is
        // nothing in this list to do" would be a verdict on a list nobody
        // has read.
        model.busy[.storage] != nil ? Strings.Storage.nothingDrawnYet : gate.confirmLabel
    }

    private var isDestructive: Bool { rung?.isDestructive ?? false }

    /// The red the destructive rungs are drawn in, dimmed while the button is
    /// off — and dimmed less where he has asked for more contrast. `nil`
    /// where there is nothing to warn about: a button whose label says the
    /// list is empty is not a red button.
    private var confirmColour: Color? {
        guard isDestructive, gate.isAnAction else { return nil }
        return Tokens.Palette.alarm.opacity(canConfirm ? 1 : (contrast == .increased ? 0.6 : 0.35))
    }

    /// The rule lives in `ExpireGate`, which is a value and is tested on its
    /// own. On the rungs above it the typed count is not asked for, so an
    /// empty field passes.
    private var gate: ExpireGate {
        ExpireGate(plan: plan,
                   listIsCurrent: model.hasPlan(for: current),
                   typed: rung == .deletesPhotographs ? typed : String(plan?.doomed ?? 0),
                   busy: model.applying)
    }

    private var canConfirm: Bool { gate.isOpen }
}

/// The command's own output, as it printed it. A monospaced list,
/// selectable, never re-wrapped, never re-ordered and never summarised — and
/// the doomed names are in it, because the command prints them itself. This
/// listed them a second time above, which read as twice as many photographs.
///
/// It hugs what the command printed. The sheet around it is what scrolls, so
/// a three-line plan is a three-line box rather than a screen still loading.
struct PlanLines: View {
    let plan: Plan

    var body: some View {
        // The engine has already left out the command's closing words to a
        // typist ("… Add --apply") and said the rest in the app's words
        // (`plan_words` in studio.py): there is no --apply for him to add in
        // an app with a button.
        let lines = plan.lines
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
        .padding(Tokens.Metric.relatedGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel(lines.joined(separator: ". "))
        .accessibilityIdentifier("storage.planLines")
    }
}

/// Rung one: replaces the machine's own work. It names what is kept, Cancel
/// is the default, and there is no red anywhere on it.
///
/// Public because the steps that own those actions — Cull Again, Write the
/// Presets Again — are other crews', and this is the sheet they use so the
/// ladder has one shape everywhere.
public struct ReplacesWorkSheet: View {
    public let title: String
    public let confirmLabel: String
    public let note: String?
    public let confirm: () -> Void
    public let close: () -> Void

    public init(title: String, confirmLabel: String, note: String? = nil,
                confirm: @escaping () -> Void, close: @escaping () -> Void) {
        self.title = title
        self.confirmLabel = confirmLabel
        self.note = note
        self.confirm = confirm
        self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.groupGap) {
            Text(title).font(.title3)
            Text(Strings.Storage.keepsYourMarks)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: Tokens.Metric.relatedGap) {
                Button(Strings.Storage.cancel, action: close)
                    .keyboardShortcut(.defaultAction)
                Spacer(minLength: Tokens.Metric.destructiveClearance)
                Button(confirmLabel) { confirm(); close() }
                    .accessibilityIdentifier("storage.replacesWork.confirm")
            }
        }
        .padding(Tokens.Metric.windowMargin)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 200)
        .accessibilityIdentifier("storage.replacesWork")
    }
}
