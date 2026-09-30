import Darwin
import Foundation
import Testing
@testable import RollPreview

/// A packed burst in Finder: the space bar shows the kept frame upright, and a
/// double-click hands Preview the kept frame whole, or, for a file iCloud has
/// evicted, the picture it carries, so nothing is downloaded.
@Suite struct RollOpenerTests {
    let roll = Fixture.directory.appendingPathComponent("Roll/burst-0.roll")

    /// The checkout this runs from, whose .venv burstpack runs in.
    static let checkout = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let python = checkout.appendingPathComponent(".venv/bin/python")

    func scratch() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("roll-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func theSpaceBarShowsTheKeptFrameUprightAsAJPEG() throws {
        let p = try #require(RollPreview.keeper(at: roll))
        let img = try #require(RollPreview.image(p))
        #expect(p.orientation == 6)
        #expect(img.height > img.width, "Orientation 6: a portrait, stood up")
        let jpeg = try #require(RollPreview.jpeg(img))
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
        let small = try #require(RollPreview.image(p, maxPixels: 64))
        #expect(max(small.width, small.height) <= 64 && small.height > small.width)
    }

    @Test func thePictureAFileCarriesIsShownBeforeItsContentsAreRead() throws {
        let d = try scratch()
        defer { try? FileManager.default.removeItem(at: d) }
        let copy = d.appendingPathComponent("burst-0.roll")
        try FileManager.default.copyItem(at: roll, to: copy)
        #expect(RollOpener.storedPicture(of: copy) == nil)
        #expect(RollPreview.picture(at: copy)?.orientation == 6, "none carried: read from the file")
        let jpg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 7, count: 40)
        let set = jpg.withUnsafeBytes {
            setxattr(copy.path, RollOpener.pictureAttribute, $0.baseAddress, jpg.count, 0, XATTR_NOFOLLOW)
        }
        #expect(set == 0)
        #expect(RollOpener.storedPicture(of: copy) == jpg)
        #expect(RollPreview.picture(at: copy) == RollPreview.Preview(jpeg: jpg, orientation: 1, frame: ""),
                "carried: already upright, and the file is not read")
        #expect(!RollOpener.isDataless(copy))
    }

    @Test func theKeptFrameIsNamedFromTheHeadOfTheFile() {
        #expect(RollOpener.keeper(of: roll) == "DSC01001.ARW")
        #expect(RollOpener.keeper(of: Fixture.directory.appendingPathComponent("Roll/keeper.jpg")) == nil)
    }

    @Test func eachFileUnpacksIntoAFolderOfItsOwn() {
        let base = URL(fileURLWithPath: "/tmp/x")
        let a = RollOpener.folder(for: URL(fileURLWithPath: "/a/2026-09-16/packed/burst-3.roll"), under: base)
        let b = RollOpener.folder(for: URL(fileURLWithPath: "/a/2026-09-21/packed/burst-3.roll"), under: base)
        #expect(a.lastPathComponent == "2026-09-16 burst-3")
        #expect(a != b)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: python.path)))
    func aDoubleClickUnpacksTheKeptFrameCheckedAndOnlyOnce() async throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let bp = Self.checkout.appendingPathComponent("pipeline/burstpack.py")
        let raw = try await RollOpener.openable(roll, python: Self.python, burstpack: bp, under: base)
        #expect(raw.lastPathComponent == "DSC01001.ARW")
        let folder = try FileManager.default.contentsOfDirectory(atPath: raw.deletingLastPathComponent().path)
        #expect(folder == ["DSC01001.ARW"], "the kept frame alone, nothing half written")
        let again = try await RollOpener.openable(roll, python: nil, burstpack: nil, under: base)
        #expect(again == raw, "found where it was, with no engine needed")
    }

    @Test func somethingElseIsSaidPlainly() async {
        let jpg = Fixture.directory.appendingPathComponent("Roll/keeper.jpg")
        await #expect(throws: RollOpener.Failure.notAPackedBurst("keeper.jpg")) {
            try await RollOpener.openable(jpg, python: nil, burstpack: nil)
        }
    }
}
