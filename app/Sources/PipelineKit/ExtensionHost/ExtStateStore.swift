import Foundation

/// Where `pipeline.state` keeps what a page remembers, per shoot.
///
/// It replaces the `localStorage` an extension's pages used before, for one
/// reason that matters: the custom scheme's origin is the host's, so what one
/// page wrote is not reliably there for the next, and nothing under a web
/// view's own storage survives the app being reinstalled. This does, it is
/// scoped to a shoot the way the page's choices are, and it is the app's to
/// clear when a shoot goes.
///
/// It holds only what a page chose to put in it. **Nothing of his — no
/// verdict, no count, no decision — is ever written here**: his are the
/// engine's files, and a second copy of them somewhere else is a second
/// answer to a question that may only have one.
public final class ExtStateStore: @unchecked Sendable {
    public static let shared = ExtStateStore()

    private let defaults: UserDefaults
    /// One key, so everything a page kept can be found and let go together.
    public static let prefix = "extension.state."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func get(shoot: String, key: String) -> String? {
        defaults.string(forKey: Self.key(shoot: shoot, key: key))
    }

    public func set(shoot: String, key: String, value: String?) {
        let k = Self.key(shoot: shoot, key: key)
        if let value {
            defaults.set(value, forKey: k)
        } else {
            defaults.removeObject(forKey: k)
        }
    }

    /// Everything one shoot's pages kept, let go at once.
    public func clear(shoot: String) {
        let head = Self.prefix + Self.escape(shoot) + "."
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(head) {
            defaults.removeObject(forKey: k)
        }
    }

    /// The shoot name and the page's own key both go in whole, so two shoots
    /// whose names differ only by a dot cannot read each other's answers.
    static func key(shoot: String, key: String) -> String {
        prefix + escape(shoot) + "." + escape(key)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: ".", with: "%2E")
    }
}
