import SwiftUI

/// The host of the read-only review: the photographs a held learner would
/// cost him, side by side, with what happens to each one in words.
///
/// The grid belongs to the light table (`Navigation.viewerMode = .review`),
/// and this host hands it the mode and gets out of the way. Until that view
/// is registered it draws the same thing itself, from the same frames, so the
/// promise the learning screen makes — *every per-frame decision visible* —
/// is kept by the app as it stands and not only by the app as it will be.
///
/// Two things are true here and nowhere else:
///
/// - **Keep and Drop are off.** A line says so. A verdict is only ever taken
///   on a frame he is deciding about, and he is not deciding here.
/// - **"Use It Anyway" exists**, and it exists only here, because the one
///   override is made with the frames in front of him.
public struct ReviewModeHost: View {
    let learner: Learner
    let model: LearnedModel
    let app: AppModel
    /// Where the pictures come from. The app's own pump by default; a
    /// snapshot or a test hands in its own.
    let pump: ImagePump?
    let close: () -> Void

    @State private var confirming = false
    /// The frame the grid has open large. While one is, Esc is the frame's —
    /// back to the grid — and not Done's.
    @State private var enlarged: LearnerFrame?

    public init(learner: Learner, model: LearnedModel, app: AppModel,
                pump: ImagePump? = nil,
                close: @escaping () -> Void) {
        self.learner = learner
        self.model = model
        self.app = app
        self.pump = pump ?? app.pump
        self.close = close
    }

    private var frames: [LearnerFrame] { learner.check?.frames ?? [] }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            grid
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 640)
        .onAppear { app.navigation.viewerMode = .review(learner) }
        .onDisappear {
            if case .review = app.navigation.viewerMode { app.navigation.viewerMode = .single }
        }
        .accessibilityIdentifier("learning.review")
    }

    // MARK: what he is looking at

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            Text(learner.title).font(.title3)
            Text("\(Strings.Learning.reviewTitle) · \(subtitle)")
                .font(.callout)
                .foregroundStyle(.secondary)
            // A lock, not a pause: nothing here is waiting to resume. The
            // two keys that write a verdict are simply not on this screen.
            Label(Strings.Learning.readOnly, systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Metric.windowMargin)
    }

    private var subtitle: String {
        let shoots = Set(frames.map(\.shoot))
        if let only = shoots.count == 1 ? shoots.first : nil {
            return Strings.Learning.reviewSubtitle(frames.count, only)
        }
        return Strings.Learning.reviewSubtitleMany(frames.count)
    }

    @ViewBuilder private var grid: some View {
        if let registered = StepRegistry.libraryView("learning.review", app) {
            registered
        } else if frames.isEmpty {
            ContentUnavailableView(Strings.Learning.reviewTitle, systemImage: Symbols.learned)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Until the light table registers its review mode, this is the
            // review: grouped by what would change, the frames walkable with
            // the keys and each one openable large.
            ReviewGrid(groups: ReviewGroups(frames), pump: pump, enlarged: $enlarged)
        }
    }

    // MARK: the one override

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.relatedGap) {
            if let m = model.refusals[.learner(learner.id)] {
                RefusalRow(m, owner: .learner(learner.id))
            }
            HStack(spacing: Tokens.Metric.relatedGap) {
                // Nothing is being cancelled: this is a look, and Done ends it.
                Button(Strings.Learning.done, action: close)
                    .keyboardShortcut(enlarged == nil ? .cancelAction : nil)
                Spacer(minLength: Tokens.Metric.destructiveClearance)
                if learner.can_use_anyway {
                    Button(Strings.Learning.useItAnyway) { confirming = true }
                        .accessibilityIdentifier("learning.useItAnyway")
                }
            }
        }
        .padding(Tokens.Metric.windowMargin)
        .confirmationDialog(Strings.Learning.useItAnywayTitle, isPresented: $confirming) {
            // Cancel is the default; the other button is the one that changes
            // something, and it is never the one Return presses.
            Button(Strings.Learning.cancel, role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button(Strings.Learning.useItAnywayConfirm) {
                Task {
                    if await model.useAnyway(learner, sawFrames: true) { close() }
                }
            }
        } message: {
            Text(confirmBody)
        }
    }

    private var confirmBody: String { Self.confirmBody(for: learner) }

    /// What the one override says it would do: the engine's own sentence for
    /// this check, then the app's fixed tail.
    ///
    /// This composed "stop putting forward N" from `hidden` for every
    /// learner, so for the burst-order learner — which hides nothing and
    /// moves 81 of his keepers later — the one override dialog in the app
    /// said "0 photographs" and hid the 81. Where the engine sent no sentence
    /// the number is composed by what the check actually says.
    ///
    /// The tail is the learner's own: "the cull just shows them less" was
    /// appended to the starting edit's sentence about white balance too, and
    /// a preset never shows a keeper less.
    static func confirmBody(for learner: Learner) -> String {
        let tail = Strings.Learning.useItAnywayTail(for: learner)
        guard let c = learner.check else { return tail }
        if !c.sentence.isEmpty { return c.sentence + " " + tail }
        let shoots = Set(c.frames.map(\.shoot))
        let only = shoots.count == 1 ? shoots.first : nil
        if c.hidden > 0 {
            return only.map { Strings.Learning.useItAnywayBody(c.hidden, $0) }
                ?? Strings.Learning.useItAnywayBodyMany(c.hidden)
        }
        return Strings.Learning.useItAnywayMoves(c.moved_down, c.moved_up) + " " + tail
    }
}
