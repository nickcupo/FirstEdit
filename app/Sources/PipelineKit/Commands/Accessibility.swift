import SwiftUI
import AppKit

// DESIGN.md §2.15, for the whole app rather than for one screen.
//
// Increase Contrast thickens the things a verdict is read from. Reduce
// Transparency swaps every material for something opaque. Colour is never the
// only signal. And a frame says the same sentence to VoiceOver that the
// design writes down, so a photographer who cannot see the badge still knows
// whose mark is on the picture.

@MainActor
public enum A11y {
    /// Read live, so turning any of these on mid-session takes effect at once.
    public static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
    public static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
    public static var differentiateWithoutColor: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
    }
    public static var voiceOverRunning: Bool {
        NSWorkspace.shared.isVoiceOverEnabled
    }

    /// The verdict badges, the current-frame ring and the stack bracket go to
    /// 3 pt under Increase Contrast, from whatever they are normally.
    public static let emphasised: CGFloat = 3

    public static func stroke(_ normal: CGFloat) -> CGFloat {
        increaseContrast ? max(normal, emphasised) : normal
    }

    /// Control bars and cards take a 1 pt border they otherwise do not have,
    /// so the edge of a region is a line rather than a shade.
    public static var border: CGFloat { increaseContrast ? 1 : 0 }
}

/// Forces Increase Contrast on inside one view tree.
///
/// The app reads the real system setting and nothing else. This exists so the
/// snapshot harness can show what Increase Contrast looks like without asking
/// whoever is looking at the picture to change their Mac's settings.
private struct IncreaseContrastOverride: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    public var increaseContrastOverride: Bool? {
        get { self[IncreaseContrastOverride.self] }
        set { self[IncreaseContrastOverride.self] = newValue }
    }
}

extension View {
    /// A 1 pt border around a grouped region, under Increase Contrast only.
    public func contrastBorder(cornerRadius: CGFloat = 10) -> some View {
        modifier(ContrastBorder(cornerRadius: cornerRadius))
    }

    /// Draws this tree as it would look with Increase Contrast turned on.
    public func forcingIncreaseContrast(_ on: Bool = true) -> some View {
        environment(\.increaseContrastOverride, on)
    }
}

/// Whether the thing being drawn should be drawn for Increase Contrast: the
/// system setting, the SwiftUI environment, or the harness's override.
public struct ContrastReader<Content: View>: View {
    @Environment(\.increaseContrastOverride) private var override
    @Environment(\.colorSchemeContrast) private var contrast
    private let content: (Bool) -> Content

    public init(@ViewBuilder content: @escaping (Bool) -> Content) { self.content = content }

    public var body: some View {
        content(override ?? (contrast == .increased || A11y.increaseContrast))
    }
}

struct ContrastBorder: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        ContrastReader { increased in
            content.overlay {
                if increased {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
                }
            }
        }
    }
}

// MARK: - what VoiceOver says about a photograph

/// The cull's guess in words, never as a number and never as a press he did
/// not make.
@MainActor
public enum SpokenVerdict {
    /// "clear win — only frame" · "maybe" · "set aside" ·
    /// "a fault it can name — blur".
    public static func cull(_ row: Row) -> String {
        let reason = (row.reason ?? "").trimmingCharacters(in: .whitespaces)
        if row.rating >= 5 {
            return reason.isEmpty ? Machine.clearWin : "\(Machine.clearWin) — \(reason)"
        }
        if row.rating >= VerdictValue.inThreshold {
            return reason.isEmpty ? Machine.maybe : "\(Machine.maybe), \(reason)"
        }
        if !row.label.isEmpty {
            return "\(Machine.namedFault) — \(row.label)"
        }
        return reason.isEmpty ? Machine.setAside : "\(Machine.setAside), \(reason)"
    }

    /// His own verdict, read only from his own field.
    public static func his(_ row: Row) -> String {
        switch VerdictValue.his(row) {
        case .kept: return Words.Spoken.youKept
        case .out: return Words.Spoken.youPutOut
        case .unmarked: return Words.Spoken.unmarked
        }
    }

