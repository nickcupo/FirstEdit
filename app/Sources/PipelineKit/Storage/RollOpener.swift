import Foundation

/// A packed burst opened from Finder: the frame he kept, unpacked whole and
/// checked, for Preview to show.
///
/// burstpack.py does the unpacking, as it does everywhere else: it refuses a
/// frame that does not match the checksum it was packed with. Only the kept
/// frame is unpacked (the file's manifest names it), into a folder of its own
/// under the temporary directory; a second open of the same file finds it
/// there. A .roll that iCloud has evicted is downloaded by the reading, which
/// is what opening it asks for.
public enum RollOpener {

    public enum Failure: LocalizedError, Equatable {
        case notAPackedBurst(String)
        case noEngine
        case unpack(String)

        public var errorDescription: String? {
            switch self {
            case .notAPackedBurst(let name): "\(name) is not a packed burst."
            case .noEngine: "The app's own Python is missing, so the burst cannot be unpacked."
            case .unpack(let why): why
            }
        }
    }

    /// The kept frame's name, from the head of the file only.
    public static func keeper(of roll: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: roll) else { return nil }
        defer { try? fh.close() }
        let magic = Data("FEBURST\u{01}".utf8)
        guard let head = try? fh.read(upToCount: magic.count + 8), head.count == magic.count + 8,
              head.prefix(magic.count) == magic else { return nil }
        var n = 0
        for (i, b) in head.suffix(8).enumerated() { n |= Int(b) << (8 * i) }
        guard n > 0, n <= 64 << 20, let json = try? fh.read(upToCount: n), json.count == n,
              let manifest = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        if let key = manifest["key"] as? String, !key.isEmpty, !key.contains("/") { return key }
        let frames = manifest["frames"] as? [[String: Any]] ?? []
        let whole = frames.first { $0["ref"] == nil || $0["ref"] is NSNull }
        return (whole?["name"] as? String).flatMap { $0.contains("/") ? nil : $0 }
    }

    /// Where the kept frame of `roll` is unpacked: a folder per file, named
    /// so that two shoots' burst-3.roll never meet.
    public static func folder(for roll: URL, under base: URL) -> URL {
        let shoot = roll.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let name = [shoot, roll.deletingPathExtension().lastPathComponent].filter { !$0.isEmpty }
            .joined(separator: " ")
        return base.appendingPathComponent(name, isDirectory: true)
    }

    public static var defaultBase: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Packed bursts", isDirectory: true)
    }

    /// The kept frame of `roll` as a RAW on disk, unpacked and checked, or
    /// the reason it is not.
    public static func unpackKeeper(_ roll: URL, launch: EngineLaunch?,
                                    under base: URL = defaultBase) async throws -> URL {
        guard let name = keeper(of: roll) else { throw Failure.notAPackedBurst(roll.lastPathComponent) }
        let dest = folder(for: roll, under: base)
        let raw = dest.appendingPathComponent(name)
        // Unpacked before, and checked then: burstpack only ever writes a
        // frame that matched, and never over a name already there.
        if let size = (try? raw.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 { return raw }
        guard let launch else { throw Failure.noEngine }
        let script = launch.resources.appendingPathComponent("pipeline/burstpack.py")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let said = try await run(launch.python, [script.path, "unpack", roll.path, dest.path, name])
        guard FileManager.default.fileExists(atPath: raw.path) else {
            let why = said.split(separator: "\n").last.map(String.init) ?? ""
            throw Failure.unpack(why.isEmpty ? "\(roll.lastPathComponent) could not be unpacked." : why)
        }
        return raw
    }

    /// The process's output, stdout and stderr together, once it has ended.
    private static func run(_ exe: URL, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { cont.resume(throwing: error); return }
            // Read as it runs, so a full pipe never holds it up.
            DispatchQueue.global(qos: .userInitiated).async {
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: String(decoding: out, as: UTF8.self))
            }
        }
    }
}
