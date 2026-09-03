import Foundation
import simd

/// Decides which tracked frames become keyframes.
///
/// A frame is a keyframe when the camera has moved more than
/// `Config.translationThresholdMeters`, turned more than `Config.rotationThresholdDegrees`, or at
/// least `Config.maxInterval` seconds have passed since the previous keyframe — provided tracking is
/// `.normal` when `Config.requireNormalTracking` is set. The first frame that passes the tracking
/// gate is always a keyframe.
///
/// Gates are checked in this fixed order and the first that fires wins:
/// 1. `mode == .paused` → `.skip(.paused)` (state untouched)
/// 2. `config.requireNormalTracking && !tracking.isNormal` → `.skip(.trackingNotNormal)`
/// 3. no previous keyframe → `.keyframe(.first)`
/// 4. translation since the last keyframe strictly greater than the threshold → `.keyframe(.translation)`
/// 5. rotation since the last keyframe strictly greater than the threshold (degrees) → `.keyframe(.rotation)`
/// 6. `timestamp - lastKeyframeTime >= maxInterval` → `.keyframe(.elapsed)`
/// 7. otherwise `.skip(.belowThresholds)`
///
/// `mode` mirrors the device thermal state: `.halved` (thermal `.serious`) doubles all three
/// thresholds so the keyframe rate roughly halves; `.paused` (thermal `.critical`) rejects every
/// frame without changing any state, so the next frame after un-pausing is judged against the
/// keyframe that preceded the pause.
///
/// Every `.keyframe` decision records `lastKeyframePose` / `lastKeyframeTime` and increments
/// `keyframeCount`; `.skip` decisions never change state. `evaluate` performs a handful of
/// floating-point operations and no allocation, so it may run inside the AR session callback.
public struct KeyframePolicy: Sendable {
    /// Thresholds that trigger a keyframe. The product defaults are 0.15 m, 12° and 0.75 s.
    public struct Config: Sendable, Equatable {
        /// Camera translation since the last keyframe above which (strictly) a keyframe is emitted, in meters.
        public var translationThresholdMeters: Float = 0.15
        /// Camera rotation since the last keyframe above which (strictly) a keyframe is emitted, in degrees.
        public var rotationThresholdDegrees: Float = 12
        /// Seconds since the last keyframe at or beyond which a keyframe is emitted even without motion.
        public var maxInterval: TimeInterval = 0.75
        /// When true, frames whose tracking state is not `.normal` are never keyframes.
        public var requireNormalTracking: Bool = true

        /// The product configuration: 0.15 m, 12°, 0.75 s, normal tracking required.
        public static let `default` = Config()

        /// Creates a configuration. Every parameter defaults to the product value.
        public init(translationThresholdMeters: Float = 0.15,
                    rotationThresholdDegrees: Float = 12,
                    maxInterval: TimeInterval = 0.75,
                    requireNormalTracking: Bool = true) {
            self.translationThresholdMeters = translationThresholdMeters
            self.rotationThresholdDegrees = rotationThresholdDegrees
            self.maxInterval = maxInterval
            self.requireNormalTracking = requireNormalTracking
        }
    }

    /// Thermal-driven operating mode.
    public enum Mode: Sendable, Equatable {
        /// Thresholds apply as configured (thermal `.nominal` / `.fair`).
        case normal
        /// Every threshold is doubled, halving the keyframe rate (thermal `.serious`).
        case halved
        /// No frame is a keyframe and no state changes (thermal `.critical`).
        case paused
    }

    /// Why a frame became a keyframe.
    public enum Reason: Sendable, Equatable {
        /// No previous keyframe existed.
        case first
        /// Translation since the last keyframe exceeded the threshold.
        case translation
        /// Rotation since the last keyframe exceeded the threshold.
        case rotation
        /// `maxInterval` elapsed since the last keyframe.
        case elapsed
    }

