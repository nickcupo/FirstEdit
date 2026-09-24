import Foundation
import Testing
@testable import PipelineKit

/// After a crash the "engine restarted" line stayed over every page,
/// including the light table, until he happened to click it. It now goes by
/// itself, and when he moves on or closes it.
@Suite("The restart line goes by itself", .serialized)
@MainActor
struct RestartBannerTests {

    @Test("the line clears itself after a while, and a newer line is not cleared by an older timer")
    func clearsItself() async throws {
        let was = AppModel.bannerLingers
        AppModel.bannerLingers = .milliseconds(40)
        defer { AppModel.bannerLingers = was }
        let app = AppModel(preview: Library(preview: try LastPlaceTests.shoots()), state: .stopped,
                           navigation: Navigation(selection: .allShoots))
        app.banner = Strings.Engine.restarted
        #expect(app.banner != nil)
        for _ in 0..<50 where app.banner != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(app.banner == nil)
    }
}
