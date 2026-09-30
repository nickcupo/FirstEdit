import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The preview as a picture, upright: what the thumbnail (RollThumbnail) and
/// the space bar (RollQuickLook) both show.
extension RollPreview {

    /// The preview, turned by the ARW's Orientation, at no more than
    /// `maxPixels` on its long side (nil: as large as the camera made it).
    public static func image(_ p: Preview, maxPixels: CGFloat? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(p.jpeg as CFData, nil) else { return nil }
        let img: CGImage?
        if let maxPixels {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(Int(maxPixels), 64),
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        } else {
            img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        return img.flatMap { upright($0, orientation: p.orientation) }
    }

    /// The ARW's Orientation applied: 3 half a turn, 6 a quarter turn
    /// clockwise, 8 a quarter turn anticlockwise.
    public static func upright(_ img: CGImage, orientation: Int) -> CGImage? {
        guard [3, 6, 8].contains(orientation) else { return img }
        let w = img.width, h = img.height
        let (ow, oh) = orientation == 3 ? (w, h) : (h, w)
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        switch orientation {
        case 3:
            ctx.translateBy(x: CGFloat(ow), y: CGFloat(oh))
            ctx.rotate(by: .pi)
        case 6:
            ctx.translateBy(x: 0, y: CGFloat(oh))
            ctx.rotate(by: -.pi / 2)
        default:
            ctx.translateBy(x: CGFloat(ow), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The picture as a JPEG, for Quick Look to show as it shows any photo.
    public static func jpeg(_ img: CGImage, quality: Double = 0.92) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
