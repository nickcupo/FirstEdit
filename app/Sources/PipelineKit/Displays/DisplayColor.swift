import Foundation
import CoreGraphics
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Colour across two panels: what macOS does for you, and what it does not.
///
/// **What it does.** If a `CGImage` carries a colour space, Core Animation
/// converts it to each display's profile when it composites — per display,
/// correctly, for free, including a window straddling two screens. That is the
/// whole of the automatic behaviour and it is enough.
///
/// **What it does not.** It does not guess. The image routes serve JPEGs that
/// are sRGB bytes with no profile embedded, and `CGImageSourceCreateThumbnail…`
/// on an untagged JPEG can hand back an image whose `colorSpace` is nil.
/// Assigned to a layer, an untagged image is treated as *already in the
/// display's space* and no conversion happens: on a P3 panel that is sRGB
/// numbers shown as P3 numbers — reds and greens roughly a quarter too
/// saturated, skin pushed orange, and the same frame looking different here
/// than in PhotoLab, in Preview or on his own website. He would trust the
/// wrong one.
///
/// So the app tags, explicitly, once, at the boundary (§4.3).
public enum DisplayColor {

    /// The one colour space this app names.
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The contract, written down so a future engine change cannot break it
    /// silently: **every image route returns sRGB bytes; if it ever returns
    /// anything else it must embed the profile, and the app will honour it.**
    ///
    /// Two cases are retagged and one is left alone. A picture with no space at
    /// all is sRGB, because that is what the routes serve. A picture in a
    /// *generic* space — one carrying no profile of its own — is also sRGB,
    /// because such a space means "whatever the display is" and so nothing is
    /// converted. A picture that does carry a profile is honoured untouched:
    /// an engine that starts tagging is obeyed, never overridden.
    public static func tagged(_ image: CGImage) -> CGImage {
        guard let space = image.colorSpace, space.copyICCData() != nil else {
            return image.copy(colorSpace: sRGB) ?? image
        }
        return image
    }

    /// Anything that renders a frame to pixels — the snapshot harness, a
    /// future export — makes its context here, or the conversion happens twice
    /// and the PNGs stop being comparable between machines.
    public static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: max(1, width), height: max(1, height),
                  bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }
}

/// The grey behind the photograph, measured (§4.4).
///
/// Three rules hold, and the reason for all three is the same: his eye adapts
/// to the surround, and every exposure and tone call he makes is made relative
/// to it.
///
/// 1. **Defined in sRGB.** A grey defined in a panel's own space renders as a
///    *different grey on each panel*, which is the single most visible
///    two-screen bug available and the one that would make him distrust the
///    colour of the photograph next to it.
/// 2. **The same value on both screens**, whatever each panel's profile is.
///    ColorSync does the per-display conversion.
/// 3. **It does not follow light/dark and it does not follow Increase
///    Contrast.** A surround that flipped when macOS went dark at sunset would
///    mean the frames he judged at 4 pm and the frames he judged at 7 pm were
///    judged against two different references, on the same shoot, with no
///    indication it happened. Chrome *around* the surround — the HUD, the title
///    bar, the hairlines — honours both normally.
public enum DisplaySurround {

    /// The window's surround: sRGB #3A3A3A.
    public static let grey = srgb(0x3A)
    /// Full Image, a picture window filling a screen, and Presentation: #1A1A1A.
    public static let greyDark = srgb(0x1A)
    public static let black = srgb(0x00)

    /// The colour for his chosen option. `wide` is true for Full Image, a
    /// picture window filling a screen and Presentation — the places that use
    /// the darkest variant of whatever he picked.
    public static func color(_ choice: ViewerBackground, wide: Bool) -> NSColor {
        switch choice {
        case .neutralGrey: return wide ? greyDark : grey
        case .matchSystem: return wide ? srgb(0x14) : .windowBackgroundColor
        case .black: return black
        }
    }

    public static func swiftUIColor(_ choice: ViewerBackground, wide: Bool) -> Color {
        Color(nsColor: color(choice, wide: wide))
    }

    /// What may be drawn **on** the surround: the two hairlines and the quiet
    /// lines of §1.5.
    ///
    /// Light or dark is his to set and it applies to this window like every
    /// other (`Design/Appearance.swift`). The surround is the one thing that
    /// does not move with it — so a `.primary` label, which is black in the
    /// light appearance, would be a line nobody can see on a fixed dark
    /// surround. Anything painted **straight onto** the surround therefore
    /// takes its contrast from the surround itself.
    ///
    /// The HUD is not this. It carries its own material, and its text follows
    /// the appearance on top of that, as a HUD should.
    public static func ink(_ choice: ViewerBackground, wide: Bool, opacity: Double = 1) -> Color {
        (isDark(choice, wide: wide) ? Color.white : Color.black).opacity(opacity)
    }

    /// Whether the surround he has chosen is a dark one.
    public static func isDark(_ choice: ViewerBackground, wide: Bool) -> Bool {
        let background = color(choice, wide: wide).usingColorSpace(.sRGB)
        let luminance = background.map {
            0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent
        } ?? 0
        return luminance < 0.5
    }

    /// One byte of grey, in sRGB, with no locale and no panel in it.
    private static func srgb(_ v: Int) -> NSColor {
        let c = CGFloat(v) / 255
        return NSColor(srgbRed: c, green: c, blue: c, alpha: 1)
    }
}
