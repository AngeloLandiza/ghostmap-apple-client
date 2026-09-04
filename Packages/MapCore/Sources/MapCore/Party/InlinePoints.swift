import Foundation
import simd

/// The `points_inline` field of a party keyframe: a small, self-contained sample of the points this
/// keyframe contributed, so every viewer can draw something without downloading the depth payload.
///
/// The wire form is a flat `x y z r g b` sequence — positions in metres in the party's origin frame,
/// colour channels as 0…255 — capped at ``maxPoints`` points, which is what the backend's schema
/// accepts (`points_inline: z.array(z.number()).max(2000 * 6)`).
public enum InlinePoints: Sendable {

    /// The contract's cap: at most 2 000 points, i.e. 12 000 floats, per keyframe.
    public static let maxPoints = 2000

    /// Floats per point (`x y z r g b`).
    public static let stride = 6

    /// True when a mirror entry is a real point rather than a parked one.
    ///
    /// `DynamicVoxelMap` parks unconfirmed and dead voxels at `y = -1e6` instead of removing them,
    /// so that indices stay aligned with the GPU buffer. Anything far below the floor is such an
    /// entry, never a measurement.
    @inlinable
    public static func isRenderable(_ point: PackedPoint) -> Bool { point.y > -1000 }

    /// The confirmed points one `DynamicVoxelMap.integrate` produced, decimated to at most
    /// `maxPoints` by a uniform stride.
    ///
    /// Both halves of the integration matter: `appended` holds voxels seen for the first time (most
    /// of them still parked, because a voxel needs `confirmHits` observations before it is shown)
    /// and `updates` holds the ones this keyframe fused or *confirmed*, which is where a keyframe's
    /// freshly promoted points appear. Parked entries are dropped from both.
    public static func select(appended: [PackedPoint],
                              updates: [DynamicVoxelMap.PointUpdate],
                              maxPoints: Int = InlinePoints.maxPoints) -> [PackedPoint] {
        var confirmed: [PackedPoint] = []
        confirmed.reserveCapacity(min(appended.count + updates.count, maxPoints * 2))
        for point in appended where isRenderable(point) { confirmed.append(point) }
        for update in updates where isRenderable(update.point) { confirmed.append(update.point) }
        guard maxPoints > 0 else { return [] }
        return Decimation.decimate(confirmed, target: maxPoints)
    }

    /// Flat `x y z r g b` floats. `originFromWorld`, when given, re-expresses every position in the
    /// party's origin frame (the marker frame) — the same transform the pose gets, so the points and
    /// the camera that saw them stay consistent.
    public static func encode(_ points: [PackedPoint], originFromWorld: Pose? = nil) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(points.count * stride)
        for point in points {
            let position = originFromWorld.map { $0.transform(point.position) } ?? point.position
            out.append(Double(position.x))
            out.append(Double(position.y))
            out.append(Double(position.z))
            out.append(Double(point.r))
            out.append(Double(point.g))
            out.append(Double(point.b))
        }
        return out
    }

    /// Inverse of ``encode(_:originFromWorld:)``.
    ///
    /// Trailing floats that do not complete a point are ignored, non-finite positions are skipped
    /// and colour channels are clamped to 0…255, because the values come off the network. `tint`
    /// blends the peer's party colour into every point so two clouds can be told apart; `limit`
    /// caps how many points one message may contribute.
    public static func decode(_ values: [Double],
                              tint: PartyColor? = nil,
                              mix: Float = 0.55,
                              limit: Int = InlinePoints.maxPoints) -> [PackedPoint] {
        let count = min(values.count / stride, max(0, limit))
        guard count > 0 else { return [] }
        var out: [PackedPoint] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let base = i * stride
            let x = Float(values[base])
            let y = Float(values[base + 1])
            let z = Float(values[base + 2])
            guard x.isFinite, y.isFinite, z.isFinite else { continue }
            let r = channel(values[base + 3])
            let g = channel(values[base + 4])
            let b = channel(values[base + 5])
            let point = PackedPoint(position: SIMD3<Float>(x, y, z), r: r, g: g, b: b)
            out.append(tint.map { $0.tinted(point, mix: mix) } ?? point)
        }
        return out
    }

    /// One colour channel off the wire: rounded and clamped into 0…255, `0` for anything non-finite.
    @inlinable
    public static func channel(_ value: Double) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8(min(255, max(0, value.rounded())))
    }
}
