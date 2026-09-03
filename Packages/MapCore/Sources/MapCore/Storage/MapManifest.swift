import Foundation
import simd

/// Identifier of one map directory (`Application Support/Maps/<mapID>/`). An uppercase UUID string.
public struct MapID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init() {
        self.rawValue = UUID().uuidString
    }

    public init?(rawValue: String) {
        guard UUID(uuidString: rawValue) != nil else { return nil }
        self.rawValue = rawValue.uppercased()
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = MapID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid map_id \(raw)"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }
}

public enum MapStatus: String, Sendable, Codable, Equatable {
    case recording
    case finalizing
    case saved
    case failed
}

/// Axis-aligned bounding box in world meters. `isEmpty` boxes have min > max.
public struct BoundingBox: Sendable, Equatable, Codable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    public static let empty = BoundingBox(
        min: SIMD3<Float>(repeating: .greatestFiniteMagnitude),
        max: SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    )

    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    public var isEmpty: Bool { min.x > max.x || min.y > max.y || min.z > max.z }

    public var extent: SIMD3<Float> { isEmpty ? .zero : max - min }

    public var center: SIMD3<Float> { isEmpty ? .zero : (min + max) * 0.5 }

    public mutating func formUnion(_ p: SIMD3<Float>) {
        min = simd_min(min, p)
        max = simd_max(max, p)
    }

    public mutating func formUnion(_ other: BoundingBox) {
        guard !other.isEmpty else { return }
        min = simd_min(min, other.min)
        max = simd_max(max, other.max)
    }

    public func union(_ p: SIMD3<Float>) -> BoundingBox {
        var b = self
        b.formUnion(p)
        return b
    }

    public func contains(_ p: SIMD3<Float>) -> Bool {
        !isEmpty && p.x >= min.x && p.y >= min.y && p.z >= min.z && p.x <= max.x && p.y <= max.y && p.z <= max.z
    }
}

/// Where the map's coordinate frame comes from. `session-start` today; the marker-based origin of the
/// MVP plan plugs in here (`type: "marker", marker_id: "tag36h11_0"`).
public struct OriginDescriptor: Sendable, Equatable, Codable {
    public var type: String
    public var markerID: String?

    public static let sessionStart = OriginDescriptor(type: "session-start", markerID: nil)

    public init(type: String, markerID: String?) {
        self.type = type
        self.markerID = markerID
    }

    enum CodingKeys: String, CodingKey {
        case type
        case markerID = "marker_id"
    }
}

public struct MapEncodings: Sendable, Equatable, Codable {
    public var depth: String
    public var confidence: String
    public var cloud: String
    public var keyframeLog: String

    public static let v1 = MapEncodings(
        depth: "u16mm+lzfse",
        confidence: "u8+lzfse",
        cloud: "ply-binary-little-endian-xyzrgb",
        keyframeLog: "smkf-v1"
    )

    public init(depth: String, confidence: String, cloud: String, keyframeLog: String) {
        self.depth = depth
        self.confidence = confidence
        self.cloud = cloud
        self.keyframeLog = keyframeLog
    }

    enum CodingKeys: String, CodingKey {
        case depth
        case confidence
        case cloud
        case keyframeLog = "keyframe_log"
    }
}

/// `manifest.json`. Field names mirror the MVP plan's manifest (`map_id`, `frame`, `bbox`, …).
public struct MapManifest: Sendable, Equatable, Codable {
    public static let currentVersion = 1
    public static let sessionStartFrame = "world:session-start"

    public var mapID: MapID
    public var version: Int
    public var name: String
    public var frame: String
    public var origin: OriginDescriptor
    public var bbox: BoundingBox?
    public var pointCount: Int
    public var keyframeCount: Int
    public var createdAt: Date
    public var durationSeconds: Double
    public var deviceModel: String
    public var iosVersion: String
    public var appVersion: String
    public var status: MapStatus
    public var encodings: MapEncodings
    public var sizeBytes: Int64?
    public var hasWorldMap: Bool
    public var voxelSizeMeters: Float
    public var finalizeSeconds: Double?

    public init(mapID: MapID = MapID(),
                version: Int = MapManifest.currentVersion,
                name: String,
                frame: String = MapManifest.sessionStartFrame,
                origin: OriginDescriptor = .sessionStart,
                bbox: BoundingBox? = nil,
                pointCount: Int = 0,
                keyframeCount: Int = 0,
                createdAt: Date,
                durationSeconds: Double = 0,
                deviceModel: String,
                iosVersion: String,
                appVersion: String = "1.0",
                status: MapStatus = .recording,
                encodings: MapEncodings = .v1,
                sizeBytes: Int64? = nil,
                hasWorldMap: Bool = false,
                voxelSizeMeters: Float = 0.02,
                finalizeSeconds: Double? = nil) {
        self.mapID = mapID
        self.version = version
        self.name = name
        self.frame = frame
        self.origin = origin
        self.bbox = bbox
        self.pointCount = pointCount
        self.keyframeCount = keyframeCount
        // `created_at` is an ISO-8601 timestamp with one-second resolution (FORMAT.md §2), so the
        // sub-second part of `createdAt` would be lost on the way to disk and a manifest would not
        // decode equal to the one that was encoded. Truncate up front instead.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.durationSeconds = durationSeconds
        self.deviceModel = deviceModel
        self.iosVersion = iosVersion
        self.appVersion = appVersion
        self.status = status
        self.encodings = encodings
        self.sizeBytes = sizeBytes
        self.hasWorldMap = hasWorldMap
        self.voxelSizeMeters = voxelSizeMeters
        self.finalizeSeconds = finalizeSeconds
    }

    enum CodingKeys: String, CodingKey {
        case mapID = "map_id"
        case version
        case name
        case frame
        case origin
        case bbox
        case pointCount = "point_count"
        case keyframeCount = "keyframe_count"
        case createdAt = "created_at"
        case durationSeconds = "duration_s"
        case deviceModel = "device_model"
        case iosVersion = "ios_version"
        case appVersion = "app_version"
        case status
        case encodings
        case sizeBytes = "size_bytes"
        case hasWorldMap = "has_world_map"
        case voxelSizeMeters = "voxel_size_m"
        case finalizeSeconds = "finalize_s"
    }

    public static func jsonEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func jsonDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func encoded() throws -> Data {
        try MapManifest.jsonEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> MapManifest {
        do {
            return try jsonDecoder().decode(MapManifest.self, from: data)
        } catch {
            throw MapError.invalidManifest(String(describing: error))
        }
    }

    /// Auto name such as "Room — Sep 2, 14:05".
    public static func defaultName(for date: Date, timeZone: TimeZone = .current, locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = "MMM d, HH:mm"
        return "Room — " + f.string(from: date)
    }
}
