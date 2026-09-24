import SwiftUI

/// Reels (DESIGN.md §2.6).
///
/// Three regions: the bursts, the burst he chose (the last reel playing beside
/// its frames), and what the reel will be. The step's primary sits where every
/// step's does, in the action bar at the bottom right, and a running cut shows
/// its progress in the same box (§2.7).
///
/// The one thing this page exists to put right: on the page it replaces, any
/// click on a frame both decided and was the only thing a click could do
/// (FLOW-01). Here a single click ticks the frame in or out of the reel, and a
/// double-click, Space or a firm click opens it large.
public struct ReelsStep: StepView {
    @Bindable var model: ReelsModel
    let session: ShootSession
    let thumbs: ReelThumbs
    @State private var showAbout = false
    /// Which of the page's two keyboard places has the keys. Return is the
    /// burst field's while it has them, and Cut It's everywhere else.
    @FocusState private var focus: ReelsFocus?
    /// The window's, for putting the sidebar away in a narrow window, with
    /// the one memory of it the light table shares (§2.1). Absent outside
    /// the window — a test that draws the page alone.
    @Environment(Navigation.self) private var navigation: Navigation?

    public init(session: ShootSession, client: StudioClient, pump: ImagePump) {
        self.session = session
        let m = ReelsModelStore.shared.model(for: session, jobs: StepJobs.model(client: client))
        _model = Bindable(wrappedValue: m)
        thumbs = ReelThumbs.store(for: session.client)
    }

    /// Below this width of the page the inspector folds under the frames
    /// rather than squeezing them to one column.
    static func sideBySide(_ width: CGFloat) -> Bool {
        width >= ReelsMetric.list + ReelsMetric.inspector + ReelsMetric.centreMinimum
    }

    private var runner: StepJobRunner { model.reelJob }

