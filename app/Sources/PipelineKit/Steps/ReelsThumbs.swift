import SwiftUI
import CoreGraphics

/// The pictures on the Reels step's tiles.
///
/// They come from `/reelthumb`, which serves the JPEG he exported when there
/// is one — he is choosing what goes in the video, so he has to be looking at
/// what goes in the video — and the cull's own decode of the RAW when there is
/// not, which is what a draft would be cut from. Never the camera's preview.
///
/// The image pump has no tier for these and does not need one: they are 400 px
/// JPEGs the engine has already made, drawn in tiles, and never zoomed. Space
/// on a tile asks for the same picture at the large view's size (`px`), so
/// what he looks at large is the export the reel is cut from, not the camera's
/// JPEG and then the unedited RAW.
@MainActor
public final class ReelThumbs {
    /// For the snapshot harness: where the bytes come from instead of the
    /// engine. Production leaves it nil.
    public static var loader: ImagePump.Loader?

    private static var stores: [ObjectIdentifier: ReelThumbs] = [:]

    public static func store(for client: StudioClient) -> ReelThumbs {
        let key = ObjectIdentifier(client)
        if let s = stores[key] { return s }
        let s = ReelThumbs(load: loader ?? { route in
            let (data, response) = try await URLSession.studio.data(for: client.imageRequest(route))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw StudioError.http(status: status, body: "") }
            return data
        })
        stores[key] = s
        return s
    }

    /// For the snapshot harness and tests.
    public static func reset() { stores = [:]; loader = nil }

    /// A tile's size, and what every tile asks for.
    public static let tilePixels = 400

    /// The size to ask for to fill `size` points at `scale`: the tile's, or
    /// the next step of 400 above it, so a window dragged wider asks again a
    /// few times rather than at every point. The engine stops at 2400.
    public static func pixels(for size: CGSize, scale: CGFloat) -> Int {
        let longest = Double(max(size.width, size.height) * max(scale, 1))
        return min(2400, max(tilePixels, Int((longest / 400).rounded(.up)) * 400))
    }

    private let load: ImagePump.Loader
    private let cache = NSCache<NSString, CGImage>()
    /// The large ones, apart: a few 2400 px pictures are worth hundreds of tiles.
    private let large = NSCache<NSString, CGImage>()

    init(load: @escaping ImagePump.Loader) {
        self.load = load
        cache.countLimit = 600
        large.countLimit = 8
    }

    /// `version` is what the picture depends on that the route does not
    /// say: whether the frame is exported. The engine serves the decode of the
    /// RAW until he exports it and his JPEG after, under the one URL, so a
    /// cache keyed on the URL alone kept the decode on the tile all evening.
    public func cached(shoot: String, stem: String, src: String?, version: String = "",
                       px: Int = tilePixels) -> CGImage? {
        store(px).object(forKey: Self.key(shoot, stem, src, version, px))
    }

    public func image(shoot: String, stem: String, src: String?, version: String = "",
                      px: Int = tilePixels) async -> CGImage? {
        let key = Self.key(shoot, stem, src, version, px)
        let store = self.store(px)
        if let c = store.object(forKey: key) { return c }
        let load = self.load
        let route = ImageRoute.reelThumb(shoot: shoot, stem: stem, src: src, px: px)
        let decoded: CGImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? await load(route) else { return nil }
            return try? Downsampler.decode(data, maxPixel: px)
        }.value
        if let decoded { store.setObject(decoded, forKey: key) }
        return decoded
    }

    /// What to draw now for a picture asked for at `px`: that picture when it
    /// is here, else the tile's, which is the same picture smaller. The large
    /// view is made on the first request from the full-size export, and it
    /// went blank on every frame he arrowed to until it was.
    public func showing(shoot: String, stem: String, src: String?, version: String = "",
                        px: Int = tilePixels) -> CGImage? {
        cached(shoot: shoot, stem: stem, src: src, version: version, px: px)
            ?? (px == Self.tilePixels ? nil : cached(shoot: shoot, stem: stem, src: src, version: version))
    }

    private func store(_ px: Int) -> NSCache<NSString, CGImage> {
        px == Self.tilePixels ? cache : large
    }

    private static func key(_ shoot: String, _ stem: String, _ src: String?, _ version: String,
                            _ px: Int) -> NSString {
        "\(shoot)/\(stem)?\(src ?? "")#\(version)@\(px)" as NSString
    }
}

/// One tile's picture, filled to its box and loaded when it scrolls in.
struct ReelThumbView: View {
    let thumbs: ReelThumbs
    let shoot: String
    let stem: String
    let src: String?
    /// Changes when the picture behind the route does; see `ReelThumbs.cached`.
    var version = ""
    /// `true` crops to fill the tile; `false` shows the whole frame.
    var fill = false
    /// The longest side to ask for: a tile's, or the large view's.
    var px = ReelThumbs.tilePixels

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Tokens.Palette.viewerBackground
            if let image = image ?? thumbs.showing(shoot: shoot, stem: stem, src: src, version: version, px: px) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            }
        }
        .clipped()
        .task(id: "\(shoot)/\(stem)/\(src ?? "")#\(version)@\(px)") {
            guard px != ReelThumbs.tilePixels else {
                image = await thumbs.image(shoot: shoot, stem: stem, src: src, version: version)
                return
            }
            // Large: the tile first when there is nothing at all to show — the
            // engine already has it, so it arrives while the large one is made
            // — and the large one over it. A large one that cannot be made
            // leaves the tile, not a blank.
            if image == nil, thumbs.showing(shoot: shoot, stem: stem, src: src, version: version, px: px) == nil {
                image = await thumbs.image(shoot: shoot, stem: stem, src: src, version: version)
            }
            if let large = await thumbs.image(shoot: shoot, stem: stem, src: src, version: version, px: px) {
                image = large
            }
        }
    }
}
