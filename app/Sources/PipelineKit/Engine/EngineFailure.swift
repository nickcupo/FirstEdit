import Foundation

/// Why the engine is down, as he reads it: one sentence in his words, what
/// would fix it, and the engine's own last line kept behind Details.
///
/// `EngineHost.State.failed` carries the reason as it came - the last line
/// of the log, or one of the host's own sentences - and this reads it. It
/// used to be printed as it came, in code font, under the title: "Traceback
/// (most recent call last): … ModuleNotFoundError: No module named 'cv2'",
/// over a prominent Restart the Engine that fails the same way every time.
public struct EngineFailure: Equatable, Sendable {
    /// The sentence under the title, in the body font, or `nil` when the
    /// title and "Nothing you marked is lost" already say all there is.
    public let sentence: String?
    /// The engine's own words, for the Details disclosure. `nil` when the
    /// sentence is all there is.
    public let detail: String?
    /// Whether starting it again can help. A part of the app that is not
    /// there is not there the second time either: the way out is to put it
    /// back, and Restart is offered as the lesser choice.
    public let restartHelps: Bool

    public init(reason: String) {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isMissingPart(r) {
            sentence = Strings.Engine.missingPart
            // The host's own sentence is replaced by this one; what it said
            // after it - the system's reason - is the detail.
            let rest = r.hasPrefix(Strings.Engine.couldNotStart)
                ? String(r.dropFirst(Strings.Engine.couldNotStart.count)).trimmingCharacters(in: .whitespaces)
                : r
            detail = rest.isEmpty ? nil : rest
            restartHelps = false
        } else if r.isEmpty || r == Strings.Engine.stopped {
            sentence = nil
            detail = nil
            restartHelps = true
        } else if Self.isOurs(r) {
            sentence = r
            detail = nil
            restartHelps = true
        } else {
            sentence = Strings.Engine.stoppedOnAnError
            detail = r
            restartHelps = true
        }
    }

    /// Nothing to start, or a module the bundled Python does not have. Both
    /// mean the app on disk is not whole.
    static func isMissingPart(_ r: String) -> Bool {
        r.hasPrefix(Strings.Engine.couldNotStart)
            || r.contains("ModuleNotFoundError")
            || r.contains("No module named")
            || (r.hasPrefix("ImportError") && !r.contains("circular import"))
    }

    /// One of the host's own sentences, which are already his words.
    static func isOurs(_ r: String) -> Bool {
        r == Strings.Engine.noPort
            || r.hasPrefix(Strings.Engine.exited(0).components(separatedBy: "(").first ?? "\u{0}")
    }
}

extension Strings.Engine {
    private static func e(_ key: String, _ value: String, _ comment: String) -> String {
        Bundle.main.localizedString(forKey: key, value: value, table: nil)
    }

    public static var missingPart: String {
        e("engine.missingPart",
          "Part of FirstEdit is missing. Install it again from the disk image — your photographs and decisions are untouched.",
          "Under the engine-down title, when the bundled Python or one of its parts is not there. Restarting cannot fix it.")
    }
    public static var stoppedOnAnError: String {
        e("engine.stoppedOnAnError",
          "It stopped on an error of its own.",
          "Under the engine-down title, when the engine's last words were an error of its own.")
    }
    public static var details: String {
        e("engine.details", "Details", "Discloses the engine's own last line in the engine-down view.")
    }
}
