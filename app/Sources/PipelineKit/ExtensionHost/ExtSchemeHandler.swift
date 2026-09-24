import Foundation
import WebKit

/// One request the page made, on its way out of the web view.
public struct ExtRequest: Sendable {
    /// The upstream URL, with the custom scheme and host already swapped back
    /// for the real ones.
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?

    public init(url: URL, method: String, headers: [String: String] = [:], body: Data? = nil) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
    }
}

/// One answer on its way back in.
public struct ExtResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func html(_ text: String, status: Int = 200) -> ExtResponse {
        ExtResponse(status: status, headers: ["Content-Type": "text/html; charset=utf-8"],
                    body: Data(text.utf8))
    }
}

/// Where an extension page's bytes come from.
///
/// Two implementations and one line between them: `ExtHTTPUpstream` talks to a
/// real local server with the key on every request, and a scene or a test
/// hands the handler its own pages without a socket. Nothing above this
/// protocol knows which it has.
public protocol ExtUpstream: Sendable {
    func load(_ request: ExtRequest) async throws -> ExtResponse
}

/// The real one: a local HTTP origin, with `X-Studio-Key` on **every** request
/// — the page and each of its subresources alike.
///
/// This is the whole reason extension pages are not loaded over `http://` and
/// not put in an iframe. A page loading its own image cannot add a header to
/// that load, so an origin that demanded the key would break every picture on
/// it; an origin that did not demand the key is reachable by anything else on
/// the machine. Going through the scheme handler, the app adds the header to
/// the page and to everything the page asks for, so the extension's server can
/// require it and nothing inside the page can read it.
public struct ExtHTTPUpstream: ExtUpstream {
    public let key: String
    private let session: URLSession

    public init(key: String, session: URLSession = .extensionPages) {
        self.key = key
        self.session = session
    }

    public func load(_ request: ExtRequest) async throws -> ExtResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        for (name, value) in request.headers where !Self.dropped.contains(name.lowercased()) {
            r.setValue(value, forHTTPHeaderField: name)
        }
        r.httpBody = request.body
        r.setValue(key, forHTTPHeaderField: "X-Studio-Key")
        let (data, response) = try await session.data(for: r)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in (http?.allHeaderFields ?? [:]) {
            guard let k = k as? String, let v = v as? String else { continue }
            if Self.strippedFromResponse.contains(k.lowercased()) { continue }
            headers[k] = v
        }
        return ExtResponse(status: http?.statusCode ?? 200, headers: headers, body: data)
    }

    /// The web view's own idea of the host and origin describes a scheme the
    /// upstream server has never heard of, so it never travels.
    static let dropped: Set<String> = ["host", "origin", "referer", "connection", "x-studio-key"]
    /// Hop-by-hop, and anything that would let a page keep state across the
    /// custom scheme's opaque origin in a way `pipeline.state` should own.
    static let strippedFromResponse: Set<String> = [
        "connection", "keep-alive", "transfer-encoding", "set-cookie", "content-length",
    ]
}

extension URLSession {
    /// An added step's page and everything it loads. Not `.studio`: those four
    /// connections carry the app's own pictures, and a page drawing a grid
    /// queued behind them and they behind it. And a memory cache, which
    /// `.studio` has none of, that does exactly what the extension's server
    /// says in `Cache-Control` — so a page visited again is not every picture
    /// fetched again when its server said they would not change. Nothing on
    /// disk, and no cookie kept.
    public static let extensionPages: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 6
        c.requestCachePolicy = .useProtocolCachePolicy
        c.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 0)
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
}

