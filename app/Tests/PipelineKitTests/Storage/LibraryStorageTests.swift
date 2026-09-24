import Foundation
import Testing
@testable import PipelineKit

/// §2.8 — the library's Storage page, as a way into each shoot's panel.
@Suite("The library's Storage page leads to each shoot's panel")
@MainActor
struct LibraryStorageTests {

    /// `/api/shoots` as captured, with each row's on-disk figure set as the
    /// engine would send it (or taken away, as an older engine sends it).
    static func rows(_ bytes: [String: Int?]) throws -> [ShootRowOK] {
        var top = try #require(JSONSerialization.jsonObject(with: Fixture.data("shoots")) as? [String: Any])
        var rows = try #require(top["shoots"] as? [[String: Any]])
        for i in rows.indices {
            guard let name = rows[i]["name"] as? String, var st = rows[i]["storage"] as? [String: Any],
                  let b = bytes[name] else { continue }
            st["bytes_here"] = b
            st["bytes_here_text"] = b.map { "\($0) B" } ?? ""
            rows[i]["storage"] = st
        }
        top["shoots"] = rows
        return try JSONDecoder().decode(ShootsResponse.self,
                                        from: JSONSerialization.data(withJSONObject: top)).ok
    }

    @Test("largest on this disk first; a row with no figure keeps its place after them")
    func bySize() throws {
        let rows = try Self.rows(["2026-09-13-dog": 5, "2026-09-19": 90, "2026-09-21": 40])
        let order = LibraryStorage.bySize(rows).map(\.name)
        #expect(Array(order.prefix(3)) == ["2026-09-19", "2026-09-21", "2026-09-13-dog"])
        // The rest in the library's order, untouched.
        let rest = rows.map(\.name).filter { !["2026-09-19", "2026-09-21", "2026-09-13-dog"].contains($0) }
        #expect(Array(order.dropFirst(3)) == rest)
    }

    @Test("an engine that sends no figure leaves the library's order as it was")
    func noFigures() throws {
        let rows = try Self.rows([:])
        #expect(rows.allSatisfy { $0.storage?.bytes_here == nil && $0.storage?.bytes_here_text == "" })
        #expect(LibraryStorage.bySize(rows).map(\.name) == rows.map(\.name))
    }

    @Test("VoiceOver hears the name, the size and the phrase, and nothing empty between them")
    func spoken() throws {
        let rows = try Self.rows(["2026-09-19": 12])
        let row = try #require(rows.first { $0.name == "2026-09-19" })
        #expect(LibraryStorage.spoken(row) == "2026-09-19. 12 B. \(row.storage?.phrase ?? "")")
        let bare = try #require(try Self.rows([:]).first { $0.name == "2026-09-19" })
        #expect(LibraryStorage.spoken(bare) == "2026-09-19. \(bare.storage?.phrase ?? "")")
    }

    @Test("a row asks for its own shoot's panel, once, and no other panel answers it")
    func arrival() {
        StorageArrival.ask(for: "2026-09-19")
        #expect(StorageArrival.take("2026-09-13-dog") == false, "another shoot's panel does not scroll")
        // Any panel that appears clears the request, so it cannot scroll a
        // later visit.
        #expect(StorageArrival.take("2026-09-19") == false)
        StorageArrival.ask(for: "2026-09-19")
        #expect(StorageArrival.take("2026-09-19"))
        #expect(StorageArrival.take("2026-09-19") == false)
    }

    @Test("the row goes to Finish, where the panel is, not to the shoot's overview")
    func goesToFinish() throws {
        let text = try #require(SafetyTests.sources.first { $0.name == "LibraryStorage.swift" }?.text)
        #expect(text.contains(".step(shoot: row.name, step: \"done\")"))
        #expect(!text.contains("selection = .shoot(row.name)"))
    }
}
