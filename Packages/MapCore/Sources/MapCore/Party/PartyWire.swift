import Foundation

extension TrackingState {
    /// The backend's `tracking_state` enum for a party keyframe:
    /// `normal | limited | relocalizing | not_available` (`keyframeIn` in the backend's schemas).
    ///
    /// ARKit's richer limited reasons collapse to `limited`, except relocalizing, which the contract
    /// keeps separate because it is the one a viewer should grey out rather than trust.
    public var wireName: String {
        switch self {
        case .normal: return "normal"
        case .limited(let reason): return reason == .relocalizing ? "relocalizing" : "limited"
        case .notAvailable: return "not_available"
        }
    }

    /// Inverse of ``wireName``, for reading a peer's keyframe off the channel. Anything unknown is
    /// treated as `not_available` rather than silently trusted.
    public init(wireName: String) {
        switch wireName {
        case "normal": self = .normal
        case "limited": self = .limited(.unknown)
        case "relocalizing": self = .limited(.relocalizing)
        default: self = .notAvailable
        }
    }
}
