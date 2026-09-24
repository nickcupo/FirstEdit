import SwiftUI

/// Instagram (DESIGN.md §2.17): the shoot's exported photographs, each with
/// the cut its copy will have drawn on it.
///
/// What it puts right, in his words about the page it replaces: the cut lines
/// did not show until he opened a photograph and pressed Escape; there were
/// "2 of the same lists of images one wiht cut lines one without"; and he
/// asked "Why not just render all the potential cut lines, let me select and
/// adjust what i want to save?" So there is one wall, every cut is drawn on
/// it as soon as it is worked out — which starts the moment the step opens —
/// a tick chooses what is made, and a click opens the editor. The keys are
/// Choose Keepers' own (`InstagramKeys`).
public struct InstagramStep: StepView {
    @Bindable var model: InstagramModel
    let session: ShootSession
    let pictures: InstagramPictures

    public init(session: ShootSession, client: StudioClient, pump: ImagePump) {
        self.session = session
        let m = InstagramModelStore.shared.model(for: session, jobs: StepJobs.model(client: client))
        _model = Bindable(wrappedValue: m)
        pictures = InstagramPictures.store(for: session.client)
    }

    private var runner: StepJobRunner { model.makeJob }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(spacing: 0) {
                    InstagramHeader(model: model)
                        .padding(.horizontal, Tokens.Metric.groupGap)
                        .padding(.vertical, 10)
                    Divider()
                    InstagramWall(model: model, pictures: pictures)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    StepActionBar {
                        leading
                    } box: {
                        JobInPlace(phase: runner.phase, stop: { runner.stop() },
                                   cancelQueue: { runner.cancelQueued() }) {
                            StepPrimary(model.makeWord, wouldWait: model.wouldWait,
                                        disabled: model.makeSet.isEmpty, returnKey: model.editor == nil) {
                                model.make()
                            } addToTheList: {
                                model.addToTheList()
                            }
                        }
                    }
                    .environment(\.stepColumnWidth, max(240, geo.size.width - 2 * Tokens.Metric.windowMargin))
                }
                if model.editor != nil {
                    InstagramEditor(model: model, pictures: pictures)
                        .transition(.opacity)
                }
                InstagramKeySink(model: model)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Strings.Instagram.title))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                StepPrimaryToolbarButton(model.makeWord, wouldWait: model.wouldWait,
                                         disabled: model.makeSet.isEmpty,
                                         busy: runner.phase != .idle) {
                    model.make()
                } addToTheList: {
                    model.addToTheList()
                }
            }
        }
        .task { model.appeared() }
        .onAppear {
            InstagramCommands.attach(model)
            // Once more on the next turn: coming straight from Choose
            // Keepers, its detach can run after this appear and take the
            // rows away (`InstagramCommands.attach`).
            DispatchQueue.main.async { InstagramCommands.attach(model) }
        }
        .onDisappear {
            InstagramCommands.detach(model)
            model.disappeared()
        }
    }

    @ViewBuilder private var leading: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            if let m = model.jobs.refusals[.job] { RefusalRow(m, owner: .job) }
            if let m = model.queue.refusals[.job] { RefusalRow(m, owner: .job) }
            if let n = model.note { RefusalRow(n, owner: .job) }
            if let added = model.added {
                Text(added).font(.callout).foregroundStyle(.secondary)
            }
            if runner.isQueued, let other = runner.other {
                Text(Strings.Step.waitingFor(Strings.Queue.named(other))).font(.callout).foregroundStyle(.secondary)
            }
            if let j = runner.mine {
                JobTiming(j)
            } else if let ended = JobEndedNote(runner.lastEnded) {
                ended
            } else if let line = model.makeLine {
                Text(line).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.status?.folder_exists == true {
                Button(Strings.Instagram.showTheFolder) { model.showFolder() }
                    .buttonStyle(.link)
                    .font(.callout)
                    .help(Strings.Instagram.showTheFolderHelp)
            }
        }
    }
}

// MARK: - the header

