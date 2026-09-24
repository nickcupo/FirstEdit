import Foundation

/// Release smoke must not read or change the installed app's preferences.
/// Other entry points retain the normal persistent store.
public enum AppDefaults {
    nonisolated(unsafe) public static let current: UserDefaults = CommandLine.arguments.contains("--smoke-offscreen")
        ? SmokeDefaults(memoryOnly: ()) : .standard
}

private final class SmokeDefaults: UserDefaults {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init(memoryOnly: Void) { super.init(suiteName: "first-edit.smoke.\(UUID().uuidString)")! }
    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func dictionaryRepresentation() -> [String: Any] { lock.withLock { values } }
    override func set(_ value: Any?, forKey key: String) {
        lock.withLock { values[key] = value }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }
    override func removeObject(forKey key: String) { set(nil as Any?, forKey: key) }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    override func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    override func float(forKey key: String) -> Float { (object(forKey: key) as? NSNumber)?.floatValue ?? 0 }
    override func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    override func url(forKey key: String) -> URL? { object(forKey: key) as? URL }
    override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: URL?, forKey key: String) { set(value as Any?, forKey: key) }
}
