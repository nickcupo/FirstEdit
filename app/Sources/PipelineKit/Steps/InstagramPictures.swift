import SwiftUI
import CoreGraphics

/// The pictures on the Instagram step: always the photograph he exported,
/// upright, from `/exported/` (DESIGN.md §2.17).
///
/// The cut is drawn as fractions of this picture, so it has to be the export
/// the copy is cut from — not the camera's JPEG, not the cull's decode of the
/// RAW. Tiles ask for 400 px, the editor for 2400 px, and 1:1 for the
/// export's own bytes. Each is keyed on the export's mtime, so a photograph
/// exported again is asked for afresh rather than drawn from last time.
/// Modelled on `ReelThumbs`.
@MainActor
public final class InstagramPictures {
    /// For the snapshot harness: where the bytes come from instead of the
    /// engine. Production leaves it nil.
    public static var loader: ImagePump.Loader?

    private static var stores: [ObjectIdentifier: InstagramPictures] = [:]

    public static func store(for client: StudioClient) -> InstagramPictures {
        let key = ObjectIdentifier(client)
        if let s = stores[key] { return s }
        let s = InstagramPictures(load: loader ?? { route in
            let (data, response) = try await URLSession.studio.data(for: client.imageRequest(route))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw StudioError.http(status: status, body: "") }
            return data
        })
        stores[key] = s
        return s
    }

    /// For tests and the snapshot harness.
    public static func reset() { stores = [:]; loader = nil }

    public static let tile = 400
    public static let large = 2400
    /// The export's own pixels, for 1:1.
    public static let full: Int? = nil

    private let load: ImagePump.Loader
    private let tiles = NSCache<NSString, CGImage>()
    private let larges = NSCache<NSString, CGImage>()

    init(load: @escaping ImagePump.Loader) {
        self.load = load
        tiles.countLimit = 800
        larges.countLimit = 6
    }

    public func cached(shoot: String, stem: String, version: Int, px: Int?) -> CGImage? {
        store(px).object(forKey: Self.key(shoot, stem, version, px))
    }

    /// For the snapshot harness: a picture already decoded, so a render does
    /// not race the decode.
    public func put(_ image: CGImage, shoot: String, stem: String, version: Int, px: Int?) {
        store(px).setObject(image, forKey: Self.key(shoot, stem, version, px))
    }

    public func image(shoot: String, stem: String, version: Int, px: Int?) async -> CGImage? {
        let key = Self.key(shoot, stem, version, px)
        let store = self.store(px)
        if let c = store.object(forKey: key) { return c }
        let load = self.load
        let route = ImageRoute.exported(shoot: shoot, stem: stem, px: px, version: version)
        let decoded: CGImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? await load(route) else { return nil }
            return try? Downsampler.decode(data, maxPixel: px)
        }.value
        if let decoded { store.setObject(decoded, forKey: key) }
        return decoded
    }

    /// What to draw now for a picture asked for at `px`: that one when it is
    /// here, else a smaller one of the same photograph.
    public func showing(shoot: String, stem: String, version: Int, px: Int?) -> CGImage? {
        cached(shoot: shoot, stem: stem, version: version, px: px)
            ?? (px == Self.tile ? nil : cached(shoot: shoot, stem: stem, version: version, px: Self.large))
            ?? (px == Self.tile ? nil : cached(shoot: shoot, stem: stem, version: version, px: Self.tile))
    }

    private func store(_ px: Int?) -> NSCache<NSString, CGImage> { px == Self.tile ? tiles : larges }

    private static func key(_ shoot: String, _ stem: String, _ version: Int, _ px: Int?) -> NSString {
        "\(shoot)/\(stem)#\(version)@\(px.map(String.init) ?? "full")" as NSString
    }
}

/// A photograph for the step, loaded when it comes into view. It hands the
/// picture to `content` so the view drawing the cut can draw over exactly
/// the picture's own rectangle.
struct InstagramPicture<Content: View>: View {
    let pictures: InstagramPictures
    let shoot: String
    let stem: String
    let version: Int
    var px: Int? = InstagramPictures.tile
    @ViewBuilder let content: (CGImage?) -> Content

    /// The picture loaded, and which one it is: a picture of another
    /// photograph is never drawn under this one's cut.
    @State private var loaded: (key: String, image: CGImage)?

    private var key: String { "\(shoot)/\(stem)#\(version)@\(px.map(String.init) ?? "full")" }

    var body: some View {
        let k = key
        let mine = loaded.flatMap { $0.key == k ? $0.image : nil }
        content(mine ?? pictures.showing(shoot: shoot, stem: stem, version: version, px: px))
            .task(id: k) {
                if px != InstagramPictures.tile,
                   pictures.showing(shoot: shoot, stem: stem, version: version, px: px) == nil,
                   let small = await pictures.image(shoot: shoot, stem: stem, version: version,
                                                    px: InstagramPictures.tile) {
                    // The tile's first, which the engine has already made, so
                    // there is a picture while the large one comes.
                    loaded = (k, small)
                }
                if let got = await pictures.image(shoot: shoot, stem: stem, version: version, px: px) {
                    loaded = (k, got)
                }
            }
    }
}
