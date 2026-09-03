import simd

/// One colored point, laid out to match the Metal vertex struct exactly:
/// `packed_float3 position; uint color;` = 16 bytes, 4-byte aligned.
/// `color` packs RGBA as `r | g << 8 | b << 16 | a << 24` (bytes r, g, b, a in memory on little-endian).
public struct PackedPoint: Sendable, Equatable, Hashable {
    public var x: Float
    public var y: Float
    public var z: Float
    public var color: UInt32

    public static let byteSize = 16

    public init(x: Float, y: Float, z: Float, color: UInt32) {
        self.x = x
        self.y = y
        self.z = z
        self.color = color
    }

    public init(position: SIMD3<Float>, color: UInt32) {
        self.init(x: position.x, y: position.y, z: position.z, color: color)
    }

    public init(position: SIMD3<Float>, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.init(position: position, color: PackedPoint.packColor(r: r, g: g, b: b, a: a))
    }

    public var position: SIMD3<Float> {
        get { SIMD3<Float>(x, y, z) }
        set { x = newValue.x; y = newValue.y; z = newValue.z }
    }

    public var r: UInt8 { UInt8(truncatingIfNeeded: color) }
    public var g: UInt8 { UInt8(truncatingIfNeeded: color >> 8) }
    public var b: UInt8 { UInt8(truncatingIfNeeded: color >> 16) }
    public var a: UInt8 { UInt8(truncatingIfNeeded: color >> 24) }

    public static func packColor(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> UInt32 {
        UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (UInt32(a) << 24)
    }
}
