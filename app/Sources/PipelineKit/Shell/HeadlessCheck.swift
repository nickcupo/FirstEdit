import Foundation
import CoreGraphics

/// `FirstEdit --check` (DESIGN.md §4.4): start the real engine, wait for
/// its port, send one authenticated `GET /api/shoots`, print `OK <n> shoots`,
/// stop the engine and exit 0. On any failure: a non-zero exit and the last
/// lines of the log.
///
/// `--check --deep` goes further, and goes through **every** culled shoot in
/// the library rather than the first one. For each it opens the shoot, builds
/// the same `ShootSession` the window builds, takes the frame the light table
/// would open on, loads one `/thumb`, one `/full?px=2048` and one `/crop`
/// through `Downsampler` — the app's own decoder, not a header read — and
/// checks the bitmap that comes back has pixels and is not blank. It prints
/// one line per shoot with its frames, whether the light table got rows,
/// whether a picture decoded, and which `cull.csv` columns the engine sent.
///
/// It goes through every shoot because his shoots were culled by four
/// different builds over three weeks and their `cull.csv` files do not have
/// the same columns. A check that only ever looks at the newest one proves
/// nothing about the seven on his disk — which is how a light table that drew
/// no photograph at all shipped past a green smoke run.
///
/// This is also what catches "the bundle is signed but the interpreter cannot
/// start" before a DMG exists.
public enum HeadlessCheck {
    public static func run(deep: Bool, bundle: Bundle = .main,
                           environment env: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        let support = AppPaths.support(environment: env)
        let engine = EngineHost(bundle: bundle, support: support, settings: .shared,
                                environment: env, startTimeout: .seconds(120))
        let started = ContinuousClock.now
        defer { engine.terminateNow() }

        let endpoint: EngineHost.Endpoint
        do {
            endpoint = try await engine.start()
        } catch {
            print("FAIL the engine did not start: \(error)")
            printLogTail(engine.logURL)
            return 1
        }
        let client = StudioClient(endpoint: endpoint)
        let shoots: ShootsResponse
        do {
            shoots = try await client.get(Routes.shoots())
        } catch {
            print("FAIL GET /api/shoots: \(error)")
            printLogTail(engine.logURL)
            return 1
        }
        let launch = ContinuousClock.now - started
        print("OK \(shoots.shoots.count) shoots")
        print("launch \(launch.formatted(.units(allowed: [.milliseconds], width: .narrow)))")
        if let pid = engine.childPID { print("engine pid \(pid)") }

        if deep {
            let culled = shoots.ok.filter(\.culled)
            guard !culled.isEmpty else {
                print("FAIL --deep needs a culled shoot and there is none")
                return 1
            }
            var failed = 0
            for row in culled {
                if await !pictures(in: row.name, client: client, log: engine.logURL) { failed += 1 }
            }
            if failed > 0 {
                print("FAIL \(failed) of \(culled.count) culled shoots have no photograph in the light table")
                return 1
            }
            print("OK a photograph decodes in all \(culled.count) culled shoots")
        }
        await engine.stop()
        return 0
    }

