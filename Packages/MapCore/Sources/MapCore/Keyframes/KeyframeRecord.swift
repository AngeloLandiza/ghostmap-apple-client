/// Everything persisted for one keyframe. Depth is quantized to millimeters (0 = no depth) and
/// confidence is 0 (low), 1 (medium) or 2 (high); both are row-major at `intrinsics.width × height`.
public struct KeyframeRecord: Sendable, Equatable {
    public var seq: UInt32
    /// Seconds. In the app this is `ARFrame.timestamp` (system uptime); tests use arbitrary values.
    public var timestamp: Double
    /// `world_from_camera` (ARKit `camera.transform`, expressed in the map's origin frame).
    public var pose: Pose
    /// Intrinsics already scaled to the depth map resolution.
    public var intrinsics: Intrinsics
    public var tracking: TrackingState
    public var depthMillimeters: [UInt16]
    public var confidence: [UInt8]

    public init(seq: UInt32,
                timestamp: Double,
                pose: Pose,
                intrinsics: Intrinsics,
                tracking: TrackingState,
                depthMillimeters: [UInt16],
                confidence: [UInt8]) {
        self.seq = seq
        self.timestamp = timestamp
        self.pose = pose
        self.intrinsics = intrinsics
        self.tracking = tracking
        self.depthMillimeters = depthMillimeters
        self.confidence = confidence
    }

    public var pixelCount: Int { intrinsics.pixelCount }

    /// True when the depth and confidence arrays match the intrinsics' pixel count.
    public var isConsistent: Bool {
        depthMillimeters.count == pixelCount && confidence.count == pixelCount
    }
}
