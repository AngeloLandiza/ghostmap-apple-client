import XCTest
import simd
@testable import MapCore

final class InlinePointsTests: XCTestCase {

    private func point(_ x: Float, r: UInt8 = 10, g: UInt8 = 20, b: UInt8 = 30) -> PackedPoint {
        PackedPoint(position: SIMD3<Float>(x, 1, 2), r: r, g: g, b: b)
    }

    private let parked = PackedPoint(position: SIMD3<Float>(0, -1.0e6, 0), color: 0)

    // MARK: - Selection

    func testSelectDropsParkedEntriesFromBothHalves() {
        let selected = InlinePoints.select(
            appended: [point(0), parked, point(1)],
            updates: [DynamicVoxelMap.PointUpdate(index: 0, point: parked),
                      DynamicVoxelMap.PointUpdate(index: 1, point: point(2))])
        XCTAssertEqual(selected.count, 3)
        XCTAssertEqual(selected.map(\.x), [0, 1, 2])
    }

    func testSelectDecimatesToTheCap() {
        let appended = (0..<5000).map { point(Float($0)) }
        let selected = InlinePoints.select(appended: appended, updates: [], maxPoints: 2000)
        XCTAssertLessThanOrEqual(selected.count, 2000)
        XCTAssertGreaterThan(selected.count, 1000)
        // Uniform stride: consecutive kept points are `stride` apart in the source.
        XCTAssertEqual(selected[0].x, 0)
        XCTAssertEqual(selected[1].x, Float(Decimation.stride(count: 5000, target: 2000)))
    }

    func testSelectWithNoCapReturnsNothing() {
        XCTAssertTrue(InlinePoints.select(appended: [point(0)], updates: [], maxPoints: 0).isEmpty)
    }

    func testSelectOnAnEmptyIntegrationIsEmpty() {
        XCTAssertTrue(InlinePoints.select(appended: [], updates: []).isEmpty)
        XCTAssertTrue(InlinePoints.select(appended: [parked], updates: []).isEmpty)
    }

    // MARK: - Encoding

    func testEncodeProducesFlatXYZRGB() {
        let encoded = InlinePoints.encode([PackedPoint(position: SIMD3<Float>(1, 2, 3), r: 4, g: 5, b: 6)])
        XCTAssertEqual(encoded, [1, 2, 3, 4, 5, 6])
    }

    func testEncodeAppliesTheOriginTransform() {
        // origin is 1 m along +x from the world origin, so a world point at x = 3 is at x = 2 in it.
        let worldFromOrigin = Pose(translation: SIMD3<Float>(1, 0, 0))
        let encoded = InlinePoints.encode([PackedPoint(position: SIMD3<Float>(3, 0, 0), r: 7, g: 8, b: 9)],
                                          originFromWorld: worldFromOrigin.inverse)
        XCTAssertEqual(encoded[0], 2, accuracy: 1e-6)
        XCTAssertEqual(encoded[3], 7)
    }

    func testEncodeDecodeRoundTrip() {
        let points: [PackedPoint] = (0..<20).map { (i: Int) -> PackedPoint in
            point(Float(i), r: UInt8(i), g: UInt8(i * 2), b: UInt8(i * 3))
        }
        let decoded = InlinePoints.decode(InlinePoints.encode(points))
        XCTAssertEqual(decoded.count, points.count)
        for (a, b) in zip(points, decoded) {
            XCTAssertEqual(a.position, b.position)
            XCTAssertEqual(a.r, b.r)
            XCTAssertEqual(a.g, b.g)
            XCTAssertEqual(a.b, b.b)
        }
    }

    // MARK: - Decoding hostile input

    func testDecodeIgnoresATrailingPartialPoint() {
        XCTAssertEqual(InlinePoints.decode([1, 2, 3, 4, 5, 6, 7, 8]).count, 1)
        XCTAssertTrue(InlinePoints.decode([1, 2, 3]).isEmpty)
        XCTAssertTrue(InlinePoints.decode([]).isEmpty)
    }

    func testDecodeSkipsNonFinitePositionsAndClampsColours() {
        let values: [Double] = [.nan, 0, 0, 0, 0, 0,
                                .infinity, 0, 0, 0, 0, 0,
                                1, 2, 3, -40, 300, 12.6]
        let decoded = InlinePoints.decode(values)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].r, 0)
        XCTAssertEqual(decoded[0].g, 255)
        XCTAssertEqual(decoded[0].b, 13)
    }

    func testDecodeHonoursTheLimit() {
        let values = InlinePoints.encode((0..<100).map { point(Float($0)) })
        XCTAssertEqual(InlinePoints.decode(values, limit: 10).count, 10)
        XCTAssertTrue(InlinePoints.decode(values, limit: 0).isEmpty)
        XCTAssertTrue(InlinePoints.decode(values, limit: -5).isEmpty)
    }

    func testDecodeTintsWithThePartyColour() {
        let values = InlinePoints.encode([PackedPoint(position: .zero, r: 255, g: 255, b: 255)])
        let decoded = InlinePoints.decode(values, tint: PartyColor(r: 0, g: 0, b: 0), mix: 1)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].r, 0)
        XCTAssertEqual(decoded[0].g, 0)
        XCTAssertEqual(decoded[0].b, 0)
    }

    func testAFullMessageStaysInsideTheBackendSchemaLimit() {
        let points = (0..<InlinePoints.maxPoints).map { point(Float($0)) }
        XCTAssertEqual(InlinePoints.encode(points).count, InlinePoints.maxPoints * InlinePoints.stride)
    }
}
