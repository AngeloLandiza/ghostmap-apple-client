import Foundation
import simd
import XCTest
@testable import MapCore

final class KeyframeLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyframeLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// The exact 16 header bytes: "SMKF", u16 version 1, u16 headerSize 16, u32 flags 0, u32 reserved 0.
    private static let expectedHeader: [UInt8] = [
        0x53, 0x4D, 0x4B, 0x46,
        0x01, 0x00,
        0x10, 0x00,
        0, 0, 0, 0,
        0, 0, 0, 0,
    ]

    /// 4×3 pixels = 12 samples per array.
    private static let intrinsics4x3 = Intrinsics(fx: 100, fy: 110, cx: 2, cy: 1.5, width: 4, height: 3)

    private static let record1 = KeyframeRecord(
        seq: 1,
        timestamp: 10.5,
        pose: Pose(translation: SIMD3<Float>(1, 2, 3)),
        intrinsics: intrinsics4x3,
        tracking: .normal,
        depthMillimeters: (0..<12).map { UInt16(100 + $0 * 100) },     // 100, 200, …, 1200
        confidence: (0..<12).map { UInt8($0 % 3) }                       // 0,1,2,0,1,2,…
    )

    private static let record2 = KeyframeRecord(
        seq: 2,
        timestamp: 11.25,
        pose: Pose(translation: SIMD3<Float>(-1, 0.5, 2),
                   rotation: simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))),
        intrinsics: intrinsics4x3,
        tracking: .limited(.excessiveMotion),
        depthMillimeters: (0..<12).map { UInt16(2000 + $0 * 7) },       // 2000, 2007, …, 2077
        confidence: (0..<12).map { UInt8(2 - $0 % 3) }                   // 2,1,0,2,1,0,…
    )

    private static let record3 = KeyframeRecord(
        seq: 3,
        timestamp: 12.0,
        pose: .identity,
        intrinsics: intrinsics4x3,
        tracking: .notAvailable,
        depthMillimeters: [0, 0, 500, 500, 0, 0, 500, 500, 0, 0, 500, 500],
        confidence: [UInt8](repeating: 2, count: 12)
    )

    private static let threeRecords = [record1, record2, record3]

    private var logURL: URL { directory.appendingPathComponent("keyframes.bin") }

    private func fileBytes(_ url: URL? = nil) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: url ?? logURL))
    }

    private func writeBytes(_ bytes: [UInt8], to url: URL? = nil) throws {
        try Data(bytes).write(to: url ?? logURL)
    }

    private func u32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private func u16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func f32(_ bytes: [UInt8], at offset: Int) -> Float {
        Float(bitPattern: u32(bytes, at: offset))
    }

    /// Writes `records` with a fresh writer, closes it and returns the offsets `append` reported.
    @discardableResult
    private func writeLog(_ records: [KeyframeRecord]) throws -> [Int64] {
        let writer = try KeyframeLogWriter(url: logURL)
        var offsets: [Int64] = []
        for record in records {
            offsets.append(try writer.append(record))
        }
        try writer.close()
        return offsets
    }

    /// Recomputes and stores the CRC of the record whose length field starts at `offset`.
    private func rewriteCRC(_ bytes: inout [UInt8], recordOffset offset: Int) {
        let payloadLength = Int(u32(bytes, at: offset))
        let payloadStart = offset + 4
        let crcOffset = payloadStart + payloadLength - 4
        let crc = CRC32.checksum(bytes[payloadStart ..< crcOffset])
        bytes[crcOffset] = UInt8(truncatingIfNeeded: crc)
        bytes[crcOffset + 1] = UInt8(truncatingIfNeeded: crc >> 8)
        bytes[crcOffset + 2] = UInt8(truncatingIfNeeded: crc >> 16)
        bytes[crcOffset + 3] = UInt8(truncatingIfNeeded: crc >> 24)
    }

    private func assertMapError(_ expected: MapError, _ body: () throws -> Void,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? MapError, expected, file: file, line: line)
        }
    }

    // MARK: - Format constants

    func testFormatConstants() {
        XCTAssertEqual(KeyframeLogFormat.magic, Array("SMKF".utf8))
        XCTAssertEqual(KeyframeLogFormat.magic, [0x53, 0x4D, 0x4B, 0x46])
        XCTAssertEqual(KeyframeLogFormat.version, 1)
        XCTAssertEqual(KeyframeLogFormat.headerSize, 16)
        XCTAssertEqual(KeyframeLogFormat.headerBytes, KeyframeLogTests.expectedHeader)
        // seq 4 + timestamp 8 + pose 64 + fx fy cx cy 16 + width height 4 + 4 × u8 4 + depthBytes 4 = 104
        XCTAssertEqual(KeyframeLogFormat.payloadPrefixSize, 104)
        // 104 + confidenceBytes 4 + crc 4 = 112
        XCTAssertEqual(KeyframeLogFormat.minimumPayloadSize, 112)
        XCTAssertEqual(KeyframeLogFormat.PayloadOffset.timestamp, 4)      // after u32 seq
        XCTAssertEqual(KeyframeLogFormat.PayloadOffset.pose, 12)          // 4 + 8
        XCTAssertEqual(KeyframeLogFormat.PayloadOffset.fx, 76)            // 12 + 16 × 4
        XCTAssertEqual(KeyframeLogFormat.PayloadOffset.width, 92)         // 76 + 4 × 4
        XCTAssertEqual(KeyframeLogFormat.PayloadOffset.trackingState, 96) // 92 + 2 × 2
        XCTAssertEqual(KeyframeLogFormat.PayloadOffset.depthBytes, 100)   // 96 + 4 × 1
        XCTAssertEqual(KeyframeLogFormat.PayloadOffset.depthData, 104)    // 100 + 4
    }

    // MARK: - Writer: header

    func testNewLogHasExactHeaderBytes() throws {
        let writer = try KeyframeLogWriter(url: logURL)
        try writer.close()
        XCTAssertEqual(try fileBytes(), KeyframeLogTests.expectedHeader)
        XCTAssertEqual(writer.recordCount, 0)
        XCTAssertEqual(writer.byteCount, 16)
    }

    func testEmptyExistingFileGetsHeader() throws {
        try writeBytes([])
        let writer = try KeyframeLogWriter(url: logURL)
        try writer.close()
        XCTAssertEqual(try fileBytes(), KeyframeLogTests.expectedHeader)
        XCTAssertEqual(writer.byteCount, 16)
    }

    func testHeaderOnlyFileScansEmpty() throws {
        try writeBytes(KeyframeLogTests.expectedHeader)
        let scan = try KeyframeLogReader.scan(url: logURL)
        XCTAssertEqual(scan, KeyframeLogScan(records: [], recordCount: 0, truncatedAtOffset: nil, corruptedAtOffset: nil, byteCount: 16))
    }

    // MARK: - Writer: append

    func testAppendReturnsPreviousByteCountAndLengthFieldMatches() throws {
        let writer = try KeyframeLogWriter(url: logURL)
        var expectedOffset: Int64 = 16   // first record starts right after the 16-byte header
        for (index, record) in KeyframeLogTests.threeRecords.enumerated() {
            XCTAssertEqual(writer.byteCount, expectedOffset)
            let offset = try writer.append(record)
            XCTAssertEqual(offset, expectedOffset, "record \(index)")
            XCTAssertEqual(writer.recordCount, index + 1)
            let bytes = try fileBytes()
            XCTAssertEqual(Int64(bytes.count), writer.byteCount)
            // payloadLength = bytes that follow the 4-byte length field up to the end of the record.
            let payloadLength = Int(u32(bytes, at: Int(offset)))
            XCTAssertEqual(Int(offset) + 4 + payloadLength, bytes.count)
            // payloadLength = 112 fixed + depthBytes + confidenceBytes
            let payloadStart = Int(offset) + 4
            let depthBytes = Int(u32(bytes, at: payloadStart + 100))
            let confidenceBytes = Int(u32(bytes, at: payloadStart + 104 + depthBytes))
            XCTAssertEqual(payloadLength, 112 + depthBytes + confidenceBytes)
            expectedOffset += Int64(4 + payloadLength)
        }
        try writer.close()
        XCTAssertEqual(writer.recordCount, 3)
    }

    func testPayloadFixedFieldLayout() throws {
        let offsets = try writeLog(KeyframeLogTests.threeRecords)
        let bytes = try fileBytes()
        let record = KeyframeLogTests.record2
        let p = Int(offsets[1]) + 4   // payload start of record 2

        // u32 seq = 2 → bytes 02 00 00 00
        XCTAssertEqual(Array(bytes[p ..< p + 4]), [2, 0, 0, 0])
        // f64 timestamp 11.25 = 0x4026800000000000 little-endian
        XCTAssertEqual(Array(bytes[p + 4 ..< p + 12]), [0, 0, 0, 0, 0, 0x80, 0x26, 0x40])
        // 16 × f32 pose, column-major
        let pose = record.pose.columnMajorArray
        for i in 0..<16 {
            XCTAssertEqual(f32(bytes, at: p + 12 + i * 4).bitPattern, pose[i].bitPattern, "pose[\(i)]")
        }
        // translation is column 3 = floats 12..14 → offsets 12 + 48 = 60, 64, 68
        XCTAssertEqual(f32(bytes, at: p + 60), -1)
        XCTAssertEqual(f32(bytes, at: p + 64), 0.5)
        XCTAssertEqual(f32(bytes, at: p + 68), 2)
        // fx 100 fy 110 cx 2 cy 1.5
        XCTAssertEqual(f32(bytes, at: p + 76), 100)
        XCTAssertEqual(f32(bytes, at: p + 80), 110)
        XCTAssertEqual(f32(bytes, at: p + 84), 2)
        XCTAssertEqual(f32(bytes, at: p + 88), 1.5)
        // u16 width 4, u16 height 3
        XCTAssertEqual(Array(bytes[p + 92 ..< p + 96]), [4, 0, 3, 0])
        // trackingState 1 (limited), trackingReason 1 (excessiveMotion), encodings 0, 0
        XCTAssertEqual(Array(bytes[p + 96 ..< p + 100]), [1, 1, 0, 0])
        // depth block == DepthCodec.encodeDepth output
        let depthEncoded = [UInt8](try DepthCodec.encodeDepth(record.depthMillimeters))
        let depthBytes = Int(u32(bytes, at: p + 100))
        XCTAssertEqual(depthBytes, depthEncoded.count)
        XCTAssertEqual(Array(bytes[p + 104 ..< p + 104 + depthBytes]), depthEncoded)
        // confidence block == DepthCodec.encodeConfidence output
        let confidenceEncoded = [UInt8](try DepthCodec.encodeConfidence(record.confidence))
        let c = p + 104 + depthBytes
        let confidenceBytes = Int(u32(bytes, at: c))
        XCTAssertEqual(confidenceBytes, confidenceEncoded.count)
        XCTAssertEqual(Array(bytes[c + 4 ..< c + 4 + confidenceBytes]), confidenceEncoded)
        // crc32 over every payload byte before the crc field
        let payloadLength = Int(u32(bytes, at: Int(offsets[1])))
        let crcOffset = p + payloadLength - 4
        XCTAssertEqual(crcOffset, c + 4 + confidenceBytes)
        XCTAssertEqual(u32(bytes, at: crcOffset), CRC32.checksum(bytes[p ..< crcOffset]))
    }

    func testRecord3TrackingBytes() throws {
        let offsets = try writeLog(KeyframeLogTests.threeRecords)
        let bytes = try fileBytes()
        let p = Int(offsets[2]) + 4
        // notAvailable → state 2, reason 0
        XCTAssertEqual(Array(bytes[p + 96 ..< p + 98]), [2, 0])
        let p1 = Int(offsets[0]) + 4
        // normal → state 0, reason 0
        XCTAssertEqual(Array(bytes[p1 + 96 ..< p1 + 98]), [0, 0])
    }

    func testEmptyDepthMapRoundTripsWithMinimumPayload() throws {
        let empty = KeyframeRecord(
            seq: 9, timestamp: 1, pose: .identity,
            intrinsics: Intrinsics(fx: 1, fy: 1, cx: 0, cy: 0, width: 0, height: 0),
            tracking: .normal, depthMillimeters: [], confidence: []
        )
        let writer = try KeyframeLogWriter(url: logURL)
        let offset = try writer.append(empty)
        try writer.close()
        XCTAssertEqual(offset, 16)
        // 4-byte length + 112-byte payload (0 depth bytes, 0 confidence bytes) = 116 bytes after the header
        XCTAssertEqual(writer.byteCount, 16 + 116)
        let bytes = try fileBytes()
        XCTAssertEqual(u32(bytes, at: 16), 112)
        XCTAssertEqual(u32(bytes, at: 16 + 4 + 100), 0)   // depthBytes
        XCTAssertEqual(u32(bytes, at: 16 + 4 + 104), 0)   // confidenceBytes
        let scan = try KeyframeLogReader.scan(url: logURL)
        XCTAssertEqual(scan.records, [empty])
        XCTAssertEqual(scan.recordCount, 1)
    }

    func testFullResolutionRecordRoundTrips() throws {
        let pixelCount = 256 * 192   // 49 152
        let record = KeyframeRecord(
            seq: 42, timestamp: 1234.5678,
            pose: Pose(translation: SIMD3<Float>(0.1, 0.2, 0.3),
                       rotation: simd_quatf(angle: 0.3, axis: simd_normalize(SIMD3<Float>(1, 1, 0)))),
            intrinsics: Intrinsics(fx: 212.5, fy: 212.5, cx: 128, cy: 96, width: 256, height: 192),
            tracking: .limited(.relocalizing),
            depthMillimeters: (0..<pixelCount).map { UInt16(1000 + ($0 % 97)) },
            confidence: (0..<pixelCount).map { UInt8($0 % 3) }
        )
        try writeLog([record])
        let scan = try KeyframeLogReader.scan(url: logURL)
        XCTAssertEqual(scan.records, [record])
        // The 98 304 raw depth bytes are highly repetitive and must have compressed.
        let bytes = try fileBytes()
        XCTAssertLessThan(Int(u32(bytes, at: 16 + 4 + 100)), pixelCount * 2)
    }

    func testAppendRejectsInconsistentRecord() throws {
        var bad = KeyframeLogTests.record1
        bad.depthMillimeters.removeLast()   // 11 depth samples for 12 pixels
        let writer = try KeyframeLogWriter(url: logURL)
        assertMapError(.sizeMismatch(expected: 12, actual: 11)) { try writer.append(bad) }
        var badConfidence = KeyframeLogTests.record1
        badConfidence.confidence.append(1)  // 13 confidence samples for 12 pixels
        assertMapError(.sizeMismatch(expected: 12, actual: 13)) { try writer.append(badConfidence) }
        XCTAssertEqual(writer.recordCount, 0)
        XCTAssertEqual(writer.byteCount, 16)
        try writer.close()
        XCTAssertEqual(try fileBytes().count, 16)
    }

    func testAppendRejectsDimensionsBeyondU16() throws {
        // width 65 536 does not fit u16; height 0 keeps the arrays consistent (pixelCount 0).
        let wide = KeyframeRecord(
            seq: 1, timestamp: 0, pose: .identity,
            intrinsics: Intrinsics(fx: 1, fy: 1, cx: 0, cy: 0, width: 65_536, height: 0),
            tracking: .normal, depthMillimeters: [], confidence: []
        )
        let writer = try KeyframeLogWriter(url: logURL)
        XCTAssertThrowsError(try writer.append(wide)) { error in
            guard let mapError = error as? MapError, case .io = mapError else {
                return XCTFail("expected MapError.io, got \(error)")
            }
        }
        try writer.close()
    }

    func testAppendAfterCloseThrowsAndCloseIsIdempotent() throws {
        let writer = try KeyframeLogWriter(url: logURL)
        try writer.append(KeyframeLogTests.record1)
        try writer.sync()
        try writer.close()
        try writer.close()
        try writer.sync()
        XCTAssertThrowsError(try writer.append(KeyframeLogTests.record2)) { error in
            guard let mapError = error as? MapError, case .io = mapError else {
                return XCTFail("expected MapError.io, got \(error)")
            }
        }
        XCTAssertEqual(writer.recordCount, 1)
    }

    func testWriterThrowsIOWhenDirectoryMissing() {
        let missing = directory.appendingPathComponent("nope/keyframes.bin")
        XCTAssertThrowsError(try KeyframeLogWriter(url: missing)) { error in
            guard let mapError = error as? MapError, case .io = mapError else {
                return XCTFail("expected MapError.io, got \(error)")
            }
        }
    }

    // MARK: - Reader: scan

    func testScanReturnsThreeEqualRecords() throws {
        let offsets = try writeLog(KeyframeLogTests.threeRecords)
        let scan = try KeyframeLogReader.scan(url: logURL)
        XCTAssertEqual(scan.records, KeyframeLogTests.threeRecords)
        XCTAssertEqual(scan.recordCount, 3)
        XCTAssertNil(scan.truncatedAtOffset)
        XCTAssertNil(scan.corruptedAtOffset)
        XCTAssertEqual(scan.byteCount, Int64(try fileBytes().count))
        XCTAssertEqual(scan.validByteCount, scan.byteCount)
        XCTAssertEqual(offsets[0], 16)
        XCTAssertEqual(scan.records[1].tracking, .limited(.excessiveMotion))
    }

    func testScanWithoutDepthLeavesArraysEmpty() throws {
        try writeLog(KeyframeLogTests.threeRecords)
        let scan = try KeyframeLogReader.scan(url: logURL, decodeDepth: false)
        XCTAssertEqual(scan.recordCount, 3)
        XCTAssertEqual(scan.records.count, 3)
        for (record, expected) in zip(scan.records, KeyframeLogTests.threeRecords) {
            XCTAssertEqual(record.depthMillimeters, [])
            XCTAssertEqual(record.confidence, [])
            XCTAssertEqual(record.seq, expected.seq)
            XCTAssertEqual(record.timestamp, expected.timestamp)
            XCTAssertEqual(record.pose, expected.pose)
            XCTAssertEqual(record.intrinsics, expected.intrinsics)
            XCTAssertEqual(record.tracking, expected.tracking)
            XCTAssertFalse(record.isConsistent)   // 0 samples for 12 pixels
        }
    }

    func testTruncatedTailIsReported() throws {
        let offsets = try writeLog(KeyframeLogTests.threeRecords)
        let bytes = try fileBytes()
        // Keep 10 bytes of record 3: the 4-byte length field plus 6 payload bytes.
        try writeBytes(Array(bytes[0 ..< Int(offsets[2]) + 10]))
        let scan = try KeyframeLogReader.scan(url: logURL)
        XCTAssertEqual(scan.records, [KeyframeLogTests.record1, KeyframeLogTests.record2])
        XCTAssertEqual(scan.recordCount, 2)
        XCTAssertEqual(scan.truncatedAtOffset, offsets[2])
        XCTAssertNil(scan.corruptedAtOffset)
        XCTAssertEqual(scan.byteCount, offsets[2] + 10)
        XCTAssertEqual(scan.validByteCount, offsets[2])
    }

    func testPartialLengthFieldIsTruncated() throws {
        let offsets = try writeLog(KeyframeLogTests.threeRecords)
        let end = try fileBytes().count
        // Two stray bytes after record 3: a partial length field.
        try writeBytes(try fileBytes() + [0xAB, 0xCD])
        let scan = try KeyframeLogReader.scan(url: logURL)
        XCTAssertEqual(scan.recordCount, 3)
        XCTAssertEqual(scan.truncatedAtOffset, Int64(end))
        XCTAssertNil(scan.corruptedAtOffset)
        XCTAssertGreaterThan(Int64(end), offsets[2])
    }

    func testHugePayloadLengthIsTruncated() throws {
        let offsets = try writeLog([KeyframeLogTests.record1])
        let end = try fileBytes().count
        try writeBytes(try fileBytes() + [0xFF, 0xFF, 0xFF, 0xFF])   // payloadLength 4 294 967 295
        let scan = try KeyframeLogReader.scan(url: logURL)
        XCTAssertEqual(scan.recordCount, 1)
        XCTAssertEqual(scan.truncatedAtOffset, Int64(end))
        XCTAssertEqual(offsets[0], 16)
    }

    func testCorruptDepthByteIsReported() throws {
        let offsets = try writeLog(KeyframeLogTests.threeRecords)
        var bytes = try fileBytes()
        // First depth byte of record 2 lives at offset + 4 (length) + 104 (payload prefix).
        let target = Int(offsets[1]) + 4 + 104
        bytes[target] ^= 0x01
        try writeBytes(bytes)
        let scan = try KeyframeLogReader.scan(url: logURL)
        XCTAssertEqual(scan.records, [KeyframeLogTests.record1])
        XCTAssertEqual(scan.recordCount, 1)
        XCTAssertEqual(scan.corruptedAtOffset, offsets[1])
        XCTAssertNil(scan.truncatedAtOffset)
        XCTAssertEqual(scan.validByteCount, offsets[1])
    }

    func testCorruptCRCByteIsReported() throws {
        let offsets = try writeLog(KeyframeLogTests.threeRecords)
        var bytes = try fileBytes()
        bytes[Int(offsets[1]) - 1] ^= 0x80   // last byte of record 1 = high byte of its crc
        try writeBytes(bytes)
        let scan = try KeyframeLogReader.scan(url: logURL, decodeDepth: false)
        XCTAssertEqual(scan.recordCount, 0)
        XCTAssertEqual(scan.corruptedAtOffset, 16)
    }

    func testZeroPayloadLengthIsCorrupt() throws {
        try writeLog([KeyframeLogTests.record1])
        let end = try fileBytes().count
        try writeBytes(try fileBytes() + [0, 0, 0, 0])   // a record claiming a 0-byte payload
        let scan = try KeyframeLogReader.scan(url: logURL)
        XCTAssertEqual(scan.recordCount, 1)
        XCTAssertEqual(scan.corruptedAtOffset, Int64(end))
        XCTAssertNil(scan.truncatedAtOffset)
    }

    func testInnerLengthMismatchIsCorruptEvenWithValidCRC() throws {
        let offsets = try writeLog(KeyframeLogTests.threeRecords)
        var bytes = try fileBytes()
        let depthBytesField = Int(offsets[1]) + 4 + 100
        bytes[depthBytesField] &+= 1          // depthBytes + 1 → inner lengths no longer add up
        rewriteCRC(&bytes, recordOffset: Int(offsets[1]))
        try writeBytes(bytes)
        let scan = try KeyframeLogReader.scan(url: logURL, decodeDepth: false)
        XCTAssertEqual(scan.recordCount, 1)
        XCTAssertEqual(scan.corruptedAtOffset, offsets[1])
    }

    func testUnknownEncodingIsCorrupt() throws {
        let offsets = try writeLog(KeyframeLogTests.threeRecords)
        var bytes = try fileBytes()
        bytes[Int(offsets[2]) + 4 + 98] = 1   // depthEncoding 1 is not defined in version 1
        rewriteCRC(&bytes, recordOffset: Int(offsets[2]))
        try writeBytes(bytes)
        let scan = try KeyframeLogReader.scan(url: logURL, decodeDepth: false)
        XCTAssertEqual(scan.recordCount, 2)
        XCTAssertEqual(scan.corruptedAtOffset, offsets[2])
    }

    func testUndecodableLZFSEIsCorruptOnlyWhenDecodingDepth() throws {
        let offsets = try writeLog(KeyframeLogTests.threeRecords)
        var bytes = try fileBytes()
        // Replace record 3's depth block with zeros (same length) and fix the CRC: structurally valid, LZFSE garbage.
        let p = Int(offsets[2]) + 4
        let depthBytes = Int(u32(bytes, at: p + 100))
        for i in 0 ..< depthBytes { bytes[p + 104 + i] = 0 }
        rewriteCRC(&bytes, recordOffset: Int(offsets[2]))
        try writeBytes(bytes)
        let decoded = try KeyframeLogReader.scan(url: logURL, decodeDepth: true)
        XCTAssertEqual(decoded.recordCount, 2)
        XCTAssertEqual(decoded.corruptedAtOffset, offsets[2])
        let metadataOnly = try KeyframeLogReader.scan(url: logURL, decodeDepth: false)
        XCTAssertEqual(metadataOnly.recordCount, 3)
        XCTAssertNil(metadataOnly.corruptedAtOffset)
    }

    // MARK: - Reader: header errors

    func testBadMagicThrowsInvalidMagic() throws {
        var bytes = KeyframeLogTests.expectedHeader
        bytes[3] = 0x47   // "SMKG"
        try writeBytes(bytes)
        assertMapError(.invalidMagic) { _ = try KeyframeLogReader.scan(url: logURL) }
        assertMapError(.invalidMagic) { _ = try KeyframeLogReader.forEachRecord(url: logURL) { _ in } }
        assertMapError(.invalidMagic) { _ = try KeyframeLogWriter(url: logURL) }
        XCTAssertEqual(try fileBytes(), bytes, "a foreign file must not be modified")
    }

    func testVersion2ThrowsUnsupportedVersion() throws {
        var bytes = KeyframeLogTests.expectedHeader
        bytes[4] = 2
        try writeBytes(bytes)
        assertMapError(.unsupportedVersion(2)) { _ = try KeyframeLogReader.scan(url: logURL) }
        assertMapError(.unsupportedVersion(2)) { _ = try KeyframeLogWriter(url: logURL) }
        XCTAssertEqual(try fileBytes(), bytes)
    }

    func testEightByteFileThrowsTruncatedHeader() throws {
        try writeBytes(Array(KeyframeLogTests.expectedHeader[0 ..< 8]))
        assertMapError(.truncatedRecord(offset: 0)) { _ = try KeyframeLogReader.scan(url: logURL) }
        assertMapError(.truncatedRecord(offset: 0)) { _ = try KeyframeLogWriter(url: logURL) }
        XCTAssertEqual(try fileBytes().count, 8)
    }

    func testEmptyFileReaderThrowsTruncatedHeader() throws {
        try writeBytes([])
        assertMapError(.truncatedRecord(offset: 0)) { _ = try KeyframeLogReader.scan(url: logURL) }
    }

    func testWrongHeaderSizeIsCorruptHeader() throws {
        var bytes = KeyframeLogTests.expectedHeader
        bytes[6] = 0x20   // headerSize 32
        try writeBytes(bytes)
        XCTAssertThrowsError(try KeyframeLogReader.scan(url: logURL)) { error in
            guard let mapError = error as? MapError, case .corruptRecord(let offset, _) = mapError else {
                return XCTFail("expected MapError.corruptRecord, got \(error)")
            }
            XCTAssertEqual(offset, 0)
        }
    }

    func testMissingFileThrowsIO() {
        XCTAssertThrowsError(try KeyframeLogReader.scan(url: directory.appendingPathComponent("missing.bin"))) { error in
            guard let mapError = error as? MapError, case .io = mapError else {
                return XCTFail("expected MapError.io, got \(error)")
            }
        }
    }

    // MARK: - Reader: forEachRecord

    func testForEachRecordVisitsAllAndReturnsEmptyRecords() throws {
        try writeLog(KeyframeLogTests.threeRecords)
        var visited: [KeyframeRecord] = []
        let scan = try KeyframeLogReader.forEachRecord(url: logURL) { visited.append($0) }
        XCTAssertEqual(visited, KeyframeLogTests.threeRecords)
        XCTAssertEqual(visited.map(\.seq), [1, 2, 3])
        XCTAssertEqual(scan.records, [])
        XCTAssertEqual(scan.recordCount, 3)
        XCTAssertNil(scan.truncatedAtOffset)
        XCTAssertNil(scan.corruptedAtOffset)
        XCTAssertEqual(scan.byteCount, Int64(try fileBytes().count))
    }

    func testForEachRecordPropagatesBodyError() throws {
        try writeLog(KeyframeLogTests.threeRecords)
        struct Stop: Error {}
        var seen = 0
        XCTAssertThrowsError(try KeyframeLogReader.forEachRecord(url: logURL) { _ in
            seen += 1
            if seen == 2 { throw Stop() }
        }) { error in
            XCTAssertTrue(error is Stop)
        }
        XCTAssertEqual(seen, 2)
    }

    // MARK: - Writer: reopen / crash recovery

    func testReopenTruncatesPartialTailAndAppends() throws {
        let offsets = try writeLog(KeyframeLogTests.threeRecords)
        let bytes = try fileBytes()
        try writeBytes(Array(bytes[0 ..< Int(offsets[2]) + 10]))

        let writer = try KeyframeLogWriter(url: logURL)
        XCTAssertEqual(writer.recordCount, 2)
        XCTAssertEqual(writer.byteCount, offsets[2])
        XCTAssertEqual(Int64(try fileBytes().count), offsets[2], "the partial tail is truncated on reopen")

        let offset = try writer.append(KeyframeLogTests.record3)
        XCTAssertEqual(offset, offsets[2])
        try writer.close()

        let scan = try KeyframeLogReader.scan(url: logURL)
        XCTAssertEqual(scan.records, KeyframeLogTests.threeRecords)
        XCTAssertNil(scan.truncatedAtOffset)
        XCTAssertEqual(try fileBytes(), bytes, "identical input produces identical bytes")
    }

    func testReopenTruncatesCorruptTail() throws {
        let offsets = try writeLog(KeyframeLogTests.threeRecords)
        var bytes = try fileBytes()
        bytes[Int(offsets[1]) + 4 + 104] ^= 0x01   // record 2's first depth byte
        try writeBytes(bytes)

        let writer = try KeyframeLogWriter(url: logURL)
        XCTAssertEqual(writer.recordCount, 1)
        XCTAssertEqual(writer.byteCount, offsets[1])
        try writer.close()
        XCTAssertEqual(Int64(try fileBytes().count), offsets[1])
        let scan = try KeyframeLogReader.scan(url: logURL)
        XCTAssertEqual(scan.records, [KeyframeLogTests.record1])
    }

    func testReopenIntactFileContinuesAppending() throws {
        let offsets = try writeLog(KeyframeLogTests.threeRecords)
        let sizeBefore = Int64(try fileBytes().count)
        let writer = try KeyframeLogWriter(url: logURL)
        XCTAssertEqual(writer.recordCount, 3)
        XCTAssertEqual(writer.byteCount, sizeBefore)
        var fourth = KeyframeLogTests.record1
        fourth.seq = 4
        let offset = try writer.append(fourth)
        XCTAssertEqual(offset, sizeBefore)
        XCTAssertGreaterThan(offset, offsets[2])
        try writer.close()
        let scan = try KeyframeLogReader.scan(url: logURL)
        XCTAssertEqual(scan.records.map(\.seq), [1, 2, 3, 4])
        XCTAssertEqual(scan.records[3], fourth)
    }

    func testReopenHeaderOnlyFile() throws {
        try writeBytes(KeyframeLogTests.expectedHeader)
        let writer = try KeyframeLogWriter(url: logURL)
        XCTAssertEqual(writer.recordCount, 0)
        XCTAssertEqual(writer.byteCount, 16)
        try writer.append(KeyframeLogTests.record2)
        try writer.close()
        XCTAssertEqual(try KeyframeLogReader.scan(url: logURL).records, [KeyframeLogTests.record2])
    }

    func testReopenDropsStrayBytesAfterLastRecord() throws {
        try writeLog(KeyframeLogTests.threeRecords)
        let end = Int64(try fileBytes().count)
        try writeBytes(try fileBytes() + [1, 2, 3])
        let writer = try KeyframeLogWriter(url: logURL)
        XCTAssertEqual(writer.recordCount, 3)
        XCTAssertEqual(writer.byteCount, end)
        try writer.close()
        XCTAssertEqual(Int64(try fileBytes().count), end)
    }

    // MARK: - KeyframeLogScan

    func testScanDefaultsAndValidByteCount() {
        let empty = KeyframeLogScan()
        XCTAssertEqual(empty.records, [])
        XCTAssertEqual(empty.recordCount, 0)
        XCTAssertNil(empty.truncatedAtOffset)
        XCTAssertNil(empty.corruptedAtOffset)
        XCTAssertEqual(empty.byteCount, 0)
        XCTAssertEqual(KeyframeLogScan(byteCount: 500).validByteCount, 500)
        XCTAssertEqual(KeyframeLogScan(truncatedAtOffset: 300, byteCount: 500).validByteCount, 300)
        XCTAssertEqual(KeyframeLogScan(corruptedAtOffset: 200, byteCount: 500).validByteCount, 200)
    }
}
