import Foundation
import MapCore

// MARK: - Open string enumerations

/// A string the backend may extend without breaking the client: unknown values decode into
/// `rawValue` instead of failing.
protocol WireString: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible where RawValue == String {
    init(rawValue: String)
}

extension WireString {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }
}

struct GhostmapRole: WireString {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let device = GhostmapRole(rawValue: "device")
    static let user = GhostmapRole(rawValue: "user")
    static let client = GhostmapRole(rawValue: "client")
    static let worker = GhostmapRole(rawValue: "worker")
    static let admin = GhostmapRole(rawValue: "admin")

    /// Device tokens are the only ones that may upload maps and stream keyframes.
    var canMap: Bool { self == .device }
}

struct CloudMapStatus: WireString {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let uploading = CloudMapStatus(rawValue: "uploading")
    static let saved = CloudMapStatus(rawValue: "saved")
    static let failed = CloudMapStatus(rawValue: "failed")
    static let deleted = CloudMapStatus(rawValue: "deleted")
}

struct SessionStatus: WireString {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let active = SessionStatus(rawValue: "active")
    static let ended = SessionStatus(rawValue: "ended")
    static let merging = SessionStatus(rawValue: "merging")
    static let merged = SessionStatus(rawValue: "merged")
    static let failed = SessionStatus(rawValue: "failed")
}

struct ParticipantKind: WireString {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    /// A phone that maps.
    static let device = ParticipantKind(rawValue: "device")
    /// A browser or phone that only watches.
    static let viewer = ParticipantKind(rawValue: "viewer")
}

struct ParticipantRole: WireString {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let leader = ParticipantRole(rawValue: "leader")
    static let member = ParticipantRole(rawValue: "member")
}

/// Why a party cannot be joined (`GET /v1/sessions/by-code/:code`).
struct JoinRejection: WireString {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let sessionFull = JoinRejection(rawValue: "session_full")
    static let sessionEnded = JoinRejection(rawValue: "session_ended")

    var message: String {
        switch self {
        case .sessionFull: return "This party is full."
        case .sessionEnded: return "This party has ended."
        default: return "This party cannot be joined."
        }
    }
}

/// The six files a map folder may contain, as the backend names them.
struct CloudMapFile: WireString {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let manifest = CloudMapFile(rawValue: "manifest.json")
    static let keyframes = CloudMapFile(rawValue: "keyframes.bin")
    static let cloud = CloudMapFile(rawValue: "cloud.ply")
    static let thumbnail = CloudMapFile(rawValue: "thumbnail.png")
    static let worldMap = CloudMapFile(rawValue: "worldmap.arworldmap")
    static let log = CloudMapFile(rawValue: "session.log")

    /// What `POST /v1/maps` uploads by default (the world map is optional).
    static let defaults: [CloudMapFile] = [.manifest, .keyframes, .cloud, .thumbnail, .log]
}

/// Keyframe payload kinds for `POST /v1/sessions/:id/upload-urls`.
struct KeyframeAssetKind: WireString {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let depth = KeyframeAssetKind(rawValue: "depth")
    static let confidence = KeyframeAssetKind(rawValue: "confidence")
    static let jpeg = KeyframeAssetKind(rawValue: "jpeg")
    static let mesh = KeyframeAssetKind(rawValue: "mesh")
}

// MARK: - Shared records

/// This installation, as reported to `POST /v1/auth/google`.
struct DeviceIdentity: Codable, Sendable, Equatable {
    /// A UUID generated once and kept in the keychain.
    let id: String
    let name: String
    /// `ios`, `ipados`, `web`, `worker` or `other`.
    let platform: String

    init(id: UUID, name: String, platform: String = "ios") {
        self.id = id.uuidString.lowercased()
        // The backend caps the name at 80 characters.
        self.name = String(name.prefix(80))
        self.platform = platform
    }
}

struct GhostmapUser: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let email: String?
    let name: String?
    let pictureUrl: String?
    let createdAt: Date?

    /// Name if the account has one, otherwise the email address.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let email, !email.isEmpty { return email }
        return "Signed in"
    }
}

/// The origin frame a map or party is expressed in.
struct CloudOrigin: Codable, Sendable, Equatable {
    let type: String
    let markerId: String?

    static let sessionStart = CloudOrigin(type: "session-start", markerId: nil)
    static func marker(_ id: String) -> CloudOrigin { CloudOrigin(type: "marker", markerId: id) }
}

/// A direct-to-GCS upload ticket. `resumable` entries need a `POST` to open the session followed
/// by a `PUT` of the bytes to the `Location` GCS returns.
struct SignedUpload: Codable, Sendable, Equatable {
    let path: String
    let url: String
    let method: String
    let headers: [String: String]
    let expiresAt: Date?
    let resumable: Bool?
}

struct SignedDownload: Codable, Sendable, Equatable {
    let url: String
    let expiresAt: Date?
}

// MARK: - Health and authentication

