import Foundation
import Testing
@testable import PipelineKit

/// The one path nothing else covers: a real engine, over HTTP, through
/// `ImagePump` — which is what the light table draws from. The headless check
/// fetches with `URLSession` directly and the snapshot harness injects its own
/// loader, so both were green while the app showed no photographs at all.
///
/// Skipped unless an engine is already listening where DIAG_STUDIO says, so it
/// costs nothing in an ordinary run:
///   DIAG_STUDIO=127.0.0.1:8899 DIAG_KEY=… DIAG_SHOOT=2026-09-21 DIAG_STEM=TSC07363 swift test --filter LivePump
@Suite("A photograph through the real pump")
struct LivePumpDiagTests {
    static var endpoint: EngineHost.Endpoint? {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DIAG_STUDIO"], let key = env["DIAG_KEY"],
              let url = URL(string: "http://\(host)/") else { return nil }
        return EngineHost.Endpoint(base: url, key: key)
    }

    @Test("the pump returns pixels for a frame the engine serves")
    func pumpDrawsAFrame() async throws {
        guard let endpoint = Self.endpoint else { return }
        let env = ProcessInfo.processInfo.environment
        let shoot = env["DIAG_SHOOT"] ?? "2026-09-21"
        let stem = env["DIAG_STEM"] ?? "TSC07363"
        let client = StudioClient(endpoint: endpoint)
        let pump = ImagePump(client: client)

        for tier in [ImagePump.Tier.thumb, .large, .full(px: 2048)] {
            let key = ImagePump.Key(shoot: shoot, stem: stem, tier: tier)
            do {
                let image = try await pump.image(key, priority: .userInitiated)
                print("PUMP OK \(tier): \(image.width)×\(image.height)")
                #expect(image.width > 0 && image.height > 0)
            } catch {
                print("PUMP FAILED \(tier): \(error)")
                Issue.record("pump could not draw \(tier): \(error)")
            }
        }
    }
}
