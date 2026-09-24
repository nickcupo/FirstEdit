import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// ImageIO decoding, off the main actor, straight to the size it will be drawn.
///
/// Today's page hands a 1440 px asset to an 1157 pt tile and a 7.5 MB decode
/// to a 1105 pt view. Here every decode asks ImageIO for a thumbnail no larger
/// than `maxPixel` — the view's point size times its backing scale — so a
/// 6024 px frame drawn into a 90 pt filmstrip cell costs 180 px of memory.
public enum Downsampler {

    public enum Failure: Error, Sendable, Equatable {
        case notAnImage
        case couldNotDecode
    }

    /// `maxPixel: nil` decodes at the asset's own size: the right answer for
    /// a `/crop` tile, which exists to put one source pixel on one device
    /// pixel.
    public static func decode(_ data: Data, maxPixel: Int?) throws -> CGImage {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              CGImageSourceGetCount(src) > 0
        else { throw Failure.notAnImage }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        if let maxPixel, maxPixel > 0 {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel
        } else if let (w, h) = pixelSize(src) {
            options[kCGImageSourceThumbnailMaxPixelSize] = max(w, h)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw Failure.couldNotDecode
        }
        // The engine's JPEGs carry no profile at all today. An untagged image
        // means "whatever the display is", so the same frame is a different
        // colour on each panel; tagged sRGB it is the same photograph in both
        // windows. An image that does carry a profile is honoured untouched —
        // an engine that starts tagging is obeyed, never overridden. The
        // picture window already does this to everything it commits; this puts
        // the main window's stage and its filmstrip on the same footing.
        return DisplayColor.tagged(image)
    }

    /// The pixel size an asset declares, without decoding it.
    public static func pixelSize(of data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(src)
    }

    private static func pixelSize(_ src: CGImageSource) -> (Int, Int)? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int,
              let h = p[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    /// `ceil(points × scale)`, the number ImageIO is asked for.
    public static func maxPixel(forPoints points: CGSize, scale: CGFloat) -> Int {
        Int((max(points.width, points.height) * max(scale, 1)).rounded(.up))
    }

    /// Bytes a decoded bitmap holds, for the ring's byte cap.
    public static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }
}
