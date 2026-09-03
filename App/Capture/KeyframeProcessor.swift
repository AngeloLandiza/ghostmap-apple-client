import Foundation
import MapCore
import simd

/// Snapshot of the global cloud state for the status strip and the manifest.
struct CloudStats: Sendable, Equatable {
    var keyframes = 0
    var points = 0
    var gridState: VoxelGrid.State = .accepting
    var cellSize: Float = 0.02
    var removedPoints = 0
    var carveMisses = 0
    var mapBytes = 0
    var bounds = BoundingBox.empty
    var lastProcessMs: Double = 0
    var maxProcessMs: Double = 0
    var pointsLastKeyframe = 0
    var coarsened = false
}

/// Turns keyframe snapshots into global-cloud points: quantize depth, unproject with color, voxel
/// dedupe, append to the shared GPU buffer and trajectory, and persist the record.
actor KeyframeProcessor {
    private let pointBuffer: SharedPointBuffer
    private let trajectory: TrajectoryBuffer
    private let storage: StorageQueue
    private let logger: SessionLogger
    private var map: DynamicVoxelMap
    private var options: Unprojector.Options
    private var seq: UInt32 = 0
    private var loggedFull = false
    private(set) var stats = CloudStats()

    init(pointBuffer: SharedPointBuffer,
         trajectory: TrajectoryBuffer,
         storage: StorageQueue,
         logger: SessionLogger,
         mapConfig: DynamicVoxelMap.Config = .default,
         minConfidence: UInt8) {
        self.pointBuffer = pointBuffer
        self.trajectory = trajectory
        self.storage = storage
        self.logger = logger
        self.map = DynamicVoxelMap(config: mapConfig)
        var o = Unprojector.Options()
        o.minConfidence = minConfidence
        self.options = o
        self.stats.cellSize = mapConfig.cellSize
    }

    func setMinConfidence(_ c: UInt8) {
        options.minConfidence = c
    }

    func process(_ snapshot: KeyframeSnapshot) -> CloudStats {
        let start = ContinuousClock.now

        let mm = DepthCodec.quantize(depthMeters: snapshot.depthMeters)
        let record = KeyframeRecord(
            seq: seq,
            timestamp: snapshot.timestamp,
            pose: Pose(matrix: snapshot.cameraTransform),
            intrinsics: snapshot.intrinsics,
            tracking: snapshot.tracking,
            depthMillimeters: mm,
            confidence: snapshot.confidence)
        seq &+= 1

        let packed: [PackedPoint]
        if snapshot.hasColor {
            packed = snapshot.luma.withUnsafeBufferPointer { yp in
                snapshot.chromaCb.withUnsafeBufferPointer { cbp in
                    snapshot.chromaCr.withUnsafeBufferPointer { crp in
                        Unprojector.unprojectPacked(record: record, options: options) { index in
                            let i = Int(index)
                            return KeyframeProcessor.rgb(y: yp[i], cb: cbp[i], cr: crp[i])
                        }
                    }
                }
            }
        } else {
            let gray = PackedPoint.packColor(r: 180, g: 180, b: 180)
            packed = Unprojector.unprojectPacked(record: record, options: options) { _ in gray }
        }

        let cellBefore = map.cellSize
        let r = map.integrate(samples: packed, depthMillimeters: mm, confidence: snapshot.confidence,
                              intrinsics: snapshot.intrinsics, pose: record.pose, minCarveConfidence: 2)
        if r.compacted {
            do {
                try pointBuffer.replaceAll(map.points)
                if map.cellSize != cellBefore {
                    stats.coarsened = true
                    logger.log(.cloud, "cap reached; coarsened to \(map.cellSize) m cells, \(map.liveCount) points")
                } else {
                    logger.log(.cloud, "compacted: \(map.liveCount) live points after removing carved voxels")
                }
            } catch {
                logger.log(.cloud, "replaceAll failed: \(error)", level: .error)
            }
        } else {
            pointBuffer.update(r.updates)
            pointBuffer.append(r.appended)
        }
        if r.state == .full, !loggedFull {
            loggedFull = true
            logger.log(.cloud, "global cloud full at \(map.liveCount) points; waiting for carving to free space", level: .default)
        }
        stats.removedPoints += r.killed
        stats.carveMisses += r.missed
        let accepted = r.appended
        trajectory.append(record.pose.translation)
        storage.append(record)

        let d = ContinuousClock.now - start
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        stats.keyframes += 1
        stats.points = map.liveCount
        stats.gridState = r.state
        stats.cellSize = map.cellSize
        stats.bounds = map.bounds
        stats.mapBytes = map.estimatedBytes
        stats.lastProcessMs = ms
        stats.maxProcessMs = max(stats.maxProcessMs, ms)
        stats.pointsLastKeyframe = accepted.count
        return stats
    }

    /// Full-range BT.601 YCbCr → packed RGBA.
    static func rgb(y: UInt8, cb: UInt8, cr: UInt8) -> UInt32 {
        let yf = Float(y)
        let cbf = Float(cb) - 128
        let crf = Float(cr) - 128
        let r = yf + 1.402 * crf
        let g = yf - 0.344136 * cbf - 0.714136 * crf
        let b = yf + 1.772 * cbf
        func clamp(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        return PackedPoint.packColor(r: clamp(r), g: clamp(g), b: clamp(b))
    }
}
