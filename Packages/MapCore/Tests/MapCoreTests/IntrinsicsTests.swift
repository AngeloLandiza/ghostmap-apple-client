import XCTest
import simd
@testable import MapCore

final class IntrinsicsTests: XCTestCase {

    /// Full-resolution intrinsics as ARKit would report them for a 1920×1440 video format.
    private let fullRes = Intrinsics(fx: 1000, fy: 1000, cx: 960, cy: 720, width: 1920, height: 1440)

    /// Tiny 4×3 camera used by the unprojection tests: principal point at the image center.
    private let tiny = Intrinsics(fx: 2, fy: 2, cx: 2, cy: 1.5, width: 4, height: 3)

    // MARK: - Init and pixel count

    func testInitStoresFields() {
        XCTAssertEqual(fullRes.fx, 1000)
        XCTAssertEqual(fullRes.fy, 1000)
        XCTAssertEqual(fullRes.cx, 960)
        XCTAssertEqual(fullRes.cy, 720)
        XCTAssertEqual(fullRes.width, 1920)
        XCTAssertEqual(fullRes.height, 1440)
    }

    func testPixelCount() {
        // 1920 · 1440 = 2 764 800.
        XCTAssertEqual(fullRes.pixelCount, 2_764_800)
        // 4 · 3 = 12.
        XCTAssertEqual(tiny.pixelCount, 12)
        // 256 · 192 = 49 152 (the LiDAR depth map).
        XCTAssertEqual(fullRes.scaled(toWidth: 256, height: 192).pixelCount, 49_152)
        // A zero-sized image has no pixels.
        XCTAssertEqual(Intrinsics(fx: 1, fy: 1, cx: 0, cy: 0, width: 0, height: 0).pixelCount, 0)
    }

    // MARK: - Scaling

    func testScaledToDepthMapResolution() {
        let s = fullRes.scaled(toWidth: 256, height: 192)
        // sx = 256 / 1920 = 0.13333…, sy = 192 / 1440 = 0.13333…
        // fx = 1000 · 0.13333… = 133.333…, fy = 133.333…
        // cx = 960 · 0.13333… = 128, cy = 720 · 0.13333… = 96.
        XCTAssertEqual(s.fx, 133.3333, accuracy: 1e-3)
        XCTAssertEqual(s.fy, 133.3333, accuracy: 1e-3)
        XCTAssertEqual(s.cx, 128, accuracy: 1e-4)
        XCTAssertEqual(s.cy, 96, accuracy: 1e-4)
        XCTAssertEqual(s.width, 256)
        XCTAssertEqual(s.height, 192)
    }

    func testScaledToSameSizeIsIdentity() {
        // sx = sy = 1, so every field is unchanged.
        XCTAssertEqual(fullRes.scaled(toWidth: 1920, height: 1440), fullRes)
    }

    func testScaledNonUniform() {
        // Doubling the width only: sx = 8 / 4 = 2, sy = 3 / 3 = 1.
        // fx = 2·2 = 4, fy = 2·1 = 2, cx = 2·2 = 4, cy = 1.5·1 = 1.5.
        let s = tiny.scaled(toWidth: 8, height: 3)
        XCTAssertEqual(s, Intrinsics(fx: 4, fy: 2, cx: 4, cy: 1.5, width: 8, height: 3))
    }

    // MARK: - Unprojection

    func testUnprojectPrincipalPointLiesOnOpticalAxis() {
        // u = cx, v = cy ⇒ x = 0/fx·d = 0, y = 0/fy·d = 0 ⇒ (0, −0, −2).
        let p = fullRes.unproject(u: fullRes.cx, v: fullRes.cy, depth: 2)
        XCTAssertEqual(p, SIMD3<Float>(0, 0, -2))
    }

    func testUnprojectOneFocalLengthOffAxis() {
        // u = cx + fx ⇒ x = (fx / fx)·1 = 1.  v = cy − fy ⇒ y = (−fy / fy)·1 = −1.
        // Returned as (x, −y, −depth) = (1, 1, −1): one pixel-row above the center is +y (up).
        let p = fullRes.unproject(u: fullRes.cx + fullRes.fx, v: fullRes.cy - fullRes.fy, depth: 1)
        XCTAssertEqual(p.x, 1, accuracy: 1e-6)
        XCTAssertEqual(p.y, 1, accuracy: 1e-6)
        XCTAssertEqual(p.z, -1, accuracy: 1e-6)
    }

    func testUnprojectScalesWithDepth() {
        // u = 1460, v = 220, d = 2: x = (1460 − 960)/1000 · 2 = 1, y = (220 − 720)/1000 · 2 = −1.
        // ⇒ (1, −(−1), −2) = (1, 1, −2).
        let p = fullRes.unproject(u: 1460, v: 220, depth: 2)
        XCTAssertEqual(p.x, 1, accuracy: 1e-6)
        XCTAssertEqual(p.y, 1, accuracy: 1e-6)
        XCTAssertEqual(p.z, -2, accuracy: 1e-6)
    }

