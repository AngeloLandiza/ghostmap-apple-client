/// Uniform stride decimation used to keep the number of drawn points under a renderer budget
/// (for example ≤ 1 M in the main view and ≤ 250 k in the Ghost Map).
public enum Decimation {
    /// Smallest stride `s ≥ 1` such that drawing every `s`-th point of `count` points yields at most
    /// `target` points, i.e. `ceil(count / s) ≤ target`, computed as `(count + target − 1) / target`.
    /// Returns 1 when `count ≤ target`. A `target ≤ 0` (nothing should be drawn) returns
    /// `max(1, count)`, which keeps the stride usable as a loop step and leaves at most one point.
    public static func stride(count: Int, target: Int) -> Int {
        if count <= target { return 1 }
        if target <= 0 { return Swift.max(1, count) }
        return (count + target - 1) / target
    }

    /// Number of points `decimate` keeps: `ceil(count / stride)`, or 0 when `count == 0`.
    /// A `stride ≤ 0` is treated as 1.
    public static func decimatedCount(count: Int, stride: Int) -> Int {
        guard count > 0 else { return 0 }
        let step = Swift.max(1, stride)
        return (count + step - 1) / step
    }

    /// Keeps the points at indices `0, s, 2s, …` where `s = stride(count: points.count, target: target)`.
    /// Returns the input unchanged when no decimation is needed.
    public static func decimate(_ points: [PackedPoint], target: Int) -> [PackedPoint] {
        let step = Decimation.stride(count: points.count, target: target)
        guard step > 1 else { return points }
        var kept: [PackedPoint] = []
        kept.reserveCapacity(decimatedCount(count: points.count, stride: step))
        var i = 0
        while i < points.count {
            kept.append(points[i])
            i += step
        }
        return kept
    }
}
