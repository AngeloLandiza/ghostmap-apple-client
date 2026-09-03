/// IEEE 802.3 CRC-32 (polynomial 0xEDB88320, reflected), the same value `zlib.crc32` produces.
public struct CRC32: Sendable, Equatable {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var c = state
        for byte in bytes {
            c = CRC32.table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        state = c
    }

    public mutating func update<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        var c = state
        for byte in bytes {
            c = CRC32.table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        state = c
    }

    public var value: UInt32 { state ^ 0xFFFF_FFFF }

    public static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var crc = CRC32()
        crc.update(bytes)
        return crc.value
    }

    public static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc = CRC32()
        crc.update(bytes)
        return crc.value
    }
}
