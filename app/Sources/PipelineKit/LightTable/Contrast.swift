import SwiftUI
import AppKit


// Two crews wrote `increaseContrastOverride`; the one kept is in
// Commands/Accessibility.swift, which owns accessibility for the whole app and
// whose reader also consults the live system setting, not only the environment.

extension View {
    /// Under Increase Contrast the verdict badges, the current-frame ring and
    /// the stack bracket thicken to 3 pt and the control bar takes a 1 pt
    /// border (§2.15).
    public func increaseContrast(_ on: Bool) -> some View {
        environment(\.increaseContrastOverride, on)
    }
}

/// A line that sits **on the photograph**: the end-of-burst note, the stack
/// invitation, the reasons strip, the one-line caption overlay below 1100 pt.
///
/// Not glass. §2.2 gives Liquid Glass to four places — the Full Image HUD, the
/// stack badge, the scrubber popover and the job popover — and this is none of
/// them, for a reason he would notice: a translucent chip over a bright sky is
/// a sentence he cannot read, and the sentence here is the one that tells him
/// what he has just done to a burst.
public struct ViewerChip<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.increaseContrastOverride) private var override

    public init(_ shape: S) { self.shape = shape }

    public func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.94), in: shape)
            .overlay {
                shape.strokeBorder(.primary.opacity(0.15),
                                   lineWidth: (override ?? (contrast == .increased)) ? 1 : 0.5)
            }
    }
}

extension View {
    public func viewerChip() -> some View {
        modifier(ViewerChip(RoundedRectangle(cornerRadius: 8, style: .continuous)))
    }
    public func viewerChip<S: InsettableShape>(_ shape: S) -> some View {
        modifier(ViewerChip(shape))
    }
}

/// Writing painted **straight onto** the viewer's surround — the All Bursts
/// captions, the numbers under Compare's tiles — takes its light or dark from
/// the surround, not from the app's appearance. Neutral Grey and Black stay
/// what they are in both appearances, so in Light a `.primary` caption was
/// near-black on #3A3A3A. Match the System follows the appearance, and so does
/// everything on it.
public struct OnViewerSurround: ViewModifier {
    let wide: Bool

    public func body(content: Content) -> some View {
        let choice = SettingsStore.shared.viewerBackground
        if choice == .matchSystem {
            content
        } else {
            content.environment(\.colorScheme, DisplaySurround.isDark(choice, wide: wide) ? .dark : .light)
        }
    }
}

extension View {
    public func onViewerSurround(wide: Bool = false) -> some View {
        modifier(OnViewerSurround(wide: wide))
    }
}
