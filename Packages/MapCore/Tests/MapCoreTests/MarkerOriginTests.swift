import XCTest
import simd
@testable import MapCore

final class MarkerOriginTests: XCTestCase {

    // MARK: - Helpers

    /// Right-handed 90° about +Y: x̂ → (0, 0, −1), ẑ → (1, 0, 0).
    private let yaw90 = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))

    private func assertApproximatelyEqual(_ a: Pose, _ b: Pose, accuracy: Float = 1e-5,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let x = a.columnMajorArray
        let y = b.columnMajorArray
        for i in 0..<16 {
            XCTAssertEqual(x[i], y[i], accuracy: accuracy, "entry \(i)", file: file, line: line)
        }
    }

    private func tracked(_ pose: Pose, at t: TimeInterval = 0, name: String = "ghostmap-marker") -> MarkerOrigin {
        var origin = MarkerOrigin()
        origin.observe(worldFromOrigin: pose, isTracked: true, name: name, timestamp: t)
        return origin
    }

    // MARK: - Pose math (hand-computed)

    /// world_from_origin = translation (1, 0, 0) with a +90° yaw, camera at world (3, 0, 0) unrotated.
    ///
    /// R columns are c0 = (0, 0, −1), c1 = (0, 1, 0), c2 = (1, 0, 0), so Rᵀ columns are
    /// (0, 0, 1), (0, 1, 0), (−1, 0, 0). The inverse origin transform is [Rᵀ | −Rᵀt] with
    /// −Rᵀ·(1, 0, 0) = (0, 0, −1), hence
    ///   translation = Rᵀ·(3, 0, 0) + (0, 0, −1) = (0, 0, 3) + (0, 0, −1) = (0, 0, 2)
    ///   rotation    = Rᵀ = Ry(−90°)
    /// Geometrically: the camera sits 2 m along the marker's own +Z axis (which points to world +X).
    func testOriginFromCameraHandComputed() {
        let worldFromOrigin = Pose(translation: SIMD3<Float>(1, 0, 0), rotation: yaw90)
        let worldFromCamera = Pose(translation: SIMD3<Float>(3, 0, 0))

        let result = MarkerOrigin.originFromCamera(worldFromOrigin: worldFromOrigin, worldFromCamera: worldFromCamera)

        XCTAssertEqual(result.translation.x, 0, accuracy: 1e-5)
        XCTAssertEqual(result.translation.y, 0, accuracy: 1e-5)
        XCTAssertEqual(result.translation.z, 2, accuracy: 1e-5)
        // Rᵀ columns, entry by entry.
        let c = result.matrix.columns
        XCTAssertEqual(SIMD3<Float>(c.0.x, c.0.y, c.0.z).z, 1, accuracy: 1e-5)
        XCTAssertEqual(SIMD3<Float>(c.0.x, c.0.y, c.0.z).x, 0, accuracy: 1e-5)
        XCTAssertEqual(SIMD3<Float>(c.1.x, c.1.y, c.1.z).y, 1, accuracy: 1e-5)
        XCTAssertEqual(SIMD3<Float>(c.2.x, c.2.y, c.2.z).x, -1, accuracy: 1e-5)
        XCTAssertEqual(c.0.w, 0)
        XCTAssertEqual(c.3.w, 1)
    }

    /// Pure translation: marker at (1, 2, 3), camera at (4, 6, 8) → (3, 4, 5) in the marker frame.
    func testTranslationOnlyOrigin() {
        let origin = tracked(Pose(translation: SIMD3<Float>(1, 2, 3)))
        guard let pose = origin.markerFrame(from: Pose(translation: SIMD3<Float>(4, 6, 8))) else {
            return XCTFail("expected a marker-frame pose")
        }
        XCTAssertEqual(pose.translation.x, 3, accuracy: 1e-5)
        XCTAssertEqual(pose.translation.y, 4, accuracy: 1e-5)
        XCTAssertEqual(pose.translation.z, 5, accuracy: 1e-5)
        assertApproximatelyEqual(Pose(matrix: pose.rotationMatrixAsPose), .identity)
    }

    /// An identity marker leaves the world pose untouched (but still flags it aligned).
    func testIdentityOriginIsTheIdentityMapping() {
        let origin = tracked(.identity)
        let camera = Pose(translation: SIMD3<Float>(0.3, -1.2, 4), rotation: yaw90)
        guard let pose = origin.markerFrame(from: camera) else { return XCTFail("expected a pose") }
        assertApproximatelyEqual(pose, camera)
    }

    /// world_from_camera = world_from_origin · origin_from_camera must invert exactly.
    func testRoundTripThroughTheOrigin() {
        let worldFromOrigin = Pose(translation: SIMD3<Float>(-2.5, 1.25, 0.75),
                                   rotation: simd_quatf(angle: 0.9, axis: simd_normalize(SIMD3<Float>(1, 2, 3))))
        let originFromCamera = Pose(translation: SIMD3<Float>(0.4, -0.2, 3.1),
                                    rotation: simd_quatf(angle: -0.4, axis: simd_normalize(SIMD3<Float>(-1, 0.5, 2))))
        let origin = tracked(worldFromOrigin)

        guard let recovered = origin.markerFrame(from: worldFromOrigin * originFromCamera) else {
            return XCTFail("expected a pose")
        }
        assertApproximatelyEqual(recovered, originFromCamera, accuracy: 1e-4)
    }

    func testMatrixOverloadsAgreeWithPoseOverloads() {
        let origin = tracked(Pose(translation: SIMD3<Float>(1, 0, 0), rotation: yaw90))
        let camera = Pose(translation: SIMD3<Float>(3, 0.5, -1))
        guard let viaPose = origin.markerFrame(from: camera),
              let viaMatrix = origin.markerFrame(from: camera.matrix) else {
            return XCTFail("expected both overloads to produce a pose")
        }
        assertApproximatelyEqual(viaPose, Pose(matrix: viaMatrix))
        XCTAssertEqual(origin.alignedPose(worldFromCamera: camera), origin.alignedPose(worldFromCamera: camera.matrix))
    }

    // MARK: - aligned flag

    func testBeforeDetectionThePoseIsTheWorldPoseAndUnaligned() {
        let origin = MarkerOrigin()
        let camera = Pose(translation: SIMD3<Float>(1, 2, 3), rotation: yaw90)

        XCTAssertNil(origin.markerFrame(from: camera))
        XCTAssertNil(origin.resolvedWorldFromOrigin)
        XCTAssertFalse(origin.isAligned)

        let uploaded = origin.alignedPose(worldFromCamera: camera)
        XCTAssertFalse(uploaded.aligned)
        assertApproximatelyEqual(uploaded.pose, camera)
    }

    func testAfterDetectionThePoseIsTheMarkerFrameAndAligned() {
        let worldFromOrigin = Pose(translation: SIMD3<Float>(1, 0, 0), rotation: yaw90)
        let origin = tracked(worldFromOrigin)
        let uploaded = origin.alignedPose(worldFromCamera: Pose(translation: SIMD3<Float>(3, 0, 0)))

        XCTAssertTrue(uploaded.aligned)
        XCTAssertEqual(uploaded.pose.translation.z, 2, accuracy: 1e-5)
        XCTAssertEqual(origin.resolvedWorldFromOrigin, worldFromOrigin)
    }

    /// A lost marker keeps the frame: poses stay aligned, only the strip changes colour.
    func testLostOriginStaysAligned() {
        var origin = tracked(Pose(translation: SIMD3<Float>(1, 0, 0), rotation: yaw90))
        origin.observe(worldFromOrigin: .identity, isTracked: false)

        XCTAssertEqual(origin.state, .lost)
        XCTAssertTrue(origin.isAligned)
        XCTAssertEqual(origin.worldFromOrigin.translation, SIMD3<Float>(1, 0, 0), "the last origin must survive")
        XCTAssertTrue(origin.alignedPose(worldFromCamera: Pose(translation: SIMD3<Float>(3, 0, 0))).aligned)
    }

    // MARK: - State machine

    func testDetectionLossAndRedetection() {
        var origin = MarkerOrigin()
        XCTAssertEqual(origin.state, .none)

        var transition = origin.observe(worldFromOrigin: .identity, isTracked: true, name: "ghostmap-marker", timestamp: 10)
        XCTAssertEqual(transition.from, .none)
        XCTAssertEqual(transition.to, .tracking)
        XCTAssertEqual(origin.detections, 1)
        XCTAssertEqual(origin.markerID, "ghostmap-marker")
        XCTAssertEqual(origin.firstDetection, 10)

        // Further tracked updates refresh the origin without counting a new detection.
        transition = origin.observe(worldFromOrigin: Pose(translation: SIMD3<Float>(0, 0, 1)), isTracked: true, timestamp: 11)
        XCTAssertEqual(transition.from, .tracking)
        XCTAssertEqual(transition.to, .tracking)
        XCTAssertEqual(origin.detections, 1)
        XCTAssertEqual(origin.losses, 0)
        XCTAssertEqual(origin.lastUpdate, 11)
        XCTAssertEqual(origin.firstDetection, 10, "the first detection timestamp never moves")
        XCTAssertEqual(origin.worldFromOrigin.translation, SIMD3<Float>(0, 0, 1))

        transition = origin.observe(worldFromOrigin: .identity, isTracked: false, timestamp: 12)
        XCTAssertEqual(transition.to, .lost)
        XCTAssertEqual(origin.losses, 1)

        // A second untracked report is not a second loss.
        origin.observe(worldFromOrigin: .identity, isTracked: false, timestamp: 13)
        XCTAssertEqual(origin.losses, 1)

        transition = origin.observe(worldFromOrigin: Pose(translation: SIMD3<Float>(0, 0, 2)), isTracked: true, timestamp: 14)
        XCTAssertEqual(transition.from, .lost)
        XCTAssertEqual(transition.to, .tracking)
        XCTAssertEqual(origin.detections, 2)
        XCTAssertEqual(origin.worldFromOrigin.translation, SIMD3<Float>(0, 0, 2))
    }

    func testUntrackedBeforeAnyDetectionStaysNone() {
        var origin = MarkerOrigin()
        let transition = origin.observe(worldFromOrigin: Pose(translation: SIMD3<Float>(9, 9, 9)), isTracked: false, timestamp: 1)
        XCTAssertEqual(transition.to, .none)
        XCTAssertEqual(origin.losses, 0)
        XCTAssertEqual(origin.worldFromOrigin, .identity, "an untracked anchor must not define an origin")
    }

    func testTickDemotesAStaleOriginOnlyAfterTheTimeout() {
        var origin = tracked(.identity, at: 100)

        XCTAssertEqual(origin.tick(timestamp: 100.5, staleAfter: 1).to, .tracking)
        XCTAssertEqual(origin.tick(timestamp: 101, staleAfter: 1).to, .tracking, "exactly at the timeout is not stale")
        XCTAssertEqual(origin.losses, 0)

        let transition = origin.tick(timestamp: 101.5, staleAfter: 1)
        XCTAssertEqual(transition.from, .tracking)
        XCTAssertEqual(transition.to, .lost)
        XCTAssertEqual(origin.losses, 1)

        // Ticking a lost origin is a no-op, and it never resurrects one.
        XCTAssertEqual(origin.tick(timestamp: 200, staleAfter: 1).to, .lost)
        XCTAssertEqual(origin.losses, 1)

        var fresh = MarkerOrigin()
        XCTAssertEqual(fresh.tick(timestamp: 999).to, .none)
    }

    func testResetForgetsTheMarker() {
        var origin = tracked(Pose(translation: SIMD3<Float>(1, 0, 0), rotation: yaw90), at: 5)
        origin.reset()

        XCTAssertEqual(origin.state, .none)
        XCTAssertEqual(origin.worldFromOrigin, .identity)
        XCTAssertNil(origin.markerID)
        XCTAssertNil(origin.lastUpdate)
        XCTAssertNil(origin.firstDetection)
        XCTAssertEqual(origin.detections, 0)
        XCTAssertEqual(origin.losses, 0)
    }

    // MARK: - Labels

    func testStateLabelsAndAlignment() {
        XCTAssertEqual(MarkerOrigin.State.none.label, "none")
        XCTAssertEqual(MarkerOrigin.State.tracking.label, "aligned")
        XCTAssertEqual(MarkerOrigin.State.lost.label, "lost")
        XCTAssertFalse(MarkerOrigin.State.none.isAligned)
        XCTAssertTrue(MarkerOrigin.State.tracking.isAligned)
        XCTAssertTrue(MarkerOrigin.State.lost.isAligned)
        XCTAssertEqual(MarkerOrigin.State.allCases.count, 3)
    }
}

private extension Pose {
    /// The rotation part as a pose, so a whole-matrix comparison can ignore translation.
    var rotationMatrixAsPose: simd_float4x4 {
        var m = matrix_identity_float4x4
        let r = rotationMatrix
        m.columns.0 = SIMD4<Float>(r.columns.0, 0)
        m.columns.1 = SIMD4<Float>(r.columns.1, 0)
        m.columns.2 = SIMD4<Float>(r.columns.2, 0)
        return m
    }
}