    public enum Machine {
        public static var clearWin: String {
            Bundle.main.localizedString(forKey: "cull.clearWin", value: "clear win", table: nil)
        }
        public static var maybe: String {
            Bundle.main.localizedString(forKey: "cull.maybe", value: "maybe", table: nil)
        }
        public static var setAside: String {
            Bundle.main.localizedString(forKey: "cull.setAside", value: "set aside", table: nil)
        }
        public static var namedFault: String {
            Bundle.main.localizedString(forKey: "cull.namedFault", value: "a fault it can name", table: nil)
        }
    }
}

/// The sentence a frame gives VoiceOver, exactly as DESIGN.md §2.15 writes it:
///
/// > Frame 04330, 2 of 7 in burst 3. You kept it. The cull's guess: maybe, the
/// > face is softer than most frames here. In a stack of 4 similar frames.
@MainActor
public enum Announcements {
    public static func frame(_ row: Row, position: Int, of total: Int, burst: Int,
                             stackCount: Int? = nil) -> String {
        var parts: [String] = [
            "\(Words.Spoken.frame(ShootSession.shortStem(row.stem))), "
                + Words.Spoken.positionInBurst(position, total, burst) + ".",
            SpokenVerdict.his(row),
            Words.Spoken.cullGuess(SpokenVerdict.cull(row)) + ".",
        ]
        if let stackCount, stackCount > 1 { parts.append(Words.Spoken.inStack(stackCount)) }
        return parts.joined(separator: " ")
    }

    /// The four things he can do to a frame without leaving it, offered as
    /// VoiceOver custom actions.
    public static var frameActions: [(name: String, command: CommandID)] {
        [
            (Words.Spoken.keep, CommandTable.ID.keep),
            (Words.Spoken.drop, CommandTable.ID.drop),
            (Words.Spoken.clearMark, CommandTable.ID.clearMark),
            (Words.Spoken.compare, CommandTable.ID.compare),
        ]
    }
}

/// Progress is announced at the start and the finish only, politely. A bar
/// that speaks every percent is a bar nobody can work beside.
@MainActor
public final class Announcer {
    public static let shared = Announcer()

    /// §2.15 asks for polite. `.low` is the level AppKit documents as the one
    /// that does not interrupt what VoiceOver is already saying — a job that
    /// finishes should never cut across him reading a frame.
    public static let priority = NSAccessibilityPriorityLevel.low

    /// What is posted for one sentence. Public so the rule above is checkable
    /// without a running VoiceOver.
    public static func announcement(_ text: String) -> [NSAccessibility.NotificationUserInfoKey: Any] {
        [.announcement: text, .priority: priority.rawValue]
    }

    /// Injected for the test.
    var speak: (String) -> Void = { text in
        NSAccessibility.post(element: NSApplication.shared,
                             notification: .announcementRequested,
                             userInfo: Announcer.announcement(text))
    }

    /// The job being followed, by identity rather than by name: two culls
    /// of two shoots back to back are both "Cull".
    private var running: String?

    public func jobChanged(_ job: Job?) {
        guard let job, !job.kind.isEmpty else { running = nil; return }
        let what = JobWords.what(job)
        let key = "\(job.id).\(job.kind).\(job.shoot)"
        if job.running {
            guard running != key else { return }
            running = key
            speak(Words.Spoken.jobStarted(what))
        } else if running != nil {
            running = nil
            speak(Self.ended(job, what))
        }
    }

    /// How it ended, in the same words as the notification: a cull that
    /// crashed is never announced as finished.
    static func ended(_ job: Job, _ what: String) -> String {
        switch job.outcome {
        case .failed: return Words.Notify.failed(what)
        case .stopped: return Words.Notify.stopped(what)
        case .refused: return Words.Notify.refused(what)
        default: return Words.Spoken.jobFinished(what)
        }
    }
}
