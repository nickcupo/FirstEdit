import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Window ▸ These Screens… — small, cheap, and he will use it once a month.
///
/// It answers, in one look, the two questions a converted panel makes him ask:
/// *is this thing actually running at its real resolution* (the "real" column),
/// and *what profile has macOS given it* (the last column). The row worth
/// catching is a board that presents no profile, so macOS has fallen back to a
/// generic one. Neither fact is discoverable in one place anywhere in System
/// Settings.
///
/// Nothing on it changes anything.
public struct ScreensPanel: View {
    let screens: ScreenSet
    let picture: ScreenKey?

    public init(screens: ScreenSet, picture: ScreenKey?) {
        self.screens = screens
        self.picture = picture
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.groupGap) {
            ForEach(screens.screens) { info in
                row(info)
            }
            Divider()
            Text(DisplayStrings.Screens.explain)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Metric.windowMargin)
        .frame(width: 420, alignment: .leading)
        .navigationTitle(DisplayStrings.Screens.title)
    }

    @ViewBuilder
    private func row(_ info: ScreenInfo) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            HStack(spacing: Tokens.Metric.relatedGap) {
                Text(info.name)
                    .font(.headline)
                if info.key == picture {
                    Text("← \(DisplayStrings.Screens.thePicture)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Text(DisplayStrings.Screens.line(points: points(info),
                                             scale: scale(info),
                                             real: real(info),
                                             profile: info.colorSpaceName ?? DisplayStrings.Screens.noProfile))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func points(_ i: ScreenInfo) -> String {
        "\(Int(i.frame.width.rounded())) × \(Int(i.frame.height.rounded())) pt"
    }

    private func scale(_ i: ScreenInfo) -> String {
        let tenths = Int((i.backingScale * 10).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10)×" : "\(Double(tenths) / 10)×"
    }

    private func real(_ i: ScreenInfo) -> String {
        let p = i.realPixels
        return "\(Int(p.width)) × \(Int(p.height))"
    }
}

#if canImport(AppKit)
/// A non-modal utility panel. It never blocks anything and it holds no state
/// worth remembering beyond its own frame.
@MainActor
public final class ScreensPanelController: NSWindowController {
    private weak var director: DisplayDirector?

    public init(director: DisplayDirector) {
        self.director = director
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = DisplayStrings.Screens.title
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.setFrameAutosaveName("displays.theseScreens")
        super.init(window: panel)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    public func rebuild() {
        guard let director else { return }
        let view = ScreensPanel(screens: director.screens.screens, picture: director.presence.key)
        window?.contentView = NSHostingView(rootView: view)
        window?.setContentSize(window?.contentView?.fittingSize ?? NSSize(width: 420, height: 280))
    }

    public func show() {
        rebuild()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
#endif

extension DisplayDirector {
    #if canImport(AppKit)
    /// Window ▸ These Screens…
    public func showScreensPanel() {
        if screensPanel == nil { screensPanel = ScreensPanelController(director: self) }
        screensPanel?.show()
    }
    #else
    public func showScreensPanel() {}
    #endif
}
