import Foundation
import MapCore
import XCTest

/// Deterministic SplitMix64 generator so "random" payloads are reproducible.
private struct DepthCodecTestRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class DepthCodecTests: XCTestCase {
    private static let width = 256
    private static let height = 192
    private static let pixelCount = 256 * 192 // 49 152

    /// A 256×192 depth ramp: mm = (v·7 + u·3) mod 5000. Every value stays below 5000 because the
    /// largest is 191·7 + 255·3 = 1337 + 765 = 2102, and row v+3 equals row v shifted by 7 pixels
    /// (3·7 = 7·3), which makes the raster highly LZ-compressible.
    private static func ramp() -> [UInt16] {
        var mm = [UInt16](repeating: 0, count: pixelCount)
        for v in 0..<height {
            for u in 0..<width {
                mm[v * width + u] = UInt16((v * 7 + u * 3) % 5000)
            }
        }
        return mm
    }

    private func assertThrows(_ expected: MapError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? MapError, expected, file: file, line: line)
        }
    }

    // MARK: - quantize / dequantize

    func testQuantizeSpecValues() {
        let meters: [Float] = [1.2345, 0.0004, -1, .nan, .infinity, 70, 0]
        let mm = DepthCodec.quantize(depthMeters: meters)
        XCTAssertEqual(mm.count, 7)
        // Float(1.2345) = 1.23450005…; × 1000 = 1234.50005…, whose nearest Float is exactly 1234.5;
        // .rounded() is schoolbook (ties away from zero) → 1235.
        XCTAssertEqual(mm[0], 1235)
        // Float(0.0004) × 1000 = 0.39999998 → rounds to 0 → clamped up to 1 (a positive depth is never 0).
        XCTAssertEqual(mm[1], 1)
        // -1 is not > 0 → 0 (no depth).
        XCTAssertEqual(mm[2], 0)
        // NaN is not finite → 0.
        XCTAssertEqual(mm[3], 0)
        // +inf is not finite → 0.
        XCTAssertEqual(mm[4], 0)
        // 70 × 1000 = 70 000 > 65 535 → saturates to 65 535.
        XCTAssertEqual(mm[5], 65535)
        // 0 is not > 0 → 0.
        XCTAssertEqual(mm[6], 0)
    }

    func testQuantizeMoreEdges() {
        let meters: [Float] = [-.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude, 0.001, 2, 65.535, 0.0005, -0.0]
        let mm = DepthCodec.quantize(depthMeters: meters)
        XCTAssertEqual(mm[0], 0)      // -inf is not finite → 0
        XCTAssertEqual(mm[1], 65535)  // 3.4e38 × 1000 overflows to +inf ≥ 65 535 → saturates instead of trapping
        XCTAssertEqual(mm[2], 1)      // 1.4e-45 × 1000 ≈ 1.4e-42 → rounds to 0 → clamped to 1
        XCTAssertEqual(mm[3], 1)      // Float(0.001) × 1000 = 1.0000000475 → 1
        XCTAssertEqual(mm[4], 2000)   // 2 × 1000 = 2000 exactly
        XCTAssertEqual(mm[5], 65535)  // Float(65.535) × 1000 = 65 535 ± 0.004 → rounds to 65 535 → saturates at 65 535
        XCTAssertEqual(mm[6], 1)      // Float(0.0005) × 1000 = 0.5 ± 3e-8 → rounds to 0 (→ clamped 1) or 1: 1 either way
        XCTAssertEqual(mm[7], 0)      // -0.0 is not > 0 → 0
    }

    func testQuantizeBufferOverloadMatchesArrayOverload() {
        let meters: [Float] = [1.2345, 0.0004, -1, .nan, .infinity, 70, 0, 3.25]
        let fromArray = DepthCodec.quantize(depthMeters: meters)
        let fromBuffer = meters.withUnsafeBufferPointer { DepthCodec.quantize(depthMeters: $0) }
        XCTAssertEqual(fromArray, fromBuffer)
        XCTAssertEqual(fromBuffer[7], 3250) // 3.25 × 1000 = 3250 exactly
        XCTAssertEqual(DepthCodec.quantize(depthMeters: []), [])
        XCTAssertEqual(DepthCodec.quantize(depthMeters: UnsafeBufferPointer<Float>(start: nil, count: 0)), [])
    }

    func testDequantize() {
        let meters = DepthCodec.dequantize([1235, 0, 65535, 1])
        XCTAssertEqual(meters.count, 4)
        XCTAssertEqual(meters[0], 1.235, accuracy: 1e-6)   // 1235 / 1000
        XCTAssertEqual(meters[1], 0)                       // 0 / 1000 = 0 exactly
        XCTAssertEqual(meters[2], 65.535, accuracy: 1e-5)  // 65535 / 1000; Float ulp near 65 is 7.6e-6
        XCTAssertEqual(meters[3], 0.001, accuracy: 1e-9)   // 1 / 1000
        XCTAssertEqual(DepthCodec.dequantize([]), [])
    }

    func testQuantizeDequantizeRoundTripsEveryMillimeterValue() {
        // Float carries ~7 significant digits, so Float(mm)/1000·1000 is within 0.01 of mm for
        // every mm ≤ 65 535 and rounds back exactly.
        let all = (0...65535).map { UInt16($0) }
        let roundTrip = DepthCodec.quantize(depthMeters: DepthCodec.dequantize(all))
        XCTAssertEqual(roundTrip, all)
    }

    // MARK: - compress / decompress

    func testCompressEmptyAndDecompressEmpty() throws {
        let empty = try DepthCodec.compress(UnsafeRawBufferPointer(start: nil, count: 0))
        XCTAssertEqual(empty, Data())
        XCTAssertEqual(try DepthCodec.decompress(Data(), expectedByteCount: 0), Data())
    }

    func testCompressDecompressRoundTripAndSizeChecks() throws {
        // 200 bytes of a period-7 pattern: 0,1,…,6,0,1,…
        let bytes = (0..<200).map { UInt8($0 % 7) }
        let encoded = try bytes.withUnsafeBytes { try DepthCodec.compress($0) }
        XCTAssertFalse(encoded.isEmpty)
        XCTAssertLessThan(encoded.count, 200) // repetitive input compresses

        XCTAssertEqual(try DepthCodec.decompress(encoded, expectedByteCount: 200), Data(bytes))
        // Expecting one byte less: the decoder is offered 199 + 1 slack bytes and fills all 200 → actual 200 ≠ 199.
        assertThrows(.decompressionFailed(expected: 199, actual: 200)) {
            _ = try DepthCodec.decompress(encoded, expectedByteCount: 199)
        }
        // Expecting one byte more: the stream only holds 200 → actual 200 ≠ 201.
        assertThrows(.decompressionFailed(expected: 201, actual: 200)) {
            _ = try DepthCodec.decompress(encoded, expectedByteCount: 201)
        }
        // Expecting nothing from a non-empty payload: reported with the payload size as `actual`.
        assertThrows(.decompressionFailed(expected: 0, actual: encoded.count)) {
            _ = try DepthCodec.decompress(encoded, expectedByteCount: 0)
        }
        // Negative expectation never reaches the decoder.
        assertThrows(.decompressionFailed(expected: -5, actual: 0)) {
            _ = try DepthCodec.decompress(encoded, expectedByteCount: -5)
        }
        // Empty payload cannot produce 10 bytes.
        assertThrows(.decompressionFailed(expected: 10, actual: 0)) {
            _ = try DepthCodec.decompress(Data(), expectedByteCount: 10)
        }
    }

    func testDecompressGarbageThrows() {
        // Not an LZFSE block header (magic must be "bvx-", "bvx1", "bvx2", "bvxn" or "bvx$") → decoder yields 0 bytes.
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
        assertThrows(.decompressionFailed(expected: 1000, actual: 0)) {
            _ = try DepthCodec.decompress(garbage, expectedByteCount: 1000)
        }
    }

    func testCompressIncompressibleInputFitsInSlack() throws {
        // 100 000 pseudo-random bytes: LZFSE stores them raw; the overhead must fit in count + 4096.
        var rng = DepthCodecTestRNG(seed: 0xC0FFEE)
        let bytes = (0..<100_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let encoded = try bytes.withUnsafeBytes { try DepthCodec.compress($0) }
        XCTAssertGreaterThanOrEqual(encoded.count, 100_000)
        XCTAssertLessThan(encoded.count, 100_000 + 4096)
        XCTAssertEqual(try DepthCodec.decompress(encoded, expectedByteCount: 100_000), Data(bytes))
    }

    // MARK: - depth

    func testDepthRampRoundTripsAndCompresses() throws {
        let mm = Self.ramp()
        let encoded = try DepthCodec.encodeDepth(mm)
        // Raw size is 49 152 px × 2 B = 98 304 B; the ramp must shrink below half of that (49 152 B).
        XCTAssertLessThan(encoded.count, 98_304 / 2)
        let decoded = try DepthCodec.decodeDepth(encoded, pixelCount: Self.pixelCount)
        XCTAssertEqual(decoded, mm)
        // Spot-check a hand-computed sample: v = 10, u = 20 → 10·7 + 20·3 = 70 + 60 = 130.
        XCTAssertEqual(decoded[10 * 256 + 20], 130)
        // Last pixel: v = 191, u = 255 → 1337 + 765 = 2102.
        XCTAssertEqual(decoded[Self.pixelCount - 1], 2102)
    }

    func testDepthBytesAreLittleEndian() throws {
        // 0x1234 mm must be stored as bytes [0x34, 0x12] before compression.
        let encoded = try DepthCodec.encodeDepth([0x1234])
        let raw = try DepthCodec.decompress(encoded, expectedByteCount: 2)
        XCTAssertEqual(Array(raw), [0x34, 0x12])
        XCTAssertEqual(try DepthCodec.decodeDepth(encoded, pixelCount: 1), [0x1234])
    }

    func testDecodeDepthWithWrongPixelCountThrows() throws {
        // 100 pixels → 200 raw bytes.
        let mm = (0..<100).map { UInt16($0 * 3) }
        let encoded = try DepthCodec.encodeDepth(mm)
        // 101 px expects 202 B; the stream holds 200 B.
        assertThrows(.decompressionFailed(expected: 202, actual: 200)) {
            _ = try DepthCodec.decodeDepth(encoded, pixelCount: 101)
        }
        // 99 px expects 198 B; the decoder fills the 198 + 1 slack bytes → actual 199.
        assertThrows(.decompressionFailed(expected: 198, actual: 199)) {
            _ = try DepthCodec.decodeDepth(encoded, pixelCount: 99)
        }
        // 0 px with a non-empty payload → expected 0, actual = payload size.
        assertThrows(.decompressionFailed(expected: 0, actual: encoded.count)) {
            _ = try DepthCodec.decodeDepth(encoded, pixelCount: 0)
        }
        // Negative pixel count is reported as-is.
        assertThrows(.decompressionFailed(expected: -1, actual: 0)) {
            _ = try DepthCodec.decodeDepth(encoded, pixelCount: -1)
        }
        // Correct count still works after the failures.
        XCTAssertEqual(try DepthCodec.decodeDepth(encoded, pixelCount: 100), mm)
    }

    func testDecodeDepthGarbageThrows() {
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
        // 500 px expects 1000 B; garbage decodes to 0 B.
        assertThrows(.decompressionFailed(expected: 1000, actual: 0)) {
            _ = try DepthCodec.decodeDepth(garbage, pixelCount: 500)
        }
    }

    func testDepthEmptyRoundTrip() throws {
        let encoded = try DepthCodec.encodeDepth([])
        XCTAssertEqual(encoded, Data())
        XCTAssertEqual(try DepthCodec.decodeDepth(encoded, pixelCount: 0), [])
        // Empty payload cannot yield 5 px = 10 B.
        assertThrows(.decompressionFailed(expected: 10, actual: 0)) {
            _ = try DepthCodec.decodeDepth(Data(), pixelCount: 5)
        }
    }

    func testDepthRandomRoundTrip() throws {
        var rng = DepthCodecTestRNG(seed: 42)
        let mm = (0..<Self.pixelCount).map { _ in UInt16(truncatingIfNeeded: rng.next()) }
        let encoded = try DepthCodec.encodeDepth(mm)
        // Incompressible: at most raw (98 304 B) + slack.
        XCTAssertLessThan(encoded.count, 98_304 + 4096)
        XCTAssertEqual(try DepthCodec.decodeDepth(encoded, pixelCount: Self.pixelCount), mm)
    }

    // MARK: - confidence

    func testConfidenceRoundTrip() throws {
        // Values 0/1/2 in the pattern (u + v) mod 3.
        var confidence = [UInt8](repeating: 0, count: Self.pixelCount)
        for v in 0..<Self.height {
            for u in 0..<Self.width {
                confidence[v * Self.width + u] = UInt8((u + v) % 3)
            }
        }
        let encoded = try DepthCodec.encodeConfidence(confidence)
        // Raw is 49 152 B; the 3-periodic pattern must shrink below half (24 576 B).
        XCTAssertLessThan(encoded.count, 49_152 / 2)
        let decoded = try DepthCodec.decodeConfidence(encoded, pixelCount: Self.pixelCount)
        XCTAssertEqual(decoded, confidence)
        // v = 1, u = 1 → (1 + 1) mod 3 = 2.
        XCTAssertEqual(decoded[1 * 256 + 1], 2)
    }

    func testDecodeConfidenceWithWrongPixelCountThrows() throws {
        let confidence = (0..<100).map { UInt8($0 % 3) }
        let encoded = try DepthCodec.encodeConfidence(confidence)
        // 101 expected, stream holds 100.
        assertThrows(.decompressionFailed(expected: 101, actual: 100)) {
            _ = try DepthCodec.decodeConfidence(encoded, pixelCount: 101)
        }
        // 99 expected, decoder fills 99 + 1 slack → 100.
        assertThrows(.decompressionFailed(expected: 99, actual: 100)) {
            _ = try DepthCodec.decodeConfidence(encoded, pixelCount: 99)
        }
        assertThrows(.decompressionFailed(expected: -1, actual: 0)) {
            _ = try DepthCodec.decodeConfidence(encoded, pixelCount: -1)
        }
        XCTAssertEqual(try DepthCodec.decodeConfidence(encoded, pixelCount: 100), confidence)
    }

    func testConfidenceEmptyRoundTrip() throws {
        let encoded = try DepthCodec.encodeConfidence([])
        XCTAssertEqual(encoded, Data())
        XCTAssertEqual(try DepthCodec.decodeConfidence(encoded, pixelCount: 0), [])
        assertThrows(.decompressionFailed(expected: 3, actual: 0)) {
            _ = try DepthCodec.decodeConfidence(Data(), pixelCount: 3)
        }
    }
}
