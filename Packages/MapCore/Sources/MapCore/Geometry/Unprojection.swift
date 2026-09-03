import simd

/// Turns a quantized depth map (millimeters, row-major at `intrinsics.width × height`) into world-space
/// points. Every retained pixel is unprojected at its center through `Intrinsics.unproject(pixelU:pixelV:depth:)`
/// (ARKit camera convention: x right, y up, −z forward) and then mapped through `pose.transform`, where
/// `pose` is `world_from_camera`.
///
/// Pixels are skipped when their depth is 0 (no measurement), their confidence is below
/// `Options.minConfidence`, or their depth in meters (`Float(mm) / 1000`) lies outside
/// `[Options.minDepthMeters, Options.maxDepthMeters]`. `Options.stride` samples every stride-th pixel in
/// both `u` and `v`, starting at 0. Retained pixels are visited in row-major scan order.
///
/// The hot loop performs no per-pixel allocations: both output arrays are reserved up front for the
/// largest possible retained count.
public enum Unprojector {

    /// Filtering and sampling parameters for one unprojection pass.
    public struct Options: Sendable, Equatable {
        /// Minimum ARKit depth confidence a pixel needs to be retained: 0 = low, 1 = medium, 2 = high.
        public var minConfidence: UInt8
        /// Pixels closer than this (meters along the optical axis) are dropped.
        public var minDepthMeters: Float
        /// Pixels farther than this (meters along the optical axis) are dropped.
        public var maxDepthMeters: Float
        /// Sample every Nth pixel in `u` and in `v`, starting at pixel 0. Values below 1 behave as 1.
        public var stride: Int

        /// Creates options; every parameter defaults to the values in the MapCore API contract.
        public init(minConfidence: UInt8 = 1,
                    minDepthMeters: Float = 0.1,
                    maxDepthMeters: Float = 5.0,
                    stride: Int = 1) {
            self.minConfidence = minConfidence
            self.minDepthMeters = minDepthMeters
            self.maxDepthMeters = maxDepthMeters
            self.stride = stride
        }
    }

    /// Output of an unprojection pass. `positions[i]` is the world-space point of the pixel whose
    /// row-major index (`v * width + u`) is `pixelIndices[i]`; both arrays always have the same count.
    public struct Result: Sendable, Equatable {
        /// World-space points of the retained pixels, in row-major scan order.
        public var positions: [SIMD3<Float>]
        /// Row-major pixel index (`v * width + u`) of each retained pixel, parallel to `positions`.
        public var pixelIndices: [Int32]

        /// Creates a result from parallel arrays; both default to empty.
        public init(positions: [SIMD3<Float>] = [], pixelIndices: [Int32] = []) {
            self.positions = positions
            self.pixelIndices = pixelIndices
        }

        /// The empty result returned for malformed input.
        internal static let empty = Result()
    }

    /// Unprojects a depth map into world space.
    ///
    /// - Parameters:
    ///   - depthMillimeters: Row-major depth in millimeters; 0 means "no depth". Count must equal
    ///     `intrinsics.pixelCount`.
    ///   - confidence: Row-major ARKit confidence (0 low, 1 medium, 2 high). Count must equal
    ///     `intrinsics.pixelCount`.
    ///   - intrinsics: Intrinsics already scaled to the depth map resolution.
    ///   - pose: `world_from_camera` for the frame.
    ///   - options: Filtering and stride; see `Options`.
    /// - Returns: Retained points and their pixel indices. If either array's count does not match
    ///   `intrinsics.pixelCount`, or the intrinsics describe an empty image, the result is empty.
    public static func unproject(depthMillimeters: [UInt16],
                                 confidence: [UInt8],
                                 intrinsics: Intrinsics,
                                 pose: Pose,
                                 options: Options = .init()) -> Result {
        guard let scan = Scan(intrinsics: intrinsics,
                              options: options,
                              depthCount: depthMillimeters.count,
                              confidenceCount: confidence.count) else {
            return .empty
        }

        var positions: [SIMD3<Float>] = []
        var pixelIndices: [Int32] = []
        positions.reserveCapacity(scan.maxRetained)
        pixelIndices.reserveCapacity(scan.maxRetained)

        depthMillimeters.withUnsafeBufferPointer { depth in
            confidence.withUnsafeBufferPointer { conf in
                var v = 0
                while v < scan.height {
                    let rowBase = v * scan.width
                    var u = 0
                    while u < scan.width {
                        let index = rowBase + u
                        let mm = depth[index]
                        if mm != 0 && conf[index] >= scan.minConfidence {
                            let d = Float(mm) / 1000
                            if d >= scan.minDepth && d <= scan.maxDepth {
                                let camera = intrinsics.unproject(pixelU: u, pixelV: v, depth: d)
                                positions.append(pose.transform(camera))
                                pixelIndices.append(Int32(truncatingIfNeeded: index))
                            }
                        }
                        u += scan.stride
                    }
                    v += scan.stride
                }
            }
        }

        return Result(positions: positions, pixelIndices: pixelIndices)
    }

