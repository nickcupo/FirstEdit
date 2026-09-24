import Foundation
import Observation

/// What the sidebar has selected.
public enum SidebarSelection: Hashable, Sendable {
    case allShoots
    case learned
    case storage
    case card(String)
    case shoot(String)
    case step(shoot: String, step: String)

    public var shoot: String? {
        switch self {
        case .shoot(let s), .step(let s, _): return s
        default: return nil
        }
    }
}

/// The light table's modes. Compare is a mode of the viewer, not a sheet.
public enum ViewerMode: Equatable, Sendable {
    case single
    case compare
    case allBursts
    /// The learning screen's read-only review: the affected keepers side by
    /// side. K and D are disabled with a line saying why.
    case review(Learner)
}

/// Selection, step, viewer mode and the inspector. One per window.
@MainActor @Observable
public final class Navigation {
    public var selection: SidebarSelection? {
        didSet {
            if let s = selection?.shoot { expandedShoot = s }
            // The step follows the selection and nothing else. It used to be
            // left behind on a move to a shoot's own page or a library page,
            // so the overview of the next shoot was titled "Choose Keepers ·
            // 3 of 19 bursts", showed the light table's inspector, ticked
            // Go ▸ Choose Keepers, and ⌘] went to the step after it.
            if case .step(_, let step) = selection { self.step = step } else { self.step = nil }
            noteThePlace()
            if let shoot = selection?.shoot, oldValue != selection { onPlace?(shoot, step) }
        }
    }
    public var step: String?

    /// Per shoot, the step he was last on in it, so a click on the shoot
    /// goes back there (DESIGN.md §2.1, "Clicking a shoot"). For this run;
    /// `ShootSteps` keeps it across launches.
    public private(set) var lastStepIn: [String: String] = [:]
    /// The shoot he was last in, on a step or its own page: where ⌘J goes
    /// back to from a library page.
    public private(set) var lastShoot: String?

    private func noteThePlace() {
        if case .step(let shoot, let step) = selection { lastStepIn[shoot] = step }
        if let shoot = selection?.shoot { lastShoot = shoot }
    }

    /// What an earlier launch remembered. What he has done in this one
    /// wins: a click made while the engine was starting is his.
    public func recall(_ steps: [String: String], lastShoot shoot: String?) {
        for (name, step) in steps where lastStepIn[name] == nil { lastStepIn[name] = step }
        if lastShoot == nil { lastShoot = shoot }
    }

    /// Where arriving at a shoot from outside it goes: the step he was last
    /// on in it; one he has not been on in, the step it is up to (`next`, the
    /// engine's first step not done that can be started); with neither, the
    /// shoot's own page. A remembered step the shoot no longer has — an
    /// extension's step whose extension is gone — counts as none.
    public func place(in shoot: String, has steps: [StepState], next: String?) -> SidebarSelection {
        if let step = lastStepIn[shoot], steps.contains(where: { $0.id == step }) {
            return .step(shoot: shoot, step: step)
        }
        if let next, steps.contains(where: { $0.id == next }) { return .step(shoot: shoot, step: next) }
        return .shoot(shoot)
    }
    /// Told every time he arrives at a shoot or one of its steps, so the app
    /// can open there next time (`LastPlace`). Unset in the harness and the
    /// smoke run, which must never move his.
    public var onPlace: (@MainActor (_ shoot: String, _ step: String?) -> Void)?
    public var viewerMode: ViewerMode = .single
    public var inspectorShown = false
    /// Set the first time he moves the inspector himself — ⌥⌘I, View ▸ Show
    /// Inspector, or the toolbar's own button. After that the light table's
    /// portrait default never touches it again.
    ///
    /// DESIGN.md §2.5.1 says "⌥⌘I pins either choice and it sticks", and it
    /// did not: Choose Keepers assigned the default on every `onAppear`, so
    /// leaving the step and coming back put his choice back the way the
    /// current frame's orientation liked it.
    public private(set) var inspectorIsHisChoice = false
    public var sidebarShown = true

