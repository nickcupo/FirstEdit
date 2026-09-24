import Foundation
import Testing
@testable import PipelineKit

/// §2.13: US spelling on screen, as the Mac's own menus spell it. Window ▸
/// "Centre" sat under the system's Minimize, Settings offered "Neutral Grey"
/// and the zoom label read "1:1 · centred".
@Suite("US spelling on screen")
struct SpellingTests {

    /// The British spellings the app used, and their family.
    static let british = try! NSRegularExpression(
        pattern: #"\b(centre|centred|centring|grey|greyed|colour\w*|behaviour|favourite|licence|cancelled|cancelling|labelled|labelling|whilst|organis\w*|recognis\w*|analys(e|ed|ing))\b"#,
        options: [.caseInsensitive])

    @Test("the words named in the decision are the American ones")
    func theNamedWords() {
        #expect(Strings.Settings.neutralGrey == "Neutral Gray")
        #expect(Strings.Settings.backgroundWhy.contains("Neutral Gray"))
        #expect(Words.Window.centre == "Center")
        #expect(Words.View.neutralGrey == "Neutral Gray")
        #expect(Strings.LightTable.aimCentre == "centered")
    }

    @Test("no sentence the app shows uses a British spelling")
    func everyShownString() throws {
        let sources = try StringCatalogTests.sources()
        // A key, then the value that follows it: `s("key", "value"` and
        // `String(localized: "key", defaultValue: "value"`. The comment that
        // comes after is a note to a translator, never shown, and not read.
        let pairs = try NSRegularExpression(
            pattern: #"(?:\b[a-z]\(|localized:\s*)"([A-Za-z][A-Za-z0-9_]*\.[A-Za-z0-9_.]+)"\s*,\s*(?:defaultValue:\s*)?"((?:[^"\\]|\\.)*)""#)
        let ns = sources as NSString
        var read = 0
        for m in pairs.matches(in: sources, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1)), value = ns.substring(with: m.range(at: 2))
            read += 1
            let hit = Self.british.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length))
            #expect(hit == nil, "\(key): \"\(value)\"")
        }
        #expect(read > 300, "the reader found the app's strings")
    }
}

/// §2.8: "Cut" was a format, "Cut It" makes any format, and "Slow into the
/// cut" was its checkbox. The format is Push In on screen; "cut" means only
/// making the reel.
@Suite("Push In, not Cut")
struct PushInTests {
    @Test("the format that pushes in is called that, and so is its checkbox")
    func named() {
        #expect(Strings.Reels.formatName(.cut) == "Push In")
        #expect(Strings.Reels.slowIn == "Slow into the push-in")
        #expect(Strings.Reels.cutIt == "Cut It")
        for f in ReelFormat.allCases where f != .cut {
            #expect(Strings.Reels.formatName(f) != "Cut")
        }
    }
}