    /// Why a frame was not a keyframe.
    public enum SkipReason: Sendable, Equatable {
        /// `mode` is `.paused`.
        case paused
        /// Tracking was not `.normal` and `Config.requireNormalTracking` is set.
        case trackingNotNormal
        /// Motion and elapsed time were all within the thresholds.
        case belowThresholds
    }

    /// The outcome of `evaluate(pose:timestamp:tracking:)`.
    public enum Decision: Sendable, Equatable {
        /// Emit a keyframe for this frame.
        case keyframe(Reason)
        /// Drop this frame.
        case skip(SkipReason)
    }

    /// Thresholds in effect for `.normal` mode; `.halved` doubles them (see `effectiveConfig`).
    public var config: Config

    /// Current thermal mode. Starts as `.normal` and is not affected by `reset()`.
    public var mode: Mode

    /// Pose of the most recent keyframe, or nil before the first keyframe and after `reset()`.
    public private(set) var lastKeyframePose: Pose?

    /// Timestamp of the most recent keyframe, or nil before the first keyframe and after `reset()`.
    public private(set) var lastKeyframeTime: TimeInterval?

    /// Number of `.keyframe` decisions since initialization or the last `reset()`.
    public private(set) var keyframeCount: Int

    /// Creates a policy in `.normal` mode with no keyframe history.
    public init(config: Config = .default) {
        self.config = config
        self.mode = .normal
        self.lastKeyframePose = nil
        self.lastKeyframeTime = nil
        self.keyframeCount = 0
    }

    /// The thresholds actually compared against under the current `mode`: `config` unchanged for
    /// `.normal` and `.paused`, and `config` with translation, rotation and interval thresholds all
    /// multiplied by 2 for `.halved`. `requireNormalTracking` is never altered.
    var effectiveConfig: Config {
        guard mode == .halved else { return config }
        var doubled = config
        doubled.translationThresholdMeters *= 2
        doubled.rotationThresholdDegrees *= 2
        doubled.maxInterval *= 2
        return doubled
    }

    /// Judges one frame. See the type documentation for the gate order. A `.keyframe` result
    /// updates `lastKeyframePose`, `lastKeyframeTime` and `keyframeCount`; a `.skip` result leaves
    /// the policy untouched. A `timestamp` earlier than `lastKeyframeTime` can never satisfy the
    /// elapsed gate.
    public mutating func evaluate(pose: Pose, timestamp: TimeInterval, tracking: TrackingState) -> Decision {
        if mode == .paused {
            return .skip(.paused)
        }
        if config.requireNormalTracking && !tracking.isNormal {
            return .skip(.trackingNotNormal)
        }
        guard let lastPose = lastKeyframePose, let lastTime = lastKeyframeTime else {
            return accept(.first, pose: pose, timestamp: timestamp)
        }
        let thresholds = effectiveConfig
        if lastPose.translationDistance(to: pose) > thresholds.translationThresholdMeters {
            return accept(.translation, pose: pose, timestamp: timestamp)
        }
        if lastPose.rotationAngleDegrees(to: pose) > thresholds.rotationThresholdDegrees {
            return accept(.rotation, pose: pose, timestamp: timestamp)
        }
        if timestamp - lastTime >= thresholds.maxInterval {
            return accept(.elapsed, pose: pose, timestamp: timestamp)
        }
        return .skip(.belowThresholds)
    }

    /// Forgets the keyframe history (`lastKeyframePose`, `lastKeyframeTime`, `keyframeCount`) so the
    /// next accepted frame is `.keyframe(.first)` again. `config` and `mode` are unchanged.
    public mutating func reset() {
        lastKeyframePose = nil
        lastKeyframeTime = nil
        keyframeCount = 0
    }

    /// Records `pose`/`timestamp` as the latest keyframe and returns the matching decision.
    private mutating func accept(_ reason: Reason, pose: Pose, timestamp: TimeInterval) -> Decision {
        lastKeyframePose = pose
        lastKeyframeTime = timestamp
        keyframeCount += 1
        return .keyframe(reason)
    }
}
