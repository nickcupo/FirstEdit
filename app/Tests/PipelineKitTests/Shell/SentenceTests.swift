import Testing
@testable import PipelineKit

/// Engine refusals are fragments; where he reads them they are sentences.
@Suite("A refusal reads as a sentence")
struct SentenceTests {

    @Test("first letter up and a full stop, for a fragment")
    func fragment() {
        #expect("cull the shoot first".asSentence == "Cull the shoot first.")
        #expect("a job is already running".asSentence == "A job is already running.")
        #expect("there are no frames to cull yet: copy the card first".asSentence
                == "There are no frames to cull yet: copy the card first.")
    }

    @Test("a sentence that already ends, or starts with a name, is left as written")
    func leftAlone() {
        #expect("Nothing was ever pushed.".asSentence == "Nothing was ever pushed.")
        #expect("2026-09-13-dog has no archive manifest".asSentence == "2026-09-13-dog has no archive manifest.")
        #expect("a-broken-shoot will not read".asSentence == "a-broken-shoot will not read.")
        #expect("organize.json will not read: Expecting value".asSentence == "organize.json will not read: Expecting value.")
        #expect("Is it on?".asSentence == "Is it on?")
        #expect("".asSentence == "")
    }

    @Test("a first word with a capital inside it is a name: iCloud, macOS")
    func innerCapital() {
        #expect("iCloud has not finished uploading".asSentence == "iCloud has not finished uploading.")
        #expect("macOS refused the copy".asSentence == "macOS refused the copy.")
    }

    /// On the main actor and without a suspension, so no library read in
    /// another test can change the names between the set and the checks:
    /// `Library` writes them only from the main actor.
    @Test("a first word that is one of his shoots keeps the case he typed it in")
    @MainActor func shootName() {
        defer { ShootNames.set([]) }
        #expect("lounge already exists".asSentence == "Lounge already exists.")
        ShootNames.set(["lounge", "2026-09-19"])
        #expect("lounge already exists".asSentence == "lounge already exists.")
        #expect("lounge: nothing to cull".asSentence == "lounge: nothing to cull.")
        // A word that is not a shoot still starts the sentence in capitals.
        #expect("cull the shoot first".asSentence == "Cull the shoot first.")
    }

    @Test("the library says which names are his shoots whenever it reads the list")
    @MainActor func libraryTellsTheNames() throws {
        defer { ShootNames.set([]) }
        let lib = Library(preview: try LastPlaceTests.shoots())
        let first = try #require(lib.rows.first?.name)
        #expect(ShootNames.contains(first))
        #expect(!ShootNames.contains("cull"))
    }
}
