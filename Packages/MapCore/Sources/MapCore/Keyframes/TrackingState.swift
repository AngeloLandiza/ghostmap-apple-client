/// Mirror of `ARCamera.TrackingState` without importing ARKit, with a stable wire encoding.
public enum TrackingState: Sendable, Equatable, Hashable, Codable {
    case normal
    case limited(LimitedReason)
    case notAvailable

    public enum LimitedReason: UInt8, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case initializing = 0
        case excessiveMotion = 1
        case insufficientFeatures = 2
        case relocalizing = 3
        case unknown = 4

        public var label: String {
            switch self {
            case .initializing: return "initializing"
            case .excessiveMotion: return "excessive motion"
            case .insufficientFeatures: return "insufficient features"
            case .relocalizing: return "relocalizing"
            case .unknown: return "unknown"
            }
        }
    }

    public var isNormal: Bool {
        if case .normal = self { return true }
        return false
    }

    /// Wire encoding: 0 = normal, 1 = limited, 2 = not available.
    public var rawState: UInt8 {
        switch self {
        case .normal: return 0
        case .limited: return 1
        case .notAvailable: return 2
        }
    }

    /// Wire encoding of the limited reason; 0 when not limited.
    public var rawReason: UInt8 {
        if case .limited(let reason) = self { return reason.rawValue }
        return 0
    }

    public init(rawState: UInt8, rawReason: UInt8) {
        switch rawState {
        case 0: self = .normal
        case 1: self = .limited(LimitedReason(rawValue: rawReason) ?? .unknown)
        default: self = .notAvailable
        }
    }

    public var label: String {
        switch self {
        case .normal: return "normal"
        case .limited(let reason): return "limited: \(reason.label)"
        case .notAvailable: return "not available"
        }
    }
}
