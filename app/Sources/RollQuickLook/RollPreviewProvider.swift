import Foundation
import QuickLookUI
import RollPreview
import UniformTypeIdentifiers

/// The space bar on a packed burst: the camera's preview of the frame you
/// kept, upright and as large as the camera made it. Nothing is unpacked; see
/// RollPreview. A data-based preview (QLIsDataBasedPreview): Quick Look shows
/// the JPEG this returns as it shows any photograph.
@objc(RollPreviewProvider)
final class RollPreviewProvider: QLPreviewProvider, QLPreviewingController {

    enum Failure: Error { case noPreview }

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        guard let p = RollPreview.keeper(at: request.fileURL),
              let image = RollPreview.image(p),
              let jpeg = RollPreview.jpeg(image) else { throw Failure.noPreview }
        let size = CGSize(width: image.width, height: image.height)
        return QLPreviewReply(dataOfContentType: .jpeg, contentSize: size) { _ in jpeg }
    }
}
