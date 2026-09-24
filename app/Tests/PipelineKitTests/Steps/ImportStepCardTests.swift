import Foundation
import Testing
@testable import PipelineKit

/// What the card page reads off a card, and what it makes of the name he
/// types (DESIGN.md §2.6).
@Suite("What is on the card, and what the shoot is called")
struct ImportStepCardTests {

    // MARK: - the name

    @Test("a space or a slash becomes a dash as he types")
    func tidy() {
        #expect(ShootName.tidy("2026-09-23-night 2") == "2026-09-23-night-2")
        #expect(ShootName.tidy("main/prelims") == "main-prelims")
        #expect(ShootName.tidy("  2026-09-23") == "2026-09-23")
    }

    @Test("a dash, dot or underscore left at the end is not part of the name")
    func finished() {
        #expect(ShootName.finished("2026-09-23-") == "2026-09-23")
        #expect(ShootName.finished("2026-09-23-night._-") == "2026-09-23-night")
        #expect(ShootName.finished("2026-09-23") == "2026-09-23")
    }

    @Test("the engine's own rule, with a reason he can act on")
    @MainActor func problems() {
        #expect(ShootName.problem("", taken: []) == Strings.Import.nameEmpty)
        #expect(ShootName.problem("-lake", taken: []) == Strings.Import.nameStart)
        #expect(ShootName.problem(".lake", taken: []) == Strings.Import.nameStart)
        #expect(ShootName.problem("lake?", taken: []) == Strings.Import.nameCharacters)
        #expect(ShootName.problem("2026-09-19", taken: ["2026-09-19"]) == Strings.Import.nameTaken("2026-09-19"))
        #expect(ShootName.problem("2026-09-19-ufc_300.b", taken: ["2026-09-19"]) == nil)
    }

    @Test("one photograph is a photograph")
    @MainActor func count() {
        #expect(Strings.Import.copyCount(1) == "Copy 1 Frame")
        #expect(Strings.Import.copyCount(2) == "Copy 2 Frames")
    }

    // MARK: - the card

    /// A card in a scratch folder: DCIM and whatever is written into it.
    static func card(_ files: [String: Date], raw: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("card-\(UUID().uuidString)")
        for (path, date) in files {
            let u = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: path.count).write(to: u)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
        }
        return root
    }

    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 9) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: month, day: day,
                                                                   hour: hour, minute: minute))!
    }

    @Test("the count is what the copy will take: RAW and JPEG, not clips, sidecars or hidden files")
    func countsWhatIsCopied() throws {
        let t = Self.at(19, 20)
        let root = try Self.card([
            "DCIM/100MSDCF/DSC00001.ARW": t, "DCIM/100MSDCF/DSC00002.JPG": t, "DCIM/101MSDCF/DSC00003.arw": t,
            "DCIM/100MSDCF/C0001.MP4": t, "DCIM/100MSDCF/C0001M01.XML": t, "DCIM/100MSDCF/DSC00001.THM": t,
            "DCIM/100MSDCF/._DSC00001.ARW": t, "PRIVATE/M4ROOT/CLIP/C0001.MP4": t,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CardScan.read(root.path)?.photographs == 3)
    }

    @Test("a card with nothing to copy has no count")
    func emptyCard() throws {
        let root = try Self.card(["DCIM/100MSDCF/C0001.MP4": Self.at(19, 20)])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CardScan.read(root.path) == nil)
    }

    @Test("the name starts from the day the card's last evening started, not the Mac's clock")
    func dayOfTheCard() throws {
        let root = try Self.card([
            // Last week's shoot, still on the card because the card is the backup.
            "DCIM/100MSDCF/DSC00001.ARW": Self.at(13, 14), "DCIM/100MSDCF/DSC00002.ARW": Self.at(13, 16),
            // Tonight's, running past midnight.
            "DCIM/100MSDCF/DSC00100.ARW": Self.at(19, 19, 5), "DCIM/100MSDCF/DSC00101.ARW": Self.at(19, 22, 30),
            "DCIM/100MSDCF/DSC00102.ARW": Self.at(20, 0, 40),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let scan = try #require(CardScan.read(root.path))
        #expect(scan.day == "2026-09-19")
        #expect(scan.newest?.name == "DSC00102.ARW")
    }

    @Test("already copied means a shoot holds the card's newest photograph, not that the card has the same name")
    func alreadyCopied() throws {
        let t = Self.at(19, 23)
        let root = try Self.card(["DCIM/100MSDCF/DSC00102.ARW": t])
        defer { try? FileManager.default.removeItem(at: root) }
        let newest = try #require(CardScan.read(root.path)?.newest)

        let library = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }
        let same = library.appendingPathComponent("2026-09-19/raw")
        let other = library.appendingPathComponent("2026-09-13-dog/raw")
        for d in [same, other] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        // The copy keeps the photograph's time.
        try FileManager.default.copyItem(at: root.appendingPathComponent("DCIM/100MSDCF/DSC00102.ARW"),
                                         to: same.appendingPathComponent("DSC00102.ARW"))
        try FileManager.default.setAttributes([.modificationDate: t],
                                              ofItemAtPath: same.appendingPathComponent("DSC00102.ARW").path)
        // Another night's frame of the same number and size is not this one.
        try Data(repeating: 7, count: "DCIM/100MSDCF/DSC00102.ARW".count)
            .write(to: other.appendingPathComponent("DSC00102.ARW"))
        try FileManager.default.setAttributes([.modificationDate: Self.at(13, 16)],
                                              ofItemAtPath: other.appendingPathComponent("DSC00102.ARW").path)

        #expect(CardScan.copiedAs(newest, shoots: [("2026-09-13-dog", other.path), ("2026-09-19", same.path)])
                == "2026-09-19")
        #expect(CardScan.copiedAs(newest, shoots: [("2026-09-13-dog", other.path), ("empty", "")]) == nil)
    }

    @Test("the extensions counted are the ones ingest.py copies")
    func extensionsAreTheEngines() throws {
        // app/Tests/PipelineKitTests/Steps/<this file> → the repository.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let common = try String(contentsOf: repo.appendingPathComponent("pipeline/common.py"), encoding: .utf8)
        var engine: Set<String> = []
        for name in ["RAW_EXTS", "JPEG_EXTS"] {
            let line = try #require(common.split(separator: "\n").first { $0.hasPrefix("\(name) = {") })
            for m in line.matches(of: /"\.([a-z0-9]+)"/) { engine.insert(String(m.1)) }
        }
        #expect(!engine.isEmpty)
        #expect(CardScan.extensions == engine)
    }
}
