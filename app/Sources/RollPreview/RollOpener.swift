import Darwin
import Foundation

/// A packed burst opened from Finder: the frame he kept, for Preview.
///
/// Opening one never downloads it. A .roll that is on this Mac gives its kept
/// frame whole: burstpack.py unpacks that one frame, and refuses it unless it
/// matches the checksum it was packed with. A .roll that iCloud has evicted
/// gives the picture it carries beside its icon (pipeline/rollicon.py): the
/// camera's own preview of that frame, upright, read from the file's extended
/// attributes, which stay on this Mac when its contents do not.
public enum RollOpener {

    public enum Failure: LocalizedError, Equatable {
        case notAPackedBurst(String)
        case noPicture(String)
        case noEngine
        case unpack(String)

        public var errorDescription: String? {
            switch self {
            case .notAPackedBurst(let name): "\(name) is not a packed burst."
            case .noPicture(let name):
                "\(name) is only in iCloud, and carries no picture of its own to show without downloading it."
            case .noEngine: "FirstEdit's own Python is missing, so the burst cannot be unpacked."
            case .unpack(let why): why
            }
        }
    }

    /// The extended attribute rollicon.py keeps the upright picture in.
    public static let pictureAttribute = "com.nickcupo.firstedit.keeper#S"

    /// Whether the file's contents are somewhere else (iCloud has evicted it):
    /// reading them would download it.
    public static func isDataless(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return st.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// The picture the file carries, read without its contents.
    public static func storedPicture(of url: URL) -> Data? {
        let n = getxattr(url.path, pictureAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard n > 0 else { return nil }
        var data = Data(count: n)
        let got = data.withUnsafeMutableBytes { getxattr(url.path, pictureAttribute, $0.baseAddress, n, 0, XATTR_NOFOLLOW) }
        guard got == n, data.starts(with: [0xFF, 0xD8]) else { return nil }
        return data
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

    /// Where `roll`'s kept frame goes: a folder per file, named so that two
    /// shoots' burst-3.roll never meet.
    public static func folder(for roll: URL, under base: URL) -> URL {
        let shoot = roll.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let name = [shoot, roll.deletingPathExtension().lastPathComponent].filter { !$0.isEmpty }
            .joined(separator: " ")
        return base.appendingPathComponent(name, isDirectory: true)
    }

    public static var defaultBase: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Packed bursts", isDirectory: true)
    }

    /// What to show for `roll`, on disk: its kept frame's RAW when the file
    /// is here, its stored picture when it is not. `python` and `burstpack`
    /// are FirstEdit's own; nil when they are not there.
    public static func openable(_ roll: URL, python: URL?, burstpack: URL?,
                                under base: URL = defaultBase) async throws -> URL {
        let dest = folder(for: roll, under: base)
        if isDataless(roll) {
            guard let jpg = storedPicture(of: roll) else { throw Failure.noPicture(roll.lastPathComponent) }
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let out = dest.appendingPathComponent(roll.deletingPathExtension().lastPathComponent + ".jpg")
            try jpg.write(to: out, options: .atomic)
            return out
        }
        guard let name = keeper(of: roll) else { throw Failure.notAPackedBurst(roll.lastPathComponent) }
        let raw = dest.appendingPathComponent(name)
        // Unpacked before, and checked then: burstpack only ever writes a
        // frame that matched, and never over a name already there.
        if let size = (try? raw.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 { return raw }
        guard let python, let burstpack else { throw Failure.noEngine }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let said = try await run(python, [burstpack.path, "unpack", roll.path, dest.path, name])
        guard FileManager.default.fileExists(atPath: raw.path) else {
            let why = said.split(separator: "\n").last.map(String.init) ?? ""
            throw Failure.unpack(why.isEmpty ? "\(roll.lastPathComponent) could not be unpacked." : why)
        }
        return raw
    }

    /// The process's output, stdout and stderr together, once it has ended.
    private static func run(_ exe: URL, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { cont.resume(throwing: error); return }
            let reader = pipe.fileHandleForReading
            // Read as it runs, so a full pipe never holds it up.
            DispatchQueue.global(qos: .userInitiated).async {
                let out = reader.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: String(decoding: out, as: UTF8.self))
            }
        }
    }
}
