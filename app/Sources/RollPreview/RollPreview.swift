import Foundation
import ImageIO

/// The camera's own preview of the frame a packed burst (`.roll`) was built
/// around, read without unpacking a RAW.
///
/// A `.roll` is burstpack's format (pipeline/burstpack.py, docs/BURSTPACK.md):
///
///     "FEBURST\x01"  u64 LE n  n bytes of JSON  then each frame's bytes
///
/// The JSON names the kept frame ("key") and, for each frame, where its bytes
/// are ("at", "length", from the end of the JSON) and how they were stored
/// ("codec"). A "craw" frame is two parts, each a u64 LE length and its bytes:
/// everything in the ARW but the sensor data, xz-compressed, and the sensor
/// data, which is what is expensive to decode and is not needed here. The
/// camera's JPEG is in the first part. An "lzma" frame is the whole file, xz.
///
/// Only the head of the file and the kept frame are read. Everything is
/// bounds-checked: a damaged or foreign file gives nil, never a crash, because
/// this runs inside Finder's thumbnailer on whatever file it is handed.
public enum RollPreview {

    public struct Preview: Equatable, Sendable {
        /// The JPEG, as the camera wrote it.
        public let jpeg: Data
        /// The ARW's TIFF Orientation (1 upright, 3 upside down, 6 turn
        /// clockwise, 8 turn anticlockwise). The camera's preview is stored
        /// as the sensor saw it and carries none of its own.
        public let orientation: Int
        /// The kept frame's file name, e.g. "DSC01234.ARW".
        public let frame: String
    }

    public static let magic = Data("FEBURST\u{01}".utf8)

    /// The kept frame's picture for `url`: the one the file carries beside
    /// its icon (already upright, read without the file's contents, so it
    /// never downloads one iCloud has evicted), else the camera's preview
    /// read from the file itself.
    public static func picture(at url: URL) -> Preview? {
        if let jpg = RollOpener.storedPicture(of: url) {
            return Preview(jpeg: jpg, orientation: 1, frame: "")
        }
        return RollOpener.isDataless(url) ? nil : keeper(at: url)
    }

