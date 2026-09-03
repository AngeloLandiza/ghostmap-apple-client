import simd

/// A rigid transform in SE(3) stored as a column-major 4×4 matrix, matching `ARCamera.transform`
/// (`world_from_camera`). Points are transformed as `p_world = matrix * [p_camera, 1]`.
public struct Pose: Sendable, Equatable {
    public var matrix: simd_float4x4

    public init(matrix: simd_float4x4) {
        self.matrix = matrix
    }

    public init(translation: SIMD3<Float>, rotation: simd_quatf) {
        var m = simd_float4x4(rotation)
        m.columns.3 = SIMD4<Float>(translation, 1)
        self.matrix = m
    }

    public init(translation: SIMD3<Float>) {
        self.init(translation: translation, rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)))
    }

    /// Builds a pose from 16 floats in column-major order. Returns nil unless exactly 16 values are given.
    public init?(columnMajorArray a: [Float]) {
        guard a.count == 16 else { return nil }
        self.matrix = simd_float4x4(
            SIMD4<Float>(a[0], a[1], a[2], a[3]),
            SIMD4<Float>(a[4], a[5], a[6], a[7]),
            SIMD4<Float>(a[8], a[9], a[10], a[11]),
            SIMD4<Float>(a[12], a[13], a[14], a[15])
        )
    }

    public static let identity = Pose(matrix: matrix_identity_float4x4)

    /// The 16 matrix entries in column-major order (the ARKit / Metal / `simd` memory layout).
    public var columnMajorArray: [Float] {
        let c = matrix.columns
        return [c.0.x, c.0.y, c.0.z, c.0.w,
                c.1.x, c.1.y, c.1.z, c.1.w,
                c.2.x, c.2.y, c.2.z, c.2.w,
                c.3.x, c.3.y, c.3.z, c.3.w]
    }

    public var translation: SIMD3<Float> {
        get { SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z) }
        set { matrix.columns.3 = SIMD4<Float>(newValue, 1) }
    }

    public var rotationMatrix: simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
            SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
            SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        )
    }

    public var rotation: simd_quatf {
        simd_quatf(rotationMatrix)
    }

    /// Camera-space basis vectors expressed in the parent frame (ARKit convention: −Z is forward).
    public var right: SIMD3<Float> { SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z) }
    public var up: SIMD3<Float> { SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z) }
    public var forward: SIMD3<Float> { -SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z) }

    public var inverse: Pose {
        Pose(matrix: matrix.inverse)
    }

    /// Composition: `(a * b)` maps b's local frame through a. Same semantics as matrix multiplication.
    public static func * (lhs: Pose, rhs: Pose) -> Pose {
        Pose(matrix: lhs.matrix * rhs.matrix)
    }

    /// Transforms a point (applies rotation and translation).
    public func transform(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = matrix * SIMD4<Float>(p, 1)
        return SIMD3<Float>(r.x, r.y, r.z)
    }

    /// Rotates a direction (ignores translation).
    public func rotate(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let r = matrix * SIMD4<Float>(v, 0)
        return SIMD3<Float>(r.x, r.y, r.z)
    }

    /// Euclidean distance between the two translations, in the units of the pose (meters for ARKit).
    public func translationDistance(to other: Pose) -> Float {
        simd_distance(translation, other.translation)
    }

    /// Smallest rotation angle (radians, in [0, π]) that takes this pose's orientation to `other`'s.
    public func rotationAngle(to other: Pose) -> Float {
        let relative = simd_normalize(rotation.inverse * other.rotation)
        let w = min(1, abs(relative.real))
        return 2 * acos(w)
    }

    public func rotationAngleDegrees(to other: Pose) -> Float {
        rotationAngle(to: other) * 180 / .pi
    }

    /// Approximate equality on every matrix entry.
    public func isApproximatelyEqual(to other: Pose, tolerance: Float = 1e-5) -> Bool {
        let a = columnMajorArray
        let b = other.columnMajorArray
        for i in 0..<16 where abs(a[i] - b[i]) > tolerance { return false }
        return true
    }
}
