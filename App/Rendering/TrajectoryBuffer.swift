import Metal
import os
import simd

/// Append-only GPU buffer of keyframe positions (12-byte packed floats) drawn as a polyline.
///
/// Thread-safety invariant (`@unchecked Sendable`): same scheme as `SharedPointBuffer` — bytes are
/// written beyond the published count under the lock, and readers only read `[0, count)`.
final class TrajectoryBuffer: @unchecked Sendable {
    struct Snapshot: @unchecked Sendable {
        let buffer: MTLBuffer
        let count: Int
    }

    private struct State {
        var count: Int
        var last: SIMD3<Float>?
    }

    let buffer: MTLBuffer
    let capacity: Int
    private let lock: OSAllocatedUnfairLock<State>

    init(device: MTLDevice, capacity: Int = 65_536) throws {
        let bytes = capacity * MemoryLayout<RMLineVertex>.stride
        guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            throw RenderError.bufferAllocationFailed(bytes: bytes)
        }
        buffer.label = "Trajectory"
        self.buffer = buffer
        self.capacity = capacity
        self.lock = OSAllocatedUnfairLock(uncheckedState: State(count: 0, last: nil))
    }

    var count: Int { lock.withLockUnchecked { $0.count } }

    /// Appends a position; silently drops once the capacity is reached.
    func append(_ p: SIMD3<Float>) {
        lock.withLockUnchecked { s in
            guard s.count < capacity else { return }
            let v = RMLineVertex(x: p.x, y: p.y, z: p.z)
            buffer.contents()
                .advanced(by: s.count * MemoryLayout<RMLineVertex>.stride)
                .storeBytes(of: v, as: RMLineVertex.self)
            s.count += 1
            s.last = p
        }
    }

    var lastPosition: SIMD3<Float>? { lock.withLockUnchecked { $0.last } }

    func snapshot() -> Snapshot {
        lock.withLockUnchecked { Snapshot(buffer: buffer, count: $0.count) }
    }

    func removeAll() {
        lock.withLockUnchecked { s in
            s.count = 0
            s.last = nil
        }
    }
}