    /// One shoot, end to end, the way the window does it.
    ///
    /// The session is built rather than the raw response read, because the
    /// session is where the rows table is keyed and where the bursts are
    /// settled, and those two are what the light table reads. A frame that
    /// answers 200 to a route the app would never ask for proves nothing.
    static func pictures(in name: String, client: StudioClient, log: URL) async -> Bool {
        let response: ShootResponse
        do {
            response = try await client.get(Routes.shoot(name))
        } catch {
            print("FAIL \(name): GET /api/shoot: \(error)")
            printLogTail(log)
            return false
        }
        let columns = response.rows.first.map(Self.columns) ?? []
        // The frame the light table would actually open on: the resume burst's
        // own frames, keyed the way the rows table is keyed.
        let session = await MainActor.run {
            ShootSession(response: response, ext: nil, client: client,
                         pump: ImagePump(loader: { _ in Data() }),
                         queue: VerdictQueue(sender: { _ in .failure(.offline) }))
        }
        let (bursts, stems, row) = await MainActor.run { () -> (Int, Int, Row?) in
            let opensAt = LightTableSeams.resume(for: session).burst_id
                .flatMap { id in session.bursts.firstIndex { $0.id == id } } ?? 0
            let frames = session.bursts.indices.contains(opensAt) ? session.bursts[opensAt].frames : []
            let onStage = frames.first { session.rows[$0]?.hasAnyRendering == true }
                ?? frames.first
                ?? session.order.first
            return (session.bursts.count, frames.count, onStage.flatMap { session.rows[$0] })
        }

        func say(_ verdict: String, _ note: String = "") {
            print("\(verdict) \(name): \(response.info.frames) frames, \(response.rows.count) rows, "
                  + "\(bursts) bursts, \(stems) in the first"
                  + (note.isEmpty ? "" : ", \(note)"))
            print("   columns: \(columns.joined(separator: " "))")
        }

        guard response.rows.count > 0 else { say("FAIL", "the light table gets no rows"); return false }
        guard stems > 0 else { say("FAIL", "the burst it opens on is empty"); return false }
        guard let row else { say("FAIL", "no frame of that burst has a row"); return false }

        for route in [ImageRoute.thumb(shoot: name, stem: row.stem),
                      .full(shoot: name, stem: row.stem, px: 2048),
                      .crop(shoot: name, stem: row.stem, cx: 0.5, cy: 0.5, px: 1024, ar: 0.75)] {
            do {
                let (data, resp) = try await URLSession.studio.data(for: client.imageRequest(route))
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    say("FAIL", "\(route.path) answered \(status)")
                    printLogTail(log)
                    return false
                }
                // Through the app's own decoder, and then at the bitmap: a
                // JPEG whose header says 640 × 427 and whose pixels are all
                // one colour is not a photograph, and `pixelSize` cannot tell
                // the difference.
                guard let image = try? Downsampler.decode(data, maxPixel: nil),
                      image.width > 0, image.height > 0 else {
                    say("FAIL", "\(route.path) is \(data.count) bytes that will not decode")
                    return false
                }
                guard notBlank(image) else {
                    say("FAIL", "\(route.path) decodes to \(image.width)×\(image.height) of one flat colour")
                    return false
                }
            } catch {
                say("FAIL", "\(route.path): \(error)")
                printLogTail(log)
                return false
            }
        }
        say("OK", "a photograph decodes at \(row.stem)")
        return true
    }

    /// Whether a decoded frame has anything in it. Sampled on a grid rather
    /// than read whole: a 6024 × 4024 bitmap is 97 MB and the question is only
    /// whether two pixels differ.
    static func notBlank(_ image: CGImage, samples: Int = 12) -> Bool {
        let w = 64, h = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return true }   // cannot tell: not a reason to fail a shoot
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return true }
        let px = base.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var first: (UInt8, UInt8, UInt8)?
        for y in stride(from: 0, to: h, by: max(1, h / samples)) {
            for x in stride(from: 0, to: w, by: max(1, w / samples)) {
                let i = (y * w + x) * 4
                let here = (px[i], px[i + 1], px[i + 2])
                guard let f = first else { first = here; continue }
                if here != f { return true }
            }
        }
        return false
    }

    /// The `cull.csv` columns this shoot's rows actually carry, named, so a
    /// shoot culled by an older build can be told apart from a new one at a
    /// glance. `Row` holds the ones it knows about in fixed properties and the
    /// rest in `extra`.
    static func columns(of row: Row) -> [String] {
        var out: [String] = ["file", "stem", "rating"]
        func note(_ name: String, _ present: Bool) { if present { out.append(name) } }
        note("override", row.override != nil)
        note("reason", row.reason != nil)
        note("face_flags", row.face_flags != nil)
        note("face_score", row.face_score != nil)
        note("quality", row.quality != nil)
        note("borderline", row.borderline != nil)
        note("focus", row.focus != nil)
        note("aesthetic", row.aesthetic != nil)
        note("group", row.group != nil)
        note("scene", row.scene != nil)
        note("burst", row.burst != nil)
        note("moment", row.moment != nil)
        note("shot_at", row.shot_at != nil)
        note("face_x", row.face_x != nil)
        note("face_y", row.face_y != nil)
        note("face_w", row.face_w != nil)
        note("face_h", row.face_h != nil)
        note("subject", row.subject != nil)
        note("stack", row.stack != nil)
        note("stack_top", row.stack_top != nil)
        note("tw/th", row.tw != nil)
        note("lw/lh", row.lw != nil)
        note("dw/dh", row.dw != nil)
        return out + row.extra.keys.sorted()
    }

    static func printLogTail(_ url: URL, lines: Int = 12) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines)
        print("--- last lines of \(url.lastPathComponent) ---")
        tail.forEach { print($0) }
    }
}