    /// Unprojects a persisted keyframe using its own intrinsics and pose.
    /// Returns an empty result when `record.isConsistent` is false.
    public static func unproject(record: KeyframeRecord, options: Options = .init()) -> Result {
        unproject(depthMillimeters: record.depthMillimeters,
                  confidence: record.confidence,
                  intrinsics: record.intrinsics,
                  pose: record.pose,
                  options: options)
    }

    /// Unprojects a persisted keyframe straight into `PackedPoint`s, asking `color` for the packed RGBA
    /// of each retained pixel by its row-major pixel index (`v * width + u`). Same filtering, ordering
    /// and empty-on-mismatch behaviour as `unproject(record:options:)`.
    public static func unprojectPacked(record: KeyframeRecord,
                                       options: Options = .init(),
                                       color: (Int32) -> UInt32) -> [PackedPoint] {
        guard let scan = Scan(intrinsics: record.intrinsics,
                              options: options,
                              depthCount: record.depthMillimeters.count,
                              confidenceCount: record.confidence.count) else {
            return []
        }

        let intrinsics = record.intrinsics
        let pose = record.pose
        var points: [PackedPoint] = []
        points.reserveCapacity(scan.maxRetained)

        record.depthMillimeters.withUnsafeBufferPointer { depth in
            record.confidence.withUnsafeBufferPointer { conf in
                var v = 0
                while v < scan.height {
                    let rowBase = v * scan.width
                    var u = 0
                    while u < scan.width {
                        let index = rowBase + u
                        let mm = depth[index]
                        if mm != 0 && conf[index] >= scan.minConfidence {
                            let d = Float(mm) / 1000
                            if d >= scan.minDepth && d <= scan.maxDepth {
                                let camera = intrinsics.unproject(pixelU: u, pixelV: v, depth: d)
                                let pixelIndex = Int32(truncatingIfNeeded: index)
                                points.append(PackedPoint(position: pose.transform(camera),
                                                          color: color(pixelIndex)))
                            }
                        }
                        u += scan.stride
                    }
                    v += scan.stride
                }
            }
        }

        return points
    }

    /// Validated, loop-ready view of the inputs shared by both hot loops.
    /// `init` fails (→ empty output) when the image is empty or an input array does not cover it.
    internal struct Scan {
        let width: Int
        let height: Int
        let stride: Int
        let minConfidence: UInt8
        let minDepth: Float
        let maxDepth: Float
        /// Upper bound on retained pixels: `ceil(width / stride) * ceil(height / stride)`.
        let maxRetained: Int

        init?(intrinsics: Intrinsics, options: Options, depthCount: Int, confidenceCount: Int) {
            let width = intrinsics.width
            let height = intrinsics.height
            guard width > 0, height > 0 else { return nil }
            let pixelCount = width * height
            guard depthCount == pixelCount, confidenceCount == pixelCount else { return nil }

            let stride = max(1, options.stride)
            self.width = width
            self.height = height
            self.stride = stride
            self.minConfidence = options.minConfidence
            self.minDepth = options.minDepthMeters
            self.maxDepth = options.maxDepthMeters
            self.maxRetained = ((width + stride - 1) / stride) * ((height + stride - 1) / stride)
        }
    }
}
