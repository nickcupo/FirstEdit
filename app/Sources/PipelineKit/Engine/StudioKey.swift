import Foundation
import Security

/// The per-launch key.
///
/// 32 bytes from `SecRandomCopyBytes`, base64url. It is handed to the child in
/// `PIPELINE_STUDIO_KEY` and sent as `X-Studio-Key` on every request, images
/// included. It is never written to disk, never put in a URL and never logged:
/// `Log.redact` strips it out of any text the app captures.
public enum StudioKey {
    public static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // SecRandomCopyBytes does not fail on a working Mac. If it ever
            // did, a key from the system generator is still unguessable; a
            // fixed or empty one would not be.
            var g = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &g) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The engine's log, and the one place captured text is cleaned before it is
/// kept anywhere.
public enum Log {
    /// Every occurrence of the key becomes `‹key›`. Applied to every line the
    /// child prints before it reaches the log file, the Activity window or a
    /// refusal's Details.
    public static func redact(_ text: String, key: String) -> String {
        guard !key.isEmpty else { return text }
        return text.replacingOccurrences(of: key, with: "‹key›")
    }

    /// Kept to about 2 MB, as today: over that, the next launch starts a fresh
    /// file rather than growing one nobody will scroll.
    public static let maximumBytes = 2_000_000
}
