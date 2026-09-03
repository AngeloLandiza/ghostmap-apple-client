import XCTest
import simd
@testable import MapCore

final class PointCloudTests: XCTestCase {

    private func pt(_ x: Float, _ y: Float, _ z: Float, _ color: UInt32 = 0xFF00_0000) -> PackedPoint {
        PackedPoint(x: x, y: y, z: z, color: color)
    }

    func testEmptyCloud() {
        let cloud = PointCloud()
        XCTAssertEqual(cloud.count, 0)
        XCTAssertTrue(cloud.points.isEmpty)
        XCTAssertTrue(cloud.bounds.isEmpty)
        XCTAssertEqual(cloud.bounds, .empty)
        XCTAssertEqual(cloud, PointCloud(points: []))
    }

    func testInitComputesBounds() {
        let cloud = PointCloud(points: [pt(1, -2, 3), pt(-4, 5, 0.5)])
        XCTAssertEqual(cloud.count, 2)
        // min = (min(1, −4), min(−2, 5), min(3, 0.5)) = (−4, −2, 0.5)
        XCTAssertEqual(cloud.bounds.min, SIMD3<Float>(-4, -2, 0.5))
        // max = (max(1, −4), max(−2, 5), max(3, 0.5)) = (1, 5, 3)
        XCTAssertEqual(cloud.bounds.max, SIMD3<Float>(1, 5, 3))
        XCTAssertFalse(cloud.bounds.isEmpty)
    }

    func testSinglePointBoundsAreDegenerate() {
        let cloud = PointCloud(points: [pt(0.25, -0.5, 2)])
        XCTAssertEqual(cloud.bounds.min, SIMD3<Float>(0.25, -0.5, 2))
        XCTAssertEqual(cloud.bounds.max, SIMD3<Float>(0.25, -0.5, 2))
        // extent = max − min = 0 on every axis
        XCTAssertEqual(cloud.bounds.extent, .zero)
        XCTAssertFalse(cloud.bounds.isEmpty)
    }

