import XCTest
import simd
@testable import MapCore

final class PoseTests: XCTestCase {

    // MARK: - Helpers

    /// 90° about +Y (right-hand rule): (x, y, z) → (z, y, −x).
    private let yaw90 = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
    /// 90° about +Z (right-hand rule): (x, y, z) → (−y, x, z).
    private let roll90 = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))

    // MARK: - Basis vectors

    func testIdentityBasisVectors() {
        let p = Pose.identity
        // Identity matrix columns: c0 = (1,0,0), c1 = (0,1,0), c2 = (0,0,1).
        // right = c0 = (1,0,0); up = c1 = (0,1,0); forward = −c2 = (0,0,−1).
        XCTAssertEqual(p.right, SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(p.up, SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(p.forward, SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(p.translation, SIMD3<Float>(0, 0, 0))
    }

    func testInitTranslationRotationColumns() {
        let t = SIMD3<Float>(1, 2, 3)
        let p = Pose(translation: t, rotation: yaw90)
        // Ry(90°) rows: [0 0 1; 0 1 0; −1 0 0]. Columns are the rotated basis vectors:
        //   c0 = R·(1,0,0) = (0, 0, −1)
        //   c1 = R·(0,1,0) = (0, 1, 0)
        //   c2 = R·(0,0,1) = (1, 0, 0)
        //   c3 = (1, 2, 3, 1)
        assertEqual(p.right, SIMD3<Float>(0, 0, -1), accuracy: 1e-6)
        assertEqual(p.up, SIMD3<Float>(0, 1, 0), accuracy: 1e-6)
        // forward = −c2 = (−1, 0, 0): the camera's −Z axis rotated 90° about Y points along −X.
        assertEqual(p.forward, SIMD3<Float>(-1, 0, 0), accuracy: 1e-6)
        XCTAssertEqual(p.translation, t)
        XCTAssertEqual(p.matrix.columns.3, SIMD4<Float>(1, 2, 3, 1))
        // Bottom row of a rigid transform is (0, 0, 0, 1).
        XCTAssertEqual(p.matrix.columns.0.w, 0)
        XCTAssertEqual(p.matrix.columns.1.w, 0)
        XCTAssertEqual(p.matrix.columns.2.w, 0)
    }

    func testInitTranslationOnlyIsPureTranslation() {
        let p = Pose(translation: SIMD3<Float>(4, 5, 6))
        // Rotation part is identity, so column-major entries are
        // [1,0,0,0, 0,1,0,0, 0,0,1,0, 4,5,6,1].
        XCTAssertEqual(p.columnMajorArray, [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 4, 5, 6, 1])
        XCTAssertEqual(p.forward, SIMD3<Float>(0, 0, -1))
    }

    func testTranslationSetter() {
        var p = Pose(translation: SIMD3<Float>(1, 1, 1), rotation: yaw90)
        p.translation = SIMD3<Float>(7, 8, 9)
        XCTAssertEqual(p.translation, SIMD3<Float>(7, 8, 9))
        XCTAssertEqual(p.matrix.columns.3.w, 1)
        // Rotation columns are untouched: right is still R·(1,0,0) = (0,0,−1).
        assertEqual(p.right, SIMD3<Float>(0, 0, -1), accuracy: 1e-6)
    }

    // MARK: - Distances and angles

    func testTranslationDistance() {
        let a = Pose(translation: SIMD3<Float>(0, 0, 0))
        let b = Pose(translation: SIMD3<Float>(3, 4, 0))
        // sqrt(3² + 4² + 0²) = sqrt(25) = 5.
        XCTAssertEqual(a.translationDistance(to: b), 5, accuracy: 1e-6)
        XCTAssertEqual(b.translationDistance(to: a), 5, accuracy: 1e-6)
        XCTAssertEqual(a.translationDistance(to: a), 0)
    }

    func testRotationAngleNinetyDegreesAboutY() {
        let a = Pose.identity
        let b = Pose(translation: .zero, rotation: yaw90)
        // relative = q(90° about Y): real part w = cos(45°) = 0.70711.
        // angle = 2·acos(0.70711) = 2·(π/4) = π/2.
        XCTAssertEqual(a.rotationAngle(to: b), .pi / 2, accuracy: 1e-6)
        // Symmetric: the inverse relative rotation has the same real part.
        XCTAssertEqual(b.rotationAngle(to: a), .pi / 2, accuracy: 1e-6)
        // π/2 rad · 180/π = 90°.
        XCTAssertEqual(a.rotationAngleDegrees(to: b), 90, accuracy: 1e-4)
    }

    func testRotationAngleTwelveDegrees() {
        let a = Pose(translation: SIMD3<Float>(1, 2, 3))
        let q = simd_quatf(angle: 12 * .pi / 180, axis: simd_normalize(SIMD3<Float>(1, 1, 0)))
        let b = Pose(translation: SIMD3<Float>(9, 9, 9), rotation: q)
        // Translation does not affect the rotation angle. w = cos(6°) = 0.994522,
        // 2·acos(0.994522) = 2·6° = 12° = 0.209440 rad.
        XCTAssertEqual(a.rotationAngleDegrees(to: b), 12, accuracy: 1e-3)
        XCTAssertEqual(a.rotationAngle(to: b), 12 * .pi / 180, accuracy: 1e-5)
    }

    func testRotationAngleOneEightyDegreesIsPi() {
        let a = Pose.identity
        let b = Pose(translation: .zero, rotation: simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
        // w = cos(90°) = 0 (≈ −4.4e−8 in Float). abs → 0, min(1, 0) = 0, 2·acos(0) = π.
        XCTAssertEqual(a.rotationAngle(to: b), .pi, accuracy: 1e-5)
        XCTAssertEqual(a.rotationAngleDegrees(to: b), 180, accuracy: 1e-3)
        XCTAssertFalse(a.rotationAngle(to: b).isNaN)
    }

    func testRotationAngleToSelfIsZeroAndNeverNaN() {
        // Non-trivial rotation so that q⁻¹·q is only ≈ (1, 0, 0, 0) up to Float rounding: without
        // the min(1, |w|) clamp a real part of 1.0000001 would make acos return NaN.
        let q = simd_quatf(angle: 0.6435, axis: simd_normalize(SIMD3<Float>(0.3, -0.7, 0.2)))
        let a = Pose(translation: SIMD3<Float>(1, 2, 3), rotation: q)
        let angle = a.rotationAngle(to: a)
        XCTAssertFalse(angle.isNaN)
        // Ideally 2·acos(1) = 0, but acos is steep at 1: a real part one Float ulp low
        // (1 − 6e−8) gives 2·acos(1 − 6e−8) ≈ 2·sqrt(2·6e−8) ≈ 6.9e−4 rad, so allow 1e−3.
        XCTAssertEqual(angle, 0, accuracy: 1e-3)
    }

    func testRotationAngleUsesShortestArc() {
        // 270° about Y is the same rotation as −90° about Y; the smallest angle is 90°.
        // w = cos(135°) = −0.70711; abs → 0.70711; 2·acos(0.70711) = π/2.
        let a = Pose.identity
        let b = Pose(translation: .zero, rotation: simd_quatf(angle: 3 * .pi / 2, axis: SIMD3<Float>(0, 1, 0)))
        XCTAssertEqual(a.rotationAngle(to: b), .pi / 2, accuracy: 1e-5)
    }

    // MARK: - Composition, transform, rotate, inverse

    func testCompositionMatchesSequentialTransform() {
        // T2: rotate 90° about Z then translate (1, 0, 0).  T1: rotate 90° about Y then translate (0, 0, 5).
        let t1 = Pose(translation: SIMD3<Float>(0, 0, 5), rotation: yaw90)
        let t2 = Pose(translation: SIMD3<Float>(1, 0, 0), rotation: roll90)
        let p = SIMD3<Float>(1, 2, 3)

        // T2·p: Rz(90°)·(1,2,3) = (−2, 1, 3); + (1,0,0) = (−1, 1, 3).
        let q = t2.transform(p)
        assertEqual(q, SIMD3<Float>(-1, 1, 3), accuracy: 1e-5)

        // T1·q: Ry(90°)·(−1,1,3) = (3, 1, 1); + (0,0,5) = (3, 1, 6).
        let expected = SIMD3<Float>(3, 1, 6)
        assertEqual(t1.transform(q), expected, accuracy: 1e-5)
        assertEqual((t1 * t2).transform(p), expected, accuracy: 1e-5)
        assertEqual((t1 * t2).transform(p), t1.transform(t2.transform(p)), accuracy: 1e-5)

        // Composition is not commutative: (T2·T1)·p = T2·(T1·p).
        // T1·p = Ry·(1,2,3) + (0,0,5) = (3, 2, −1) + (0,0,5) = (3, 2, 4).
        // T2·(3,2,4) = Rz·(3,2,4) + (1,0,0) = (−2, 3, 4) + (1,0,0) = (−1, 3, 4).
        assertEqual((t2 * t1).transform(p), SIMD3<Float>(-1, 3, 4), accuracy: 1e-5)
    }

    func testIdentityIsCompositionNeutral() {
        let t = Pose(translation: SIMD3<Float>(1, 2, 3), rotation: yaw90)
        XCTAssertTrue((Pose.identity * t).isApproximatelyEqual(to: t))
        XCTAssertTrue((t * Pose.identity).isApproximatelyEqual(to: t))
    }

    func testRotateIgnoresTranslation() {
        let t = Pose(translation: SIMD3<Float>(1, 2, 3), rotation: yaw90)
        // Ry(90°)·(1,0,0) = (0, 0, −1); no translation is added.
        assertEqual(t.rotate(SIMD3<Float>(1, 0, 0)), SIMD3<Float>(0, 0, -1), accuracy: 1e-6)
        // transform of the same vector adds the translation: (0,0,−1) + (1,2,3) = (1, 2, 2).
        assertEqual(t.transform(SIMD3<Float>(1, 0, 0)), SIMD3<Float>(1, 2, 2), accuracy: 1e-6)
    }

    func testRotationMatrixAndQuaternionRoundTrip() {
        let t = Pose(translation: SIMD3<Float>(1, 2, 3), rotation: yaw90)
        let r = t.rotationMatrix
        // Columns of Ry(90°): (0,0,−1), (0,1,0), (1,0,0).
        assertEqual(r.columns.0, SIMD3<Float>(0, 0, -1), accuracy: 1e-6)
        assertEqual(r.columns.1, SIMD3<Float>(0, 1, 0), accuracy: 1e-6)
        assertEqual(r.columns.2, SIMD3<Float>(1, 0, 0), accuracy: 1e-6)
        // The recovered quaternion rotates (1,0,0) the same way: → (0, 0, −1).
        assertEqual(t.rotation.act(SIMD3<Float>(1, 0, 0)), SIMD3<Float>(0, 0, -1), accuracy: 1e-6)
        // Rebuilding from the recovered quaternion gives the same pose.
        XCTAssertTrue(Pose(translation: t.translation, rotation: t.rotation).isApproximatelyEqual(to: t))
    }

    func testInverseRoundTrip() {
        let t = Pose(translation: SIMD3<Float>(0, 0, 5), rotation: yaw90)
        let inv = t.inverse
        // Inverse of [R | t] is [Rᵀ | −Rᵀt]. Rᵀ = Ry(−90°): (x,y,z) → (−z, y, x).
        // Rᵀ·(0,0,5) = (−5, 0, 0), so the inverse translation is (5, 0, 0).
        assertEqual(inv.translation, SIMD3<Float>(5, 0, 0), accuracy: 1e-5)
        // Inverse rotation columns: Rᵀ·(1,0,0) = (0,0,1), Rᵀ·(0,1,0) = (0,1,0), Rᵀ·(0,0,1) = (−1,0,0).
        assertEqual(inv.right, SIMD3<Float>(0, 0, 1), accuracy: 1e-5)
        assertEqual(inv.up, SIMD3<Float>(0, 1, 0), accuracy: 1e-5)
        assertEqual(inv.forward, SIMD3<Float>(1, 0, 0), accuracy: 1e-5)

        // Round trips: T⁻¹·(T·p) = p, and T⁻¹·T = I.
        let p = SIMD3<Float>(-1, 1, 3)
        // T·p = (3, 1, 6) (see composition test); T⁻¹·(3,1,6) = Rᵀ·(3,1,6) + (5,0,0) = (−6,1,3) + (5,0,0) = (−1,1,3).
        assertEqual(t.transform(p), SIMD3<Float>(3, 1, 6), accuracy: 1e-5)
        assertEqual(inv.transform(t.transform(p)), p, accuracy: 1e-5)
        assertEqual(t.transform(inv.transform(p)), p, accuracy: 1e-5)
        XCTAssertTrue((inv * t).isApproximatelyEqual(to: .identity, tolerance: 1e-5))
        XCTAssertTrue((t * inv).isApproximatelyEqual(to: .identity, tolerance: 1e-5))
        XCTAssertTrue(inv.inverse.isApproximatelyEqual(to: t, tolerance: 1e-5))
    }

    func testPureTranslationInverse() {
        let t = Pose(translation: SIMD3<Float>(1, 2, 3))
        // Inverse of a pure translation negates it: (−1, −2, −3).
        assertEqual(t.inverse.translation, SIMD3<Float>(-1, -2, -3), accuracy: 1e-6)
        XCTAssertEqual(t.inverse.forward, SIMD3<Float>(0, 0, -1))
    }

    // MARK: - Column-major array

    func testColumnMajorArrayRoundTrip() {
        let t = Pose(translation: SIMD3<Float>(1, 2, 3), rotation: yaw90)
        let a = t.columnMajorArray
        XCTAssertEqual(a.count, 16)
        // Column-major layout of [Ry(90°) | (1,2,3)]:
        //   c0 = (0, 0, −1, 0), c1 = (0, 1, 0, 0), c2 = (1, 0, 0, 0), c3 = (1, 2, 3, 1).
        let expected: [Float] = [0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 2, 3, 1]
        for i in 0..<16 {
            XCTAssertEqual(a[i], expected[i], accuracy: 1e-6, "entry \(i)")
        }
        // Translation lives at indices 12, 13, 14 (column 3).
        XCTAssertEqual(a[12], 1)
        XCTAssertEqual(a[13], 2)
        XCTAssertEqual(a[14], 3)
        XCTAssertEqual(a[15], 1)

        guard let rebuilt = Pose(columnMajorArray: a) else {
            return XCTFail("16 floats must produce a pose")
        }
        XCTAssertEqual(rebuilt, t)
        XCTAssertEqual(rebuilt.columnMajorArray, a)
    }

    func testColumnMajorArrayInitPlacesValuesByColumn() {
        // Entries 0…15 in column-major order: column k holds entries 4k…4k+3.
        let values: [Float] = (0..<16).map(Float.init)
        guard let p = Pose(columnMajorArray: values) else {
            return XCTFail("16 floats must produce a pose")
        }
        XCTAssertEqual(p.matrix.columns.0, SIMD4<Float>(0, 1, 2, 3))
        XCTAssertEqual(p.matrix.columns.1, SIMD4<Float>(4, 5, 6, 7))
        XCTAssertEqual(p.matrix.columns.2, SIMD4<Float>(8, 9, 10, 11))
        XCTAssertEqual(p.matrix.columns.3, SIMD4<Float>(12, 13, 14, 15))
        XCTAssertEqual(p.translation, SIMD3<Float>(12, 13, 14))
        XCTAssertEqual(p.columnMajorArray, values)
    }

    func testColumnMajorArrayInitRejectsWrongCount() {
        XCTAssertNil(Pose(columnMajorArray: []))
        XCTAssertNil(Pose(columnMajorArray: [Float](repeating: 0, count: 15)))
        XCTAssertNil(Pose(columnMajorArray: [Float](repeating: 0, count: 17)))
        XCTAssertNil(Pose(columnMajorArray: [Float](repeating: 0, count: 12)))
        XCTAssertNotNil(Pose(columnMajorArray: [Float](repeating: 0, count: 16)))
    }

    // MARK: - Equality

    func testEquatableAndApproximateEquality() {
        let a = Pose(translation: SIMD3<Float>(1, 2, 3), rotation: yaw90)
        let b = Pose(translation: SIMD3<Float>(1, 2, 3), rotation: yaw90)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, Pose.identity)

        // Perturb one entry by 5e−6: inside a 1e−5 tolerance, outside 1e−6.
        var c = a
        c.matrix.columns.3.x += 5e-6
        XCTAssertNotEqual(a, c)
        XCTAssertTrue(a.isApproximatelyEqual(to: c, tolerance: 1e-5))
        XCTAssertFalse(a.isApproximatelyEqual(to: c, tolerance: 1e-6))
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
