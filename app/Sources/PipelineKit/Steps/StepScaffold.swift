import SwiftUI

/// The numbers the five workflow steps are laid out on, in one place, so a
/// layout test can assert them and no view types one in by hand.
///
/// The one that matters is `primaryBox`. Every step's primary action is drawn
/// inside a box of exactly this size, and a running job draws its progress
/// into the same box. The box never changes size, so the control he just
/// pressed is in the same place before, during and after the job — the old
/// page moved it between 150 and 215 pt (FLOW-04).
public enum StepMetric {
    /// The primary's own box. Wide enough for the bar, the engine's stage
    /// words and Stop, so the box a button sits in and the box a job's
    /// progress sits in are one box.
    public static let primaryBox = CGSize(width: 320, height: 36)
    /// The action bar's padding inside the window's margin.
    public static let barVerticalPadding: CGFloat = 14
    /// A step's page is a centred column, left-aligned inside (§2.2).
    public static let column: CGFloat = Tokens.Metric.column
    /// The gap between the bar's leading text and the primary's box.
    public static let barGap: CGFloat = Tokens.Metric.groupGap
    /// How far a grouped `Form` insets its cards from each side of whatever
    /// holds it. The scaffold hands the form this much more than the column
    /// on each side, so the cards land on the column's edges.
    public static let formInset: CGFloat = 20

    /// How long the progress box's Stop and × ignore a press after they
    /// appear. The button he pressed becomes the progress box one request
    /// later, tens of milliseconds, well inside a double-click: the second
    /// click of "Cull It" landed on Stop and killed the cull it had just
    /// started, and the second click of "Add It to the List" landed on × and
    /// took back what it had just added.
    public static let settle: TimeInterval = 0.8

    /// Whether a press on the box's own control counts, `since` the box
    /// changed to show it.
    public static func takesPress(since shown: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(shown) >= settle
    }
}

/// Where the other crews hand this one a panel or a destination, in one line
/// each, so a step page never has a control that goes nowhere.
///
/// Every one of these is optional and every caller checks: a `nil` here means
/// the link or the panel is simply not drawn, never that a button sits there
/// doing nothing.
@MainActor
public enum StepSlots {
    /// The storage panel of §2.8, which belongs to the storage crew and is
    /// drawn on the Finish page. Set once at launch.
    public static var storagePanel: (@MainActor (ShootSession) -> AnyView)?
    /// Goes to What the Cull Has Learned. Wired by whoever owns navigation.
    public static var showLearned: (@MainActor () -> Void)?
    /// Goes to another step of the shoot that is open.
    public static var showStep: (@MainActor (String, String) -> Void)?
    /// Opens the Activity window (⌥⌘L).
    public static var showActivity: (@MainActor () -> Void)?

    /// For tests and the snapshot harness.
    public static func reset() {
        storagePanel = nil; showLearned = nil; showStep = nil; showActivity = nil
    }
}

/// A step page: a scrolling 680 pt column, and an action bar pinned to the
/// bottom of the window.
///
/// The bar is pinned rather than being the last row of the form, which is what
/// makes "no error can render below the fold at any window size" (FLOW-02) a
/// property of the layout instead of a thing to remember. Inside the bar the
/// primary is bottom-aligned and the refusal grows *upward* beside it, so a
/// refusal appearing never moves the button he just pressed.
public struct StepScaffold<Content: View, Action: View>: View {
    /// Kept for the accessibility label of the page, and for a test to read.
    /// It is deliberately *not* a heading drawn on the page: the window's own
    /// two-line title carries the shoot and the step (§2.1), and a third copy
    /// of the same word on the page is noise.
    let title: String
    let blurb: String?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let action: () -> Action

    public init(title: String, blurb: String? = nil,
                @ViewBuilder content: @escaping () -> Content,
                @ViewBuilder action: @escaping () -> Action) {
        self.title = title
        self.blurb = blurb
        self.content = content
        self.action = action
    }

    public var body: some View {
        // The column is measured once and handed down, rather than left to
        // each view to hug its own content: a grouped `Form` sizes itself to
        // its narrowest row, and a page whose sections are each a different
        // width is not a page Apple would ship.
        GeometryReader { proxy in
            let column = StepScaffold.columnWidth(in: proxy.size.width)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.Metric.groupGap) {
                        if let blurb {
                            Text(blurb)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // A grouped `Form` insets its cards from each side
                        // of whatever holds it. Given only the column, it
                        // put its cards 20 pt inside the intro sentence and
                        // the bar, and the button 20 pt past their right
                        // edge, on every step. Given the column and its own
                        // inset each side, its cards sit on the column's
                        // edges with the sentence above and the bar below.
                        content()
                            .padding(.horizontal, -StepMetric.formInset)
                    }
                    .frame(width: column, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Tokens.Metric.windowMargin)
                    .padding(.bottom, Tokens.Metric.groupGap)
                }
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityLabel(Text(title))
                action()
            }
            .environment(\.stepColumnWidth, column)
        }
    }

    /// The page's column: 680 pt where there is room, and the window's own
    /// width less its margins where there is not.
    public static func columnWidth(in available: CGFloat) -> CGFloat {
        let usable = available - 2 * Tokens.Metric.windowMargin
        return max(240, min(usable, StepMetric.column))
    }
}