struct HealthResponse: Codable, Sendable, Equatable {
    let ok: Bool
    let configured: Bool?
    let missingEnv: [String]?
    let envIssues: [String]?
    let service: String?
    let version: String?
    let region: String?
    let time: Date?
}

struct GoogleSignInRequest: Codable, Sendable, Equatable {
    let idToken: String
    let device: DeviceIdentity?
}

struct AuthResponse: Codable, Sendable, Equatable {
    let token: String
    let expiresAt: Date
    let role: GhostmapRole
    let deviceId: String?
    let user: GhostmapUser?
}

struct MeResponse: Codable, Sendable, Equatable {
    let role: GhostmapRole
    let deviceId: String?
    let user: GhostmapUser?
}

/// What the keychain holds between launches. Written by `AccountStore`, read by `GhostmapAPI`.
struct StoredCredentials: Codable, Sendable, Equatable {
    var token: String
    var expiresAt: Date
    var role: GhostmapRole
    var deviceId: String?
    var user: GhostmapUser?

    func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        expiresAt.addingTimeInterval(-leeway) <= now
    }

    static func load() -> StoredCredentials? {
        (try? Keychain.value(StoredCredentials.self, for: .credentials)) ?? nil
    }

    func save() throws {
        try Keychain.setValue(self, for: .credentials)
    }

    static func clear() throws {
        try Keychain.remove(.credentials)
    }
}

// MARK: - Maps

struct CloudMap: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let version: Int?
    let parentMapId: String?
    let sessionId: String?
    let deviceId: String?
    let ownerUserId: String?
    let frame: String?
    let origin: CloudOrigin?
    let status: CloudMapStatus
    let manifest: JSONValue?
    let pointCount: Int?
    let keyframeCount: Int?
    let bbox: JSONValue?
    let durationS: Double?
    let sizeBytes: Int?
    let files: [String]?
    let createdAt: Date?
    let finalizedAt: Date?
}

struct CreateMapRequest: Codable, Sendable, Equatable {
    let name: String
    let frame: String?
    let origin: CloudOrigin?
    let sessionId: String?
    let parentMapId: String?
    let files: [CloudMapFile]?

    init(name: String, frame: String? = nil, origin: CloudOrigin? = nil, sessionId: String? = nil, parentMapId: String? = nil, files: [CloudMapFile]? = nil) {
        self.name = name
        self.frame = frame
        self.origin = origin
        self.sessionId = sessionId
        self.parentMapId = parentMapId
        self.files = files
    }
}

struct MapEnvelope: Codable, Sendable, Equatable {
    let map: CloudMap
}

struct CreateMapResponse: Codable, Sendable, Equatable {
    let map: CloudMap
    let uploads: [SignedUpload]
}

struct UploadURLsResponse: Codable, Sendable, Equatable {
    let uploads: [SignedUpload]
}

struct MapListResponse: Codable, Sendable, Equatable {
    let maps: [CloudMap]
    /// ISO 8601 timestamp to pass back as `cursor`.
    let nextCursor: String?
}

struct MapDetailResponse: Codable, Sendable, Equatable {
    let map: CloudMap
    let downloads: [String: SignedDownload]?
}

struct DeleteMapResponse: Codable, Sendable, Equatable {
    let deleted: Bool
    let objectsRemoved: Int?
}

// MARK: - Parties (sessions)

struct CloudSession: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let status: SessionStatus
    let origin: CloudOrigin?
    let leaderDeviceId: String?
    let ownerUserId: String?
    let inviteCode: String?
    let maxParticipants: Int?
    let baseMapId: String?
    let mergedMapId: String?
    let keyframeCount: Int?
    let bytes: Int?
    let createdAt: Date?
    let endedAt: Date?
    /// Present on `GET /v1/sessions` rows only: distinct active identities and the owner's display name.
    let participantCount: Int?
    let ownerName: String?
}

struct SessionParticipant: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let sessionId: String?
    let deviceId: String?
    let userId: String?
    let kind: ParticipantKind
    /// A hex colour from the backend's palette of eight.
    let color: String?
    let displayName: String?
    let role: ParticipantRole?
    let joinedAt: Date?
    let leftAt: Date?

    var isActive: Bool { leftAt == nil }
}

struct CreateSessionRequest: Codable, Sendable, Equatable {
    let name: String
    let origin: CloudOrigin?
    let baseMapId: String?
    let maxParticipants: Int?

    init(name: String, origin: CloudOrigin? = nil, baseMapId: String? = nil, maxParticipants: Int? = nil) {
        self.name = name
        self.origin = origin
        self.baseMapId = baseMapId
        self.maxParticipants = maxParticipants
    }
}

struct SessionEnvelope: Codable, Sendable, Equatable {
    let session: CloudSession
    let participants: [SessionParticipant]
    let channel: String?
    let shareUrl: String?
}

struct SessionListResponse: Codable, Sendable, Equatable {
    let sessions: [CloudSession]
}

struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let status: SessionStatus
    let origin: CloudOrigin?
    let inviteCode: String?
    let shareUrl: String?
    let participantCount: Int?
    let maxParticipants: Int?
    let ownerName: String?
}

