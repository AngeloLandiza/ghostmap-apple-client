import MapCore
import Metal
import os

/// GPU-visible, append-only store for the accumulated global point cloud, read by both the main
/// renderer and the Ghost Map renderer and written by the keyframe processor.
///
/// Thread-safety invariant (`@unchecked Sendable`): all mutable state lives in `State` behind an
/// `OSAllocatedUnfairLock`. Point bytes are written to the active buffer strictly beyond the published
/// `count`, and `count` is advanced only after the bytes are in place, so a reader that reads
/// `[0, count)` of a snapshot never sees a partially written point. `replaceAll` writes the *inactive*
/// buffer and then swaps, so a snapshot taken before the swap stays internally consistent. There is a
/// single writer (the `KeyframeProcessor` actor, then the finalizer), which is what makes reading
/// outside the lock in `withPoints` safe. The GPU may still be reading the previously active buffer for
/// up to one frame after a swap; a second `replaceAll` within that window is not possible because
/// coarsening happens at most once per session (see DECISIONS.md).
final class SharedPointBuffer: @unchecked Sendable {
    struct Snapshot: @unchecked Sendable {
        let buffer: MTLBuffer
        let count: Int
        let bounds: BoundingBox
        let generation: UInt64
    }

    private struct State {
        var buffers: [MTLBuffer]
        var active: Int
        var count: Int
        var bounds: BoundingBox
        var generation: UInt64
    }

    let capacity: Int
    private let device: MTLDevice
    private let lock: OSAllocatedUnfairLock<State>

    static let logger = Logger(subsystem: "tech.alandiza.roommapper", category: "cloud")

    init(device: MTLDevice, capacity: Int) throws {
        let bytes = capacity * PackedPoint.byteSize
        guard let buffer = device.makeBuffer(length: max(bytes, PackedPoint.byteSize), options: .storageModeShared) else {
            throw RenderError.bufferAllocationFailed(bytes: bytes)
        }
        buffer.label = "GlobalCloud.0"
        self.device = device
        self.capacity = capacity
        self.lock = OSAllocatedUnfairLock(uncheckedState: State(buffers: [buffer], active: 0, count: 0, bounds: .empty, generation: 0))
    }

    var count: Int { lock.withLockUnchecked { $0.count } }

    var bounds: BoundingBox { lock.withLockUnchecked { $0.bounds } }

    func snapshot() -> Snapshot {
        lock.withLockUnchecked { s in
            Snapshot(buffer: s.buffers[s.active], count: s.count, bounds: s.bounds, generation: s.generation)
        }
    }

    /// Appends points (truncating at capacity). Returns how many were appended.
    @discardableResult
    func append(_ points: [PackedPoint]) -> Int {
        guard !points.isEmpty else { return 0 }
        return lock.withLockUnchecked { s in
            let room = capacity - s.count
            let n = min(room, points.count)
            guard n > 0 else { return 0 }
            let buffer = s.buffers[s.active]
            let dst = buffer.contents().advanced(by: s.count * PackedPoint.byteSize)
            let copied = points.withUnsafeBytes { src -> Bool in
                guard let base = src.baseAddress else { return false }
                dst.copyMemory(from: base, byteCount: n * PackedPoint.byteSize)
                return true
            }
            guard copied else { return 0 }
            var b = s.bounds
            for i in 0..<n where points[i].y > -1000 { b.formUnion(points[i].position) }   // skip parked (unconfirmed/dead) entries
            s.bounds = b
            s.count += n
            s.generation &+= 1
            return n
        }
    }

    /// Replaces the whole cloud (used once after the voxel grid coarsens). Allocates the second buffer
    /// lazily on first use.
    func replaceAll(_ points: [PackedPoint]) throws {
        let n = min(points.count, capacity)
        try lock.withLockUnchecked { s in
            if s.buffers.count < 2 {
                let bytes = capacity * PackedPoint.byteSize
                guard let second = device.makeBuffer(length: max(bytes, PackedPoint.byteSize), options: .storageModeShared) else {
                    throw RenderError.bufferAllocationFailed(bytes: bytes)
                }
                second.label = "GlobalCloud.1"
                s.buffers.append(second)
            }
            let inactive = 1 - s.active
            let buffer = s.buffers[inactive]
            if n > 0 {
                points.withUnsafeBytes { src in
                    if let base = src.baseAddress {
                        buffer.contents().copyMemory(from: base, byteCount: n * PackedPoint.byteSize)
                    }
                }
            }
            var b = BoundingBox.empty
            for i in 0..<n where points[i].y > -1000 { b.formUnion(points[i].position) }
            s.bounds = b
            s.count = n
            s.active = inactive
            s.generation &+= 1
        }
        SharedPointBuffer.logger.notice("global cloud replaced: \(n) points")
    }

    /// Rewrites existing points in place (fused positions/colors, parked dead voxels). A renderer may see a
    /// single torn 16-byte point for one frame; that is cosmetic and accepted (see DECISIONS.md).
    func update(_ updates: [DynamicVoxelMap.PointUpdate]) {
        guard !updates.isEmpty else { return }
        lock.withLockUnchecked { s in
            let base = s.buffers[s.active].contents()
            var b = s.bounds
            for u in updates {
                let i = Int(u.index)
                guard i < s.count else { continue }
                var p = u.point
                withUnsafeBytes(of: &p) { src in
                    if let a = src.baseAddress { base.advanced(by: i * PackedPoint.byteSize).copyMemory(from: a, byteCount: PackedPoint.byteSize) }
                }
                if p.y > -1000 { b.formUnion(p.position) }
            }
            s.bounds = b
            s.generation &+= 1
        }
    }

    /// Reads the current contents without copying. Safe because the active buffer's `[0, count)` region
    /// is never rewritten (see the class invariant).
    func withPoints<R>(_ body: (UnsafeBufferPointer<PackedPoint>) throws -> R) rethrows -> R {
        let snap = snapshot()
        let base = snap.buffer.contents().bindMemory(to: PackedPoint.self, capacity: max(snap.count, 1))
        return try body(UnsafeBufferPointer(start: base, count: snap.count))
    }

    /// Resets to empty (keeps allocations).
    func removeAll() {
        lock.withLockUnchecked { s in
            s.count = 0
            s.bounds = .empty
            s.generation &+= 1
        }
    }
}
