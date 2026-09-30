import Foundation
import Testing
@testable import PipelineKit
import RollPreview

/// A packed burst in Finder: the space bar shows the kept frame upright, and a
/// double-click unpacks that frame whole, checked, for Preview.
@Suite struct RollOpenerTests {
    let roll = Fixture.directory.appendingPathComponent("Roll/burst-0.roll")

    /// The checkout this runs from, whose .venv burstpack runs in.
    static let checkout = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let python = checkout.appendingPathComponent(".venv/bin/python")

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
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("roll-open-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let launch = EngineLaunch(origin: .checkout, python: Self.python,
                                  script: Self.checkout.appendingPathComponent("pipeline/studio.py"),
                                  resources: Self.checkout)
        let raw = try await RollOpener.unpackKeeper(roll, launch: launch, under: base)
        #expect(raw.lastPathComponent == "DSC01001.ARW")
        let folder = try FileManager.default.contentsOfDirectory(atPath: raw.deletingLastPathComponent().path)
        #expect(folder == ["DSC01001.ARW"], "the kept frame alone, nothing half written")
        let again = try await RollOpener.unpackKeeper(roll, launch: nil, under: base)
        #expect(again == raw, "found where it was, with no engine needed")
    }

    @Test func somethingElseIsSaidPlainly() async {
        let jpg = Fixture.directory.appendingPathComponent("Roll/keeper.jpg")
        await #expect(throws: RollOpener.Failure.notAPackedBurst("keeper.jpg")) {
            try await RollOpener.unpackKeeper(jpg, launch: nil)
        }
    }
}
