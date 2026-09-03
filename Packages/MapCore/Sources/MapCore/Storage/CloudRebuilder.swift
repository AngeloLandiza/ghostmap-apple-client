import Foundation

/// Rebuilds a point cloud from a `keyframes.bin` log alone, for maps whose recording was
/// interrupted before `cloud.ply` was written.
///
/// The log carries depth and confidence but no color, so every point is a confidence-tinted gray:
/// high confidence (2) → 210, anything else → 150, alpha 255. Keyframes are replayed through the
/// same `Unprojector` → `VoxelGrid` pipeline the live capture uses, including the single
/// coarsening step when the grid reaches its cap.
public enum CloudRebuilder {
    /// Packed RGBA for a high-confidence pixel: gray 210 (`0xFFD2D2D2`).
    static let highConfidenceColor = PackedPoint.packColor(r: 210, g: 210, b: 210, a: 255)
    /// Packed RGBA for every other retained pixel: gray 150 (`0xFF969696`).
    static let mediumConfidenceColor = PackedPoint.packColor(r: 150, g: 150, b: 150, a: 255)

    /// What `rebuild` produced.
    public struct Result: Sendable {
        /// The deduplicated cloud, in acceptance order.
        public var cloud: PointCloud
        /// Number of records replayed (every complete valid record in the log).
        public var keyframeCount: Int
        /// Lifecycle state of the voxel grid after the last keyframe.
        public var gridState: VoxelGrid.State
        /// The log scan; `records` is empty, and `truncatedAtOffset` / `corruptedAtOffset` tell
        /// whether the log had a damaged tail.
        public var scan: KeyframeLogScan

        /// Creates a result.
        public init(cloud: PointCloud, keyframeCount: Int, gridState: VoxelGrid.State, scan: KeyframeLogScan) {
            self.cloud = cloud
            self.keyframeCount = keyframeCount
            self.gridState = gridState
            self.scan = scan
        }
    }

    /// Replays every complete valid record of the log at `logURL`.
    ///
    /// For each record whose arrays cover its pixel count, the depth map is unprojected with
    /// `options` (colored by confidence as described above), inserted into a `VoxelGrid` built
    /// from `gridConfig`, and the accepted points are appended to the cloud. When the grid reports
    /// `.capReached`, the partially accepted batch is dropped, the cloud's points are handed to
    /// `coarsen(existingPoints:)`, the cloud is replaced by the survivors and the whole keyframe is
    /// re-inserted at the coarse cell size — exactly what the live capture does. `progress` is
    /// called after every record with the number of records replayed so far.
    ///
    /// A damaged tail does not throw; it is reported in `Result.scan`. Throws `MapError.io` when
    /// the file cannot be read and `MapError.invalidMagic` / `unsupportedVersion` /
    /// `truncatedRecord(offset: 0)` for a bad header.
    public static func rebuild(logURL: URL,
                               gridConfig: VoxelGrid.Config = .default,
                               options: Unprojector.Options = .init(),
                               progress: ((Int) -> Void)? = nil) throws -> Result {
        var grid = VoxelGrid(config: gridConfig)
        var cloud = PointCloud()
        var keyframeCount = 0

        let scan = try KeyframeLogReader.forEachRecord(url: logURL) { record in
            if record.isConsistent {
                let confidence = record.confidence
                let points = Unprojector.unprojectPacked(record: record, options: options) { pixelIndex in
                    confidence[Int(pixelIndex)] == 2 ? highConfidenceColor : mediumConfidenceColor
                }
                // Mirrors the live pipeline (KeyframeProcessor): when a keyframe hits the cap its
                // partially accepted batch is discarded, the cloud is coarsened, and the whole
                // keyframe is re-inserted at the coarse cell size. Appending the partial batch
                // instead would drop every candidate that came after the cap, so a rebuilt cloud
                // would differ from the cloud the same log produced live.
                var accepted = grid.insert(points)
                if grid.state == .capReached {
                    let kept = cloud.points.withUnsafeBufferPointer { grid.coarsen(existingPoints: $0) }
                    cloud = PointCloud(points: kept)
                    accepted = grid.insert(points)
                }
                cloud.append(contentsOf: accepted)
            }
            keyframeCount += 1
            progress?(keyframeCount)
        }

        return Result(cloud: cloud, keyframeCount: keyframeCount, gridState: grid.state, scan: scan)
    }
}
