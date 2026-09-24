import Foundation

/// One decoded JSON object, read by name.
///
/// Every model in this file's neighbourhood is built from one of these rather
/// than from synthesised `Codable` conformances, for three measured reasons.
///
/// 1. The engine's row values come out of `csv.DictReader`, so a number is a
///    string — `"rating": "3"` sits beside `"override": 5` in the same row.
///    A synthesised decoder refuses the whole shoot over it.
/// 2. Half the fields DESIGN.md §3.4 names do not exist on the server yet
///    (`will_be_edited`, `bursts`, `steps`, `can_cut_reels`, the job's `id`).
///    A crew has to be able to write against the final shape today and still
///    talk to the engine that is running today.
/// 3. A field that vanishes must not be silently zero. The identity fields of
///    each model are *required* here and throw when absent, and the decoding
///    tests assert real values out of the real fixtures, so a default can
///    never stand in for a fact that went missing.
public struct Fields: Sendable {
    public let raw: [String: JSONValue]
    public init(_ raw: [String: JSONValue]) { self.raw = raw }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.raw = try c.decode([String: JSONValue].self)
    }

    public subscript(key: String) -> JSONValue? {
        guard let v = raw[key], !v.isNull else { return nil }
        return v
    }

    public func has(_ key: String) -> Bool { self[key] != nil }

    public func string(_ key: String, _ fallback: String = "") -> String {
        self[key]?.stringValue ?? fallback
    }
    public func stringOrNil(_ key: String) -> String? { self[key]?.stringValue }
    public func int(_ key: String, _ fallback: Int = 0) -> Int { self[key]?.intValue ?? fallback }
    public func intOrNil(_ key: String) -> Int? { self[key]?.intValue }
    public func double(_ key: String, _ fallback: Double = 0) -> Double { self[key]?.doubleValue ?? fallback }
    /// An empty string is "not measured", which is what `borderline` is on
    /// most frames. It is not zero.
    public func doubleOrNil(_ key: String) -> Double? {
        guard let v = self[key] else { return nil }
        if case .string(let s) = v, s.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return v.doubleValue
    }
    public func bool(_ key: String, _ fallback: Bool = false) -> Bool { self[key]?.boolValue ?? fallback }

    public func strings(_ key: String) -> [String] {
        (self[key]?.arrayValue ?? []).compactMap(\.stringValue)
    }
    public func ints(_ key: String) -> [Int] {
        (self[key]?.arrayValue ?? []).compactMap(\.intValue)
    }
    public func doubles(_ key: String) -> [Double] {
        (self[key]?.arrayValue ?? []).compactMap(\.doubleValue)
    }
    public func doublesOrNil(_ key: String) -> [Double]? {
        guard let a = self[key]?.arrayValue else { return nil }
        return a.compactMap(\.doubleValue)
    }
    public func counts(_ key: String) -> [String: Int] {
        (self[key]?.objectValue ?? [:]).compactMapValues(\.intValue)
    }
    public func words(_ key: String) -> [String: String] {
        (self[key]?.objectValue ?? [:]).compactMapValues(\.stringValue)
    }
    public func object(_ key: String) -> Fields? {
        self[key]?.objectValue.map(Fields.init)
    }
    public func objects(_ key: String) -> [Fields] {
        (self[key]?.arrayValue ?? []).compactMap { $0.objectValue.map(Fields.init) }
    }
    public func objectMap(_ key: String) -> [String: Fields] {
        (self[key]?.objectValue ?? [:]).compactMapValues { $0.objectValue.map(Fields.init) }
    }

    /// The whole object minus the names this app knows. It is how an
    /// extension's own fields reach an extension's own page without any of
    /// them being written down here.
    public func extra(without known: Set<String>) -> [String: JSONValue] {
        raw.filter { !known.contains($0.key) }
    }

    public func require(_ key: String) throws -> JSONValue {
        guard let v = self[key] else {
            throw DecodingError.keyNotFound(
                StringKey(key),
                .init(codingPath: [], debugDescription: "the engine did not send \(key)"))
        }
        return v
    }
    public func requireString(_ key: String) throws -> String {
        guard let s = try require(key).stringValue else {
            throw DecodingError.typeMismatch(String.self, .init(codingPath: [StringKey(key)],
                                                                debugDescription: "\(key) is not text"))
        }
        return s
    }
    public func requireInt(_ key: String) throws -> Int {
        guard let i = try require(key).intValue else {
            throw DecodingError.typeMismatch(Int.self, .init(codingPath: [StringKey(key)],
                                                             debugDescription: "\(key) is not a number"))
        }
        return i
    }
}

public struct StringKey: CodingKey, Sendable {
    public let stringValue: String
    public var intValue: Int? { nil }
    public init(_ s: String) { stringValue = s }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
}

/// A model that is decoded out of one JSON object.
public protocol FieldDecodable: Decodable, Sendable {
    init(fields: Fields) throws
}

extension FieldDecodable {
    public init(from decoder: Decoder) throws {
        try self.init(fields: Fields(from: decoder))
    }
}