struct SessionByCodeResponse: Codable, Sendable, Equatable {
    let session: SessionSummary
    let canJoin: Bool
    let reason: JoinRejection?
}

struct JoinSessionRequest: Codable, Sendable, Equatable {
    let code: String?
    let kind: ParticipantKind?
    let displayName: String?
}

struct RealtimeToken: Codable, Sendable, Equatable {
    /// Opaque Ably token request, passed to the SDK (or to the REST endpoint) verbatim.
    let tokenRequest: JSONValue?
    let channel: String?
    let canPublish: Bool?
}

struct JoinSessionResponse: Codable, Sendable, Equatable {
    let session: CloudSession
    let participants: [SessionParticipant]
    let channel: String?
    let shareUrl: String?
    /// The caller's own participant row.
    let me: SessionParticipant?
    let realtime: RealtimeToken?
}

struct LeaveSessionResponse: Codable, Sendable, Equatable {
    let left: Bool
    let participants: [SessionParticipant]?
}

struct SessionStatusResponse: Codable, Sendable, Equatable {
    let session: CloudSession
}

// MARK: - Keyframes

struct KeyframeIntrinsics: Codable, Sendable, Equatable {
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
    let w: Int
    let h: Int
}

struct KeyframeUploadItem: Codable, Sendable, Equatable {
    let seq: Int
    let kinds: [KeyframeAssetKind]
}

struct KeyframeUploadURLsRequest: Codable, Sendable, Equatable {
    let items: [KeyframeUploadItem]
}

struct KeyframeUpload: Codable, Sendable, Equatable {
    let seq: Int
    let kind: KeyframeAssetKind
    let path: String
    let url: String
    let method: String
    let headers: [String: String]
    let expiresAt: Date?
}

struct KeyframeUploadURLsResponse: Codable, Sendable, Equatable {
    let uploads: [KeyframeUpload]
}

/// One keyframe as streamed to a party. `pose` is column-major, in the party's origin frame;
/// `aligned` is false while the device has not seen the marker yet.
struct SessionKeyframe: Codable, Sendable, Equatable {
    let seq: Int
    let t: Double
    let pose: [Double]
    let intrinsics: KeyframeIntrinsics
    let trackingState: String?
    let worldMappingStatus: String?
    let aligned: Bool?
    let depthRef: String?
    let confidenceRef: String?
    let jpegRef: String?
    let meshRef: String?
    /// Flat `x y z r g b` floats, at most 2 000 points.
    let pointsInline: [Double]?
    let bytes: Int?

    init(
        seq: Int,
        t: Double,
        pose: [Double],
        intrinsics: KeyframeIntrinsics,
        trackingState: String? = nil,
        worldMappingStatus: String? = nil,
        aligned: Bool? = nil,
        depthRef: String? = nil,
        confidenceRef: String? = nil,
        jpegRef: String? = nil,
        meshRef: String? = nil,
        pointsInline: [Double]? = nil,
        bytes: Int? = nil
    ) {
        self.seq = seq
        self.t = t
        self.pose = pose
        self.intrinsics = intrinsics
        self.trackingState = trackingState
        self.worldMappingStatus = worldMappingStatus
        self.aligned = aligned
        self.depthRef = depthRef
        self.confidenceRef = confidenceRef
        self.jpegRef = jpegRef
        self.meshRef = meshRef
        self.pointsInline = pointsInline
        self.bytes = bytes
    }
}

struct RegisterKeyframesRequest: Codable, Sendable, Equatable {
    let keyframes: [SessionKeyframe]
}

struct RegisteredKeyframe: Codable, Sendable, Equatable {
    let id: Int?
    let seq: Int?
}

struct RegisterKeyframesResponse: Codable, Sendable, Equatable {
    let registered: [RegisteredKeyframe]
}

/// A stored keyframe row. Everything except the identity is optional because the row shape
/// depends on `urls=1` and on what the producing device sent.
struct StoredKeyframe: Codable, Sendable, Equatable {
    let id: Int?
    let sessionId: String?
    let deviceId: String?
    let seq: Int?
    let t: Double?
    let pose: [Double]?
    let intrinsics: KeyframeIntrinsics?
    let trackingState: String?
    let aligned: Bool?
    let depthRef: String?
    let confidenceRef: String?
    let jpegRef: String?
    let meshRef: String?
    let pointsInline: [Double]?
    let bytes: Int?
    let createdAt: Date?
    let urls: JSONValue?
}

struct KeyframeListResponse: Codable, Sendable, Equatable {
    let keyframes: [StoredKeyframe]
    let nextSinceId: Int?
}

// MARK: - Errors

/// The backend's error envelope: `{ "error": { "code", "message", "details?" } }`.
struct APIErrorEnvelope: Codable, Sendable, Equatable {
    struct Body: Codable, Sendable, Equatable {
        let code: String
        let message: String?
        let details: JSONValue?
    }

    let error: Body
}
