import CoreGraphics
import simd

/// Matrix helpers in Metal conventions: right-handed, column-major, clip-space depth in [0, 1].
enum RenderMath {
    static func perspective(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovYRadians * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)
        )
    }

    static func orthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> simd_float4x4 {
        let rl = right - left
        let tb = top - bottom
        let fn = far - near
        return simd_float4x4(
            SIMD4<Float>(2 / rl, 0, 0, 0),
            SIMD4<Float>(0, 2 / tb, 0, 0),
            SIMD4<Float>(0, 0, -1 / fn, 0),
            SIMD4<Float>(-(right + left) / rl, -(top + bottom) / tb, -near / fn, 1)
        )
    }

    /// View matrix looking from `eye` toward `target`.
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)          // forward
        var s = simd_cross(f, up)
        if simd_length_squared(s) < 1e-8 {            // up parallel to forward: pick any perpendicular
            s = simd_cross(f, SIMD3<Float>(1, 0, 0))
            if simd_length_squared(s) < 1e-8 { s = simd_cross(f, SIMD3<Float>(0, 0, 1)) }
        }
        s = simd_normalize(s)                          // right
        let u = simd_cross(s, f)                       // true up
        return simd_float4x4(
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        )
    }

    /// A `CGAffineTransform` as a 3×3 column-major matrix acting on (x, y, 1).
    static func matrix(from t: CGAffineTransform) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(Float(t.a), Float(t.b), 0),
            SIMD3<Float>(Float(t.c), Float(t.d), 0),
            SIMD3<Float>(Float(t.tx), Float(t.ty), 1)
        )
    }

    static func rotationY(_ radians: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: radians, axis: SIMD3<Float>(0, 1, 0)))
    }

    static func degrees(_ radians: Float) -> Float { radians * 180 / .pi }
    static func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }
}