    /// Whether a page put the sidebar away in a narrow window, and the width
    /// it last acted at (§2.1): one memory for the window, shared by every
    /// page that does it — Choose Keepers and Reels. Each page kept its own,
    /// and SwiftUI brings the next page in before the last one goes, so
    /// moving between the two at 1100 pt left the sidebar out on both: the
    /// page arriving measured a window with the sidebar already away, did not
    /// count it as its own doing, and read the sidebar coming back as the
    /// leaving page's as his ⌃⌘S.
    @ObservationIgnored private var sidebarHider = LightTableGeometry.SidebarAutoHider()
    /// The pages up now that put the sidebar away, however many at once.
    @ObservationIgnored private var sidebarPages: Set<UUID> = []

    /// A page that puts the sidebar away in a narrow window is up, and laid
    /// out in a pane this wide, ending `window` points from the window's
    /// leading edge when the page measured that too.
    public func sidebarPage(_ page: UUID, laidOutAt pane: CGFloat, window: CGFloat? = nil) {
        sidebarPages.insert(page)
        switch sidebarHider.onLayout(detailPane: pane, sidebarShown: sidebarShown, window: window) {
        case .hide: sidebarShown = false
        case .show: sidebarShown = true
        case .leaveAlone: break
        }
    }

    /// That page has gone. The sidebar comes back if a page put it away,
    /// once no page that puts it away is left: going from Choose Keepers to
    /// Reels, the one arriving keeps it away and the memory of having done
    /// so, so leaving Reels for Presets still brings it back.
    public func sidebarPageLeft(_ page: UUID) {
        sidebarPages.remove(page)
        guard sidebarPages.isEmpty else { return }
        if sidebarHider.onLeave() == .show { sidebarShown = true }
    }
    /// Only the selected shoot is expanded; expanding another collapses the
    /// previous one.
    public var expandedShoot: String?
    /// The Finished section opened for him: the shoot he is in, or reopens
    /// on, is in it. Collapsed otherwise, unless he chose (`finishedChoice`)
    /// or nothing is in progress (`finishedOpen`).
    public var finishedExpanded = false
    /// His own opening or closing of the Finished section, kept across
    /// launches. `nil` until he has touched it.
    public private(set) var finishedChoice: Bool?
    /// Told when he opens or closes the section himself.
    public var onFinishedChoice: (@MainActor (Bool) -> Void)?

    /// Whether the Finished section is open. With nothing in progress it is
    /// open unless he closed it: collapsed at every launch, a library whose
    /// shoots were all finished showed a lone "Finished" heading over
    /// nothing, with a chevron that appears only on hover, and his choice
    /// to keep it open was forgotten.
    public func finishedOpen(nothingInProgress: Bool) -> Bool {
        finishedExpanded || (finishedChoice ?? nothingInProgress)
    }

    /// His click on the section's chevron.
    public func chooseFinished(_ open: Bool) {
        finishedExpanded = open
        finishedChoice = open
        onFinishedChoice?(open)
    }

    /// A choice he made in an earlier launch.
    public func restoreFinishedChoice(_ open: Bool) { finishedChoice = open }

    public init(selection: SidebarSelection? = nil) {
        self.selection = selection
        if let s = selection?.shoot { expandedShoot = s }
        if case .step(_, let st) = selection { step = st }
        noteThePlace()
    }

    /// Opens where he left off, once, at launch — the shoot expanded and
    /// selected, and the Finished section opened if that is where it is.
    public func restore(_ place: SidebarSelection, finished: Bool) {
        if finished { finishedExpanded = true }
        selection = place
        revealed = place.shoot
    }

    /// The shoot the sidebar scrolls to once, because a selected row below
    /// the fold is not one he can see.
    public private(set) var revealed: String?

