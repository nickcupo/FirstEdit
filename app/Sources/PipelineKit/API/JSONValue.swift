import Foundation

/// Any JSON the engine can send, carried without being named.
///
/// Two jobs, and only two. It carries the fields an extension adds to a shoot
/// row through the app untouched — nothing in `PipelineKit` ever matches on a
/// key that came out of one, because the extension's vocabulary is not in this
/// repository. And it is what `Fields` reads, which is how a model survives a
/// server that spells a number as a string.
public enum JSONValue: Sendable, Hashable, Codable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool before Int: JSONDecoder will read `true` as an Int on some
        // paths and a shoot that is "finished: 1" is not the same fact as a
        // shoot that is finished.
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .integer(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not JSON this app can carry")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var isNull: Bool { if case .null = self { return true }; return false }

    /// The engine writes `cull.csv` straight out with `csv.DictReader`, so
    /// `rating` arrives as `"3"` and `focus` as `"53.7"` while `override`,
    /// which the app itself wrote, arrives as `5`. Both are the same fact and
    /// both have to read as one.
    public var intValue: Int? {
        switch self {
        case .integer(let v): return v
        case .number(let v): return v.isFinite ? Int(v.rounded()) : nil
        case .bool(let v): return v ? 1 : 0
        case .string(let v):
            let t = v.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { return i }
            if let d = Double(t), d.isFinite { return Int(d.rounded()) }
            return nil
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let v): return Double(v)
        case .number(let v): return v
        case .bool(let v): return v ? 1 : 0
        case .string(let v):
            let d = Double(v.trimmingCharacters(in: .whitespaces))
            return (d?.isFinite ?? false) ? d : nil
        default: return nil
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let v): return v
        case .integer(let v): return String(v)
        case .number(let v): return String(v)
        case .bool(let v): return v ? "true" : "false"
        default: return nil
        }
    }

    /// Python writes a date string where it means "finished on", and `false`
    /// where it means "not finished". An empty string is not a yes.
    public var boolValue: Bool? {
        switch self {
        case .bool(let v): return v
        case .integer(let v): return v != 0
        case .number(let v): return v != 0
        case .string(let v):
            let t = v.trimmingCharacters(in: .whitespaces).lowercased()
            if t.isEmpty || t == "false" || t == "0" || t == "none" { return false }
            return true
        case .null: return false
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
}
