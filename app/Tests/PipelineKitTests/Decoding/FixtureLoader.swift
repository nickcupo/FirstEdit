import Foundation
@testable import PipelineKit

/// The bytes `tools/capture-fixtures.sh` saved from the real engine.
enum Fixture {
    static let directory: URL = {
        if let u = Bundle.module.url(forResource: "Fixtures", withExtension: nil) { return u }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }()

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }

    /// A body written out in the test itself, for an answer that has no
    /// fixture because it only exists for a second — a refusal, a queued
    /// start. Decoded through exactly the same path as one off disk.
    static func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }
}
