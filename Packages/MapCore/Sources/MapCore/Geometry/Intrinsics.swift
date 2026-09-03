import simd

/// Pinhole camera intrinsics for an image of `width`×`height` pixels.
/// ARKit reports intrinsics for the full captured image; use `scaled(toWidth:height:)` to
/// obtain the intrinsics that apply to the 256×192 depth map.
public struct Intrinsics: Sendable, Equatable, Codable {
    public var fx: Float
    public var fy: Float
    public var cx: Float
    public var cy: Float
    public var width: Int
    public var height: Int

    public init(fx: Float, fy: Float, cx: Float, cy: Float, width: Int, height: Int) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }

    /// Intrinsics for the same camera at a different image resolution.
    public func scaled(toWidth newWidth: Int, height newHeight: Int) -> Intrinsics {
        let sx = Float(newWidth) / Float(width)
        let sy = Float(newHeight) / Float(height)
        return Intrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy, width: newWidth, height: newHeight)
    }

    /// Pixel (u, v) at depth `depth` (meters along the optical axis) → camera-space point in the ARKit
    /// convention (x right, y up, −z forward). `u`/`v` are pixel coordinates; pass `Float(u) + 0.5`
    /// for pixel centers (see `unproject(pixelU:pixelV:depth:)`).
    public func unproject(u: Float, v: Float, depth: Float) -> SIMD3<Float> {
        let x = (u - cx) / fx * depth
        let y = (v - cy) / fy * depth
        return SIMD3<Float>(x, -y, -depth)
    }

    /// Unprojects the center of integer pixel (pixelU, pixelV).
    public func unproject(pixelU: Int, pixelV: Int, depth: Float) -> SIMD3<Float> {
        unproject(u: Float(pixelU) + 0.5, v: Float(pixelV) + 0.5, depth: depth)
    }

    /// K as a 3×3 column-major matrix (`simd` convention).
    public var matrix: simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(fx, 0, 0),
            SIMD3<Float>(0, fy, 0),
            SIMD3<Float>(cx, cy, 1)
        )
    }

    /// K⁻¹, convenient for shaders: `K⁻¹ · [u, v, 1] · depth` gives the image-space camera point (x right, y down, z forward).
    public var inverseMatrix: simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(1 / fx, 0, 0),
            SIMD3<Float>(0, 1 / fy, 0),
            SIMD3<Float>(-cx / fx, -cy / fy, 1)
        )
    }

    public var pixelCount: Int { width * height }
}
