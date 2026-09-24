import Foundation
@testable import PipelineKit

/// The answers this crew's own capture took off the real engine, against a
/// scratch clone of the library — a push, a drop, an expire with and without
/// the frames that have no other copy, a reclaim, and the four states the
/// panel has to draw.
///
/// They live in their own folder so the foundation's "every fixture is one
/// this suite knows about" test keeps meaning what it says.
enum StorageFixture {
    static let folder = "StorageLearning"

    static func data(_ name: String) throws -> Data {
        try Fixture.data("\(folder)/\(name)")
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try Fixture.decode(T.self, "\(folder)/\(name)")
    }

    static var names: [String] {
        let dir = Fixture.directory.appendingPathComponent(folder)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }
}
