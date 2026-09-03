import XCTest
@testable import MapCore

final class DecimationTests: XCTestCase {

    private func points(_ count: Int) -> [PackedPoint] {
        (0..<count).map { PackedPoint(x: Float($0), y: 0, z: 0, color: UInt32($0)) }
    }

    func testStride() {
        // (1_000_000 + 250_000 − 1) / 250_000 = 1_249_999 / 250_000 = 4 (ceil(1_000_000 / 4) = 250_000 ≤ target)
        XCTAssertEqual(Decimation.stride(count: 1_000_000, target: 250_000), 4)
        // count ≤ target → 1
        XCTAssertEqual(Decimation.stride(count: 250_000, target: 250_000), 1)
        // (250_001 + 249_999) / 250_000 = 500_000 / 250_000 = 2
        XCTAssertEqual(Decimation.stride(count: 250_001, target: 250_000), 2)
        // 0 ≤ 250_000 → 1
        XCTAssertEqual(Decimation.stride(count: 0, target: 250_000), 1)
        // target ≤ 0 → max(1, count) = 10
        XCTAssertEqual(Decimation.stride(count: 10, target: 0), 10)
        XCTAssertEqual(Decimation.stride(count: 10, target: -5), 10)
        // count 0, target 0: 0 ≤ 0 → 1 (and max(1, 0) would also be 1)
        XCTAssertEqual(Decimation.stride(count: 0, target: 0), 1)
        // (7 + 2) / 3 = 3: ceil(7/3) = 3 ≤ 3, whereas stride 2 gives ceil(7/2) = 4 > 3
        XCTAssertEqual(Decimation.stride(count: 7, target: 3), 3)
        // (1_999_999 + 999_999) / 1_000_000 = 2_999_998 / 1_000_000 = 2 (ceil(1_999_999 / 2) = 1_000_000 ≤ target)
        XCTAssertEqual(Decimation.stride(count: 1_999_999, target: 1_000_000), 2)
        // (1 + 0) / 1 = 1 when count == target == 1
        XCTAssertEqual(Decimation.stride(count: 1, target: 1), 1)
        // (2 + 0) / 1 = 2
        XCTAssertEqual(Decimation.stride(count: 2, target: 1), 2)
    }

    func testStrideAlwaysMeetsTargetAndIsMinimal() {
        for count in 0...60 {
            for target in 1...12 {
                let s = Decimation.stride(count: count, target: target)
                XCTAssertGreaterThanOrEqual(s, 1)
                // ceil(count / s) ≤ target
                XCTAssertLessThanOrEqual((count + s - 1) / s, target, "count \(count) target \(target)")
                if s > 1 {
                    // s − 1 would overshoot the target, otherwise s would not be minimal
                    XCTAssertGreaterThan((count + s - 2) / (s - 1), target, "count \(count) target \(target)")
                }
            }
        }
    }

    func testDecimatedCount() {
        // ceil(1_000_000 / 4) = 250_000
        XCTAssertEqual(Decimation.decimatedCount(count: 1_000_000, stride: 4), 250_000)
        // count 0 → 0
        XCTAssertEqual(Decimation.decimatedCount(count: 0, stride: 1), 0)
        XCTAssertEqual(Decimation.decimatedCount(count: 0, stride: 7), 0)
        // ceil(10 / 3) = (10 + 2) / 3 = 4
        XCTAssertEqual(Decimation.decimatedCount(count: 10, stride: 3), 4)
        // stride 1 keeps everything
        XCTAssertEqual(Decimation.decimatedCount(count: 10, stride: 1), 10)
        // stride ≥ count keeps exactly the first point: ceil(5 / 10) = 1
        XCTAssertEqual(Decimation.decimatedCount(count: 5, stride: 10), 1)
        // stride ≤ 0 is treated as 1
        XCTAssertEqual(Decimation.decimatedCount(count: 10, stride: 0), 10)
        XCTAssertEqual(Decimation.decimatedCount(count: 10, stride: -3), 10)
        // ceil(250_001 / 2) = 125_001
        XCTAssertEqual(Decimation.decimatedCount(count: 250_001, stride: 2), 125_001)
    }

    func testDecimateKeepsEveryStrideThPointStartingAtZero() {
        let input = points(10)
        // stride(10, 4) = (10 + 3) / 4 = 3 → indices 0, 3, 6, 9
        let kept = Decimation.decimate(input, target: 4)
        XCTAssertEqual(kept.map(\.color), [0, 3, 6, 9])
        XCTAssertEqual(kept.count, Decimation.decimatedCount(count: 10, stride: 3))
        XCTAssertEqual(kept, [input[0], input[3], input[6], input[9]])
    }

    func testDecimateReturnsInputWhenUnderTarget() {
        let input = points(10)
        XCTAssertEqual(Decimation.decimate(input, target: 10), input)
        XCTAssertEqual(Decimation.decimate(input, target: 11), input)
        XCTAssertEqual(Decimation.decimate(input, target: 1_000_000), input)
    }

    func testDecimateEmptyInput() {
        XCTAssertEqual(Decimation.decimate([], target: 4), [])
        XCTAssertEqual(Decimation.decimate([], target: 0), [])
    }

    func testDecimateWithNonPositiveTargetKeepsOnlyTheFirstPoint() {
        let input = points(10)
        // stride(10, 0) = 10 → only index 0
        XCTAssertEqual(Decimation.decimate(input, target: 0).map(\.color), [0])
        XCTAssertEqual(Decimation.decimate(input, target: -1).map(\.color), [0])
        // target 1: stride (10 + 0) / 1 = 10 → only index 0 as well
        XCTAssertEqual(Decimation.decimate(input, target: 1).map(\.color), [0])
    }

    func testDecimateTwoToOne() {
        let input = points(9)
        // stride(9, 5) = (9 + 4) / 5 = 13 / 5 = 2 → indices 0, 2, 4, 6, 8 (5 points = target)
        XCTAssertEqual(Decimation.decimate(input, target: 5).map(\.color), [0, 2, 4, 6, 8])
        // stride(9, 4) = (9 + 3) / 4 = 3 → indices 0, 3, 6 (3 points ≤ target 4)
        XCTAssertEqual(Decimation.decimate(input, target: 4).map(\.color), [0, 3, 6])
    }

    func testDecimateCountMatchesDecimatedCountAndTarget() {
        for count in 0...40 {
            let input = points(count)
            for target in 0...9 {
                let s = Decimation.stride(count: count, target: target)
                let kept = Decimation.decimate(input, target: target)
                XCTAssertEqual(kept.count, Decimation.decimatedCount(count: count, stride: s), "count \(count) target \(target)")
                if target > 0 {
                    XCTAssertLessThanOrEqual(kept.count, target, "count \(count) target \(target)")
                }
                for (j, p) in kept.enumerated() {
                    XCTAssertEqual(Int(p.color), j * s, "kept[\(j)] must be input[\(j)·\(s)]")
                }
            }
        }
    }
}
