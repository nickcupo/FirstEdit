import SwiftUI

/// The library-wide pages' grouped `Form`, filling the detail column with its
/// rows held to the page column.
///
/// These pages used to narrow the `Form` itself to the 680 pt column and
/// centre it. A `Form` is its own scroll view, so that narrowed the scroll
/// view with it: the wheel did nothing over the margins either side — about
/// 110 pt of the default window, about 500 pt at 1920 wide — and the scroller
/// was drawn at the column's edge, floating in the middle of the window. The
/// step pages never did this (`StepScaffold` scrolls full width), which is
/// the other half of why the mouse "moves weird" going from one to the other.
///
/// Now the scroll view is the whole pane and only its contents are held in:
/// the margins are the scroll view's own content margins, so the wheel works
/// anywhere on the page and the scroller sits at the window's edge.
///
/// Only for a `Form` that is the page. The storage panel is not: it sits
/// inside Finish's scroll view, where the geometry reader here has no height
/// of its own, and it collapsed to a sliver.
struct ColumnForm: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .contentMargins(.horizontal, Self.margin(in: proxy.size.width), for: .scrollContent)
        }
    }

    /// Each side's margin: what centres the column, and nothing where the
    /// pane is narrower than it.
    ///
    /// A grouped `Form` keeps its own inset inside these margins, the window
    /// margin, as it did when the `Form` itself was 680 pt wide — so the rows
    /// land exactly where they were, and nothing on the page moves except
    /// the scroller.
    nonisolated static func margin(in width: CGFloat) -> CGFloat {
        max(0, (width - Tokens.Metric.column) / 2)
    }
}

extension View {
    /// A grouped `Form` that scrolls across the whole pane, with its rows in
    /// the page column (§2.1).
    func columnForm() -> some View { modifier(ColumnForm()) }
}