/// The two shapes, the numbers, and what working out the cuts is doing —
/// in two lines at most.
struct InstagramHeader: View {
    @Bindable var model: InstagramModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Metric.groupGap) {
                    pickers
                    Spacer(minLength: Tokens.Metric.relatedGap)
                    counts
                }
                HStack(spacing: Tokens.Metric.groupGap) {
                    pickers
                    Spacer(minLength: 0)
                }
            }
            // Narrower, the warning says it shorter, and then the pass's
            // words go to the bar's help tag: two lines, whatever the width.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.groupGap) {
                    warning(short: false).fixedSize()
                    Spacer(minLength: 0)
                    planLine(compact: false).fixedSize()
                }
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.groupGap) {
                    warning(short: true).fixedSize()
                    Spacer(minLength: 0)
                    planLine(compact: false).fixedSize()
                }
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.groupGap) {
                    warning(short: true)
                    Spacer(minLength: 0)
                    planLine(compact: true)
                }
            }
            .frame(minHeight: 18)
        }
    }

    private var pickers: some View {
        HStack(spacing: Tokens.Metric.groupGap) {
            HStack(spacing: 6) {
                Text(Strings.Instagram.portraits).font(.callout).foregroundStyle(.secondary)
                Picker(Strings.Instagram.portraits, selection: Binding(get: { model.ratio },
                                                                       set: { model.choose(ratio: $0) })) {
                    ForEach(model.status?.ratios ?? ["3:4", "4:5"], id: \.self) { r in
                        Text(r).tag(r).help(Strings.Instagram.ratioHelp(r))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help(Strings.Instagram.ratioHelp(model.ratio))
            }
            HStack(spacing: 6) {
                Text(Strings.Instagram.landscapes).font(.callout).foregroundStyle(.secondary)
                Picker(Strings.Instagram.landscapes, selection: Binding(get: { model.landscape },
                                                                        set: { model.choose(landscape: $0) })) {
                    Text(Strings.Instagram.whole).tag("fit").help(Strings.Instagram.wholeHelp)
                    Text(Strings.Instagram.cut).tag("crop").help(Strings.Instagram.cutHelp)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help(model.landscape == "crop" ? Strings.Instagram.cutHelp : Strings.Instagram.wholeHelp)
            }
        }
        .disabled(model.status == nil || model.frames.isEmpty)
        .fixedSize()
    }

    private var counts: some View {
        Text(Strings.Instagram.counts(exported: model.exportedCount, planned: model.plannedCount,
                                      made: model.madeCount))
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder private func warning(short: Bool) -> some View {
        if let r = model.shapeRefusal {
            RefusalRow(r, owner: .job)
        } else if let e = model.loadError {
            RefusalRow(e, owner: .job)
        } else if model.gridMisses > 0 {
            Label {
                Text(short ? Strings.Instagram.gridMissesShort(model.gridMisses)
                           : Strings.Instagram.gridMisses(model.gridMisses))
                    .lineLimit(1).truncationMode(.tail)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.Palette.fault)
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
            .help(Strings.Instagram.gridMisses(model.gridMisses))
        } else {
            counts.opacity(0).accessibilityHidden(true).frame(width: 0)
        }
    }

    @ViewBuilder private func planLine(compact: Bool) -> some View {
        switch model.plan {
        case .running(let label, let fraction):
            HStack(spacing: Tokens.Metric.relatedGap) {
                if !compact {
                    Text(label).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                ProgressView(value: min(1, max(0, fraction)))
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                    .help(label)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(Strings.Instagram.percent(fraction)))
        case .waiting(let what):
            Text(Strings.Instagram.waitingFor(what)).font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        case .stopped:
            HStack(spacing: Tokens.Metric.relatedGap) {
                Text(Strings.Instagram.stopped).font(.callout).foregroundStyle(.secondary)
                Button(Strings.Instagram.workOutTheRest) { model.askAgain() }.controlSize(.small)
            }
        case .failed(let line):
            HStack(spacing: Tokens.Metric.relatedGap) {
                Text(Strings.Instagram.failed(line)).font(.callout).foregroundStyle(Tokens.Palette.alarm)
                    .lineLimit(1).truncationMode(.tail)
                Button(Strings.Instagram.tryAgain) { model.askAgain() }.controlSize(.small)
            }
        case .none, .wanted:
            EmptyView()
        }
    }
}

// MARK: - the wall

/// Every exported photograph, one tile each, in the wall's order.
struct InstagramWall: View {
    @Bindable var model: InstagramModel
    let pictures: InstagramPictures
    @FocusState private var focused: String?

    static let tile: CGFloat = 150
    static let gap: CGFloat = Tokens.Metric.relatedGap

    /// How many tiles a row holds, the way `.adaptive` lays them out.
    static func columns(in width: CGFloat) -> Int {
        max(1, Int((width + gap) / (tile + gap)))
    }

    var body: some View {
        Group {
            if let status = model.status, status.frames.isEmpty {
                ContentUnavailableView {
                    Label(Strings.Steps.instagram, systemImage: Symbols.stepInstagram)
                } description: {
                    Text(Strings.Instagram.nothingExported(model.editorName))
                }
            } else if model.status == nil {
                if let e = model.loadError {
                    ContentUnavailableView(e, systemImage: Symbols.refusal)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tile), spacing: Self.gap)],
                                      spacing: Tokens.Metric.groupGap) {
                                ForEach(model.wall) { f in
                                    InstagramTile(frame: f, model: model, pictures: pictures, focus: $focused)
                                        .id(f.stem)
                                }
                            }
                            .padding(Tokens.Metric.groupGap)
                        }
                        .onChange(of: model.revealRequests) { _, _ in
                            guard let r = model.ring else { return }
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(r) }
                        }
                    }
                    .onAppear { model.columns = Self.columns(in: geo.size.width - 2 * Tokens.Metric.groupGap) }
                    .onChange(of: geo.size.width) { _, w in
                        model.columns = Self.columns(in: w - 2 * Tokens.Metric.groupGap)
                    }
                }
            }
        }
        .onChange(of: focused) { _, s in
            model.keyFocus = s
            if let s { model.ring = s }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Strings.Instagram.wallLabel))
    }
}
