import Foundation
import Testing

/// The code is the text; the catalog is a copy of some of it (DESIGN.md §4.2, §5).
///
/// A compiled catalog wins over the default written at the call site, so a
/// value left behind in `Localizable.xcstrings` is what the built app says,
/// while every run from a checkout — and every snapshot — shows the corrected
/// sentence. That is how the shipped sidebar read "368 kept" and the empty
/// library pointed at a menu item that is always greyed, weeks after the code
/// had stopped saying either. The build's gate only counts keys, so nothing
/// else notices.
@Suite("The string catalog")
struct StringCatalogTests {

    static let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func catalog() throws -> [String: String] {
        let url = app.appendingPathComponent("Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(json?["strings"] as? [String: Any])
        var out: [String: String] = [:]
        for (key, entry) in strings {
            let value = ((((entry as? [String: Any])?["localizations"] as? [String: Any])?["en"]
                as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            guard let value else {
                Issue.record("\(key) has no English value, and a key short is a sentence that shows as its own name")
                continue
            }
            out[key] = value
        }
        return out
    }

    /// Every Swift file of the app, as one text: a key is unique, so where it
    /// is does not matter, only what follows it.
    static func sources() throws -> String {
        let root = app.appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return try walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    @Test("every value in the catalog is the sentence the code says, word for word")
    func noStaleValue() throws {
        let catalog = try Self.catalog()
        let sources = try Self.sources()
        #expect(!catalog.isEmpty)
        for (key, value) in catalog.sorted(by: { $0.key < $1.key }) {
            guard let code = SwiftDefault.after(key: key, in: sources) else {
                Issue.record("\(key) is in the catalog and nowhere in the code: the catalog would say it anyway")
                continue
            }
            #expect(SwiftDefault.normalised(catalog: value) == code,
                    "\(key): the catalog says \"\(value)\", the code says \"\(code.replacingOccurrences(of: "\u{1}", with: "%"))\"")
        }
    }

    @Test("the reading of the code is right: interpolation, escapes and a wrapped call")
    func theReaderItself() {
        let src = #"""
        s("a.plain", "Nothing you decided is lost.", "note")
        String(localized: "a.counted",
               defaultValue: "\(n) frames · \(kept) you kept", comment: "x")
        s("a.quoted", "He said \"no\" \(x ? "twice" : "once").", "y")
        """#
        #expect(SwiftDefault.after(key: "a.plain", in: src) == "Nothing you decided is lost.")
        #expect(SwiftDefault.after(key: "a.counted", in: src) == "\u{1} frames · \u{1} you kept")
        #expect(SwiftDefault.after(key: "a.quoted", in: src) == "He said \"no\" \u{1}.")
        #expect(SwiftDefault.after(key: "a.missing", in: src) == nil)
        #expect(SwiftDefault.normalised(catalog: "%lld frames · %1$@ you kept, 100%%")
                == "\u{1} frames · \u{1} you kept, 100%")
    }
}

/// Just enough of Swift's string literal to read the default value that
/// follows a key: `"key", "value"` or `"key", defaultValue: "value"`. Every
/// interpolation becomes one marker, and so does every format specifier on
/// the catalog's side, because `\(n)` is `%lld` there and `\(name)` is `%@`.
enum SwiftDefault {
    static let marker: Character = "\u{1}"

    static func after(key: String, in text: String) -> String? {
        let needle = "\"\(key)\""
        var from = text.startIndex
        while let hit = text.range(of: needle, range: from..<text.endIndex) {
            // Only the stretch after the key is read, so a long file costs a
            // search and not a walk character by character.
            let chars = Array(text[hit.upperBound...].prefix(4000))
            var j = 0
            skipSpace(chars, &j)
            if j < chars.count, chars[j] == "," {
                j += 1
                skipSpace(chars, &j)
                let label = Array("defaultValue:")
                if j + label.count <= chars.count, Array(chars[j..<j + label.count]) == label {
                    j += label.count
                    skipSpace(chars, &j)
                }
                if j < chars.count, chars[j] == "\"", let (value, _) = literal(chars, j) {
                    return value
                }
            }
            from = hit.upperBound
        }
        return nil
    }

    static func normalised(catalog value: String) -> String {
        let pattern = #"%(\d+\$)?(lld|ld|d|@|f|\.\d+f)"#
        let marked = value.replacingOccurrences(of: pattern, with: String(marker), options: .regularExpression)
        return marked.replacingOccurrences(of: "%%", with: "%")
    }

    private static func skipSpace(_ c: [Character], _ j: inout Int) {
        while j < c.count, c[j].isWhitespace { j += 1 }
    }

    /// The literal starting at `start` (its opening quote), and the index just
    /// past its closing one.
    private static func literal(_ c: [Character], _ start: Int) -> (String, Int)? {
        var out = ""
        var i = start + 1
        while i < c.count {
            let ch = c[i]
            if ch == "\"" { return (out, i + 1) }
            if ch == "\\", i + 1 < c.count {
                let next = c[i + 1]
                if next == "(" {
                    var depth = 1
                    var j = i + 2
                    while j < c.count, depth > 0 {
                        if c[j] == "\"" {
                            guard let (_, end) = literal(c, j) else { return nil }
                            j = end
                            continue
                        }
                        if c[j] == "(" { depth += 1 }
                        if c[j] == ")" { depth -= 1 }
                        j += 1
                    }
                    out.append(marker)
                    i = j
                    continue
                }
                switch next {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "u":
                    // \u{2026}
                    if let close = c[(i + 2)...].firstIndex(of: "}"),
                       let scalar = UInt32(String(c[(i + 3)..<close]), radix: 16).flatMap(Unicode.Scalar.init) {
                        out.append(Character(scalar))
                        i = close + 1
                        continue
                    }
                    out.append(next)
                default: out.append(next)
                }
                i += 2
                continue
            }
            out.append(ch)
            i += 1
        }
        return nil
    }
}
