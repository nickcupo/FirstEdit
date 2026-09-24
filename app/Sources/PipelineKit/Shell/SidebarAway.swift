import SwiftUI

extension View {
    /// §2.1: the sidebar goes while this page is up in a window narrower than
    /// 1280 pt and comes back when he leaves for a page that does not do the
    /// same. `geo` is the page's own measure, as SwiftUI just laid it out; the
    /// window's `Navigation` keeps the one memory of it, which Choose Keepers
    /// and Reels share. Without a `navigation` — a test drawing the page alone
    /// — nothing moves.
    func putsTheSidebarAway(_ navigation: Navigation?, in geo: GeometryProxy) -> some View {
        modifier(SidebarAway(navigation: navigation,
                             layout: .init(pane: geo.size.width, window: geo.frame(in: .global).maxX)))
    }
}

/// The page's side of `Navigation.sidebarPage(_:laidOutAt:window:)`: who it
/// is, told at each layout, and told when it goes.
///
/// The window is where the page ends, measured, not the pane plus a sidebar
/// of the default width. He can drag the sidebar anywhere from 180 to 320 pt,
/// and at any width but 256 the sum made the window one width with the
/// sidebar out and another with it away: his ⌃⌘S read as a resize, and the
/// sidebar was put straight back. The page's trailing edge does not move when
/// the sidebar does. Both numbers come from one layout, and are told together.
private struct SidebarAway: ViewModifier {
    struct Layout: Equatable {
        let pane: CGFloat
        let window: CGFloat
    }

    let navigation: Navigation?
    let layout: Layout
    @State private var page = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { tell(layout) }
            .onChange(of: layout) { _, now in tell(now) }
            .onDisappear { navigation?.sidebarPageLeft(page) }
    }

    private func tell(_ l: Layout) {
        navigation?.sidebarPage(page, laidOutAt: l.pane, window: l.window)
    }
}