    func testAppendExtendsBoundsIncrementally() {
        var cloud = PointCloud(points: [pt(1, 1, 1, 1)])
        cloud.append(contentsOf: [pt(2, 0, 1, 2), pt(0, 3, -1, 3)])
        XCTAssertEqual(cloud.count, 3)
        XCTAssertEqual(cloud.points.map(\.color), [1, 2, 3], "insertion order is preserved")
        // min = (min(1, 2, 0), min(1, 0, 3), min(1, 1, −1)) = (0, 0, −1)
        XCTAssertEqual(cloud.bounds.min, SIMD3<Float>(0, 0, -1))
        // max = (max(1, 2, 0), max(1, 0, 3), max(1, 1, −1)) = (2, 3, 1)
        XCTAssertEqual(cloud.bounds.max, SIMD3<Float>(2, 3, 1))

        // A point strictly inside the box leaves the bounds unchanged.
        cloud.append(contentsOf: [pt(1, 1, 0, 4)])
        XCTAssertEqual(cloud.count, 4)
        XCTAssertEqual(cloud.bounds.min, SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(cloud.bounds.max, SIMD3<Float>(2, 3, 1))

        // A point outside on one axis only moves that axis: z max 1 → 7.
        cloud.append(contentsOf: [pt(1, 1, 7, 5)])
        XCTAssertEqual(cloud.bounds.min, SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(cloud.bounds.max, SIMD3<Float>(2, 3, 7))
    }

    func testAppendToEmptyCloudSetsBounds() {
        var cloud = PointCloud()
        cloud.append(contentsOf: [pt(-1, 2, -3)])
        XCTAssertEqual(cloud.count, 1)
        XCTAssertEqual(cloud.bounds.min, SIMD3<Float>(-1, 2, -3))
        XCTAssertEqual(cloud.bounds.max, SIMD3<Float>(-1, 2, -3))
    }

    func testAppendEmptyBatchIsNoOp() {
        var cloud = PointCloud(points: [pt(1, 2, 3)])
        let before = cloud
        cloud.append(contentsOf: [])
        XCTAssertEqual(cloud, before)
        XCTAssertEqual(cloud.count, 1)

        var empty = PointCloud()
        empty.append(contentsOf: [])
        XCTAssertTrue(empty.bounds.isEmpty)
        XCTAssertEqual(empty.count, 0)
    }

    func testSettingPointsRecomputesBounds() {
        var cloud = PointCloud(points: [pt(1, 1, 1), pt(9, 9, 9)])
        cloud.points = [pt(5, 5, 5)]
        XCTAssertEqual(cloud.count, 1)
        // bounds shrink to the single remaining point instead of keeping the old (1…9) box
        XCTAssertEqual(cloud.bounds.min, SIMD3<Float>(5, 5, 5))
        XCTAssertEqual(cloud.bounds.max, SIMD3<Float>(5, 5, 5))

        cloud.points = []
        XCTAssertEqual(cloud.count, 0)
        XCTAssertTrue(cloud.bounds.isEmpty)

        cloud.points.append(pt(-2, 4, 6))
        XCTAssertEqual(cloud.count, 1)
        XCTAssertEqual(cloud.bounds.min, SIMD3<Float>(-2, 4, 6))
        XCTAssertEqual(cloud.bounds.max, SIMD3<Float>(-2, 4, 6))
    }

    func testStaticBoundsOfEmptyBuffer() {
        let empty: [PackedPoint] = []
        let bounds = empty.withUnsafeBufferPointer(PointCloud.bounds(of:))
        XCTAssertTrue(bounds.isEmpty)
        XCTAssertEqual(bounds, .empty)
    }

    func testStaticBoundsOfBuffer() {
        let points = [pt(3, 3, 3), pt(-1, 8, 3), pt(3, -7, 10)]
        let bounds = points.withUnsafeBufferPointer(PointCloud.bounds(of:))
        // min = (min(3, −1, 3), min(3, 8, −7), min(3, 3, 10)) = (−1, −7, 3)
        XCTAssertEqual(bounds.min, SIMD3<Float>(-1, -7, 3))
        // max = (max(3, −1, 3), max(3, 8, −7), max(3, 3, 10)) = (3, 8, 10)
        XCTAssertEqual(bounds.max, SIMD3<Float>(3, 8, 10))
        // center = (min + max) / 2 = ((−1+3)/2, (−7+8)/2, (3+10)/2) = (1, 0.5, 6.5)
        XCTAssertEqual(bounds.center, SIMD3<Float>(1, 0.5, 6.5))
        // extent = max − min = (4, 15, 7)
        XCTAssertEqual(bounds.extent, SIMD3<Float>(4, 15, 7))
    }

    func testEquatableComparesPointsAndBounds() {
        let viaInit = PointCloud(points: [pt(1, 2, 3, 1), pt(4, 5, 6, 2)])
        var viaAppend = PointCloud(points: [pt(1, 2, 3, 1)])
        viaAppend.append(contentsOf: [pt(4, 5, 6, 2)])
        XCTAssertEqual(viaInit, viaAppend, "same points in the same order → equal, however they were built")
        XCTAssertEqual(viaInit.bounds, viaAppend.bounds)

        let reordered = PointCloud(points: [pt(4, 5, 6, 2), pt(1, 2, 3, 1)])
        XCTAssertNotEqual(viaInit, reordered, "order matters")
        XCTAssertEqual(viaInit.bounds, reordered.bounds, "but the bounds are the same")

        let recolored = PointCloud(points: [pt(1, 2, 3, 9), pt(4, 5, 6, 2)])
        XCTAssertNotEqual(viaInit, recolored)
    }

    func testIncrementalBoundsMatchFullRecomputeOnSeededRandomBatches() {
        // Deterministic LCG so the test never flakes.
        var seed: UInt32 = 12345
        func nextFloat() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24) * 10 - 5   // uniform in [−5, 5)
        }
        var cloud = PointCloud()
        var all: [PackedPoint] = []
        for batch in 0..<20 {
            let points = (0..<(batch * 7 + 1)).map { _ in pt(nextFloat(), nextFloat(), nextFloat()) }
            cloud.append(contentsOf: points)
            all.append(contentsOf: points)
            XCTAssertEqual(cloud.bounds, all.withUnsafeBufferPointer(PointCloud.bounds(of:)), "batch \(batch)")
        }
        XCTAssertEqual(cloud.count, all.count)
        XCTAssertEqual(cloud, PointCloud(points: all))
        // Sanity: 20 batches of sizes 1, 8, 15, …, 134 = 20·1 + 7·(0+1+…+19) = 20 + 7·190 = 1 350 points
        XCTAssertEqual(cloud.count, 1_350)
    }
}
