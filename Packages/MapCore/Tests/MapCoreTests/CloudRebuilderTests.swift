import Foundation
import simd
import XCTest
@testable import MapCore

final class CloudRebuilderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudRebuilderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// 2×2 image with fx = fy = 1 and the principal point at (1, 1): pixel (u, v) at depth d
    /// unprojects to camera (X, −Y, −d) with X = (u + 0.5 − 1) · d, Y = (v + 0.5 − 1) · d.
    /// At d = 1 m the four pixels are, in row-major order:
    ///   0 (0,0) → (−0.5,  0.5, −1)
    ///   1 (1,0) → ( 0.5,  0.5, −1)
    ///   2 (0,1) → (−0.5, −0.5, −1)
    ///   3 (1,1) → ( 0.5, −0.5, −1)
    private static let intrinsics2x2 = Intrinsics(fx: 1, fy: 1, cx: 1, cy: 1, width: 2, height: 2)

    private static let cameraPoints: [SIMD3<Float>] = [
        SIMD3<Float>(-0.5, 0.5, -1),
        SIMD3<Float>(0.5, 0.5, -1),
        SIMD3<Float>(-0.5, -0.5, -1),
        SIMD3<Float>(0.5, -0.5, -1),
    ]

    private static let gray210: UInt32 = 0xFFD2_D2D2   // a 255, b 210, g 210, r 210
    private static let gray150: UInt32 = 0xFF96_9696   // a 255, b 150, g 150, r 150

    private func makeRecord(seq: UInt32,
                            translation: SIMD3<Float> = .zero,
                            depth: [UInt16] = [1000, 1000, 1000, 1000],
                            confidence: [UInt8]) -> KeyframeRecord {
        KeyframeRecord(
            seq: seq,
            timestamp: Double(seq),
            pose: Pose(translation: translation),
            intrinsics: CloudRebuilderTests.intrinsics2x2,
            tracking: .normal,
            depthMillimeters: depth,
            confidence: confidence
        )
    }

    @discardableResult
    private func writeLog(_ records: [KeyframeRecord], name: String = "keyframes.bin") throws -> (url: URL, offsets: [Int64]) {
        let url = directory.appendingPathComponent(name)
        let writer = try KeyframeLogWriter(url: url)
        var offsets: [Int64] = []
        for record in records {
            offsets.append(try writer.append(record))
        }
        try writer.close()
        return (url, offsets)
    }

    private func expectedPoints(translation: SIMD3<Float>, confidence: [UInt8]) -> [PackedPoint] {
        zip(CloudRebuilderTests.cameraPoints, confidence).map { camera, c in
            PackedPoint(position: camera + translation,
                        color: c == 2 ? CloudRebuilderTests.gray210 : CloudRebuilderTests.gray150)
        }
    }

    // MARK: - Tests

    func testColorConstants() {
        XCTAssertEqual(CloudRebuilder.highConfidenceColor, CloudRebuilderTests.gray210)
        XCTAssertEqual(CloudRebuilder.mediumConfidenceColor, CloudRebuilderTests.gray150)
        XCTAssertEqual(PackedPoint(position: .zero, color: CloudRebuilder.highConfidenceColor).r, 210)
        XCTAssertEqual(PackedPoint(position: .zero, color: CloudRebuilder.mediumConfidenceColor).g, 150)
        XCTAssertEqual(PackedPoint(position: .zero, color: CloudRebuilder.mediumConfidenceColor).a, 255)
    }

    func testTwoKeyframesFarApartGiveEightPoints() throws {
        let first = makeRecord(seq: 1, confidence: [2, 1, 2, 1])
        let second = makeRecord(seq: 2, translation: SIMD3<Float>(10, 0, 0), confidence: [1, 1, 2, 2])
        let (url, _) = try writeLog([first, second])

        var progress: [Int] = []
        let result = try CloudRebuilder.rebuild(logURL: url) { progress.append($0) }

        XCTAssertEqual(result.cloud.count, 8)
        // Keyframe 1 at the origin, then keyframe 2 shifted by +10 in x; 2 cm cells never collide.
        let expected = expectedPoints(translation: .zero, confidence: [2, 1, 2, 1])
            + expectedPoints(translation: SIMD3<Float>(10, 0, 0), confidence: [1, 1, 2, 2])
        XCTAssertEqual(result.cloud.points, expected)
        XCTAssertEqual(result.cloud.points.map(\.r), [210, 150, 210, 150, 150, 150, 210, 210])
        XCTAssertEqual(result.cloud.points[0].position, SIMD3<Float>(-0.5, 0.5, -1))
        XCTAssertEqual(result.cloud.points[5].position, SIMD3<Float>(10.5, 0.5, -1))
        // bounds: x ∈ [−0.5, 10.5], y ∈ [−0.5, 0.5], z = −1
        XCTAssertEqual(result.cloud.bounds.min, SIMD3<Float>(-0.5, -0.5, -1))
        XCTAssertEqual(result.cloud.bounds.max, SIMD3<Float>(10.5, 0.5, -1))
        XCTAssertEqual(result.keyframeCount, 2)
        XCTAssertEqual(progress, [1, 2])
        XCTAssertEqual(result.gridState, .accepting)
        XCTAssertEqual(result.scan.recordCount, 2)
        XCTAssertEqual(result.scan.records, [])
        XCTAssertNil(result.scan.truncatedAtOffset)
        XCTAssertNil(result.scan.corruptedAtOffset)
    }

    func testSamePoseTwiceDeduplicates() throws {
        let first = makeRecord(seq: 1, confidence: [2, 2, 2, 2])
        let second = makeRecord(seq: 2, confidence: [1, 1, 1, 1])
        let (url, _) = try writeLog([first, second])
        var calls = 0
        let result = try CloudRebuilder.rebuild(logURL: url) { _ in calls += 1 }
        // Same four cells → the first sample wins, so all four keep the high-confidence gray.
        XCTAssertEqual(result.cloud.count, 4)
        XCTAssertEqual(result.cloud.points, expectedPoints(translation: .zero, confidence: [2, 2, 2, 2]))
        XCTAssertEqual(result.keyframeCount, 2)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.gridState, .accepting)
    }

    func testLowConfidenceAndZeroDepthPixelsAreSkipped() throws {
        // Pixel 0: confidence 0 < minConfidence 1 → dropped. Pixel 2: depth 0 → dropped.
        let record = makeRecord(seq: 1, depth: [1000, 1000, 0, 1000], confidence: [0, 2, 2, 1])
        let (url, _) = try writeLog([record])
        let result = try CloudRebuilder.rebuild(logURL: url)
        XCTAssertEqual(result.cloud.points, [
            PackedPoint(position: CloudRebuilderTests.cameraPoints[1], color: CloudRebuilderTests.gray210),
            PackedPoint(position: CloudRebuilderTests.cameraPoints[3], color: CloudRebuilderTests.gray150),
        ])
        XCTAssertEqual(result.keyframeCount, 1)
    }

    func testUnprojectorOptionsAreHonored() throws {
        let record = makeRecord(seq: 1, depth: [1000, 1000, 6000, 1000], confidence: [2, 1, 2, 2])
        let (url, _) = try writeLog([record])
        // minConfidence 2 drops pixel 1; maxDepth 5 m drops pixel 2 (6 m).
        let strict = try CloudRebuilder.rebuild(logURL: url, options: Unprojector.Options(minConfidence: 2))
        XCTAssertEqual(strict.cloud.points.map(\.position), [
            CloudRebuilderTests.cameraPoints[0],
            CloudRebuilderTests.cameraPoints[3],
        ])
        // Raising maxDepth to 7 m keeps pixel 2 at depth 6: X = −0.5·6 = −3, Y = 0.5·6 = 3 → (−3, −3, −6).
        let deep = try CloudRebuilder.rebuild(logURL: url, options: Unprojector.Options(minConfidence: 2, maxDepthMeters: 7))
        XCTAssertEqual(deep.cloud.points.map(\.position), [
            CloudRebuilderTests.cameraPoints[0],
            SIMD3<Float>(-3, -3, -6),
            CloudRebuilderTests.cameraPoints[3],
        ])
    }

    func testCapReachedCoarsensExistingCloud() throws {
        // Keyframe 1 at (5, 5, 5): points (4.5, 5.5, 4), (5.5, 5.5, 4), (4.5, 4.5, 4), (5.5, 4.5, 4).
        // Keyframe 2 at (15, 5, 5): points (14.5, 5.5, 4), (15.5, 5.5, 4), (14.5, 4.5, 4), (15.5, 4.5, 4).
        let first = makeRecord(seq: 1, translation: SIMD3<Float>(5, 5, 5), confidence: [2, 1, 2, 1])
        let second = makeRecord(seq: 2, translation: SIMD3<Float>(15, 5, 5), confidence: [1, 2, 2, 2])
        let (url, _) = try writeLog([first, second])

        // Cap 4 at 2 cm; coarsening to 10 m cells.
        let config = VoxelGrid.Config(cellSize: 0.02, maxPoints: 4, coarsenedCellSize: 10)
        let result = try CloudRebuilder.rebuild(logURL: url, gridConfig: config)

        // Keyframe 1 fills 4 distinct 2 cm cells → count 4 = cap → .capReached → coarsen at 10 m:
        // all four fall in cell (0, 0, 0) (floor(4.5/10) = floor(5.5/10) = floor(4/10) = 0), first wins.
        // Keyframe 2: cells x = floor(14.5/10) = floor(15.5/10) = 1 → one new cell (1, 0, 0), first wins.
        XCTAssertEqual(result.cloud.points, [
            PackedPoint(position: SIMD3<Float>(4.5, 5.5, 4), color: CloudRebuilderTests.gray210),
            PackedPoint(position: SIMD3<Float>(14.5, 5.5, 4), color: CloudRebuilderTests.gray150),
        ])
        XCTAssertEqual(result.gridState, .coarsened)
        XCTAssertEqual(result.keyframeCount, 2)
        XCTAssertEqual(result.cloud.bounds.min, SIMD3<Float>(4.5, 5.5, 4))
        XCTAssertEqual(result.cloud.bounds.max, SIMD3<Float>(14.5, 5.5, 4))
    }

    func testSecondCapMakesGridFull() throws {
        let first = makeRecord(seq: 1, translation: SIMD3<Float>(5, 5, 5), confidence: [2, 2, 2, 2])
        let second = makeRecord(seq: 2, translation: SIMD3<Float>(15, 5, 5), confidence: [2, 2, 2, 2])
        let third = makeRecord(seq: 3, translation: SIMD3<Float>(25, 5, 5), confidence: [2, 2, 2, 2])
        let (url, _) = try writeLog([first, second, third])

        let config = VoxelGrid.Config(cellSize: 0.02, maxPoints: 2, coarsenedCellSize: 10)
        var progress: [Int] = []
        let result = try CloudRebuilder.rebuild(logURL: url, gridConfig: config) { progress.append($0) }

        // Keyframe 1: pixels 0 and 1 accepted → count 2 = cap → coarsen → only (4.5, 5.5, 4) survives (cell 0,0,0).
        // Keyframe 2: (14.5, 5.5, 4) is cell (1, 0, 0) → accepted → count 2 = cap again → .full.
        // Keyframe 3: grid is full → nothing accepted.
        XCTAssertEqual(result.cloud.points.map(\.position), [
            SIMD3<Float>(4.5, 5.5, 4),
            SIMD3<Float>(14.5, 5.5, 4),
        ])
        XCTAssertEqual(result.gridState, .full)
        XCTAssertEqual(result.keyframeCount, 3)
        XCTAssertEqual(progress, [1, 2, 3])
    }

    func testEmptyLogGivesEmptyCloud() throws {
        let (url, _) = try writeLog([])
        var calls = 0
        let result = try CloudRebuilder.rebuild(logURL: url) { _ in calls += 1 }
        XCTAssertEqual(result.cloud.count, 0)
        XCTAssertTrue(result.cloud.bounds.isEmpty)
        XCTAssertEqual(result.keyframeCount, 0)
        XCTAssertEqual(result.gridState, .accepting)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(result.scan.byteCount, 16)
        XCTAssertEqual(result.scan.recordCount, 0)
    }

    func testTruncatedTailIsReportedInScan() throws {
        let first = makeRecord(seq: 1, confidence: [2, 2, 2, 2])
        let second = makeRecord(seq: 2, translation: SIMD3<Float>(10, 0, 0), confidence: [2, 2, 2, 2])
        let (url, offsets) = try writeLog([first, second])
        let bytes = try Data(contentsOf: url)
        try bytes[0 ..< Int(offsets[1]) + 10].write(to: url)   // 10 bytes into record 2

        let result = try CloudRebuilder.rebuild(logURL: url)
        XCTAssertEqual(result.cloud.count, 4)
        XCTAssertEqual(result.keyframeCount, 1)
        XCTAssertEqual(result.scan.recordCount, 1)
        XCTAssertEqual(result.scan.truncatedAtOffset, offsets[1])
        XCTAssertNil(result.scan.corruptedAtOffset)
    }

    func testMissingLogThrowsIO() {
        XCTAssertThrowsError(try CloudRebuilder.rebuild(logURL: directory.appendingPathComponent("missing.bin"))) { error in
            guard let mapError = error as? MapError, case .io = mapError else {
                return XCTFail("expected MapError.io, got \(error)")
            }
        }
    }

    func testBadHeaderThrows() throws {
        let url = directory.appendingPathComponent("bad.bin")
        try Data([0x42, 0x41, 0x44, 0x21, 1, 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0]).write(to: url)
        XCTAssertThrowsError(try CloudRebuilder.rebuild(logURL: url)) { error in
            XCTAssertEqual(error as? MapError, .invalidMagic)
        }
    }

    func testResultInit() {
        let scan = KeyframeLogScan(byteCount: 16)
        let result = CloudRebuilder.Result(cloud: PointCloud(), keyframeCount: 0, gridState: .accepting, scan: scan)
        XCTAssertEqual(result.cloud.count, 0)
        XCTAssertEqual(result.keyframeCount, 0)
        XCTAssertEqual(result.gridState, .accepting)
        XCTAssertEqual(result.scan, scan)
    }
}
