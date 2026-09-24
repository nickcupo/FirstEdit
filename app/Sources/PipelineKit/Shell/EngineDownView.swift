import SwiftUI
import AppKit

/// The engine is not running. Said plainly, in the window, with the two
/// things he can do about it — never a modal alert, never a traceback.
///
/// Restarting happens in place: which shoot he was on is the window's state,
/// and it survives.
public struct EngineDownView: View {
    public let reason: String
    public let logURL: URL?
    public let restart: () -> Void

    public init(reason: String, logURL: URL?, restart: @escaping () -> Void) {
        self.reason = reason
        self.logURL = logURL
        self.restart = restart
    }

    public var body: some View {
        // The reason as it came is read into a sentence of his, what would
        // fix it, and the engine's own words behind Details (EngineFailure).
        let failure = EngineFailure(reason: reason)
        ContentUnavailableView {
            Label(Strings.Engine.stoppedTitle, systemImage: Symbols.engineDown)
        } description: {
            VStack(spacing: Tokens.Metric.relatedGap) {
                if let sentence = failure.sentence {
                    Text(sentence)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if failure.restartHelps {
                    Text(Strings.Engine.nothingLost)
                    // What to do next, where starting again can help.
                    Text(Strings.EngineDown.whatToDo)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = failure.detail {
                    DisclosureGroup(Strings.Engine.details) {
                        Text(detail)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: 420)
                }
            }
        } actions: {
            HStack(spacing: Tokens.Metric.relatedGap) {
                // Restart is the way out only where starting again can help;
                // where a part of the app is missing it fails the same way
                // every time, so it is offered, not pressed for him by Return.
                if failure.restartHelps {
                    Button(Strings.Engine.restart, action: restart)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(Strings.Engine.restart, action: restart)
                        .buttonStyle(.bordered)
                }
                if let logURL {
                    // The file selected in Finder, as Settings' Show the Log
                    // does: it is what he attaches to a report.
                    Button(Strings.Engine.showLog) { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .accessibilityIdentifier("engine.down")
    }
}

/// While the engine comes up: a small ring and one word, in the detail pane.
struct EngineStartingView: View {
    var body: some View {
        VStack(spacing: Tokens.Metric.relatedGap) {
            ProgressView().controlSize(.small)
            Text(Strings.Engine.starting).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("engine.starting")
    }
}
