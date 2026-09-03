import XCTest
import simd
@testable import MapCore

final class UnprojectionTests: XCTestCase {

    // MARK: - Fixture
    //
    // 4×3 depth map (width 4, height 3), fx = fy = 2, cx = 2, cy = 1.5, depth 1000 mm (1 m) everywhere,
    // confidence 2 everywhere, identity pose. For pixel (u, v) at depth d the camera point is
    //   X = (u + 0.5 − 2)/2 · d = (u − 1.5)/2 · d
    //   Y = (v + 0.5 − 1.5)/2 · d = (v − 1)/2 · d
    //   camera = (X, −Y, −d)
    // Pixel index = v · 4 + u.

    private let intrinsics = Intrinsics(fx: 2, fy: 2, cx: 2, cy: 1.5, width: 4, height: 3)
    private let depth1m = [UInt16](repeating: 1000, count: 12)
    private let confHigh = [UInt8](repeating: 2, count: 12)

    /// 90° about +Y (right-hand rule): (x, y, z) → (z, y, −x).
    private let yaw90 = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))

    /// Expected camera-space point of pixel (u, v) in the fixture at depth `d` meters.
    private func expectedCameraPoint(u: Int, v: Int, d: Float = 1) -> SIMD3<Float> {
        let x = (Float(u) - 1.5) / 2 * d
        let y = (Float(v) - 1) / 2 * d
        return SIMD3<Float>(x, -y, -d)
    }

    private func record(depth: [UInt16]? = nil,
                        confidence: [UInt8]? = nil,
                        pose: Pose = .identity,
                        intrinsics: Intrinsics? = nil) -> KeyframeRecord {
        KeyframeRecord(seq: 7,
                       timestamp: 12.5,
                       pose: pose,
                       intrinsics: intrinsics ?? self.intrinsics,
                       tracking: .normal,
                       depthMillimeters: depth ?? depth1m,
                       confidence: confidence ?? confHigh)
    }

    // MARK: - Options and Result

    func testOptionsDefaults() {
        let o = Unprojector.Options()
        XCTAssertEqual(o.minConfidence, 1)
        XCTAssertEqual(o.minDepthMeters, 0.1)
        XCTAssertEqual(o.maxDepthMeters, 5.0)
        XCTAssertEqual(o.stride, 1)
        XCTAssertEqual(o, Unprojector.Options(minConfidence: 1, minDepthMeters: 0.1, maxDepthMeters: 5.0, stride: 1))
        XCTAssertNotEqual(o, Unprojector.Options(stride: 2))
    }

    func testResultDefaultsAndEquality() {
        let empty = Unprojector.Result()
        XCTAssertTrue(empty.positions.isEmpty)
        XCTAssertTrue(empty.pixelIndices.isEmpty)
        let a = Unprojector.Result(positions: [SIMD3<Float>(1, 2, 3)], pixelIndices: [5])
        let b = Unprojector.Result(positions: [SIMD3<Float>(1, 2, 3)], pixelIndices: [5])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, empty)
    }

    // MARK: - Identity pose

    func testIdentityPoseUnprojectsPixelCenters() {
        let r = Unprojector.unproject(depthMillimeters: depth1m,
                                      confidence: confHigh,
                                      intrinsics: intrinsics,
                                      pose: .identity)
        // Nothing is filtered: 4 · 3 = 12 points, one per pixel, in row-major order.
        XCTAssertEqual(r.positions.count, 12)
        XCTAssertEqual(r.pixelIndices.count, 12)
        XCTAssertEqual(r.pixelIndices, (0..<12).map(Int32.init))

        // Pixel (0,0): X = (0.5 − 2)/2 = −0.75, Y = (0.5 − 1.5)/2 = −0.5 ⇒ (−0.75, 0.5, −1).
        assertEqual(r.positions[0], SIMD3<Float>(-0.75, 0.5, -1), accuracy: 1e-6)
        // Pixel (3,0), index 3: X = (3.5 − 2)/2 = 0.75, Y = −0.5 ⇒ (0.75, 0.5, −1).
        assertEqual(r.positions[3], SIMD3<Float>(0.75, 0.5, -1), accuracy: 1e-6)
        // Pixel (1,1), index 5: X = (1.5 − 2)/2 = −0.25, Y = (1.5 − 1.5)/2 = 0 ⇒ (−0.25, 0, −1).
        assertEqual(r.positions[5], SIMD3<Float>(-0.25, 0, -1), accuracy: 1e-6)
        // Pixel (2,1), index 6: X = (2.5 − 2)/2 = 0.25 ⇒ (0.25, 0, −1).
        assertEqual(r.positions[6], SIMD3<Float>(0.25, 0, -1), accuracy: 1e-6)
        // Pixel (0,2), index 8: X = −0.75, Y = (2.5 − 1.5)/2 = 0.5 ⇒ (−0.75, −0.5, −1).
        assertEqual(r.positions[8], SIMD3<Float>(-0.75, -0.5, -1), accuracy: 1e-6)
        // Pixel (3,2), index 11: X = 0.75, Y = 0.5 ⇒ (0.75, −0.5, −1).
        assertEqual(r.positions[11], SIMD3<Float>(0.75, -0.5, -1), accuracy: 1e-6)

        // Every retained point matches the closed form and Intrinsics' own pixel-center unprojection.
        for v in 0..<3 {
            for u in 0..<4 {
                let i = v * 4 + u
                assertEqual(r.positions[i], expectedCameraPoint(u: u, v: v), accuracy: 1e-6)
                XCTAssertEqual(r.positions[i], intrinsics.unproject(pixelU: u, pixelV: v, depth: 1))
            }
        }
    }

    func testDepthScalesPoints() {
        // 2500 mm = 2.5 m everywhere. Pixel (3,2): X = 0.75·2.5 = 1.875, Y = 0.5·2.5 = 1.25
        // ⇒ (1.875, −1.25, −2.5).
        let r = Unprojector.unproject(depthMillimeters: [UInt16](repeating: 2500, count: 12),
                                      confidence: confHigh,
                                      intrinsics: intrinsics,
                                      pose: .identity)
        XCTAssertEqual(r.positions.count, 12)
        assertEqual(r.positions[11], SIMD3<Float>(1.875, -1.25, -2.5), accuracy: 1e-6)
    }

    // MARK: - Pose

    func testPoseTransformsCameraPoints() {
        let pose = Pose(translation: SIMD3<Float>(1, 2, 3), rotation: yaw90)
        let r = Unprojector.unproject(depthMillimeters: depth1m,
                                      confidence: confHigh,
                                      intrinsics: intrinsics,
                                      pose: pose)
        XCTAssertEqual(r.positions.count, 12)
        XCTAssertEqual(r.pixelIndices.count, 12)

        // Pixel (0,0): camera (−0.75, 0.5, −1). Ry(90°): (x,y,z) → (z, y, −x) = (−1, 0.5, 0.75).
        // + (1, 2, 3) = (0, 2.5, 3.75).
        assertEqual(r.positions[0], SIMD3<Float>(0, 2.5, 3.75), accuracy: 1e-5)
        // Pixel (3,2): camera (0.75, −0.5, −1) → (−1, −0.5, −0.75) + (1, 2, 3) = (0, 1.5, 2.25).
        assertEqual(r.positions[11], SIMD3<Float>(0, 1.5, 2.25), accuracy: 1e-5)
        // Pixel (1,1): camera (−0.25, 0, −1) → (−1, 0, 0.25) + (1, 2, 3) = (0, 2, 3.25).
        assertEqual(r.positions[5], SIMD3<Float>(0, 2, 3.25), accuracy: 1e-5)

        // And in general world = pose.transform(camera).
        for i in 0..<12 {
            let cam = expectedCameraPoint(u: i % 4, v: i / 4)
            assertEqual(r.positions[i], pose.transform(cam), accuracy: 1e-5)
        }
    }

    func testPureTranslationPose() {
        let pose = Pose(translation: SIMD3<Float>(10, 20, 30))
        let r = Unprojector.unproject(depthMillimeters: depth1m,
                                      confidence: confHigh,
                                      intrinsics: intrinsics,
                                      pose: pose)
        // Pixel (0,0): (−0.75, 0.5, −1) + (10, 20, 30) = (9.25, 20.5, 29).
        assertEqual(r.positions[0], SIMD3<Float>(9.25, 20.5, 29), accuracy: 1e-5)
    }

    // MARK: - Confidence filtering

    func testConfidenceFiltering() {
        // confidence[i] = i mod 3 ⇒ [0,1,2, 0,1,2, 0,1,2, 0,1,2].
        let conf = (0..<12).map { UInt8($0 % 3) }

        // minConfidence 1 keeps conf ≥ 1: indices 1,2,4,5,7,8,10,11 (8 points).
        let medium = Unprojector.unproject(depthMillimeters: depth1m,
                                           confidence: conf,
                                           intrinsics: intrinsics,
                                           pose: .identity,
                                           options: .init(minConfidence: 1))
        XCTAssertEqual(medium.pixelIndices, [1, 2, 4, 5, 7, 8, 10, 11])
        XCTAssertEqual(medium.positions.count, 8)
        // First retained pixel is (1,0): X = (1.5 − 2)/2 = −0.25, Y = −0.5 ⇒ (−0.25, 0.5, −1).
        assertEqual(medium.positions[0], SIMD3<Float>(-0.25, 0.5, -1), accuracy: 1e-6)

        // minConfidence 2 keeps conf ≥ 2: indices 2,5,8,11 (4 points).
        let high = Unprojector.unproject(depthMillimeters: depth1m,
                                         confidence: conf,
                                         intrinsics: intrinsics,
                                         pose: .identity,
                                         options: .init(minConfidence: 2))
        XCTAssertEqual(high.pixelIndices, [2, 5, 8, 11])
        XCTAssertEqual(high.positions.count, 4)
        // Index 8 is pixel (0,2): (−0.75, −0.5, −1) — the third retained point.
        assertEqual(high.positions[2], SIMD3<Float>(-0.75, -0.5, -1), accuracy: 1e-6)

        // minConfidence 0 keeps everything (12 points).
        let all = Unprojector.unproject(depthMillimeters: depth1m,
                                        confidence: conf,
                                        intrinsics: intrinsics,
                                        pose: .identity,
                                        options: .init(minConfidence: 0))
        XCTAssertEqual(all.positions.count, 12)

        // The default options use minConfidence 1.
        let defaults = Unprojector.unproject(depthMillimeters: depth1m,
                                             confidence: conf,
                                             intrinsics: intrinsics,
                                             pose: .identity)
        XCTAssertEqual(defaults.pixelIndices, medium.pixelIndices)
    }

    // MARK: - Depth range filtering

    func testDepthRangeFiltering() {
        // depth[i] = 500 · (i + 1) mm ⇒ 0.5, 1.0, 1.5, …, 6.0 m.
        let depth = (0..<12).map { UInt16(500 * ($0 + 1)) }

        // Defaults [0.1, 5.0]: keep 0.5…5.0 m ⇒ i + 1 ≤ 10 ⇒ indices 0…9 (10 points); 5.5 and 6.0 dropped.
        let defaults = Unprojector.unproject(depthMillimeters: depth,
                                             confidence: confHigh,
                                             intrinsics: intrinsics,
                                             pose: .identity)
        XCTAssertEqual(defaults.pixelIndices, (0..<10).map(Int32.init))
        XCTAssertEqual(defaults.positions.count, 10)

        // [1.0, 2.0] inclusive: 1.0 (i=1), 1.5 (i=2), 2.0 (i=3) ⇒ indices [1, 2, 3].
        let band = Unprojector.unproject(depthMillimeters: depth,
                                         confidence: confHigh,
                                         intrinsics: intrinsics,
                                         pose: .identity,
                                         options: .init(minDepthMeters: 1.0, maxDepthMeters: 2.0))
        XCTAssertEqual(band.pixelIndices, [1, 2, 3])
        // Index 3 = pixel (3,0) at d = 2: X = (3.5 − 2)/2 · 2 = 1.5, Y = (0.5 − 1.5)/2 · 2 = −1
        // ⇒ (1.5, 1, −2).
        assertEqual(band.positions[2], SIMD3<Float>(1.5, 1, -2), accuracy: 1e-6)

        // minDepth above everything ⇒ nothing.
        let none = Unprojector.unproject(depthMillimeters: depth,
                                         confidence: confHigh,
                                         intrinsics: intrinsics,
                                         pose: .identity,
                                         options: .init(minDepthMeters: 6.5))
        XCTAssertTrue(none.positions.isEmpty)
        XCTAssertTrue(none.pixelIndices.isEmpty)

        // Wide range keeps all 12, including 65535 mm = 65.535 m when maxDepth allows it.
        var far = depth
        far[11] = 65535
        let wide = Unprojector.unproject(depthMillimeters: far,
                                         confidence: confHigh,
                                         intrinsics: intrinsics,
                                         pose: .identity,
                                         options: .init(minDepthMeters: 0, maxDepthMeters: 100))
        XCTAssertEqual(wide.positions.count, 12)
        // Pixel (3,2) at 65.535 m: X = 0.75·65.535 = 49.15125, Y = 0.5·65.535 = 32.7675
        // ⇒ (49.15125, −32.7675, −65.535).
        assertEqual(wide.positions[11], SIMD3<Float>(49.15125, -32.7675, -65.535), accuracy: 1e-3)
        // With the default maxDepth (5 m) that far pixel is dropped: 0.5…5.0 m keeps indices 0…9 only.
        let clipped = Unprojector.unproject(depthMillimeters: far,
                                            confidence: confHigh,
                                            intrinsics: intrinsics,
                                            pose: .identity)
        XCTAssertEqual(clipped.pixelIndices, (0..<10).map(Int32.init))
    }

    func testZeroDepthIsSkippedEvenWithZeroMinDepth() {
        var depth = depth1m
        depth[5] = 0
        depth[0] = 0
        let r = Unprojector.unproject(depthMillimeters: depth,
                                      confidence: confHigh,
                                      intrinsics: intrinsics,
                                      pose: .identity,
                                      options: .init(minDepthMeters: 0))
        // 12 − 2 zero pixels = 10 points; indices 0 and 5 absent.
        XCTAssertEqual(r.positions.count, 10)
        XCTAssertEqual(r.pixelIndices, [1, 2, 3, 4, 6, 7, 8, 9, 10, 11])
        // First retained is pixel (1,0): (−0.25, 0.5, −1).
        assertEqual(r.positions[0], SIMD3<Float>(-0.25, 0.5, -1), accuracy: 1e-6)
    }

    func testAllZeroDepthYieldsEmpty() {
        let r = Unprojector.unproject(depthMillimeters: [UInt16](repeating: 0, count: 12),
                                      confidence: confHigh,
                                      intrinsics: intrinsics,
                                      pose: .identity)
        XCTAssertTrue(r.positions.isEmpty)
        XCTAssertTrue(r.pixelIndices.isEmpty)
    }

    // MARK: - Stride

    func testStrideTwo() {
        let r = Unprojector.unproject(depthMillimeters: depth1m,
                                      confidence: confHigh,
                                      intrinsics: intrinsics,
                                      pose: .identity,
                                      options: .init(stride: 2))
        // v ∈ {0, 2}, u ∈ {0, 2} ⇒ pixels (0,0), (2,0), (0,2), (2,2) ⇒ indices 0, 2, 8, 10.
        XCTAssertEqual(r.pixelIndices, [0, 2, 8, 10])
        XCTAssertEqual(r.positions.count, 4)
        // (0,0): (−0.75, 0.5, −1)
        assertEqual(r.positions[0], SIMD3<Float>(-0.75, 0.5, -1), accuracy: 1e-6)
        // (2,0): X = (2.5 − 2)/2 = 0.25, Y = −0.5 ⇒ (0.25, 0.5, −1)
        assertEqual(r.positions[1], SIMD3<Float>(0.25, 0.5, -1), accuracy: 1e-6)
        // (0,2): X = −0.75, Y = 0.5 ⇒ (−0.75, −0.5, −1)
        assertEqual(r.positions[2], SIMD3<Float>(-0.75, -0.5, -1), accuracy: 1e-6)
        // (2,2): (0.25, −0.5, −1)
        assertEqual(r.positions[3], SIMD3<Float>(0.25, -0.5, -1), accuracy: 1e-6)
    }

    func testStrideThreeAndLargerThanImage() {
        // stride 3: v ∈ {0}, u ∈ {0, 3} ⇒ indices [0, 3].
        let three = Unprojector.unproject(depthMillimeters: depth1m,
                                          confidence: confHigh,
                                          intrinsics: intrinsics,
                                          pose: .identity,
                                          options: .init(stride: 3))
        XCTAssertEqual(three.pixelIndices, [0, 3])
        // stride 10 exceeds both dimensions: only pixel (0,0).
        let ten = Unprojector.unproject(depthMillimeters: depth1m,
                                        confidence: confHigh,
                                        intrinsics: intrinsics,
                                        pose: .identity,
                                        options: .init(stride: 10))
        XCTAssertEqual(ten.pixelIndices, [0])
        assertEqual(ten.positions[0], SIMD3<Float>(-0.75, 0.5, -1), accuracy: 1e-6)
    }

    func testNonPositiveStrideBehavesAsOne() {
        let zero = Unprojector.unproject(depthMillimeters: depth1m,
                                         confidence: confHigh,
                                         intrinsics: intrinsics,
                                         pose: .identity,
                                         options: .init(stride: 0))
        XCTAssertEqual(zero.pixelIndices, (0..<12).map(Int32.init))
        let negative = Unprojector.unproject(depthMillimeters: depth1m,
                                             confidence: confHigh,
                                             intrinsics: intrinsics,
                                             pose: .identity,
                                             options: .init(stride: -4))
        XCTAssertEqual(negative.pixelIndices, (0..<12).map(Int32.init))
    }

    func testStrideCombinesWithFiltering() {
        // stride 2 visits indices 0, 2, 8, 10; confidence i mod 3 = [0,2,2,1] at those ⇒ with
        // minConfidence 1 keep 2, 8, 10; with minConfidence 2 keep 2, 8.
        let conf = (0..<12).map { UInt8($0 % 3) }
        let medium = Unprojector.unproject(depthMillimeters: depth1m,
                                           confidence: conf,
                                           intrinsics: intrinsics,
                                           pose: .identity,
                                           options: .init(minConfidence: 1, stride: 2))
        XCTAssertEqual(medium.pixelIndices, [2, 8, 10])
        let high = Unprojector.unproject(depthMillimeters: depth1m,
                                         confidence: conf,
                                         intrinsics: intrinsics,
                                         pose: .identity,
                                         options: .init(minConfidence: 2, stride: 2))
        XCTAssertEqual(high.pixelIndices, [2, 8])
    }

    // MARK: - Malformed input

    func testSizeMismatchReturnsEmpty() {
        // Depth one element short.
        let shortDepth = Unprojector.unproject(depthMillimeters: [UInt16](repeating: 1000, count: 11),
                                               confidence: confHigh,
                                               intrinsics: intrinsics,
                                               pose: .identity)
        XCTAssertTrue(shortDepth.positions.isEmpty)
        XCTAssertTrue(shortDepth.pixelIndices.isEmpty)

        // Confidence one element long.
        let longConf = Unprojector.unproject(depthMillimeters: depth1m,
                                             confidence: [UInt8](repeating: 2, count: 13),
                                             intrinsics: intrinsics,
                                             pose: .identity)
        XCTAssertTrue(longConf.positions.isEmpty)
        XCTAssertTrue(longConf.pixelIndices.isEmpty)

        // Both empty against a 4×3 image.
        let empty = Unprojector.unproject(depthMillimeters: [],
                                          confidence: [],
                                          intrinsics: intrinsics,
                                          pose: .identity)
        XCTAssertEqual(empty, Unprojector.Result())

        // Zero-sized image with empty arrays is consistent but has nothing to unproject.
        let zeroImage = Unprojector.unproject(depthMillimeters: [],
                                              confidence: [],
                                              intrinsics: Intrinsics(fx: 1, fy: 1, cx: 0, cy: 0, width: 0, height: 0),
                                              pose: .identity)
        XCTAssertEqual(zeroImage, Unprojector.Result())
    }

    // MARK: - Record-based API

    func testUnprojectRecordMatchesArrayForm() {
        let pose = Pose(translation: SIMD3<Float>(1, 2, 3), rotation: yaw90)
        let conf = (0..<12).map { UInt8($0 % 3) }
        let rec = record(confidence: conf, pose: pose)
        let options = Unprojector.Options(minConfidence: 2)
        let fromRecord = Unprojector.unproject(record: rec, options: options)
        let fromArrays = Unprojector.unproject(depthMillimeters: rec.depthMillimeters,
                                               confidence: rec.confidence,
                                               intrinsics: rec.intrinsics,
                                               pose: rec.pose,
                                               options: options)
        XCTAssertEqual(fromRecord, fromArrays)
        XCTAssertEqual(fromRecord.pixelIndices, [2, 5, 8, 11])
        // Index 2 = pixel (2,0): camera X = 0.25, Y = −0.5 ⇒ (0.25, 0.5, −1);
        // Ry(90°) → (−1, 0.5, −0.25); + (1,2,3) = (0, 2.5, 2.75).
        assertEqual(fromRecord.positions[0], SIMD3<Float>(0, 2.5, 2.75), accuracy: 1e-5)
    }

    func testUnprojectRecordDefaultOptions() {
        let r = Unprojector.unproject(record: record())
        XCTAssertEqual(r.positions.count, 12)
        XCTAssertEqual(r.pixelIndices, (0..<12).map(Int32.init))
    }

    func testUnprojectInconsistentRecordReturnsEmpty() {
        let rec = record(depth: [UInt16](repeating: 1000, count: 5))
        XCTAssertFalse(rec.isConsistent)
        XCTAssertEqual(Unprojector.unproject(record: rec), Unprojector.Result())
        XCTAssertTrue(Unprojector.unprojectPacked(record: rec) { UInt32($0) }.isEmpty)
    }

    // MARK: - Packed points

    func testUnprojectPackedMapsColorByPixelIndex() {
        let rec = record()
        let packed = Unprojector.unprojectPacked(record: rec) { UInt32($0) }
        let reference = Unprojector.unproject(record: rec)
        XCTAssertEqual(packed.count, 12)
        // Colors are the pixel indices 0…11 and positions equal the unpacked result.
        XCTAssertEqual(packed.map(\.color), (0..<12).map(UInt32.init))
        for i in 0..<12 {
            XCTAssertEqual(packed[i].position, reference.positions[i], "point \(i)")
            XCTAssertEqual(packed[i].color, UInt32(reference.pixelIndices[i]), "point \(i)")
        }
        // Pixel (3,2) again: (0.75, −0.5, −1) with color 11.
        XCTAssertEqual(packed[11], PackedPoint(x: 0.75, y: -0.5, z: -1, color: 11))
    }

    func testUnprojectPackedUsesPixelIndexNotOutputIndex() {
        // With minConfidence 2 and conf = i mod 3 only pixels 2, 5, 8, 11 survive, so the closure must
        // receive those indices (not 0, 1, 2, 3).
        let conf = (0..<12).map { UInt8($0 % 3) }
        let rec = record(confidence: conf)
        let packed = Unprojector.unprojectPacked(record: rec, options: .init(minConfidence: 2)) { UInt32($0) }
        XCTAssertEqual(packed.map(\.color), [2, 5, 8, 11])
        // Pixel 8 = (0,2): (−0.75, −0.5, −1).
        assertEqual(packed[2].position, SIMD3<Float>(-0.75, -0.5, -1), accuracy: 1e-6)

        // Stride 2 visits 0, 2, 8, 10.
        let strided = Unprojector.unprojectPacked(record: record(), options: .init(stride: 2)) { UInt32($0) }
        XCTAssertEqual(strided.map(\.color), [0, 2, 8, 10])
    }

    func testUnprojectPackedAppliesPoseAndArbitraryColor() {
        let pose = Pose(translation: SIMD3<Float>(1, 2, 3), rotation: yaw90)
        let rec = record(pose: pose)
        let packed = Unprojector.unprojectPacked(record: rec) { index in
            // Encode the index in the red channel and use full alpha.
            PackedPoint.packColor(r: UInt8(index), g: 0, b: 0, a: 255)
        }
        XCTAssertEqual(packed.count, 12)
        // Pixel (0,0) → world (0, 2.5, 3.75) (see pose test); r = 0, a = 255.
        assertEqual(packed[0].position, SIMD3<Float>(0, 2.5, 3.75), accuracy: 1e-5)
        XCTAssertEqual(packed[0].r, 0)
        XCTAssertEqual(packed[0].a, 255)
        // Pixel (3,2) → (0, 1.5, 2.25); r = 11 ⇒ color = 11 | 255 << 24 = 0xFF00000B.
        assertEqual(packed[11].position, SIMD3<Float>(0, 1.5, 2.25), accuracy: 1e-5)
        XCTAssertEqual(packed[11].color, 0xFF00_000B)
    }

    // MARK: - Full-size depth map

    func testFullSizeDepthMap() {
        // 256×192 with the depth-map intrinsics from the Intrinsics tests: fx = fy = 133.333…, cx = 128, cy = 96.
        let full = Intrinsics(fx: 1000, fy: 1000, cx: 960, cy: 720, width: 1920, height: 1440)
            .scaled(toWidth: 256, height: 192)
        let count = full.pixelCount
        XCTAssertEqual(count, 49_152)
        let depth = [UInt16](repeating: 1000, count: count)
        let conf = [UInt8](repeating: 2, count: count)
        let r = Unprojector.unproject(depthMillimeters: depth, confidence: conf, intrinsics: full, pose: .identity)
        XCTAssertEqual(r.positions.count, 49_152)
        XCTAssertEqual(r.pixelIndices.count, 49_152)

        // Pixel (128, 96), index 96·256 + 128 = 24 704:
        //   X = (128.5 − 128)/133.333 · 1 = 0.00375, Y = (96.5 − 96)/133.333 = 0.00375 ⇒ (0.00375, −0.00375, −1).
        XCTAssertEqual(r.pixelIndices[24_704], 24_704)
        assertEqual(r.positions[24_704], SIMD3<Float>(0.00375, -0.00375, -1), accuracy: 1e-6)
        // Last pixel (255, 191), index 49 151:
        //   X = (255.5 − 128)/133.333 = 0.95625, Y = (191.5 − 96)/133.333 = 0.71625 ⇒ (0.95625, −0.71625, −1).
        XCTAssertEqual(r.pixelIndices[49_151], 49_151)
        assertEqual(r.positions[49_151], SIMD3<Float>(0.95625, -0.71625, -1), accuracy: 1e-5)

        // stride 4 ⇒ 64 · 48 = 3072 points.
        let strided = Unprojector.unproject(depthMillimeters: depth,
                                            confidence: conf,
                                            intrinsics: full,
                                            pose: .identity,
                                            options: .init(stride: 4))
        XCTAssertEqual(strided.positions.count, 3072)
        // Second point is pixel (4, 0), index 4; the 65th point is pixel (0, 4), index 4·256 = 1024.
        XCTAssertEqual(strided.pixelIndices[1], 4)
        XCTAssertEqual(strided.pixelIndices[64], 1024)
    }
}

// MARK: - File-private assertions

private func assertEqual(_ actual: SIMD3<Float>,
                         _ expected: SIMD3<Float>,
                         accuracy: Float,
                         file: StaticString = #filePath,
                         line: UInt = #line) {
    XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, "x of \(actual) vs \(expected)", file: file, line: line)
    XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, "y of \(actual) vs \(expected)", file: file, line: line)
    XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, "z of \(actual) vs \(expected)", file: file, line: line)
}
