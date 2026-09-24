import Foundation
import Network

/// A stand-in for an extension's own server: two trivial pages and their
/// subresources, on its own port, requiring `X-Studio-Key` exactly as
/// DESIGN.md §3.7-2 says the real one must.
///
/// It exists so the key check can be proved rather than asserted: what the
/// host sends is what this records, and what this refuses is what a forged
/// request gets.
final class StubExtensionServer: @unchecked Sendable {
    struct Hit: Sendable {
        let method: String
        let path: String
        let key: String?
    }

    let key: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "stub.extension.server")
    private let lock = NSLock()
    private var _hits: [Hit] = []
    private var connections: [NWConnection] = []

    var hits: [Hit] { lock.withLock { _hits } }
    func hits(forPath path: String) -> [Hit] { hits.filter { $0.path == path } }

    private(set) var port: UInt16 = 0
    var base: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    init(key: String = "a-test-key") throws {
        self.key = key
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws {
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let p = self?.listener.port?.rawValue {
                ready.continuation.yield(p)
                ready.continuation.finish()
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        for await p in ready.stream { port = p; break }
        guard port != 0 else { throw StubError.neverListened }
    }

    func stop() {
        listener.cancel()
        lock.withLock {
            for c in connections { c.cancel() }
            connections = []
        }
    }

    enum StubError: Error { case neverListened }

    // MARK: - one connection, one request, one answer

    private func accept(_ c: NWConnection) {
        lock.withLock { connections.append(c) }
        c.start(queue: queue)
        read(c, buffer: Data())
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, _ in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done { c.cancel() } else { self.read(c, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
            self.answer(c, head: head)
        }
    }

    private func answer(_ c: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines.first?.components(separatedBy: " ") ?? []
        let method = request.first ?? "GET"
        let target = request.count > 1 ? request[1] : "/"
        let path = target.components(separatedBy: "?").first ?? target
        var key: String?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, parts[0].lowercased() == "x-studio-key" { key = parts[1] }
        }
        lock.withLock { _hits.append(Hit(method: method, path: path, key: key)) }

        let (status, type, body) = Self.page(path: path, key: key, expected: self.key)
        var out = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Forbidden")\r\n"
        out += "Content-Type: \(type)\r\n"
        if status == 200, path == "/cached.svg" { out += "Cache-Control: max-age=600\r\n" }
        out += "Content-Length: \(body.count)\r\n"
        out += "Connection: close\r\n\r\n"
        var data = Data(out.utf8)
        data.append(body)
        c.send(content: data, completion: .contentProcessed { _ in c.cancel() })
    }

    /// Two trivial pages, a stylesheet, a script and a picture — so a test can
    /// see that the key reached the subresources and not only the page.
    static func page(path: String, key: String?, expected: String) -> (Int, String, Data) {
        guard key == expected else {
            return (403, "text/plain; charset=utf-8", Data("no key".utf8))
        }
        switch path {
        case "/one":
            return (200, "text/html; charset=utf-8", Data("""
            <!doctype html><html><head>
            <link rel="stylesheet" href="look.css">
            <script src="page.js" defer></script>
            </head><body>
            <h1 id="title">One</h1>
            <img id="picture" src="/deeper/picture.svg" width="40" height="30">
            </body></html>
            """.utf8))
        case "/tall":
            // Grows only after it has loaded, as a page that draws its cards
            // from a fetch does.
            return (200, "text/html; charset=utf-8", Data("""
            <!doctype html><html><body style="margin:0">
            <div id="cards" style="height:10px"></div>
            <script>setTimeout(function () { document.getElementById('cards').style.height = '4000px'; }, 150);</script>
            </body></html>
            """.utf8))
        case "/two":
            return (200, "text/html; charset=utf-8", Data(
                "<!doctype html><html><body><h1 id=\"title\">Two</h1></body></html>".utf8))
        case "/look.css":
            return (200, "text/css", Data("#title { color: var(--pp-text); }".utf8))
        case "/page.js":
            return (200, "text/javascript", Data("window.stubRan = true;".utf8))
        case "/cached.svg", "/deeper/picture.svg":
            return (200, "image/svg+xml", Data(
                "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='30'></svg>".utf8))
        default:
            return (404, "text/plain; charset=utf-8", Data("no such page".utf8))
        }
    }
}
