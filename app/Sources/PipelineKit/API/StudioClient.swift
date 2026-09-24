import Foundation

public struct Route<Response: Decodable & Sendable>: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public let method: Method
    public let path: String
    public let query: [String: String]

    public init(_ method: Method = .get, _ path: String, _ query: [String: String] = [:]) {
        self.method = method
        self.path = path
        self.query = query
    }

    /// For the decoding error, and for the log. Never the query: a name can be
    /// in it and a log is a thing that gets pasted into an issue.
    public var label: String { "\(method.rawValue) \(path)" }
}

extension URLSession {
    /// One session for the whole app. Four connections, mirroring the server's
    /// own decode gate, so a prefetch can never queue behind itself and stall
    /// the frame he is looking at. No URL cache: the image routes are
    /// `immutable` and cached by `ImageCache`, and everything else is live
    /// state that must never be answered from yesterday.
    public static let studio: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 4
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
}

/// The one way anything in this app talks to the engine.
///
/// Every request carries `X-Studio-Key`, including the image routes. Today's
/// engine ignores an unknown header and the crew landing the check will
/// require it, so both versions are talked to the same way.
public actor StudioClient {
    public nonisolated let endpoint: EngineHost.Endpoint
    private let session: URLSession
    private let decoder = JSONDecoder()

    public init(endpoint: EngineHost.Endpoint, session: URLSession = .studio) {
        self.endpoint = endpoint
        self.session = session
    }

    public func get<R: Decodable & Sendable>(_ r: Route<R>) async throws -> R {
        try await send(r, body: nil)
    }

    public func post<B: Encodable & Sendable, R: Decodable & Sendable>(
        _ r: Route<R>, _ b: B
    ) async throws -> R {
        let data: Data
        do { data = try JSONEncoder().encode(b) }
        catch { throw StudioError.decoding(route: r.label, detail: "\(error)") }
        return try await send(r, body: data)
    }

    /// The image request, built without hopping onto the actor: the viewer
    /// asks for these on the frame it is drawing and cannot wait for a turn.
    public nonisolated func imageRequest(_ i: ImageRoute) -> URLRequest {
        var req = URLRequest(url: url(for: i.path, query: i.query))
        req.httpMethod = "GET"
        req.setValue(endpoint.key, forHTTPHeaderField: "X-Studio-Key")
        req.cachePolicy = .returnCacheDataElseLoad
        return req
    }

    // MARK: - the one send

    private func send<R: Decodable & Sendable>(_ r: Route<R>, body: Data?) async throws -> R {
        var req = URLRequest(url: url(for: r.path, query: r.query))
        req.httpMethod = r.method.rawValue
        req.setValue(endpoint.key, forHTTPHeaderField: "X-Studio-Key")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "content-type")
        }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as URLError where e.code == .cannotConnectToHost || e.code == .networkConnectionLost {
            throw StudioError.engineDown
        } catch {
            throw StudioError.offline
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A cheap look for the word before committing to a second full parse.
        // `refusal(in:)` walks the whole body with JSONSerialization, and this
        // ran on **every** response before the status was even checked, so
        // `GET /api/shoot` on a 2000-row shoot was parsed twice from end to
        // end — once to find out there was no error, once to decode it.
        let refusal = Self.mightRefuse(data) ? Self.refusal(in: data) : nil

        if !(200..<300).contains(status) {
            if let refusal { throw StudioError.refused(refusal) }
            throw StudioError.http(status: status, body: Self.text(data))
        }
        // A 200 with an `{"error": …}` and a model that has nowhere to put it
        // is a refusal. A model that declares `error` keeps both, because
        // /api/rating, /api/kind and /api/storage/apply send both at once.
        if let refusal, !(R.self is any CarriesRefusal.Type) {
            throw StudioError.refused(refusal)
        }
        do {
            return try decoder.decode(R.self, from: data)
        } catch {
            throw StudioError.decoding(route: r.label, detail: Self.explain(error))
        }
    }

    private nonisolated func url(for path: String, query: [String: String]) -> URL {
        var c = URLComponents(url: endpoint.base, resolvingAgainstBaseURL: false)
            ?? URLComponents(string: "http://127.0.0.1/")!
        c.path = path
        c.queryItems = query.isEmpty ? nil
            : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url ?? endpoint.base
    }

    /// Whether the body contains the bytes `"error"` at all.
    ///
    /// A byte scan, so the ordinary answer — it does not — costs a pass over
    /// the data instead of a parse of it. A body that does contain the word
    /// somewhere still has to be parsed to find out whether it is a top-level
    /// refusal; this only says when not to bother.
    static func mightRefuse(_ data: Data) -> Bool {
        let needle = Array(#""error""#.utf8)
        guard data.count >= needle.count else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            let last = bytes.count - needle.count
            var i = 0
            while i <= last {
                if bytes[i] == needle[0] {
                    var j = 1
                    while j < needle.count && bytes[i + j] == needle[j] { j += 1 }
                    if j == needle.count { return true }
                }
                i += 1
            }
            return false
        }
    }

    /// Only a top-level, non-empty `error`. A body that happens to hold the
    /// word somewhere deeper is not a refusal.
    static func refusal(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["error"] as? String, !text.isEmpty
        else { return nil }
        return text
    }

    static func text(_ data: Data) -> String {
        String(data: data.prefix(2048), encoding: .utf8) ?? ""
    }

    /// What is actually wrong, in one line, so a decoding failure names the
    /// field rather than printing a Swift enum at him.
    static func explain(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return "\(error)" }
        switch e {
        case .keyNotFound(let key, let ctx):
            return "no \(key.stringValue) in \(path(ctx))"
        case .typeMismatch(let type, let ctx):
            return "\(path(ctx)) is not \(type)"
        case .valueNotFound(let type, let ctx):
            return "\(path(ctx)) has no \(type)"
        case .dataCorrupted(let ctx):
            return "\(path(ctx)): \(ctx.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }

    private static func path(_ ctx: DecodingError.Context) -> String {
        let p = ctx.codingPath.map(\.stringValue).joined(separator: ".")
        return p.isEmpty ? "the body" : p
    }
}

