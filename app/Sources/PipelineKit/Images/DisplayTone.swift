import Foundation
import CoreGraphics
import Accelerate

/// The RAW decode, shown at the camera's brightness (DESIGN.md §3.5).
///
/// `/full` and `/crop` are the engine's RAW decode, made with the camera's
/// white balance and **no brightening at all**, because the cull reads faces
/// and focus on exactly those pixels. On his 2026-09-19 night that decode's
/// mean brightness was 0.56–0.66 of the camera's own JPEG, frame after frame.
/// The thumbnail and `/large` are that JPEG, so every frame appeared at the
/// camera's brightness and then went about 40 % darker, with more contrast, a
/// moment later when the sharp version landed — and the filmstrip beside it
/// never did. He calls exposure (reason 5) on that picture.
///
/// So the app, and only the app, puts the sharp picture back at the camera's
/// brightness before it is drawn: a tone curve per frame, measured by laying
/// the decode's brightness distribution over the camera JPEG's, and applied
/// the same to red, green and blue so the decode's own colour is kept. It is a
/// curve and not a single gain because the camera's JPEG is a curve: a gain
/// that matched the average blew out 1.9 × as many highlights as the JPEG
/// shows. Measured on sixteen frames of that night against the camera's
/// 1440 px JPEG, the curve puts the average within 1.9 levels (of 255) of
/// the JPEG's, the blown highlights within 0.75 % of the frame, and each
/// pixel on average 3.6–9.7 levels from the JPEG's, against 26–44 for the
/// decode as it comes.
///
/// Nothing on the engine's side changes. `cull/decoded` stays exactly as the
/// cull reads it, and every number the cull wrote — its exposure reading
/// included — is the same; this is how the pixels are drawn on his screen.
public enum DisplayTone {

    /// One frame's curve: level in, level out, the same for red, green and blue.
    public struct Curve: Sendable, Equatable {
        public let table: [UInt8]

        public init(table: [UInt8]) {
            precondition(table.count == 256)
            self.table = table
        }

        public static let identity = Curve(table: (0...255).map { UInt8($0) })

        /// Near enough to leave the picture as it is: a `/full` the engine
        /// served from the camera's own preview, say, which is already the
        /// JPEG's brightness. Two levels is below what a JPEG round trip moves.
        public var leavesItAlone: Bool {
            table.enumerated().allSatisfy { abs(Int($0.element) - $0.offset) <= 2 }
        }

        /// What the curve does to one level.
        public func callAsFunction(_ level: Int) -> Int { Int(table[min(255, max(0, level))]) }
    }

    /// Where the two distributions are laid over each other: every step from
    /// the deepest half percent to the brightest, closer together at the ends
    /// where the camera's curve bends most.
    static let quantiles: [Double] = [0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.3, 0.4, 0.5,
                                      0.6, 0.7, 0.8, 0.9, 0.95, 0.98, 0.99, 0.995]

    /// Both pictures are measured at this long edge: the thumbnail is 640 px,
    /// and the distribution of a 4096 px decode is the distribution of its
    /// 256 px copy to well under a level.
    static let sampleEdge = 256

    /// The curve that takes `decode` to the brightness of `camera`, the same
    /// frame's camera JPEG. `nil` only when either cannot be read at all.
    public static func curve(matching camera: CGImage, from decode: CGImage) -> Curve? {
        guard let target = histogram(camera), let source = histogram(decode) else { return nil }
        return curve(matching: target, from: source)
    }