    /// The sidebar has scrolled to it; it is not to be scrolled to again.
    public func didReveal() { revealed = nil }

    public var shoot: String? { selection?.shoot }

    /// The row selected in All Shoots, which is a shoot without being a
    /// page of one.
    public var shootInFocus: String?

    /// The shoot a shoot command means: the one on screen, or on All Shoots
    /// the row he selected there.
    public var shootForCommands: String? {
        shoot ?? (selection == .allShoots ? shootInFocus : nil)
    }

    /// Whether the page on screen has an inspector: a step that registered
    /// one (today only Choose Keepers). Everywhere else the column is not
    /// shown and its button and ⌥⌘I are not offered, whatever the pin says —
    /// the pin is kept for when he is back on the light table. The pin was
    /// window-wide, so a column pinned open there, or opened by a portrait
    /// burst, came with him to Presets, Reels and All Shoots as 280 pt of
    /// "Nothing to show here yet."
    public var hasInspector: Bool { step.map(InspectorRegistry.has) ?? false }

    /// The inspector as drawn: his pin, where there is an inspector.
    public var inspectorOnScreen: Bool { inspectorShown && hasInspector }

    /// His own press. It pins the choice.
    public func toggleInspector() {
        inspectorIsHisChoice = true
        pinFromLastLaunch = nil
        inspectorShown.toggle()
        onInspectorPinned?(inspectorShown)
    }

    /// Told each time he pins the inspector, so the pin outlives the launch.
    public var onInspectorPinned: (@MainActor (Bool) -> Void)?

    /// A pin he made in an earlier launch. §2.5.1's "it sticks" meant for
    /// the life of the window only: every launch put the portrait default
    /// back in charge of a choice he had already made.
    ///
    /// Held, not applied: the inspector is the light table's (Choose Keepers
    /// is the only page with anything in it), so the pin takes effect where
    /// the light table would have applied its own default. Applied at launch
    /// it opened a 280 pt column saying "Nothing to show" beside All Shoots
    /// and every shoot's overview, every launch.
    public func restoreInspectorPin(_ shown: Bool) {
        pinFromLastLaunch = shown
    }
    private var pinFromLastLaunch: Bool?

    /// The light table opening the inspector for a portrait burst. A default,
    /// and defaults do not override a person — including a pin he made in an
    /// earlier launch, which is taken up here the first time.
    public func setInspectorByDefault(_ shown: Bool) {
        if !inspectorIsHisChoice, let pin = pinFromLastLaunch {
            pinFromLastLaunch = nil
            inspectorIsHisChoice = true
            inspectorShown = pin
            return
        }
        guard !inspectorIsHisChoice, inspectorShown != shown else { return }
        inspectorShown = shown
    }

    /// ⌘] / ⌘[ over the shoot's own page and then its steps, in the
    /// engine's order: the page comes before the first step. It was counted
    /// as a step before the first and then clamped, so ⌘[ from the page went
    /// forward to Copy the Card, and ⌘] on Finish was an enabled item that
    /// did nothing and did not beep.
    public func moveStep(by delta: Int, in steps: [StepState]) {
        guard let shoot, canMoveStep(by: delta, in: steps) else { return }
        let n = position(in: steps) + delta
        selection = n < 0 ? .shoot(shoot) : .step(shoot: shoot, step: steps[n].id)
    }

    /// Whether ⌘] / ⌘[ has anywhere to go, so the menu greys and the key
    /// beeps at either end.
    public func canMoveStep(by delta: Int, in steps: [StepState]) -> Bool {
        guard shoot != nil, !steps.isEmpty, delta != 0 else { return false }
        let n = position(in: steps) + delta
        return n >= -1 && n < steps.count
    }

    /// The shoot's page is −1, its steps 0…
    private func position(in steps: [StepState]) -> Int {
        steps.firstIndex { $0.id == step } ?? -1
    }
}
