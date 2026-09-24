import Foundation

/// Where the engine's interpreter and script are, and what it is run with.
public struct EngineLaunch: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        /// `Contents/Resources/python` inside a built app.
        case bundled
        /// A checkout with `.venv/` beside `pipeline/`, for `swift run`.
        case checkout
    }
    public var origin: Origin
    public var python: URL
    public var script: URL
    /// `Contents/Resources`, or the checkout's root.
    public var resources: URL

    public var arguments: [String] { [script.path, "--app", "--no-open", "--port", "0"] }

    /// The bundled interpreter first — that is the shipped app. Then, for a
    /// run from a checkout, the first directory at or above `start` holding
    /// `pipeline/studio.py`, with its `.venv`. `PIPELINE_PYTHON` and
    /// `PIPELINE_CHECKOUT` name both outright and win over either.
    public static func locate(bundle: Bundle, environment env: [String: String],
                              searchFrom starts: [URL]) -> EngineLaunch? {
        let fm = FileManager.default
        if let checkout = env["PIPELINE_CHECKOUT"].map({ URL(fileURLWithPath: $0) }) {
            let py = env["PIPELINE_PYTHON"].map { URL(fileURLWithPath: $0) }
                ?? checkout.appendingPathComponent(".venv/bin/python")
            return EngineLaunch(origin: .checkout, python: py,
                                script: checkout.appendingPathComponent("pipeline/studio.py"),
                                resources: checkout)
        }
        if let res = bundle.resourceURL {
            let py = res.appendingPathComponent("python/bin/python3.12")
            let script = res.appendingPathComponent("pipeline/studio.py")
            if fm.isExecutableFile(atPath: py.path), fm.fileExists(atPath: script.path) {
                return EngineLaunch(origin: .bundled, python: py, script: script, resources: res)
            }
        }
        for start in starts {
            var dir = start.standardizedFileURL
            for _ in 0..<12 {
                let script = dir.appendingPathComponent("pipeline/studio.py")
                if fm.fileExists(atPath: script.path) {
                    let py = env["PIPELINE_PYTHON"].map { URL(fileURLWithPath: $0) }
                        ?? dir.appendingPathComponent(".venv/bin/python")
                    if fm.isExecutableFile(atPath: py.path) {
                        return EngineLaunch(origin: .checkout, python: py, script: script, resources: dir)
                    }
                }
                let up = dir.deletingLastPathComponent()
                if up.path == dir.path { break }
                dir = up
            }
        }
        return nil
    }
}

/// Runs its closure the first time it is asked, and never again: the end of
/// a pipe can be read more than once.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first: Bool = lock.withLock {
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}