// MARK: - the image routes

public enum ImageRoute: Hashable, Sendable {
    case thumb(shoot: String, stem: String)
    case large(shoot: String, stem: String)
    case preview(shoot: String, stem: String)
    /// `px` is DESIGN.md §3.9-2. The engine clamps it and defaults to 2600, so
    /// asking an engine that has not landed it yet costs nothing but sharpness.
    case full(shoot: String, stem: String, px: Int)
    /// `px` is the box's width in source pixels and `ar` its height over
    /// width — the engine's meaning, not the usual one. See `CropBox`.
    case crop(shoot: String, stem: String, cx: Double, cy: Double, px: Int, ar: Double)
    /// `px` is the longest side: 400 for a tile, the large view's own size
    /// when Space opens one. The engine clamps it and keeps each size apart.
    case reelThumb(shoot: String, stem: String, src: String?, px: Int = 400)
    case ext(shoot: String, kind: String, name: String)
    /// The photograph he exported, upright, for the Instagram step (DESIGN.md
    /// §2.17): `px` is the longest side (400 for a tile, 2400 for the
    /// editor), or nil for the export's own bytes at 1:1. `version` is the
    /// export's mtime, so a photograph exported again is asked for afresh.
    case exported(shoot: String, stem: String, px: Int? = 400, version: Int = 0)

    /// Unescaped: `URLComponents` escapes it once, when the URL is built. A
    /// shoot name may hold a space, and escaping here as well sent `%2520`.
    var path: String {
        func esc(_ s: String) -> String { s }
        switch self {
        case .thumb(let s, let f): return "/thumb/\(esc(s))/\(esc(f)).jpg"
        case .large(let s, let f): return "/large/\(esc(s))/\(esc(f)).jpg"
        case .preview(let s, let f): return "/preview/\(esc(s))/\(esc(f)).jpg"
        case .full(let s, let f, _): return "/full/\(esc(s))/\(esc(f)).jpg"
        case .crop(let s, let f, _, _, _, _): return "/crop/\(esc(s))/\(esc(f)).jpg"
        case .reelThumb(let s, let f, _, _): return "/reelthumb/\(esc(s))/\(esc(f)).jpg"
        case .ext(let s, let kind, let name): return "/ext/\(esc(s))/\(esc(kind))/\(esc(name))"
        case .exported(let s, let f, _, _): return "/exported/\(esc(s))/\(esc(f)).jpg"
        }
    }

    var query: [String: String] {
        switch self {
        case .full(_, _, let px):
            return ["px": String(px)]
        case .crop(_, _, let cx, let cy, let px, let ar):
            // The box is decided by the query, so flipping back to a frame he
            // has already looked at at 1:1 is free. Rounded so a pan of a
            // thousandth of a frame is not a different URL.
            return ["cx": Self.round(cx), "cy": Self.round(cy),
                    "px": String(px), "ar": Self.round(ar)]
        case .reelThumb(_, _, let src, let px):
            var q = src.map { ["src": $0] } ?? [:]
            if px != 400 { q["px"] = String(px) }
            return q
        case .exported(_, _, let px, let version):
            var q = ["v": String(version)]
            if px != 400 { q["px"] = px.map(String.init) ?? "full" }
            return q
        default:
            return [:]
        }
    }

    private static func round(_ v: Double) -> String { String(format: "%.4f", v) }
}
