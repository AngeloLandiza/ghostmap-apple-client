import Foundation
import simd
import XCTest
@testable import MapCore

final class KeyframeRecordTests: XCTestCase {

    /// 4×3 intrinsics: 12 pixels. Focal/principal values are arbitrary but distinct so equality tests are meaningful.
    private let intrinsics4x3 = Intrinsics(fx: 100, fy: 110, cx: 2, cy: 1.5, width: 4, height: 3)

    /// A record at 4×3 whose depth/confidence arrays have the given lengths (default: matching, 12 each).
    private func makeRecord(depthCount: Int = 12, confidenceCount: Int = 12, seq: UInt32 = 7) -> KeyframeRecord {
        KeyframeRecord(
            seq: seq,
            timestamp: 123.5,
            pose: Pose(translation: SIMD3<Float>(1, 2, 3)),
            intrinsics: intrinsics4x3,
            tracking: .normal,
            depthMillimeters: (0..<depthCount).map { UInt16($0 * 100) },
            confidence: (0..<confidenceCount).map { UInt8($0 % 3) }
        )
    }

    // MARK: - pixelCount

    func testPixelCountIsWidthTimesHeight() {
        // 4 * 3 = 12
        XCTAssertEqual(makeRecord().pixelCount, 12)
        XCTAssertEqual(makeRecord().pixelCount, intrinsics4x3.pixelCount)
    }

    func testPixelCountAtDepthMapResolution() {
        // 256 * 192 = 49 152 (the LiDAR depth map size).
        let record = KeyframeRecord(
            seq: 0,
            timestamp: 0,
            pose: .identity,
            intrinsics: Intrinsics(fx: 200, fy: 200, cx: 128, cy: 96, width: 256, height: 192),
            tracking: .normal,
            depthMillimeters: [UInt16](repeating: 1500, count: 49_152),
            confidence: [UInt8](repeating: 2, count: 49_152)
        )
        XCTAssertEqual(record.pixelCount, 49_152)
        XCTAssertTrue(record.isConsistent)
    }

    // MARK: - isConsistent

    func testIsConsistentWhenBothArraysMatchPixelCount() {
        // 12 depth + 12 confidence for 12 pixels.
        XCTAssertTrue(makeRecord(depthCount: 12, confidenceCount: 12).isConsistent)
    }

    func testIsInconsistentWhenDepthIsShort() {
        // 11 depth samples for 12 pixels.
        XCTAssertFalse(makeRecord(depthCount: 11, confidenceCount: 12).isConsistent)
    }

    func testIsInconsistentWhenDepthIsLong() {
        // 13 depth samples for 12 pixels.
        XCTAssertFalse(makeRecord(depthCount: 13, confidenceCount: 12).isConsistent)
    }

    func testIsInconsistentWhenConfidenceIsShort() {
        // 11 confidence samples for 12 pixels.
        XCTAssertFalse(makeRecord(depthCount: 12, confidenceCount: 11).isConsistent)
    }

    func testIsInconsistentWhenConfidenceIsLong() {
        // 13 confidence samples for 12 pixels.
        XCTAssertFalse(makeRecord(depthCount: 12, confidenceCount: 13).isConsistent)
    }

    func testIsInconsistentWhenBothArraysAreEmpty() {
        // 0 samples for 12 pixels.
        XCTAssertFalse(makeRecord(depthCount: 0, confidenceCount: 0).isConsistent)
    }

    func testZeroPixelRecordWithEmptyArraysIsConsistent() {
        // 0 * 0 = 0 pixels; empty arrays match.
        let record = KeyframeRecord(
            seq: 1,
            timestamp: 0,
            pose: .identity,
            intrinsics: Intrinsics(fx: 1, fy: 1, cx: 0, cy: 0, width: 0, height: 0),
            tracking: .notAvailable,
            depthMillimeters: [],
            confidence: []
        )
        XCTAssertEqual(record.pixelCount, 0)
        XCTAssertTrue(record.isConsistent)
    }

    // MARK: - Initialization

    func testInitStoresEveryField() {
        let record = makeRecord()
        XCTAssertEqual(record.seq, 7)
        XCTAssertEqual(record.timestamp, 123.5)
        XCTAssertEqual(record.pose, Pose(translation: SIMD3<Float>(1, 2, 3)))
        XCTAssertEqual(record.intrinsics, intrinsics4x3)
        XCTAssertEqual(record.tracking, .normal)
        // (0..<12).map { $0 * 100 } = 0, 100, ..., 1100
        XCTAssertEqual(record.depthMillimeters, [0, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100])
        // (0..<12).map { $0 % 3 } = 0,1,2 repeated four times
        XCTAssertEqual(record.confidence, [0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2])
    }

    func testFieldsAreMutable() {
        var record = makeRecord()
        record.seq = 8
        record.timestamp = 200
        record.tracking = .limited(.excessiveMotion)
        record.depthMillimeters[0] = 42
        record.confidence[11] = 0
        XCTAssertEqual(record.seq, 8)
        XCTAssertEqual(record.timestamp, 200)
        XCTAssertEqual(record.tracking, .limited(.excessiveMotion))
        XCTAssertEqual(record.depthMillimeters[0], 42)
        XCTAssertEqual(record.confidence[11], 0)
        XCTAssertTrue(record.isConsistent)
    }

    // MARK: - Equatable

    func testIdenticalRecordsAreEqual() {
        XCTAssertEqual(makeRecord(), makeRecord())
    }

    func testRecordsDifferingInSeqAreNotEqual() {
        XCTAssertNotEqual(makeRecord(seq: 7), makeRecord(seq: 8))
    }

    func testRecordsDifferingInOneDepthSampleAreNotEqual() {
        var other = makeRecord()
        other.depthMillimeters[5] += 1
        XCTAssertNotEqual(makeRecord(), other)
    }

    func testRecordsDifferingInTrackingAreNotEqual() {
        var other = makeRecord()
        other.tracking = .limited(.relocalizing)
        XCTAssertNotEqual(makeRecord(), other)
    }

    func testRecordsDifferingInPoseAreNotEqual() {
        var other = makeRecord()
        other.pose = Pose(translation: SIMD3<Float>(1, 2, 3.5))
        XCTAssertNotEqual(makeRecord(), other)
    }
}