    public var body: some View {
        GeometryReader { geo in
            let wide = Self.sideBySide(geo.size.width)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ReelsBurstList(model: model, thumbs: thumbs, focus: $focus)
                        .frame(width: ReelsMetric.list)
                    Divider()
                    ReelsCentre(model: model, thumbs: thumbs, inspectorBelow: !wide, focus: $focus)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if wide {
                        Divider()
                        ScrollView {
                            ReelsInspector(model: model, showAbout: $showAbout)
                                .padding(Tokens.Metric.groupGap)
                        }
                        .frame(width: ReelsMetric.inspector)
                        .scrollBounceBehavior(.basedOnSize)
                    }
                }
                StepActionBar {
                    leading
                } box: {
                    JobInPlace(phase: runner.phase, stop: { runner.stop() },
                               cancelQueue: { runner.cancelQueued() }) {
                        StepPrimary(model.primaryWord, wouldWait: model.wouldWait,
                                    disabled: !model.canPressPrimary, returnKey: focus != .search) {
                            model.primary()
                        } addToTheList: {
                            model.addToTheList()
                        }
                    }
                }
                .environment(\.stepColumnWidth, max(240, geo.size.width - 2 * Tokens.Metric.windowMargin))
            }
            // Below 1280 pt of window the sidebar goes while Reels is up and
            // comes back on leaving for a page that does not do the same, as
            // on the light table: at 900 the list, the sidebar and the player
            // left the frames two columns wide and below the fold. ⌃⌘S
            // overrides and sticks for that width.
            .putsTheSidebarAway(navigation, in: geo)
        }
        // The page's keys, from anywhere in the window, as on Choose
        // Keepers and Instagram (`ReelsKeys.route`); ↑ and ↓ stay the list's
        // while it has the keyboard.
        .background(
            ReelsKeySink(model: model, framesHaveKeys: focus == .grid) { focus = .grid }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Strings.Reels.title))
        // No copy of Cut It in the toolbar: a page's main button is at its
        // bottom right, once (§2.3). Shoot ▸ Cut a Reel is answered below.
        .sheet(item: $model.look) { look in
            ExtViewer.make(session: session, stems: look.stems, startAt: look.start,
                           source: .reel(thumbs: thumbs, src: model.source.isEmpty ? nil : model.source,
                                         exported: Set(model.frames.filter(\.exported).map(\.stem))),
                           marking: model.lookMarking) { result in
                model.lookEnded(result)
            }
        }
        // Shoot ▸ Cut a Reel is Cut It, pressed from the menu while this
        // page is showing (DESIGN.md §2.12), with ⌥ adding it to Up Next as
        // on the button. This is its one owner on Reels: `ReelsCommands`
        // answers Find Burst, Undo, Redo and the Frame rows, not this one.
        .answersMenu([CommandTable.ID.cutAReel], shoot: session.name) { _, option in
            guard model.canCut else { return }
            if StepPrimaryWords.adds(wouldWait: model.wouldWait, optionHeld: option) {
                model.addToTheList()
            } else if runner.phase == .idle {
                model.cut()
            }
        }
        // The frames have the keyboard when he arrives, so ↑ and ↓ are a row
        // of them at once; every other key of the page works wherever the
        // keyboard is (`ReelsKeySink`). Nothing hands it to them when a
        // burst's frames come in: the list has no place in `focus`, so
        // "nothing has it" was the list walked with the arrows, and each
        // burst's frames took the keys from it as they came. A click in the
        // list and Return or Escape in the burst field move the keys
        // themselves, a key that acts on a frame moves them too, and ⌘F puts
        // them in the field (`ReelsBurstList`).
        .defaultFocus($focus, .grid)
        .task { model.appeared() }
        .onAppear {
            ReelsCommands.attach(model)
            DispatchQueue.main.async {
                if focus == nil { focus = .grid }
                // Again, once the page it replaces has gone: the light
                // table's detach takes its Frame rows away whatever answers
                // them now (`ReelsCommands`).
                ReelsCommands.attach(model)
            }
        }
        .onDisappear {
            ReelsCommands.detach(model)
            model.stopObserving()
        }
    }

    @ViewBuilder private var leading: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            // The engine's sentence, as it wrote it, where he pressed.
            if let m = model.jobs.refusals[.job] { RefusalRow(m, owner: .job) }
            if let m = model.queue.refusals[.job] { RefusalRow(m, owner: .job) }
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
            } else if let why = model.whyNot {
                Text(why).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// The menu rows the Reels page answers while it is on screen, with its own
/// meanings: Edit ▸ Find Burst…, Edit ▸ Undo and Redo, and the Frame and
/// View rows Choose Keepers answers for the same keys — Frame ▸ Keep reads
/// "Include 06264" here, Drop "Leave Out 06264", and Clear the Mark, Next
/// and Previous Frame, Next and Previous Burst and View ▸ Full Image act on
/// the frames (DESIGN.md §2.6, §2.12). Shoot ▸ Cut a Reel is not here: the
/// page's `.answersMenu` owns it, which honours ⌥ as the button does, and a
/// second owner here pressed Cut It with ⌥ held.
///
/// The command centre keeps one action a row, and Find Burst, Undo and Redo
/// can each have an owner of their own — the light table's ⌘F, the app's
/// Undo. Registering over it replaced that owner for good, so his first
/// visit to Reels would have greyed ⌘F on Choose Keepers until he
/// relaunched. The page's action goes in front of the one it found, asks
/// that one whenever no Reels page is attached, and puts it back when the
/// page goes. The Frame and View rows are the light table's, which registers
/// them afresh whenever it comes on screen, so here they simply grey when no
/// page is attached — the `InstagramCommands` pattern.
///
/// A page that comes on screen can attach before the one it replaces has
/// gone: the newer is attached, and the older's detach does nothing. And the
/// light table's detach unregisters its rows whatever answers them now, and
/// can arrive after this page's appear, so the page attaches once more on
/// the next turn of the main queue.
@MainActor
enum ReelsCommands {
    typealias ID = CommandTable.ID

    private static weak var attached: ReelsModel?
    /// The centre the page's actions are in, and what answered each row there
    /// before them.
    private static var installed: (center: CommandCenter, found: [CommandID: CommandAction])?
    /// The rows that go back to the owner they had when the page goes.
    private static let handedBack = [ID.findBurst, ID.undo, ID.redo]

    /// Choose Keepers' rows, and what each means on this page.
    static let frameRows: [(CommandID, ReelsMeaning)] = [
        (ID.keep, .include), (ID.drop, .leaveOut), (ID.clearMark, .clear),
        (ID.nextFrame, .next), (ID.previousFrame, .previous),
        (ID.finishBurst, .nextBurst), (ID.previousBurst, .previousBurst),
        (ID.fullImage, .open),
    ]

    static func attach(_ model: ReelsModel, center: CommandCenter = .shared) {
        attached = model
        if installed?.center !== center {
            uninstall()
            var found: [CommandID: CommandAction] = [:]
            for id in handedBack { found[id] = center.action(id) }
            installed = (center, found)
        }
        let found = installed?.found ?? [:]
        answer(ID.findBurst, in: center, found: found[ID.findBurst],
               isEnabled: { $0.format.isBurst }, run: { $0.find() })
        answer(ID.undo, in: center, found: found[ID.undo], isEnabled: { $0.canPerform(.undo) },
               title: { $0.rowTitle(.undo) }, run: { $0.perform(.undo) })
        answer(ID.redo, in: center, found: found[ID.redo], isEnabled: { $0.canPerform(.redo) },
               title: { $0.rowTitle(.redo) }, run: { $0.perform(.redo) })
        for (id, meaning) in frameRows {
            answer(id, in: center, found: nil, isEnabled: { $0.canPerform(meaning) },
                   title: { $0.rowTitle(meaning) }, help: { _ in ReelsModel.rowHelp(meaning) },
                   run: { $0.perform(meaning) })
        }
    }

    static func detach(_ model: ReelsModel) {
        guard attached === model else { return }
        attached = nil
        uninstall()
    }

    /// The page's answer while one is attached, and the owner it found
    /// otherwise.
    private static func answer(_ id: CommandID, in center: CommandCenter, found: CommandAction?,
                               isEnabled: @escaping (ReelsModel) -> Bool,
                               title: @escaping (ReelsModel) -> String? = { _ in nil },
                               help: @escaping (ReelsModel) -> String? = { _ in nil },
                               run: @escaping (ReelsModel) -> Void) {
        center.register(id, isEnabled: {
            guard let m = attached else { return found?.isEnabled() ?? false }
            return isEnabled(m)
        }, state: {
            attached == nil ? found?.state() : nil
        }, title: {
            guard let m = attached else { return found?.title() }
            return title(m)
        }, help: {
            guard let m = attached else { return found?.help() }
            return help(m)
        }) {
            guard let m = attached else { found?.run(); return }
            run(m)
        }
    }

    /// The owners it found go back; a row nobody answered is taken out.
    private static func uninstall() {
        guard let (center, found) = installed else { return }
        installed = nil
        for id in handedBack {
            if let a = found[id] { center.register(id, a) } else { center.unregister(id) }
        }
    }
}

/// The numbers the page is laid out on.
public enum ReelsMetric {
    /// The bursts list (§2.6).
    public static let list: CGFloat = 220
    /// Within the shell inspector's own range (240–360), and the narrower end
    /// of it, so the page keeps three regions in the default window.
    public static let inspector: CGFloat = 260
    /// The least the middle may have before the inspector folds under it:
    /// the player and the summary beside it with their buttons whole. At 360
    /// the sidebarless 900 pt window kept three regions and cut both.
    public static let centreMinimum: CGFloat = 480
    /// The player's height when the page is wide; its width is 9:16 of it.
    public static let player: CGFloat = 300
    public static let playerNarrow: CGFloat = 200
    /// A frame tile's least width.
    public static let tile: CGFloat = 132
}

extension ReelsModel {
    /// Why Cut It is not pressable, when it is not — said beside it rather
    /// than left to be guessed from a grey button.
    public var whyNot: String? {
        guard options != nil, loadError == nil else { return nil }
        if waitingHere { return Strings.Reels.cutNowNote }
        if format == .timelapse {
            return timelapseFrames < ReelWait.least ? Strings.Reels.nothingTagged : nil
        }
        guard burst != nil, framesBurst == burst, !frames.isEmpty else { return nil }
        return chosen.count < ReelWait.least ? Strings.Reels.needThree : nil
    }
}
