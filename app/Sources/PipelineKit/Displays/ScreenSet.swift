import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

/// One screen, as the app needs to know it: enough to choose a screen, size a
/// window on it, ask for the right number of pixels and tell him what it is.
///
/// A value, not an `NSScreen`, so every decision about screens is made in code
/// that runs with no displays attached.
public struct ScreenInfo: Hashable, Sendable, Identifiable {
    public var id: ScreenKey { key }

    public let key: ScreenKey
    /// `localizedName` — for showing him, never for identity.
    public let name: String
    public let frame: CGRect
    /// What a window may cover: the menu bar and the Dock keep their strip.
    public let visibleFrame: CGRect
    public let backingScale: CGFloat
    /// The profile macOS has given this panel, by name. It decides nothing
    /// about the pixels; it is printed in These Screens… so he can see which
    /// of two panels is the odd one out (§4.3).
    public let colorSpaceName: String?
    public let isBuiltIn: Bool
    public let isAsleep: Bool
    public let hasMenuBar: Bool

    public init(key: ScreenKey, name: String, frame: CGRect, visibleFrame: CGRect,
                backingScale: CGFloat, colorSpaceName: String?,
                isBuiltIn: Bool, isAsleep: Bool, hasMenuBar: Bool) {
        self.key = key
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.backingScale = backingScale
        self.colorSpaceName = colorSpaceName
        self.isBuiltIn = isBuiltIn
        self.isAsleep = isAsleep
        self.hasMenuBar = hasMenuBar
    }

    public var pointArea: CGFloat { frame.width * frame.height }

    /// The panel's own pixels — the number that answers "is this thing running
    /// at its real resolution". On a converted panel driven at 1× it is half
    /// what he expects, and that is the cable, not the app (§1.6).
    public var realPixels: CGSize {
        CGSize(width: (frame.width * backingScale).rounded(),
               height: (frame.height * backingScale).rounded())
    }
}

/// Every attached screen, in one value.
public struct ScreenSet: Hashable, Sendable {
    public let screens: [ScreenInfo]
    /// Where the pointer is, for breaking a tie between two identical panels.
    public let pointer: CGPoint?

    public init(screens: [ScreenInfo], pointer: CGPoint? = nil) {
        self.screens = screens
        self.pointer = pointer
    }

    public static let none = ScreenSet(screens: [])

    public var externals: [ScreenInfo] { screens.filter { !$0.isBuiltIn } }
    public var builtIn: ScreenInfo? { screens.first(where: \.isBuiltIn) }
    public var isEmpty: Bool { screens.isEmpty }
    public var hasExternal: Bool { !externals.isEmpty }

    public subscript(_ key: ScreenKey) -> ScreenInfo? {
        screens.first { $0.key == key }
    }

    public func contains(_ key: ScreenKey) -> Bool { self[key] != nil }

    /// §3.3's ladder, in order:
    ///
    /// 1. the screen it was last open on, if that one is attached now;
    /// 2. otherwise the largest attached screen that is not the built-in, ties
    ///    broken by the one the pointer is on;
    /// 3. otherwise the built-in — where the window floats rather than fills,
    ///    because "the other screen" would be a lie.
    public func best(preferring key: ScreenKey? = nil) -> ScreenInfo? {
        if let key, let want = self[key] { return want }
        let outside = externals
        if !outside.isEmpty {
            let largest = outside.map(\.pointArea).max() ?? 0
            let tied = outside.filter { $0.pointArea == largest }
            if tied.count > 1, let p = pointer, let under = tied.first(where: { $0.frame.contains(p) }) {
                return under
            }
            return tied.first
        }
        return builtIn ?? screens.first
    }

    /// The screen a point is on, the way AppKit resolves it.
    public func screen(containing point: CGPoint) -> ScreenInfo? {
        screens.first { $0.frame.contains(point) }
    }
}

#if canImport(AppKit)
extension ScreenInfo {
    @MainActor
    public init(_ screen: NSScreen, menuBarScreen: NSScreen?) {
        let id = ScreenKey.displayID(of: screen)
        self.init(key: ScreenKey(screen),
                  name: screen.localizedName,
                  frame: screen.frame,
                  visibleFrame: screen.visibleFrame,
                  backingScale: screen.backingScaleFactor,
                  colorSpaceName: screen.colorSpace?.localizedName,
                  isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                  isAsleep: CGDisplayIsAsleep(id) != 0,
                  hasMenuBar: screen === menuBarScreen)
    }
}

extension ScreenSet {
    /// What AppKit has right now.
    @MainActor
    public static func current() -> ScreenSet {
        let all = NSScreen.screens
        // The menu bar is on `NSScreen.screens.first` — the screen with the
        // origin — whatever the arrangement.
        let menuBar = all.first
        return ScreenSet(screens: all.map { ScreenInfo($0, menuBarScreen: menuBar) },
                         pointer: NSEvent.mouseLocation)
    }
}
#endif
