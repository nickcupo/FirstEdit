import Testing
@testable import PipelineKit

/// What the card page says about a card the library may already hold. It
/// matched the path a card mounts at, and his camera formats every card as
/// "Untitled", so every new card said it had been copied as the first night.
@Suite("What is on the card")
struct CardContentsTests {
    // Counts under a thousand, so the check does not depend on how this Mac
    // groups digits.
    private func card(held: Int, of n: Int, into shoot: String = "2026-09-19",
                      stopped: Bool = false, copying: Bool = false) throws -> CardContents {
        let json = """
        {"cards": ["/Volumes/Untitled"], "described": [{"path": "/Volumes/Untitled", "name": "Untitled",
         "photographs": \(n), "bytes": 41000000000, "first": 1758300000, "last": 1758310000,
         "copied_as": "\(shoot)", "held": \(held), "stopped": \(stopped),
         "copying": \(copying)}]}
        """
        let r = try Fixture.decodeJSON(CardsResponse.self, json)
        #expect(r.cards == ["/Volumes/Untitled"])
        return try #require(r.described.first)
    }

    @Test("a new card called Untitled is not said to be copied")
    func newCard() throws {
        let c = try card(held: 0, of: 1558, into: "")
        #expect(c.photographs == 1558)
        #expect(Strings.Import.alreadyCopied(c) == nil)
    }

    @Test("a card whose every frame is in a shoot says so, with the count")
    func allOfIt() throws {
        let said = try #require(Strings.Import.alreadyCopied(try card(held: 558, of: 558)))
        #expect(said.contains("All 558") && said.contains("2026-09-19"))
    }

    @Test("a copy that stopped says where it stopped, not that it was copied")
    func stopped() throws {
        let said = try #require(Strings.Import.alreadyCopied(try card(held: 412, of: 558, stopped: true)))
        #expect(said.contains("stopped at 412 of 558"))
        #expect(!said.contains("already"))
    }

    /// A copy in flight has the same log as one that died, and the page said
    /// "stopped at 412" of a copy that was running.
    @Test("a copy still going says it is going, not where it stopped")
    func stillCopying() throws {
        let said = try #require(Strings.Import.alreadyCopied(try card(held: 412, of: 558, copying: true)))
        #expect(said.contains("being copied into 2026-09-19"))
        #expect(!said.contains("stopped") && !said.contains("412"))
    }

    @Test("a card shot on since its copy counts both")
    func shotOnSince() throws {
        let said = try #require(Strings.Import.alreadyCopied(try card(held: 300, of: 558)))
        #expect(said.hasPrefix("300 of the 558"))
    }

    @Test("an engine that only lists paths describes nothing")
    func oldEngine() throws {
        let r = try Fixture.decode(CardsResponse.self, "cards")
        #expect(r.described.isEmpty)
    }
}
