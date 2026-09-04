import Foundation

/// An arbitrary JSON value, used for the parts of the API that are opaque to the client:
/// the map manifest, `origin`, `bbox`, and the Ably `token_request` blob.
///
/// Integers keep their integer form so a round trip does not turn `1` into `1.0`.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    public var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }
    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(exactly: v.rounded())
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }
    public var boolValue: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { return v } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v } else { return nil } }
    public var isNull: Bool { self == .null }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Converts a `JSONSerialization`-style value (`[String: Any]`, `NSNumber`, …).
    /// Returns `nil` for anything that is not representable as JSON.
    public init?(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let v as NSNumber:
            // Bool bridges to NSNumber, so the CoreFoundation type id is the only way to tell them apart.
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                self = .bool(v.boolValue)
            } else if let i = Int(exactly: v) {
                self = .int(i)
            } else {
                self = .double(v.doubleValue)
            }
        case let v as String:
            self = .string(v)
        case let v as [Any]:
            var out: [JSONValue] = []
            out.reserveCapacity(v.count)
            for element in v {
                guard let converted = JSONValue(any: element) else { return nil }
                out.append(converted)
            }
            self = .array(out)
        case let v as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, element) in v {
                guard let converted = JSONValue(any: element) else { return nil }
                out[k] = converted
            }
            self = .object(out)
        default:
            return nil
        }
    }

    /// The `JSONSerialization`-compatible representation, for handing opaque blobs to other APIs.
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.anyValue)
        case .object(let v): return v.mapValues(\.anyValue)
        }
    }
}
