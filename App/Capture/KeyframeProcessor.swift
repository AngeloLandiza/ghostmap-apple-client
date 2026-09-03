import Foundation
import MapCore
import simd

/// Snapshot of the global cloud state for the status strip and the manifest.
struct CloudStats: Sendable, Equatable {
    var keyframes = 0
    var points = 0
    var gridState: VoxelGrid.State = .accepting
    var cellSize: Float = 0.02
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
    private var grid: VoxelGrid
    private var options: Unprojector.Options
    private var seq: UInt32 = 0
    private var loggedFull = false
    private(set) var stats = CloudStats()

    init(pointBuffer: SharedPointBuffer,
         trajectory: TrajectoryBuffer,
         storage: StorageQueue,
         logger: SessionLogger,
         gridConfig: VoxelGrid.Config = .default,
         minConfidence: UInt8) {
        self.pointBuffer = pointBuffer
        self.trajectory = trajectory
        self.storage = storage
        self.logger = logger
        self.grid = VoxelGrid(config: gridConfig)
        var o = Unprojector.Options()
        o.minConfidence = minConfidence
        self.options = o
        self.stats.cellSize = gridConfig.cellSize
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

        var accepted = grid.insert(packed)
        if grid.state == .capReached {
            let before = pointBuffer.count
            let kept = pointBuffer.withPoints { grid.coarsen(existingPoints: $0) }
            do {
                try pointBuffer.replaceAll(kept)
                stats.coarsened = true
                logger.log(.cloud, "cap reached at \(before) points; coarsened to \(grid.cellSize) m cells, kept \(kept.count)")
            } catch {
                logger.log(.cloud, "coarsen failed: \(error)", level: .error)
            }
            accepted = grid.insert(packed)
        }
        if grid.state == .full, !loggedFull {
            loggedFull = true
            logger.log(.cloud, "global cloud full at \(grid.count) points; no longer accepting", level: .default)
        }

        pointBuffer.append(accepted)
        trajectory.append(record.pose.translation)
        storage.append(record)

        let d = ContinuousClock.now - start
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        stats.keyframes += 1
        stats.points = pointBuffer.count
        stats.gridState = grid.state
        stats.cellSize = grid.cellSize
        stats.bounds = pointBuffer.bounds
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
