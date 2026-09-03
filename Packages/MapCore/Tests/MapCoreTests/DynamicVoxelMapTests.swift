import simd
import XCTest
@testable import MapCore

final class DynamicVoxelMapTests: XCTestCase {
    // 32×24 image, fx = fy = 40 → at 2 m one pixel spans 5 cm, so every pixel is its own 2 cm voxel.
    let intrinsics = Intrinsics(fx: 40, fy: 40, cx: 16, cy: 12, width: 32, height: 24)

    /// Depth image of a wall at `wallMM` with an optional centred 8×6 box at `objectMM`.
    func depth(wallMM: UInt16, objectMM: UInt16? = nil) -> [UInt16] {
        var d = [UInt16](repeating: wallMM, count: 32 * 24)
        if let objectMM {
            for v in 9..<15 { for u in 12..<20 { d[v * 32 + u] = objectMM } }
        }
        return d
    }

    func record(_ d: [UInt16], seq: UInt32 = 0) -> KeyframeRecord {
        KeyframeRecord(seq: seq, timestamp: Double(seq), pose: .identity, intrinsics: intrinsics, tracking: .normal,
                       depthMillimeters: d, confidence: [UInt8](repeating: 2, count: d.count))
    }

    func integrate(_ map: inout DynamicVoxelMap, _ d: [UInt16]) -> DynamicVoxelMap.Integration {
        let r = record(d)
        let samples = Unprojector.unprojectPacked(record: r, options: .init()) { _ in PackedPoint.packColor(r: 100, g: 100, b: 100) }
        return map.integrate(samples: samples, depthMillimeters: r.depthMillimeters, confidence: r.confidence,
                             intrinsics: r.intrinsics, pose: r.pose)
    }

    func testProjectIsInverseOfUnproject() {
        // pixel (5,7) centre at depth 1.5 → unproject → project gives (5.5, 7.5, 1.5)
        let p = intrinsics.unproject(pixelU: 5, pixelV: 7, depth: 1.5)
        let back = intrinsics.project(cameraPoint: p)
        XCTAssertEqual(back?.u ?? -1, 5.5, accuracy: 1e-4)
        XCTAssertEqual(back?.v ?? -1, 7.5, accuracy: 1e-4)
        XCTAssertEqual(back?.depth ?? -1, 1.5, accuracy: 1e-5)
        XCTAssertNil(intrinsics.project(cameraPoint: SIMD3<Float>(0, 0, 1)))  // behind the camera (+z)
    }

    func testSecondObservationConfirmsInsteadOfAppending() {
        var map = DynamicVoxelMap()
        let first = integrate(&map, depth(wallMM: 2000))
        XCTAssertEqual(first.appended.count, 32 * 24)            // every pixel its own voxel, all parked
        XCTAssertTrue(first.appended.allSatisfy { $0.y < -1000 })
        XCTAssertEqual(map.confirmedCount, 0)                    // nothing shown after one look
        XCTAssertEqual(map.liveCount, 768)
        let second = integrate(&map, depth(wallMM: 2000))
        XCTAssertEqual(second.appended.count, 0)
        XCTAssertEqual(second.updates.count, 768)                // all 768 revealed at their real position
        XCTAssertTrue(second.updates.allSatisfy { $0.point.y > -1000 })
        XCTAssertEqual(map.confirmedCount, 768)
        XCTAssertEqual(second.missed, 0)
        XCTAssertEqual(map.renderablePoints.filter { $0.y > -1000 }.count, 768)
    }

    func testObjectThatLeavesIsCarvedAndCompacted() {
        var config = DynamicVoxelMap.Config()
        config.minCompactionDead = 1
        config.compactionDeadFraction = 0
        var map = DynamicVoxelMap(config: config)
        _ = integrate(&map, depth(wallMM: 2000, objectMM: 1000))
        _ = integrate(&map, depth(wallMM: 2000, objectMM: 1000))   // object confirmed (seen twice)
        XCTAssertEqual(map.confirmedCount, 768)                    // 48 object + 720 wall

        // The object is gone: rays now reach the wall at 2 m through the old object voxels.
        var killedTotal = 0
        var compacted = false
        for _ in 0..<5 {
            let r = integrate(&map, depth(wallMM: 2000))
            killedTotal += r.killed
            compacted = compacted || r.compacted
        }
        // occupancy 4 after two hits; high-confidence miss −4 → 0, second miss → −4 ≤ −4 → dead after two frames.
        XCTAssertEqual(killedTotal, 48)
        XCTAssertTrue(compacted)
        XCTAssertEqual(map.deadCount, 0)
        XCTAssertEqual(map.points.count, 768)          // 720 wall + 48 wall pixels revealed behind the object
        XCTAssertEqual(map.confirmedCount, 768)
        XCTAssertTrue(map.points.allSatisfy { $0.y > -100 })
    }

    func testTransientObservationNeverShowsAndIsPurged() {
        var config = DynamicVoxelMap.Config()
        config.maxUnconfirmedAge = 2
        config.unconfirmedSweepInterval = 1
        var map = DynamicVoxelMap(config: config)
        _ = integrate(&map, depth(wallMM: 2000, objectMM: 1000))   // object seen once
        // Look the other way three times: the 768 unconfirmed voxels age out and are dropped without ever rendering.
        let turned = Pose(translation: .zero, rotation: simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
        let d = depth(wallMM: 3000)
        var killed = 0
        for _ in 0..<3 {
            killed += map.integrate(samples: [], depthMillimeters: d, confidence: [UInt8](repeating: 2, count: d.count),
                                    intrinsics: intrinsics, pose: turned).killed
        }
        XCTAssertEqual(killed, 768)
        XCTAssertEqual(map.confirmedCount, 0)
        XCTAssertEqual(map.liveCount, 0)
    }

    func testCapCoarsensAtTheLimit() {
        var config = DynamicVoxelMap.Config()
        config.maxPoints = 500
        var map = DynamicVoxelMap(config: config)
        let r = integrate(&map, depth(wallMM: 2000))
        XCTAssertTrue(r.compacted)              // coarsened at the cap
        XCTAssertEqual(map.cellSize, 0.03, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(map.points.count, 500)
        XCTAssertTrue(map.state == .coarsened || map.state == .full)
    }

    func testPointsBehindCameraAreNotCarved() {
        var map = DynamicVoxelMap()
        _ = integrate(&map, depth(wallMM: 2000))
        _ = integrate(&map, depth(wallMM: 2000))
        let turned = Pose(translation: .zero, rotation: simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
        let d = depth(wallMM: 3000)
        let r = map.integrate(samples: [], depthMillimeters: d, confidence: [UInt8](repeating: 2, count: d.count),
                              intrinsics: intrinsics, pose: turned)
        XCTAssertEqual(r.missed, 0)
        XCTAssertEqual(r.killed, 0)
        XCTAssertEqual(map.confirmedCount, 768)
    }

    func testUnmeasuredPixelsErodeConfirmedVoxelsSlowly() {
        var map = DynamicVoxelMap()
        _ = integrate(&map, depth(wallMM: 2000))
        _ = integrate(&map, depth(wallMM: 2000))          // confirmed, occupancy 4
        // Depth image with no returns at all: weak misses of −1 per frame → dead after 8 frames (4 → −4).
        let none = [UInt16](repeating: 0, count: 768)
        var killed = 0
        for _ in 0..<8 {
            killed += map.integrate(samples: [], depthMillimeters: none, confidence: [UInt8](repeating: 0, count: 768),
                                    intrinsics: intrinsics, pose: .identity).killed
        }
        XCTAssertEqual(killed, 768)
    }
}
