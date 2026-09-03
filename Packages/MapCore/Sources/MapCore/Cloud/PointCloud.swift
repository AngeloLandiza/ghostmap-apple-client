import simd

/// An in-memory colored point cloud with its axis-aligned bounds kept in step with the points.
///
/// Bounds are maintained incrementally by `init(points:)` and `append(contentsOf:)`, so growing a cloud
/// point-batch by point-batch never rescans it. Assigning `points` wholesale recomputes the bounds in
/// one O(n) pass.
public struct PointCloud: Sendable, Equatable {
    private var storage: [PackedPoint]

    /// The points, in insertion order. Setting this property replaces the whole cloud and recomputes
    /// `bounds` (O(n)); prefer `append(contentsOf:)` for incremental growth.
    public var points: [PackedPoint] {
        get { storage }
        set {
            storage = newValue
            bounds = newValue.withUnsafeBufferPointer(PointCloud.bounds(of:))
        }
    }

    /// Axis-aligned bounds of `points`; `BoundingBox.empty` when the cloud is empty.
    public private(set) var bounds: BoundingBox

    /// Creates a cloud from `points`, computing its bounds.
    public init(points: [PackedPoint] = []) {
        self.storage = points
        self.bounds = points.withUnsafeBufferPointer(PointCloud.bounds(of:))
    }

    /// Appends `newPoints`, extending `bounds` by only the new points.
    public mutating func append(contentsOf newPoints: [PackedPoint]) {
        guard !newPoints.isEmpty else { return }
        storage.append(contentsOf: newPoints)
        let added = newPoints.withUnsafeBufferPointer(PointCloud.bounds(of:))
        bounds.formUnion(added)
    }

    /// Number of points.
    public var count: Int { storage.count }

    /// Axis-aligned bounds of `points`; `BoundingBox.empty` for an empty buffer.
    public static func bounds(of points: UnsafeBufferPointer<PackedPoint>) -> BoundingBox {
        guard let base = points.baseAddress, !points.isEmpty else { return .empty }
        let first = base[0]
        var minX = first.x, minY = first.y, minZ = first.z
        var maxX = first.x, maxY = first.y, maxZ = first.z
        var i = 1
        let n = points.count
        while i < n {
            let point = base[i]
            i += 1
            if point.x < minX { minX = point.x }
            if point.y < minY { minY = point.y }
            if point.z < minZ { minZ = point.z }
            if point.x > maxX { maxX = point.x }
            if point.y > maxY { maxY = point.y }
            if point.z > maxZ { maxZ = point.z }
        }
        return BoundingBox(min: SIMD3<Float>(minX, minY, minZ), max: SIMD3<Float>(maxX, maxY, maxZ))
    }
}