    func testUnprojectPixelCenterAppliesHalfPixelOffset() {
        // Pixel (0, 0) of the 4×3 camera: u = 0.5, v = 0.5.
        // x = (0.5 − 2)/2 · 1 = −0.75; y = (0.5 − 1.5)/2 · 1 = −0.5 ⇒ (−0.75, 0.5, −1).
        let p = tiny.unproject(pixelU: 0, pixelV: 0, depth: 1)
        XCTAssertEqual(p.x, -0.75, accuracy: 1e-6)
        XCTAssertEqual(p.y, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.z, -1, accuracy: 1e-6)
        // Same as calling the continuous form with the +0.5 offset explicitly.
        XCTAssertEqual(p, tiny.unproject(u: 0.5, v: 0.5, depth: 1))

        // Pixel (3, 2) at depth 2: u = 3.5, v = 2.5.
        // x = (3.5 − 2)/2 · 2 = 1.5; y = (2.5 − 1.5)/2 · 2 = 1 ⇒ (1.5, −1, −2).
        let q = tiny.unproject(pixelU: 3, pixelV: 2, depth: 2)
        XCTAssertEqual(q.x, 1.5, accuracy: 1e-6)
        XCTAssertEqual(q.y, -1, accuracy: 1e-6)
        XCTAssertEqual(q.z, -2, accuracy: 1e-6)
    }

    // MARK: - Matrices

    func testMatrixColumns() {
        let k = fullRes.matrix
        // K = [fx 0 cx; 0 fy cy; 0 0 1] stored column-major:
        //   c0 = (fx, 0, 0), c1 = (0, fy, 0), c2 = (cx, cy, 1).
        XCTAssertEqual(k.columns.0, SIMD3<Float>(1000, 0, 0))
        XCTAssertEqual(k.columns.1, SIMD3<Float>(0, 1000, 0))
        XCTAssertEqual(k.columns.2, SIMD3<Float>(960, 720, 1))
    }

    func testMatrixProjectsCameraPointToPixel() {
        // K · (X/Z, Y/Z, 1) with X = 0.5, Y = −0.5, Z = 1:
        //   u = 1000·0.5 + 960 = 1460; v = 1000·(−0.5) + 720 = 220.
        let uv = fullRes.matrix * SIMD3<Float>(0.5, -0.5, 1)
        XCTAssertEqual(uv.x, 1460, accuracy: 1e-3)
        XCTAssertEqual(uv.y, 220, accuracy: 1e-3)
        XCTAssertEqual(uv.z, 1, accuracy: 1e-6)
    }

    func testInverseMatrixReproducesImageSpacePoint() {
        // K⁻¹ · (u, v, 1) · d for u = 1460, v = 220, d = 2:
        //   K⁻¹ columns: (1/fx, 0, 0), (0, 1/fy, 0), (−cx/fx, −cy/fy, 1).
        //   K⁻¹·(1460, 220, 1) = (1460/1000 − 960/1000, 220/1000 − 720/1000, 1) = (0.5, −0.5, 1).
        //   · 2 = (1, −1, 2)  — image space: x right, y down, z forward.
        let p = fullRes.inverseMatrix * SIMD3<Float>(1460, 220, 1) * 2
        XCTAssertEqual(p.x, 1, accuracy: 1e-5)
        XCTAssertEqual(p.y, -1, accuracy: 1e-5)
        XCTAssertEqual(p.z, 2, accuracy: 1e-6)

        // The ARKit-convention unproject of the same pixel flips y and z: (1, 1, −2).
        let cam = fullRes.unproject(u: 1460, v: 220, depth: 2)
        XCTAssertEqual(cam.x, p.x, accuracy: 1e-5)
        XCTAssertEqual(cam.y, -p.y, accuracy: 1e-5)
        XCTAssertEqual(cam.z, -p.z, accuracy: 1e-6)
    }

    func testInverseMatrixIsTrueInverse() {
        let product = fullRes.matrix * fullRes.inverseMatrix
        // K · K⁻¹ = I₃.
        let identity = matrix_identity_float3x3
        for c in 0..<3 {
            for r in 0..<3 {
                XCTAssertEqual(product[c][r], identity[c][r], accuracy: 1e-5, "entry [\(c)][\(r)]")
            }
        }
    }

    // MARK: - Codable and equality

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(fullRes)
        let decoded = try JSONDecoder().decode(Intrinsics.self, from: data)
        XCTAssertEqual(decoded, fullRes)
    }

    func testEquatable() {
        XCTAssertEqual(tiny, Intrinsics(fx: 2, fy: 2, cx: 2, cy: 1.5, width: 4, height: 3))
        XCTAssertNotEqual(tiny, Intrinsics(fx: 2, fy: 2, cx: 2, cy: 1.5, width: 4, height: 4))
        XCTAssertNotEqual(tiny, fullRes)
    }
}
