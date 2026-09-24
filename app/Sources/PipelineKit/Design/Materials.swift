import SwiftUI

/// Liquid Glass on macOS 26 and later, `.ultraThinMaterial` in the same shape
/// before it — identical geometry, so nothing reflows by OS version (§2.2,
/// §3.1). Reduce Transparency swaps both for an opaque surface.
public struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(_ shape: S) { self.shape = shape }

    public func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    /// The Full Image HUD, the stack badge, the scrubber popover and the job
    /// popover. Nothing else in the app is glass.
    public func glassSurface<S: InsettableShape>(_ shape: S) -> some View {
        modifier(GlassSurface(shape))
    }

    public func glassSurface() -> some View {
        modifier(GlassSurface(RoundedRectangle(cornerRadius: 12, style: .continuous)))
    }

    /// A step's one primary action: `.glassProminent` on 26, `.borderedProminent`
    /// before it, at the same size.
    @ViewBuilder
    public func primaryActionStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent).controlSize(.large)
        } else {
            buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}
