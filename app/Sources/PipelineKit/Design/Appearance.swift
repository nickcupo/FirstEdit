import AppKit
import SwiftUI

/// Light or dark, and the one place that decides it.
///
/// A Mac app follows the system, so `system` is the default and is what he gets
/// without touching anything. The other two exist because this app is used
/// beside PhotoLab and in rooms with the lights off, and because a photographer
/// may want the tool dark while the rest of the Mac is light: an app that can
/// only follow is an app that cannot be set.
///
/// What this does NOT change is the surround the photograph sits on. That is
/// `ViewerBackground` in Tokens.swift and is the same neutral in both
/// appearances on purpose: exposure is read against it, and a surround that
/// moved with the theme would change how a frame looks from one hour to the
/// next.
public enum AppAppearance: String, CaseIterable, Sendable, Codable {
    case system, light, dark

    /// `nil` means "whatever the Mac is set to" — AppKit's own answer when an
    /// app sets no appearance of its own.
    public var appKitName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    public var label: String {
        switch self {
        case .system: return Strings.Appearance.system
        case .light: return Strings.Appearance.light
        case .dark: return Strings.Appearance.dark
        }
    }

    public var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

/// Applies the choice to the whole app, including windows that are not the main
/// one (the picture window on a second display, the Activity window, sheets and
/// the extension's pages), because it is set on `NSApplication` rather than on
/// any one window.
@MainActor
public enum AppearanceController {
    public static func apply(_ choice: AppAppearance? = nil) {
        let want = choice ?? SettingsStore.shared.appearance
        NSApp?.appearance = want.appKitName.flatMap(NSAppearance.init(named:))
    }

    /// Set it and remember it, for the Settings control and the View menu.
    public static func choose(_ choice: AppAppearance) {
        SettingsStore.shared.appearance = choice
        apply(choice)
    }

    /// What is actually on screen right now, whatever the choice was: the
    /// snapshot harness and the picture window both ask this rather than
    /// assuming light.
    public static var effective: AppAppearance {
        let name = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            ?? NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua])
        return name == .darkAqua ? .dark : .light
    }
}
