import Foundation
import simd

/// A pose together with the contract's `aligned` flag: `true` once a marker has defined the origin,
/// `false` while the pose is still expressed in the ARKit world frame (the session-start origin).
public struct AlignedPose: Sendable, Equatable {
    public var pose: Pose
    public var aligned: Bool

    public init(pose: Pose, aligned: Bool) {
        self.pose = pose
        self.aligned = aligned
    }
}

/// The origin of a capture as defined by a printed marker.
///
/// ARKit reports the marker as an image anchor whose `transform` is `world_from_origin`: it maps a
/// point in the marker's frame into the ARKit world frame. Everything a party uploads is expressed
/// in the *marker* frame, so the pose that goes on the wire is
///
///     origin_from_camera = world_from_origin⁻¹ · world_from_camera
///
/// Feed observations in with ``observe(worldFromOrigin:isTracked:name:timestamp:)`` and, once per
/// frame, call ``tick(timestamp:staleAfter:)`` so an anchor that silently stops updating still
/// decays to ``State/lost``.
///
/// Once a marker has been seen the origin stays valid even when the marker leaves the field of view
/// — ARKit keeps tracking the anchor in the world frame — so ``isAligned`` is true in both
/// ``State/tracking`` and ``State/lost``; `.lost` only says that no fresh observation is confirming
/// it, i.e. that world-tracking drift is no longer being corrected.
public struct MarkerOrigin: Sendable, Equatable {

    public enum State: String, Sendable, Equatable, CaseIterable {
        /// No marker has been seen in this session: poses are in the ARKit world frame.
        case none
        /// The marker is being observed and the origin is being refreshed.
        case tracking
        /// The marker was seen but is not currently observed; the last origin is still in use.
        case lost

        /// What the status strip prints after "Marker: ".
        public var label: String {
            switch self {
            case .none: return "none"
            case .tracking: return "aligned"
            case .lost: return "lost"
            }
        }

        /// Whether poses derived from this origin are in the marker frame (the wire `aligned` flag).
        public var isAligned: Bool { self != .none }
    }

    /// Default seconds without a tracked observation before the origin is reported as ``State/lost``.
    public static let defaultStaleAfter: TimeInterval = 1.0

    public private(set) var state: State = .none
    /// `world_from_origin`: the marker's pose in the ARKit world frame. Identity until a marker is seen.
    public private(set) var worldFromOrigin: Pose = .identity
    /// The reference image name of the marker that defined the origin.
    public private(set) var markerID: String?
    /// Frame timestamp of the most recent tracked observation.
    public private(set) var lastUpdate: TimeInterval?
    /// Frame timestamp of the very first tracked observation.
    public private(set) var firstDetection: TimeInterval?
    /// How many times the origin went from `.none`/`.lost` to `.tracking`.
    public private(set) var detections = 0
    /// How many times a tracked origin dropped to `.lost`.
    public private(set) var losses = 0

    public init() {}

    public var isAligned: Bool { state.isAligned }

    /// The origin transform once a marker has been seen, otherwise nil.
    public var resolvedWorldFromOrigin: Pose? { state == .none ? nil : worldFromOrigin }

    // MARK: - Pure math

    /// `origin_from_camera = world_from_origin⁻¹ · world_from_camera`.
    public static func originFromCamera(worldFromOrigin: Pose, worldFromCamera: Pose) -> Pose {
        worldFromOrigin.inverse * worldFromCamera
    }

    /// The camera pose in the marker frame, or nil while no marker has been seen.
    public func markerFrame(from worldFromCamera: Pose) -> Pose? {
        guard state != .none else { return nil }
        return MarkerOrigin.originFromCamera(worldFromOrigin: worldFromOrigin, worldFromCamera: worldFromCamera)
    }

    /// Matrix overload for callers holding an `ARCamera.transform` directly.
    public func markerFrame(from worldFromCamera: simd_float4x4) -> simd_float4x4? {
        markerFrame(from: Pose(matrix: worldFromCamera)).map(\.matrix)
    }

    /// The pose to upload for `worldFromCamera`: the marker frame with `aligned == true` once a
    /// marker has been seen, otherwise the ARKit world pose unchanged with `aligned == false`.
    public func alignedPose(worldFromCamera: Pose) -> AlignedPose {
        guard let marker = markerFrame(from: worldFromCamera) else {
            return AlignedPose(pose: worldFromCamera, aligned: false)
        }
        return AlignedPose(pose: marker, aligned: true)
    }

    /// Matrix overload of ``alignedPose(worldFromCamera:)``.
    public func alignedPose(worldFromCamera: simd_float4x4) -> AlignedPose {
        alignedPose(worldFromCamera: Pose(matrix: worldFromCamera))
    }

    // MARK: - Observations

    /// One image-anchor observation. Returns the (old, new) state pair so the caller logs only edges.
    @discardableResult
    public mutating func observe(worldFromOrigin: Pose,
                                 isTracked: Bool,
                                 name: String? = nil,
                                 timestamp: TimeInterval? = nil) -> (from: State, to: State) {
        let old = state
        if isTracked {
            self.worldFromOrigin = worldFromOrigin
            if let name { markerID = name }
            lastUpdate = timestamp
            if firstDetection == nil { firstDetection = timestamp }
            if old != .tracking {
                detections += 1
                state = .tracking
            }
        } else if old != .none {
            // Keep the last origin: ARKit still tracks the anchor's world pose, the marker is only
            // no longer being re-observed.
            if old != .lost {
                losses += 1
                state = .lost
            }
        }
        return (old, state)
    }

    /// Demotes a tracked origin to ``State/lost`` when no observation arrived for `staleAfter`
    /// seconds. ARKit does not always deliver a final "not tracked" update, so the frame loop calls
    /// this with the frame timestamp. Returns the (old, new) state pair.
    @discardableResult
    public mutating func tick(timestamp: TimeInterval,
                              staleAfter: TimeInterval = MarkerOrigin.defaultStaleAfter) -> (from: State, to: State) {
        guard state == .tracking, let last = lastUpdate, timestamp - last > staleAfter else {
            return (state, state)
        }
        losses += 1
        state = .lost
        return (.tracking, .lost)
    }

    /// Forgets the marker. Call it whenever ARKit resets tracking and drops existing anchors.
    public mutating func reset() {
        self = MarkerOrigin()
    }
}
