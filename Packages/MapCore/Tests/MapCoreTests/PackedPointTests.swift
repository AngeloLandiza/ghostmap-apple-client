import XCTest
import simd
@testable import MapCore

final class PackedPointTests: XCTestCase {

    func testMemoryLayoutMatchesMetalVertexStruct() {
        // 3 × Float (12 bytes) + UInt32 (4 bytes) = 16 bytes; no padding because every field is 4-byte aligned.
        XCTAssertEqual(MemoryLayout<PackedPoint>.size, 16)
        // stride == size because 16 is already a multiple of the 4-byte alignment.
        XCTAssertEqual(MemoryLayout<PackedPoint>.stride, 16)
        // Largest field alignment is 4 (Float / UInt32).
        XCTAssertEqual(MemoryLayout<PackedPoint>.alignment, 4)
        XCTAssertEqual(PackedPoint.byteSize, MemoryLayout<PackedPoint>.stride)
    }

    func testPackColor() {
        // 1 | (2 << 8) | (3 << 16) | (4 << 24) = 1 + 512 + 196_608 + 67_108_864 = 67_305_985 = 0x04030201
        XCTAssertEqual(PackedPoint.packColor(r: 1, g: 2, b: 3, a: 4), 0x0403_0201)
        XCTAssertEqual(PackedPoint.packColor(r: 1, g: 2, b: 3, a: 4), 67_305_985)
        // Default alpha is 255: (255 << 24) | 0x030201 = 0xFF000000 | 0x00030201 = 0xFF030201
        XCTAssertEqual(PackedPoint.packColor(r: 1, g: 2, b: 3), 0xFF03_0201)
        // All channels at their maximum fill every bit.
        XCTAssertEqual(PackedPoint.packColor(r: 255, g: 255, b: 255, a: 255), 0xFFFF_FFFF)
        XCTAssertEqual(PackedPoint.packColor(r: 0, g: 0, b: 0, a: 0), 0)
    }

    func testColorAccessorsUnpackEachByte() {
        let p = PackedPoint(x: 0, y: 0, z: 0, color: 0x0403_0201)
        // byte 0 = 0x01, byte 1 = 0x02, byte 2 = 0x03, byte 3 = 0x04
        XCTAssertEqual(p.r, 1)
        XCTAssertEqual(p.g, 2)
        XCTAssertEqual(p.b, 3)
        XCTAssertEqual(p.a, 4)

        // 0xFF00A0C8: r = 0xC8 = 200, g = 0xA0 = 160, b = 0x00, a = 0xFF = 255
        let q = PackedPoint(position: SIMD3<Float>(1, 2, 3), color: 0xFF00_A0C8)
        XCTAssertEqual(q.r, 200)
        XCTAssertEqual(q.g, 160)
        XCTAssertEqual(q.b, 0)
        XCTAssertEqual(q.a, 255)
    }

    func testInitializers() {
        let a = PackedPoint(x: 1.5, y: -2, z: 3.25, color: 7)
        XCTAssertEqual(a.x, 1.5)
        XCTAssertEqual(a.y, -2)
        XCTAssertEqual(a.z, 3.25)
        XCTAssertEqual(a.color, 7)
        XCTAssertEqual(a.position, SIMD3<Float>(1.5, -2, 3.25))

        let b = PackedPoint(position: SIMD3<Float>(1.5, -2, 3.25), color: 7)
        XCTAssertEqual(a, b)

        // r 10, g 20, b 30, default alpha 255: 10 | 20 << 8 | 30 << 16 | 255 << 24
        // = 10 + 5_120 + 1_966_080 + 4_278_190_080 = 4_280_161_290 = 0xFF1E140A
        let c = PackedPoint(position: SIMD3<Float>(0, 0, 0), r: 10, g: 20, b: 30)
        XCTAssertEqual(c.color, 0xFF1E_140A)
        XCTAssertEqual(c.color, 4_280_161_290)
        XCTAssertEqual(c.a, 255)

        // Explicit alpha 0 leaves the top byte clear: 0x001E140A
        let d = PackedPoint(position: SIMD3<Float>(0, 0, 0), r: 10, g: 20, b: 30, a: 0)
        XCTAssertEqual(d.color, 0x001E_140A)
    }

    func testPositionSetterUpdatesEveryComponent() {
        var p = PackedPoint(x: 0, y: 0, z: 0, color: 1)
        p.position = SIMD3<Float>(4, 5, 6)
        XCTAssertEqual(p.x, 4)
        XCTAssertEqual(p.y, 5)
        XCTAssertEqual(p.z, 6)
        XCTAssertEqual(p.color, 1, "changing the position must not touch the color")
    }

    func testInMemoryByteOrderIsLittleEndianXYZThenRGBA() {
        let p = PackedPoint(x: 1, y: 2, z: 3, color: 0x0403_0201)
        withUnsafeBytes(of: p) { bytes in
            XCTAssertEqual(bytes.count, 16)
            // Float 1.0 = 0x3F800000 → little-endian bytes 00 00 80 3F
            XCTAssertEqual(Array(bytes[0..<4]), [0x00, 0x00, 0x80, 0x3F])
            // Float 2.0 = 0x40000000 → 00 00 00 40
            XCTAssertEqual(Array(bytes[4..<8]), [0x00, 0x00, 0x00, 0x40])
            // Float 3.0 = 0x40400000 → 00 00 40 40
            XCTAssertEqual(Array(bytes[8..<12]), [0x00, 0x00, 0x40, 0x40])
            // UInt32 0x04030201 little-endian → 01 02 03 04, i.e. r, g, b, a in memory
            XCTAssertEqual(Array(bytes[12..<16]), [1, 2, 3, 4])
        }
    }

    func testEquatableAndHashable() {
        let a = PackedPoint(x: 1, y: 2, z: 3, color: 4)
        let b = PackedPoint(x: 1, y: 2, z: 3, color: 4)
        let c = PackedPoint(x: 1, y: 2, z: 3, color: 5)
        let d = PackedPoint(x: 1, y: 2, z: 3.5, color: 4)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
        XCTAssertEqual(a.hashValue, b.hashValue)
        // Hashable: a Set collapses equal points. {a, b, c, d} has 3 distinct members.
        XCTAssertEqual(Set([a, b, c, d]).count, 3)
    }
}