/// `pipeline-ext://` — the only scheme an extension's page is ever served on.
///
/// The custom-scheme URL keeps the upstream path and query exactly, and
/// replaces only its scheme and authority, so a page's own relative link,
/// root-relative path or same-origin absolute URL all resolve to the same
/// bytes they would have upstream. Anything that is *not* this scheme is not
/// this handler's, which is how a page that reaches for the open internet
/// simply does not load.
public final class ExtSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "pipeline-ext"
    public static let host = "page"

    private let upstream: ExtUpstream
    /// The upstream origin this handler speaks for. A request that would leave
    /// it is refused rather than proxied.
    private let origin: URL
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]

    public init(upstream: ExtUpstream, origin: URL) {
        self.upstream = upstream
        self.origin = origin
    }

    // MARK: - the URL on each side

    /// The address a web view is asked to load, for an upstream URL.
    public static func schemeURL(for upstream: URL) -> URL? {
        guard var c = URLComponents(url: upstream, resolvingAgainstBaseURL: true) else { return nil }
        c.scheme = scheme
        c.host = host
        c.port = nil
        c.user = nil
        c.password = nil
        if c.path.isEmpty { c.path = "/" }
        return c.url
    }

    /// The upstream URL for an address the web view asked for, or `nil` when
    /// it is not one this handler speaks for.
    public static func upstreamURL(for url: URL, origin: URL) -> URL? {
        guard url.scheme == scheme, url.host == host else { return nil }
        guard var c = URLComponents(url: origin, resolvingAgainstBaseURL: true) else { return nil }
        guard let asked = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        // The path is carried across as the bytes it already is — decoding it
        // and re-encoding it turns a literal `%` in a shoot's name into
        // something else. `..` is standardised away first, and whatever is
        // left is rooted at the origin, so nothing addressed here is ever
        // outside the origin this handler speaks for.
        let raw = asked.percentEncodedPath
        let standard = (raw as NSString).standardizingPath
        c.percentEncodedPath = standard.hasPrefix("/") ? standard
            : "/" + standard.drop(while: { $0 == "." || $0 == "/" })
        c.percentEncodedQuery = asked.percentEncodedQuery
        c.fragment = nil
        return c.url
    }

    // MARK: - WKURLSchemeHandler

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let request = task.request
        guard let url = request.url, let target = Self.upstreamURL(for: url, origin: origin) else {
            task.didFailWithError(ExtHostError.notServed(task.request.url?.absoluteString ?? ""))
            return
        }
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] { headers[k] = v }
        let out = ExtRequest(url: target, method: request.httpMethod ?? "GET",
                             headers: headers, body: Self.body(of: request))
        let up = upstream
        let id = ObjectIdentifier(task)
        running[id] = Task { @MainActor [weak self] in
            do {
                let answer = try await up.load(out)
                guard self?.running[id] != nil else { return }
                var headers = answer.headers
                headers["Content-Length"] = String(answer.body.count)
                guard let response = HTTPURLResponse(url: url, statusCode: answer.status,
                                                     httpVersion: "HTTP/1.1", headerFields: headers) else {
                    task.didFailWithError(ExtHostError.notServed(url.absoluteString))
                    self?.running[id] = nil
                    return
                }
                task.didReceive(response)
                task.didReceive(answer.body)
                task.didFinish()
            } catch is CancellationError {
            } catch {
                guard self?.running[id] != nil else { return }
                task.didFailWithError(error)
            }
            self?.running[id] = nil
        }
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        running[id]?.cancel()
        running[id] = nil
    }

    /// A `fetch` with a body arrives as a stream more often than as data, and
    /// a POST whose body silently vanished is worse than one that never went.
    static func body(of request: URLRequest) -> Data? {
        if let d = request.httpBody { return d }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: size)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return data.isEmpty ? nil : data
    }
}

/// What the host itself can refuse, in its own plain sentences. An engine's
/// refusal is never rewritten; these are the host's own and have nowhere else
/// to come from.
public enum ExtHostError: Error, Sendable, Equatable {
    /// A page asked for something outside the origin it was served from.
    case notServed(String)
    /// The step has no page to show.
    case noPage(step: String)
    /// A page tried to leave the machine.
    case wentOutside(String)

    public var sentence: String {
        switch self {
        case .notServed:
            return Strings.Extensions.notServed
        case .noPage:
            return Strings.Extensions.noPage
        case .wentOutside:
            return Strings.Extensions.wentOutside
        }
    }

    public var detail: String? {
        switch self {
        case .notServed(let u): return u
        case .noPage(let s): return s
        case .wentOutside(let u): return u
        }
    }
}
