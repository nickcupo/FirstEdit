import Foundation

// The Mac stays awake while a cull runs (NAT-06).
//
// `beginActivity` is held for exactly the life of the job and released the
// instant it ends — not at quit, not by a timer. The display may sleep; the
// work does not. An assertion left behind is a Mac that never sleeps again,
// so this object owns exactly one and gives it up in `deinit` as well.

public final class ActivityAssertion: @unchecked Sendable {
    public static let reason = "First Edit job running"

    private let lock = NSLock()
    private var token: NSObjectProtocol?
    private let begin: (String) -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void

    public init() {
        begin = { reason in
            ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
        }
        end = { ProcessInfo.processInfo.endActivity($0) }
    }

    /// For the test that asserts the token is taken once and given back once.
    init(begin: @escaping (String) -> NSObjectProtocol, end: @escaping (NSObjectProtocol) -> Void) {
        self.begin = begin
        self.end = end
    }

    public var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return token != nil
    }

    /// Held from the first poll that says a job runs to the first that says it
    /// does not. Asking twice changes nothing.
    public func hold() {
        lock.lock(); defer { lock.unlock() }
        guard token == nil else { return }
        token = begin(Self.reason)
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard let t = token else { return }
        token = nil
        end(t)
    }

    /// The one call a job poll makes.
    public func follow(_ job: Job?) {
        if job?.running == true { hold() } else { release() }
    }

    deinit {
        if let t = token { end(t) }
    }
}