extension EnvironmentValues {
    /// What `StepScaffold` measured, so the action bar lines up with the page
    /// above it to the pixel.
    @Entry public var stepColumnWidth: CGFloat = StepMetric.column
}

/// The action bar itself: the engine's refusal or note on the leading side,
/// the primary's fixed box on the trailing side.
///
/// The two sides meet on their last line of text, and the bar is pinned to
/// the window's bottom edge. Together that is the whole trick: however tall
/// the leading text becomes it grows upward from a line level with the
/// button's own words, and the box keeps exactly the same distance from the
/// bottom of the window. It met them on their bottom edges, which put "About
/// a minute." 7 pt below "Cull It" and the running clock 10 pt below the
/// progress box's words.
public struct StepActionBar<Leading: View, Box: View>: View {
    @Environment(\.stepColumnWidth) private var column
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let box: () -> Box

    public init(@ViewBuilder leading: @escaping () -> Leading,
                @ViewBuilder box: @escaping () -> Box) {
        self.leading = leading
        self.box = box
    }

    public var body: some View {
        // Nothing in `leading` may fix its own horizontal size. A `fixedSize`
        // here asks for a whole sentence on one line, the bar lays out wider
        // than the window, and the page comes out blank — which a snapshot
        // caught and no compiler would have.
        HStack(alignment: .lastTextBaseline, spacing: StepMetric.barGap) {
            leading()
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            box()
                .frame(width: StepMetric.primaryBox.width,
                       height: StepMetric.primaryBox.height,
                       alignment: .bottomTrailing)
        }
        .frame(width: column, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.vertical, StepMetric.barVerticalPadding)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - the small pieces every step uses

/// One row of a step's checklist: a symbol, a sentence, and whatever goes on
/// the trailing edge.
public struct StepRow<Trailing: View>: View {
    let symbol: String
    let text: String
    let done: Bool
    /// The symbol's colour where it stands for a mark drawn elsewhere in that
    /// colour — the cull's triangle is orange in the filmstrip, so it is
    /// orange in the report that explains it. The text stays as it is.
    let tint: Color?
    @ViewBuilder let trailing: () -> Trailing

    public init(_ symbol: String, _ text: String, done: Bool = false, tint: Color? = nil,
                @ViewBuilder trailing: @escaping () -> Trailing) {
        self.symbol = symbol
        self.text = text
        self.done = done
        self.tint = tint
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Metric.relatedGap) {
            Label {
                Text(text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: done ? "checkmark.circle.fill" : symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(done ? Tokens.Palette.kept : tint ?? Color.secondary)
            }
            Spacer(minLength: Tokens.Metric.relatedGap)
            trailing()
        }
        .accessibilityElement(children: .combine)
    }
}

extension StepRow where Trailing == EmptyView {
    public init(_ symbol: String, _ text: String, done: Bool = false, tint: Color? = nil) {
        self.init(symbol, text, done: done, tint: tint) { EmptyView() }
    }
}

/// A sentence under a control, in the muted colour. Not a refusal: a refusal
/// is a `RefusalRow` and is the alarm colour.
public struct StepNote: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A path, with the button that shows it in Finder beside it. The button asks
/// the *engine* to open it, because a button that says it will show a folder
/// must never create one (DESIGN.md §7.10) and only the engine knows which
/// folder a shoot's exports are really in.
public struct StepPathRow: View {
    let label: String
    let url: URL
    let what: String
    let open: (String) -> Void

    public init(_ label: String, _ path: String, what: String, open: @escaping (String) -> Void) {
        self.label = label
        self.url = URL(fileURLWithPath: path)
        self.what = what
        self.open = open
    }

    public var body: some View {
        LabeledContent(label) {
            HStack(spacing: Tokens.Metric.relatedGap) {
                PathRow(url)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(Strings.Edit.show) { open(what) }
                    .accessibilityLabel(Text("\(Strings.Edit.show) \(label)"))
            }
        }
    }
}

extension StepPathRow {
    /// The label for one of the folders a shoot's exports are in. One folder
    /// is "Where they are"; two or more are each named for the folder inside
    /// the shoot — "In export", "In edit › edited" — because two rows under
    /// the same label, with the path cut exactly where the two differ, read
    /// as one folder shown twice.
    nonisolated public static func exportLabel(_ dir: String, shoot: String, among count: Int) -> String {
        guard count > 1 else { return Strings.Finish.whereTheyAre }
        let base = shoot.hasSuffix("/") ? shoot : shoot + "/"
        let inside = dir.hasPrefix(base) ? String(dir.dropFirst(base.count))
                                         : URL(fileURLWithPath: dir).lastPathComponent
        return Strings.Finish.whereTheyAreIn(inside.split(separator: "/").joined(separator: " › "))
    }
}

/// A link that goes somewhere else in the app. It is drawn only when whoever
/// owns that destination has said where it is.
public struct StepLink: View {
    let title: String
    let go: (@MainActor () -> Void)?

    public init(_ title: String, go: (@MainActor () -> Void)?) {
        self.title = title
        self.go = go
    }

    public var body: some View {
        if let go {
            Button(title) { go() }
                .buttonStyle(.link)
                .font(.callout)
        }
    }
}
