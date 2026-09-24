import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

/// Which physical screen this is, in a form that survives being unplugged.
///
/// `NSScreen` objects and `CGDirectDisplayID`s are not stable across a
/// disconnect — the id changes when a panel is re-attached and the array order
/// changes when the arrangement changes — so identity is computed once, per
/// screen, from the panel's own numbers (DESIGN-displays.md §3.4).
///
/// It is a ladder rather than one call on purpose. `CGDisplayVendorNumber`,
/// `CGDisplayModelNumber` and `CGDisplaySerialNumber` are old CoreGraphics and
/// have carried deprecation warnings before; step 3's composite needs none of
/// them beyond the two that remain, and it is also the step his own hardware
/// takes, because a third-party driver board reports a serial of 0.
///
/// `localizedName` is used to *show* him a screen and never as identity: it is
/// localised, it can be duplicated, and macOS changes how it names a panel.
public struct ScreenKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String

    public init(raw: String) { self.raw = raw }

    public var isBuiltIn: Bool { raw.hasPrefix("builtin:") }
    public var description: String { raw }

    /// The key without the arrangement: vendor, model and serial only.
    ///
    /// A change of resolution or scale on the same panel changes `raw`, which
    /// is deliberate — a frame saved for a 2560 × 1440 arrangement is wrong for
    /// a 3840 × 2160 one, and AppKit's own autosave behaves the same way. The
    /// mode and the fill flag are remembered under this coarser key instead, so
    /// they survive a resolution change even when the window frame does not.
    public var coarse: ScreenKey {
        guard let cut = raw.range(of: "|") else { return self }
        return ScreenKey(raw: String(raw[raw.startIndex..<cut.lowerBound]))
    }

    /// Safe inside an `NSWindow` frame autosave name and a defaults key.
    public var sanitised: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return String(raw.map { allowed.contains($0) ? $0 : "_" })
    }

    // MARK: - the ladder

    /// The testable seam: every input is a number or a string, so the whole of
    /// `ScreenKeyTests` runs on a build machine with one display or none.
    public static func make(displayID: CGDirectDisplayID,
                            isBuiltIn: Bool,
                            vendor: UInt32,
                            model: UInt32,
                            serial: UInt32,
                            unit: UInt32,
                            physicalMM: CGSize,
                            points: CGSize,
                            scale: CGFloat,
                            name: String) -> ScreenKey {
        // 1. There is only ever one built-in screen. It must match itself
        //    across sleep, a lid close, a scale change and a rearrangement,
        //    and nothing else — so the arrangement is not in its key at all.
        if isBuiltIn {
            return ScreenKey(raw: "builtin:\(vendor)-\(model)")
        }

        let head = "ext:\(vendor)-\(model)-\(serial)"

        // 2. A panel that reports a serial identifies itself.
        if serial != 0 {
            return ScreenKey(raw: "\(head)|\(arrangement(points, scale))")
        }

        // 3. Serial 0 — his case. A conversion board reports the board's own
        //    vendor and model and no serial, so the panel's physical size
        //    carries the identity. It is stable across a reconnect and it
        //    tells two different panels on two identical boards apart.
        let mm = "\(mmText(physicalMM.width))x\(mmText(physicalMM.height))"
        if physicalMM.width > 0, physicalMM.height > 0 {
            return ScreenKey(raw: "\(head)-\(mm)|\(arrangement(points, scale))")
        }

        // 4. Even the millimetres are degenerate (some boards report 0 × 0).
        //    The unit number is stable for as long as the panel stays plugged
        //    in, and the name is the last thing left to tell two apart.
        return ScreenKey(raw: "\(head)-\(mm)-u\(unit)-\(compact(name))|\(arrangement(points, scale))")
    }

    private static func arrangement(_ points: CGSize, _ scale: CGFloat) -> String {
        "\(intText(points.width))x\(intText(points.height))@\(scaleText(scale))"
    }

    private static func mmText(_ v: CGFloat) -> String { intText(v) }

    private static func intText(_ v: CGFloat) -> String {
        guard v.isFinite else { return "0" }
        return String(Int(v.rounded()))
    }

    /// One decimal place: 1, 2 and the 1.5 an odd mode can produce, with no
    /// locale in it.
    private static func scaleText(_ v: CGFloat) -> String {
        guard v.isFinite, v > 0 else { return "1" }
        let tenths = Int((v * 10).rounded())
        return tenths % 10 == 0 ? String(tenths / 10) : "\(tenths / 10).\(tenths % 10)"
    }

    /// A name reduced to letters and digits, so it can never carry a separator
    /// this key uses or a character a defaults key cannot hold.
    private static func compact(_ name: String) -> String {
        let s = name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return s.isEmpty ? "unnamed" : String(String.UnicodeScalarView(s.prefix(24)))
    }
}

#if canImport(AppKit)
extension ScreenKey {
    /// The key for a screen AppKit is holding.
    @MainActor
    public init(_ screen: NSScreen) {
        let id = ScreenKey.displayID(of: screen)
        self = ScreenKey.make(displayID: id,
                              isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                              vendor: CGDisplayVendorNumber(id),
                              model: CGDisplayModelNumber(id),
                              serial: CGDisplaySerialNumber(id),
                              unit: CGDisplayUnitNumber(id),
                              physicalMM: CGDisplayScreenSize(id),
                              points: screen.frame.size,
                              scale: screen.backingScaleFactor,
                              name: screen.localizedName)
    }

    /// `NSScreenNumber` out of the device description. A screen AppKit hands
    /// out always has one; 0 is only ever reached if AppKit changes that, and
    /// the ladder above still produces a usable key from it.
    @MainActor
    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}
#endif
