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
              let image = RollPreview.image(p, maxPixels: most) else {
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

    /// `size` scaled down, keeping its shape, to fit inside `box`.
    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let k = min(box.width / size.width, box.height / size.height, 1e9)
        return CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
    }
}
