import AppKit
import Foundation

/// The host's look, handed to an extension's page as CSS custom properties.
///
/// The page is light in Light Mode and dark in Dark Mode **with the app**,
/// never a third palette: every value here is read from the live semantic
/// `NSColor` for the appearance the pane is actually drawn in, and is set
/// again the moment that appearance changes while the page is open.
///
/// The names are fixed and public — they are the contract, and
/// `ExtContract.md` is the copy of it that goes to whoever writes a page.
public struct ExtAppearance: Sendable, Equatable {
    /// CSS custom property name (without the leading `--`) to value.
    public let variables: [(name: String, value: String)]
    public let isDark: Bool
    public let reduceMotion: Bool
    public let increaseContrast: Bool

    public static func == (a: ExtAppearance, b: ExtAppearance) -> Bool {
        a.isDark == b.isDark && a.reduceMotion == b.reduceMotion
            && a.increaseContrast == b.increaseContrast
            && a.variables.map(\.name) == b.variables.map(\.name)
            && a.variables.map(\.value) == b.variables.map(\.value)
    }

    /// Everything a page is given, read in `appearance`'s own drawing context
    /// so a dynamic colour resolves to the side of itself the pane is showing.
    @MainActor
    public static func current(_ appearance: NSAppearance,
                               reduceMotion: Bool = Motion.reduced,
                               increaseContrast: Bool = NSWorkspace.shared
                                   .accessibilityDisplayShouldIncreaseContrast) -> ExtAppearance {
        var vars: [(String, String)] = []
        appearance.performAsCurrentDrawingAppearance {
            vars = [
                // Text
                ("pp-text", css(.labelColor)),
                ("pp-text-secondary", css(.secondaryLabelColor)),
                ("pp-text-tertiary", css(.tertiaryLabelColor)),
                ("pp-text-disabled", css(.disabledControlTextColor)),
                ("pp-link", css(.linkColor)),

                // Surfaces
                ("pp-background", css(.controlBackgroundColor)),
                ("pp-background-secondary", css(.windowBackgroundColor)),
                ("pp-control", css(.controlColor)),
                ("pp-control-text", css(.controlTextColor)),
                ("pp-separator", css(.separatorColor)),

                // The user's own system accent, never a brand colour.
                ("pp-accent", css(.controlAccentColor)),
                ("pp-accent-text", css(.alternateSelectedControlTextColor)),
                ("pp-selection", css(.selectedContentBackgroundColor)),

                // The three states that always carry a word and a symbol too,
                // so Differentiate Without Color loses nothing.
                ("pp-kept", css(.systemGreen)),
                ("pp-alarm", css(.systemRed)),
                ("pp-fault", css(.systemOrange)),
            ]
        }

        vars += [
            ("pp-font", "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"),
            ("pp-font-mono", "ui-monospace, SFMono-Regular, Menlo, monospace"),

            // §2.2's ladder, in points, which are CSS pixels here.
            ("pp-text-large-title", "26px"),
            ("pp-text-title", "22px"),
            ("pp-text-title2", "17px"),
            ("pp-text-title3", "15px"),
            ("pp-text-headline", "13px"),
            ("pp-text-headline-weight", "600"),
            ("pp-text-body", "13px"),
            ("pp-text-callout", "12px"),
            ("pp-text-subheadline", "11px"),
            ("pp-text-footnote", "10px"),

            ("pp-space-window", "20px"),
            ("pp-space-group", "16px"),
            ("pp-space-related", "8px"),
            ("pp-space-label", "4px"),
            ("pp-column", "680px"),
            ("pp-radius", "6px"),
            ("pp-hit-target", "28px"),

            ("pp-appearance", appearanceIsDark(appearance) ? "dark" : "light"),
            ("pp-reduce-motion", reduceMotion ? "1" : "0"),
            ("pp-increase-contrast", increaseContrast ? "1" : "0"),
        ]

        return ExtAppearance(variables: vars.map { (name: $0.0, value: $0.1) },
                             isDark: appearanceIsDark(appearance),
                             reduceMotion: reduceMotion,
                             increaseContrast: increaseContrast)
    }

    public init(variables: [(name: String, value: String)], isDark: Bool,
                reduceMotion: Bool, increaseContrast: Bool) {
        self.variables = variables
        self.isDark = isDark
        self.reduceMotion = reduceMotion
        self.increaseContrast = increaseContrast
    }

    static func appearanceIsDark(_ a: NSAppearance) -> Bool {
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// `rgba(…)` in sRGB. A label colour is not opaque, and flattening it
    /// against a guess at the background is how text stops matching the app.
    static func css(_ colour: NSColor) -> String {
        guard let c = colour.usingColorSpace(.sRGB) else { return "rgba(0, 0, 0, 1)" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        let a = (c.alphaComponent * 1000).rounded() / 1000
        return a >= 1 ? "rgb(\(r), \(g), \(b))" : "rgba(\(r), \(g), \(b), \(a))"
    }

    // MARK: - what goes into the page

    /// The declaration block, without the selector.
    public var declarations: String {
        variables.map { "  --\($0.name): \($0.value);" }.joined(separator: "\n")
    }

    /// The stylesheet the host owns. It sets the variables, tells the browser
    /// which side of itself to draw its own controls on, and gives the page a
    /// sensible starting point — which a page is free to override, because
    /// every one of these is a plain declaration on `:root` and `body`.
    public var stylesheet: String {
        """
        :root {
        \(declarations)
          color-scheme: \(isDark ? "dark" : "light");
        }
        html, body {
          font-family: var(--pp-font);
          font-size: var(--pp-text-body);
          color: var(--pp-text);
          background: var(--pp-background);
          margin: 0;
          -webkit-font-smoothing: antialiased;
        }
        """
    }

    /// Applied at document start, and again on every appearance change, by
    /// setting the properties rather than replacing a stylesheet — so a page
    /// that has already laid itself out re-colours without reflowing.
    public var script: String {
        let sets = variables.map { v in
            "  r.setProperty(\(ExtJS.quote("--" + v.name)), \(ExtJS.quote(v.value)));"
        }.joined(separator: "\n")
        return """
        (function () {
          var root = document.documentElement;
          var r = root.style;
        \(sets)
          root.dataset.appearance = \(ExtJS.quote(isDark ? "dark" : "light"));
          root.dataset.reduceMotion = \(ExtJS.quote(reduceMotion ? "1" : "0"));
          root.dataset.increaseContrast = \(ExtJS.quote(increaseContrast ? "1" : "0"));
          var s = document.getElementById("pipeline-host-style");
          if (!s) {
            s = document.createElement("style");
            s.id = "pipeline-host-style";
            (document.head || root).appendChild(s);
          }
          s.textContent = \(ExtJS.quote(stylesheet));
          window.dispatchEvent(new CustomEvent("pipelineappearance", {
            detail: { appearance: root.dataset.appearance,
                      reduceMotion: \(reduceMotion ? "true" : "false"),
                      increaseContrast: \(increaseContrast ? "true" : "false") }
          }));
        })();
        """
    }
}

/// Putting a Swift string into JavaScript, once, correctly.
enum ExtJS {
    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            // `</script` inside a string closes the element in an HTML parser.
            case "<": out += "\\u003c"
            case ">": out += "\\u003e"
            case "&": out += "\\u0026"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out + "\""
    }
}