/// The child process, its pipes and its log. A class behind a lock rather
/// than actor state, because `applicationWillTerminate` has to stop it
/// synchronously — there is no awaiting anything once the app is going.
final class ServerProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var logHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var portContinuation: CheckedContinuation<Int, Error>?
    private var port: Int?
    private var lastLine = ""
    private var intentional = false
    private var key = ""
    /// Which launch is the current one. Counted, not taken from the
    /// `Process`'s address: a child's pipes and exit are reported up to two
    /// seconds after it has gone (`drainLimit`), and a restart inside that
    /// time can put the next `Process` at the address the last one freed, so
    /// the old child's exit would fail the new launch's wait for its port.
    private var launches = 0

    /// Called once per run when the child ends for any reason.
    var onExit: (@Sendable (_ status: Int32, _ intentional: Bool, _ lastLine: String) -> Void)?
    /// Called when the updater prints `QUIT`: an update is about to swap the app.
    var onQuit: (@Sendable () -> Void)?

    let logURL: URL

    init(logURL: URL) { self.logURL = logURL }

    var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }
    var pid: Int32? { lock.withLock { process?.isRunning == true ? process?.processIdentifier : nil } }
    var lastLogLine: String { lock.withLock { lastLine } }

    enum LaunchError: Error, Equatable {
        case couldNotRun(String)
        case exitedBeforePort(Int32, String)
        case noPort
    }

    /// Start the child and wait for its `PORT n` line.
    func launch(_ launch: EngineLaunch, environment: [String: String], key: String,
                timeout: Duration) async throws -> Int {
        openLog()
        let p = Process()
        p.executableURL = launch.python
        p.arguments = launch.arguments
        p.environment = environment
        p.currentDirectoryURL = URL(fileURLWithPath: environment["PIPELINE_SUPPORT"] ?? NSTemporaryDirectory())

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        let run: Int = lock.withLock {
            self.key = key
            self.intentional = false
            self.port = nil
            self.stdoutBuffer = Data()
            self.lastLine = ""
            self.process = p
            self.launches += 1
            return self.launches
        }

        // The exit and the last bytes on the two pipes arrive on three
        // different queues in no fixed order. Reported as they came, the
        // exit won often enough that the line under "First Edit's engine
        // stopped" was the one BEFORE the child's last word - "PORT 4244",
        // or nothing and "exit 1" - and two of the host's tests failed six
        // runs in fifteen under load. So the exit waits until both pipes have
        // been read to the end, and the last line is the last line.
        let drained = DispatchGroup()
        drained.enter()
        drained.enter()
        let outDone = Once(), errDone = Once()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else {
                h.readabilityHandler = nil
                outDone.run { drained.leave() }
                return
            }
            self?.received(d, fromStdout: true, run: run)
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else {
                h.readabilityHandler = nil
                errDone.run { drained.leave() }
                return
            }
            self?.received(d, fromStdout: false, run: run)
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let owner = self
            // Bounded: a grandchild that inherited a pipe and outlived the
            // engine - the updater, for one - must not hold the report back
            // for ever.
            DispatchQueue.global(qos: .userInitiated).async {
                _ = drained.wait(timeout: .now() + ServerProcess.drainLimit)
                owner?.ended(status, run: run)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
                lock.withLock { portContinuation = c }
                do {
                    try p.run()
                } catch {
                    finishPortWait(.failure(LaunchError.couldNotRun(error.localizedDescription)))
                    return
                }
                let deadline = timeout
                Task.detached { [weak self] in
                    try? await Task.sleep(for: deadline)
                    self?.finishPortWait(.failure(LaunchError.noPort))
                }
            }
        } onCancel: {
            finishPortWait(.failure(CancellationError()))
        }
    }

    private func finishPortWait(_ result: Result<Int, Error>) {
        let c: CheckedContinuation<Int, Error>? = lock.withLock {
            let c = portContinuation
            portContinuation = nil
            return c
        }
        c?.resume(with: result)
    }

    /// Whether `run` is the launch this object is running now, rather than
    /// one it has already replaced. Called under the lock.
    private func isCurrent(_ run: Int) -> Bool { run == launches }

    private func received(_ d: Data, fromStdout: Bool, run: Int) {
        let (key, current) = lock.withLock { (self.key, isCurrent(run)) }
        let text = String(decoding: d, as: UTF8.self)
        let clean = Log.redact(text, key: key)
        write(clean)
        // The last words of a child that was restarted are in the log, and
        // nowhere else: they are not the reason the new one stops, and a
        // PORT from the old one is not where the new one is listening.
        guard current else { return }
        // The last line worth SHOWING him, which is not the same as the last
        // line. `PORT 58518` and `QUIT` are how the app and the engine talk to
        // each other; either one racing ahead of a real message on the other
        // stream would put "PORT 58518" under "First Edit's engine
        // stopped", where the reason belongs. Measured: stdout and stderr
        // arrive on separate handlers and the order between them is not fixed,
        // so one run in three showed the handshake instead of the crash.
        if let last = clean.split(whereSeparator: \.isNewline).last(where: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !Self.isHandshake(t)
        }) {
            lock.withLock { lastLine = String(last) }
        }
        guard fromStdout else { return }

        // The updater's sentinel. Matched on a whole line so a shoot called
        // "QUIT" printed in some sentence can never close the app.
        if text.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "QUIT" }) {
            onQuit?()
        }

        let found: Int? = lock.withLock {
            guard port == nil else { return nil }
            stdoutBuffer.append(d)
            let s = String(decoding: stdoutBuffer, as: UTF8.self)
            guard let r = s.range(of: #"(?m)^PORT (\d+)\s*$"#, options: .regularExpression) else { return nil }
            let digits = s[r].dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let n = Int(digits), n > 0 else { return nil }
            port = n
            stdoutBuffer = Data()
            return n
        }
        if let found { finishPortWait(.success(found)) }
    }

    /// A line the two of them use to talk, not a line for him to read.
    static func isHandshake<S: StringProtocol>(_ line: S) -> Bool {
        if line == "QUIT" { return true }
        guard line.hasPrefix("PORT ") else { return false }
        let rest = line.dropFirst(5)
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }

    /// How long the exit waits for the pipes to be read to the end.
    static let drainLimit: DispatchTimeInterval = .seconds(2)

    private func ended(_ status: Int32, run: Int) {
        let (current, intentional, last) = lock.withLock { (isCurrent(run), self.intentional, self.lastLine) }
        write("\n[engine exited \(status)]\n")
        // Now that the exit waits for the pipes, a restart can launch the
        // next child before the last one's exit is reported. That exit is
        // not the new child's: it must neither end the new launch's wait for
        // its port nor be taken for a crash of the engine that is running.
        guard current else { return }
        finishPortWait(.failure(LaunchError.exitedBeforePort(status, last)))
        onExit?(status, intentional, last)
    }

    /// SIGTERM, then up to three seconds, then SIGKILL — exactly as today.
    /// Synchronous on purpose: `applicationWillTerminate` calls it.
    func terminate(grace: TimeInterval = 3) {
        let p: Process? = lock.withLock {
            intentional = true
            return process
        }
        guard let p, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit()
    }

    // MARK: the log

    private func openLog() {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? fm.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > Log.maximumBytes {
            try? fm.removeItem(at: logURL)
        }
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: logURL)
        _ = try? h?.seekToEnd()
        lock.withLock {
            try? logHandle?.close()
            logHandle = h
        }
    }

    private func write(_ text: String) {
        let h = lock.withLock { logHandle }
        try? h?.write(contentsOf: Data(text.utf8))
    }
}