    /// The same, from two 256-bin brightness histograms.
    static func curve(matching target: [Int], from source: [Int]) -> Curve? {
        guard target.count == 256, source.count == 256 else { return nil }
        let ts = target.reduce(0, +), ss = source.reduce(0, +)
        guard ts > 0, ss > 0 else { return nil }
        // Anchored at black and white, and strictly rising in, never falling
        // out, so the curve can only ever brighten or darken a level, never
        // turn one tone past another.
        var xs: [Double] = [0], ys: [Double] = [0]
        for q in quantiles {
            let x = level(at: q, of: source, total: ss)
            let y = max(level(at: q, of: target, total: ts), ys[ys.count - 1])
            if x > xs[xs.count - 1] + 0.5 {
                xs.append(x)
                ys.append(y)
            }
        }
        if xs[xs.count - 1] < 255 {
            xs.append(255)
            ys.append(max(255, ys[ys.count - 1]))
        }
        var table = [UInt8](repeating: 0, count: 256)
        var j = 0
        for i in 0..<256 {
            let x = Double(i)
            while j < xs.count - 2 && x > xs[j + 1] { j += 1 }
            let x0 = xs[j], x1 = xs[j + 1], y0 = ys[j], y1 = ys[j + 1]
            let t = x1 > x0 ? (x - x0) / (x1 - x0) : 0
            table[i] = UInt8(min(255, max(0, (y0 + t * (y1 - y0)).rounded())))
        }
        return Curve(table: table)
    }

    /// The level below which `q` of a histogram's pixels lie, read between
    /// bins so a distribution crowded into a few levels still gives a smooth
    /// answer.
    static func level(at q: Double, of hist: [Int], total: Int) -> Double {
        let want = q * Double(total)
        var below = 0.0
        for (i, n) in hist.enumerated() where n > 0 {
            let here = Double(n)
            if below + here >= want {
                return min(255, max(0, Double(i) - 0.5 + (want - below) / here))
            }
            below += here
        }
        return 255
    }

    /// A picture's brightness (Rec. 709 weights on its sRGB levels) in 256
    /// bins, from a copy no longer than `sampleEdge`.
    static func histogram(_ image: CGImage) -> [Int]? {
        let long = max(image.width, image.height)
        guard long > 0 else { return nil }
        let k = min(1, Double(sampleEdge) / Double(long))
        let w = max(1, Int((Double(image.width) * k).rounded()))
        let h = max(1, Int((Double(image.height) * k).rounded()))
        guard let ctx = DisplayColor.context(width: w, height: h) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let row = ctx.bytesPerRow
        let p = data.bindMemory(to: UInt8.self, capacity: row * h)
        var hist = [Int](repeating: 0, count: 256)
        for y in 0..<h {
            let line = p + y * row
            for x in 0..<w {
                let o = x * 4
                let l = (54 * Int(line[o]) + 183 * Int(line[o + 1]) + 19 * Int(line[o + 2]) + 128) >> 8
                hist[min(255, l)] += 1
            }
        }
        return hist
    }

    /// The picture with the curve applied to red, green and blue alike, in
    /// the colour space it came in — sRGB, as the pump tags every route's
    /// JPEG; a profile an engine embeds one day is kept, not converted away
    /// (`DisplayColor`). `nil` if it could not be redrawn, and then the
    /// caller shows it as it came.
    public static func apply(_ curve: Curve, to image: CGImage) -> CGImage? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? DisplayColor.sRGB
        guard var format = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            renderingIntent: .defaultIntent)
        else { return nil }
        var buffer = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, image,
                                           vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }
        // Bytes in memory are R, G, B, X; vImage names its four tables after
        // A, R, G, B by position. So the curve goes in the first three and the
        // unused fourth byte is left alone.
        let looked = curve.table.withUnsafeBufferPointer { t -> vImage_Error in
            let lut = t.baseAddress
            return vImageTableLookUp_ARGB8888(&buffer, &buffer, lut, lut, lut, nil,
                                              vImage_Flags(kvImageNoFlags))
        }
        guard looked == kvImageNoError else { free(buffer.data); return nil }
        var error = vImage_Error(kvImageNoError)
        // The new picture takes the buffer over and frees it when it goes.
        guard let made = vImageCreateCGImageFromBuffer(&buffer, &format, nil, nil,
                                                       vImage_Flags(kvImageNoAllocate), &error),
              error == kvImageNoError
        else { free(buffer.data); return nil }
        return made.takeRetainedValue()
    }

    /// The average brightness of a picture, 0–255, as `histogram` reads it.
    /// For the tests and the bench.
    public static func meanLevel(_ image: CGImage) -> Double? {
        guard let h = histogram(image) else { return nil }
        let n = h.reduce(0, +)
        guard n > 0 else { return nil }
        return Double(h.enumerated().reduce(0) { $0 + $1.offset * $1.element }) / Double(n)
    }
}
