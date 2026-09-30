import Foundation
import Testing
@testable import RollPreview

/// Finder's thumbnail for a packed burst comes from RollPreview. The fixture
/// is a real .roll written by burstpack (app/tools/make-roll-fixture.py):
/// three frames, the middle one kept, each ARW pointing at its JPEG from
/// IFD0 with the JPEG after the sensor data, and Orientation 6.
@Suite struct RollPreviewTests {
    let roll = Fixture.directory.appendingPathComponent("Roll/burst-0.roll")
    let keeperJPEG = Fixture.directory.appendingPathComponent("Roll/keeper.jpg")

    @Test func theKeptFramesOwnJPEGComesOutWithItsOrientation() throws {
        let p = try #require(RollPreview.keeper(at: roll))
        #expect(p.frame == "DSC01001.ARW")
        #expect(p.jpeg == (try Data(contentsOf: keeperJPEG)))
        #expect(p.orientation == 6)
    }

    @Test func fromMemoryItIsTheSame() throws {
        let data = try Data(contentsOf: roll)
        #expect(RollPreview.keeper(in: data) == RollPreview.keeper(at: roll))
        // A slice that does not start at zero is read from its own start.
        let padded = Data([1, 2, 3]) + data
        #expect(RollPreview.keeper(in: padded[3...]) == RollPreview.keeper(at: roll))
    }

    @Test func anythingElseIsNilNotACrash() throws {
        let data = try Data(contentsOf: roll)
        #expect(RollPreview.keeper(in: Data()) == nil)
        #expect(RollPreview.keeper(in: Data("not a roll at all".utf8)) == nil)
        for cut in [7, 16, 40, data.count / 3, data.count / 2, data.count - 1] {
            _ = RollPreview.keeper(in: data.prefix(cut))          // must return, whatever it returns
        }
        var damaged = data
        for i in stride(from: 200, to: damaged.count, by: 97) { damaged[i] ^= 0x5A }
        _ = RollPreview.keeper(in: damaged)
    }

    @Test func partsAreSplitAsBurstpackJoinsThem() {
        func part(_ b: [UInt8]) -> Data {
            var n = UInt64(b.count).littleEndian
            return Data(bytes: &n, count: 8) + Data(b)
        }
        #expect(RollPreview.unblob(part([1, 2]) + part([]) + part([9])) == [Data([1, 2]), Data(), Data([9])])
        #expect(RollPreview.unblob(part([1, 2]).dropLast()) == nil)
    }

    @Test func offsetsPastTheSensorDataMoveBackByItsLength() {
        let t = RollPreview.TIFFView(file: Data(0..<20), hole: 5..<105)
        #expect(t.bytes(0, 5) == Data(0..<5))
        #expect(t.bytes(105, 3) == Data(5..<8))
        #expect(t.bytes(4, 2) == nil)
        #expect(t.bytes(100, 10) == nil)
        #expect(t.bytes(115, 10) == nil)
    }
}
