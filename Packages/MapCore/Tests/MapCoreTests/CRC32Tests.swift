import MapCore
import XCTest

final class CRC32Tests: XCTestCase {
    /// The IEEE 802.3 / zlib check value: crc32(b"123456789") == 0xCBF43926.
    func testCheckValue() {
        let digits = Array("123456789".utf8)
        XCTAssertEqual(CRC32.checksum(digits), 0xCBF4_3926)
    }

    func testEmptyInputIsZero() {
        // Initial register 0xFFFFFFFF, no bytes processed, final XOR with 0xFFFFFFFF → 0.
        XCTAssertEqual(CRC32.checksum([UInt8]()), 0)
        XCTAssertEqual(CRC32().value, 0)
        XCTAssertEqual(CRC32.checksum(UnsafeRawBufferPointer(start: nil, count: 0)), 0)
    }

    func testSingleBytes() {
        // zlib.crc32(b"\x00") == 0xD202EF8D.
        XCTAssertEqual(CRC32.checksum([0x00]), 0xD202_EF8D)
        // zlib.crc32(b"a") == 0xE8B7BE43.
        XCTAssertEqual(CRC32.checksum(Array("a".utf8)), 0xE8B7_BE43)
    }

    func testIncrementalUpdateMatchesOneShot() {
        // "12345" then "6789" must equal the one-shot checksum of "123456789" == 0xCBF43926.
        var crc = CRC32()
        crc.update(Array("12345".utf8))
        crc.update(Array("6789".utf8))
        XCTAssertEqual(crc.value, 0xCBF4_3926)
        // `value` is a pure read: asking twice does not disturb the register.
        XCTAssertEqual(crc.value, 0xCBF4_3926)
        // Feeding an empty chunk changes nothing.
        crc.update([UInt8]())
        XCTAssertEqual(crc.value, 0xCBF4_3926)
    }

    func testRawBufferOverloadMatchesCollectionOverload() {
        let digits = Array("123456789".utf8)
        let oneShot = digits.withUnsafeBytes { CRC32.checksum($0) }
        XCTAssertEqual(oneShot, 0xCBF4_3926)

        // Mixed raw-buffer and collection updates over the two halves ("1234" | "56789").
        var crc = CRC32()
        digits[0..<4].withUnsafeBytes { crc.update($0) }
        crc.update(digits[4...])
        XCTAssertEqual(crc.value, 0xCBF4_3926)
    }

    func testDifferentInputsDiffer() {
        // Changing the last digit ("123456780") must not reproduce the check value.
        XCTAssertNotEqual(CRC32.checksum(Array("123456780".utf8)), 0xCBF4_3926)
        // Byte order matters: "987654321" != "123456789".
        XCTAssertNotEqual(CRC32.checksum(Array("987654321".utf8)), CRC32.checksum(Array("123456789".utf8)))
    }

    func testEquatableComparesState() {
        var a = CRC32()
        var b = CRC32()
        XCTAssertEqual(a, b)
        a.update([1, 2, 3])
        XCTAssertNotEqual(a, b)
        b.update([1])
        b.update([2, 3])
        XCTAssertEqual(a, b)
    }
}