    /// The kept frame's preview in the `.roll` at `url`, or nil.
    public static func keeper(at url: URL) -> Preview? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        return keeper { offset, count in
            guard (try? fh.seek(toOffset: UInt64(offset))) != nil else { return nil }
            return try? fh.read(upToCount: count)
        }
    }

    /// The same, from a whole `.roll` in memory.
    public static func keeper(in data: Data) -> Preview? {
        let d = data.withUnsafeBytes { Data($0) }     // indices from zero, whatever slice was passed
        return keeper { offset, count in
            guard offset >= 0, count >= 0, offset <= d.count else { return nil }
            return d.subdata(in: offset..<min(d.count, offset + count))
        }
    }

    // MARK: - the container

    private static let maxManifest = 64 << 20
    private static let maxFrame = 1 << 30

    private static func keeper(read: (Int, Int) -> Data?) -> Preview? {
        guard let head = read(0, magic.count + 8), head.count == magic.count + 8,
              head.prefix(magic.count) == magic else { return nil }
        let n = Int(clamping: u64(head, magic.count, little: true))
        guard n > 0, n <= maxManifest, let json = read(magic.count + 8, n), json.count == n,
              let manifest = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let frames = manifest["frames"] as? [[String: Any]] else { return nil }
        let base = magic.count + 8 + n

        let key = manifest["key"] as? String
        guard let frame = frames.first(where: { key != nil && ($0["name"] as? String) == key })
                ?? frames.first(where: { $0["ref"] == nil || $0["ref"] is NSNull }),
              let name = frame["name"] as? String,
              let at = int(frame["at"]), let length = int(frame["length"]),
              at >= 0, length > 0, length <= maxFrame,
              let blob = read(base + at, length), blob.count == length else { return nil }

        // The file as it was, minus its sensor data, and where that data sat.
        let file: Data
        var hole = 0..<0
        switch frame["codec"] as? String {
        case "craw":
            guard let parts = unblob(blob), let env = parts.first, let rest = xz(env),
                  let offset = int(frame["offset"]), let h = int(frame["H"]), let w = int(frame["W"]),
                  offset >= 0, offset <= rest.count, h > 0, w > 0 else { return nil }
            file = rest
            hole = offset..<(offset + h * w)
        case "lzma":
            guard let whole = xz(blob) else { return nil }
            file = whole
        default:
            return nil
        }
        return preview(in: TIFFView(file: file, hole: hole), frame: name)
    }

    /// burstpack's `_blob`: parts, each a u64 LE length then its bytes.
    static func unblob(_ b: Data) -> [Data]? {
        var out: [Data] = []
        var i = 0
        while i < b.count {
            guard i + 8 <= b.count else { return nil }
            let n = Int(clamping: u64(b, i, little: true))
            guard n >= 0, n <= b.count - i - 8 else { return nil }
            out.append(b.subdata(in: (i + 8)..<(i + 8 + n)))
            i += 8 + n
        }
        return out
    }

    /// An xz stream (Python's lzma.compress), decoded.
    static func xz(_ d: Data) -> Data? {
        try? (d as NSData).decompressed(using: .lzma) as Data
    }

    // MARK: - the ARW

    /// Offsets as the original ARW has them, over a copy that lacks the
    /// sensor data: an offset past the hole is that much earlier here, and
    /// one inside it is not here at all.
    struct TIFFView {
        let file: Data
        let hole: Range<Int>

        func bytes(_ offset: Int, _ count: Int) -> Data? {
            guard offset >= 0, count >= 0 else { return nil }
            let end = offset + count
            let at: Int
            if end <= hole.lowerBound || hole.isEmpty {
                at = offset
            } else if offset >= hole.upperBound {
                at = offset - hole.count
            } else {
                return nil
            }
            guard at + count <= file.count else { return nil }
            return file.subdata(in: at..<(at + count))
        }
    }

    /// The largest JPEG the ARW's IFD0 and IFD1 point at (Sony keeps its
    /// 1616 px preview behind JPEGInterchangeFormat), with IFD0's
    /// Orientation. Where no tag points at one, the largest JPEG found in
    /// the file that ImageIO can read.
    static func preview(in t: TIFFView, frame: String) -> Preview? {
        guard let hdr = t.bytes(0, 8) else { return nil }
        let little: Bool
        switch (hdr[0], hdr[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        var orientation = 1
        var best: Data?
        var ifd = Int(u32(hdr, 4, little: little))
        var seen = Set<Int>()
        for depth in 0..<4 {
            guard ifd > 0, !seen.contains(ifd), let cnt = t.bytes(ifd, 2) else { break }
            seen.insert(ifd)
            let n = Int(u16(cnt, 0, little: little))
            guard n > 0, n < 1024, let entries = t.bytes(ifd + 2, 12 * n + 4) else { break }
            var jpegAt: Int?, jpegLen: Int?
            for i in 0..<n {
                let e = 12 * i
                let tag = u16(entries, e, little: little)
                let type = u16(entries, e + 2, little: little)
                let value: Int = type == 3 ? Int(u16(entries, e + 8, little: little))
                                           : Int(u32(entries, e + 8, little: little))
                switch tag {
                case 0x0112 where depth == 0: orientation = value
                case 0x0201: jpegAt = value
                case 0x0202: jpegLen = value
                default: break
                }
            }
            if let at = jpegAt, let len = jpegLen, len > 0, len <= maxFrame,
               let j = t.bytes(at, len), j.starts(with: [0xFF, 0xD8]), j.count > (best?.count ?? 0) {
                best = j
            }
            ifd = Int(u32(entries, 12 * n, little: little))
        }
        if best == nil { best = largestJPEG(in: t.file) }
        guard let jpeg = best else { return nil }
        return Preview(jpeg: jpeg, orientation: [1, 3, 6, 8].contains(orientation) ? orientation : 1, frame: frame)
    }

    /// Every JPEG start in the file, tried: the one ImageIO reads widest.
    static func largestJPEG(in d: Data) -> Data? {
        var best: (width: Int, data: Data)?
        var i = d.startIndex
        var tried = 0
        while tried < 32, let r = d.range(of: Data([0xFF, 0xD8, 0xFF]), in: i..<d.endIndex) {
            tried += 1
            let slice = d.subdata(in: r.lowerBound..<d.endIndex)
            if let src = CGImageSourceCreateWithData(slice as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int, w > (best?.width ?? 0) {
                best = (w, slice)
            }
            i = r.upperBound
        }
        return best?.data
    }

    // MARK: - numbers

    private static func int(_ v: Any?) -> Int? {
        (v as? NSNumber).map { $0.intValue }
    }

    static func u16(_ d: Data, _ i: Int, little: Bool) -> UInt16 {
        guard i >= 0, i + 2 <= d.count else { return 0 }
        let a = UInt16(d[d.startIndex + i]), b = UInt16(d[d.startIndex + i + 1])
        return little ? a | b << 8 : a << 8 | b
    }

    static func u32(_ d: Data, _ i: Int, little: Bool) -> UInt32 {
        let a = UInt32(u16(d, i, little: little)), b = UInt32(u16(d, i + 2, little: little))
        return little ? a | b << 16 : a << 16 | b
    }

    static func u64(_ d: Data, _ i: Int, little: Bool) -> UInt64 {
        let a = UInt64(u32(d, i, little: little)), b = UInt64(u32(d, i + 4, little: little))
        return little ? a | b << 32 : a << 32 | b
    }
}
