import Foundation

/// Conversion between the backend's `snake_case` JSON keys and Swift's `camelCase` property names.
///
/// **Acronyms stay lowercase on purpose** (`device_id` ⇄ `deviceId`, not `deviceID`). The backend
/// serialises hand-written payloads as `snake_case` but returns database rows straight from
/// Drizzle, whose keys are the lower-camel form of the same column names (`pointCount`,
/// `parentMapId`, `inviteCode`). Because `toCamelCase` produces exactly that form, *both*
/// spellings of a key decode into the same Swift property, so one set of models reads both — and
/// keeps reading them if the backend later normalises everything to `snake_case`.
/// Requests are always encoded as `snake_case`, which is what the server's validators expect.
public enum SnakeCase: Sendable {

    /// `"device_id"` → `"deviceId"`. Leading/trailing underscores are preserved.
    public static func toCamelCase(_ key: String) -> String {
        guard key.contains("_") else { return key }
        let leading = key.prefix { $0 == "_" }
        let trailing = key.reversed().prefix { $0 == "_" }
        let core = String(key.dropFirst(leading.count).dropLast(trailing.count))
        guard !core.isEmpty else { return key }
        let parts = core.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return key }
        var out = first.lowercased()
        for part in parts.dropFirst() {
            let lower = part.lowercased()
            out += lower.prefix(1).uppercased() + lower.dropFirst()
        }
        return String(leading) + out + String(repeating: "_", count: trailing.count)
    }

    /// `"deviceId"` → `"device_id"`. A run of capitals is one word (`parseHTTPBody` → `parse_http_body`),
    /// except that its last letter starts a new word when a lowercase letter follows
    /// (`mapIDValue` → `map_id_value`).
    public static func fromCamelCase(_ key: String) -> String {
        guard key.contains(where: { $0.isUppercase }) else { return key }
        let chars = Array(key)
        var out = ""
        out.reserveCapacity(chars.count + 4)
        for (i, c) in chars.enumerated() {
            guard c.isUppercase else {
                out.append(c)
                continue
            }
            if i > 0 {
                let previous = chars[i - 1]
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLower) {
                    if !out.hasSuffix("_") { out.append("_") }
                }
            }
            out.append(Character(c.lowercased()))
        }
        return out
    }
}

/// A `CodingKey` built from an arbitrary string (or array index).
public struct AnyCodingKey: CodingKey, Sendable, Hashable {
    public let stringValue: String
    public let intValue: Int?

    public init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    public init(_ key: some CodingKey) {
        self.stringValue = key.stringValue
        self.intValue = key.intValue
    }
}

/// JSON coders configured for the Ghostmap backend.
public enum GhostmapJSON: Sendable {

    /// Keys whose *contents* are opaque JSON that must survive a decode/encode round trip
    /// unchanged: HTTP header dictionaries, the Ably token request and the map manifest.
    /// Nothing below one of these keys is converted.
    public static let opaqueKeys: Set<String> = ["headers", "token_request", "tokenRequest", "manifest", "details"]

    /// True when `path` names a key inside an opaque subtree (i.e. one of its *ancestors* is opaque).
    public static func isInsideOpaqueSubtree(_ path: [CodingKey]) -> Bool {
        path.dropLast().contains { opaqueKeys.contains($0.stringValue) }
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { @Sendable path in
            guard let last = path.last else { return AnyCodingKey(stringValue: "") }
            if isInsideOpaqueSubtree(path) { return AnyCodingKey(last) }
            return AnyCodingKey(stringValue: SnakeCase.toCamelCase(last.stringValue))
        }
        decoder.dateDecodingStrategy = .custom { @Sendable decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                guard let date = ISO8601Timestamp.date(from: text) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid timestamp \(text)")
                }
                return date
            }
            let seconds = try container.decode(Double.self)
            return Date(timeIntervalSince1970: seconds)
        }
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .custom { @Sendable path in
            guard let last = path.last else { return AnyCodingKey(stringValue: "") }
            if isInsideOpaqueSubtree(path) { return AnyCodingKey(last) }
            return AnyCodingKey(stringValue: SnakeCase.fromCamelCase(last.stringValue))
        }
        encoder.dateEncodingStrategy = .custom { @Sendable date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601Timestamp.string(from: date))
        }
        return encoder
    }
}

/// ISO 8601 timestamps as produced by the backend (`2026-09-04T12:00:00.123Z`, or without
/// fractional seconds). `Foundation.ISO8601DateFormatter` rejects one of the two forms depending
/// on its options, so both are tried.
public enum ISO8601Timestamp: Sendable {

    public static func date(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let d = formatter(fractionalSeconds: true).date(from: trimmed) { return d }
        if let d = formatter(fractionalSeconds: false).date(from: trimmed) { return d }
        return nil
    }

    public static func string(from date: Date) -> String {
        formatter(fractionalSeconds: true).string(from: date)
    }

    /// `ISO8601DateFormatter` is not `Sendable`, and timestamps appear a handful of times per
    /// response, so a formatter is built per call rather than shared across isolation domains.
    private static func formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractionalSeconds ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }
}
