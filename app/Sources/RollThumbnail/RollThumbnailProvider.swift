import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing
import RollPreview

/// Finder's thumbnail for a packed burst: the camera's preview of the frame
/// you kept, turned upright. Nothing is unpacked; see RollPreview.
@objc(RollThumbnailProvider)
final class RollThumbnailProvider: QLThumbnailProvider {

    enum Failure: Error { case noPreview }

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let most = max(request.maximumSize.width, request.maximumSize.height) * max(request.scale, 1)
        guard let p = RollPreview.keeper(at: request.fileURL),
              let image = Self.image(p, maxPixels: most) else {
            handler(nil, Failure.noPreview)
            return
        }
        let size = Self.fit(CGSize(width: image.width, height: image.height), in: request.maximumSize)
        handler(QLThumbnailReply(contextSize: size) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
            return true
        }, nil)
    }

    /// The preview at no more than `maxPixels` on its long side, upright.
    static func image(_ p: RollPreview.Preview, maxPixels: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(p.jpeg as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(maxPixels), 64),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return upright(img, orientation: p.orientation)
    }

    /// The ARW's Orientation applied: 3 half a turn, 6 a quarter turn
    /// clockwise, 8 a quarter turn anticlockwise.
    static func upright(_ img: CGImage, orientation: Int) -> CGImage? {
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

    /// `size` scaled down, keeping its shape, to fit inside `box`.
    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let k = min(box.width / size.width, box.height / size.height, 1e9)
        return CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
    }
}
