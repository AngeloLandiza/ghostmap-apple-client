import Foundation
import os

/// Frame timing shared between the main renderer (writer), the Ghost Map renderer (reads `isBehind`)
/// and the status loop. Thread-safety invariant: all fields live behind an `OSAllocatedUnfairLock`.
final class RenderClock: Sendable {
    private struct State {
        var fps: Double = 0
        var lastCPUFrameMs: Double = 0
        var framesInFlight = 0
        var lastInterval: Double = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var fps: Double { lock.withLock { $0.fps } }
    var lastCPUFrameMs: Double { lock.withLock { $0.lastCPUFrameMs } }
    var framesInFlight: Int { lock.withLock { $0.framesInFlight } }

    /// True when the main renderer is over budget (CPU frame > 16.7 ms) or three frames are queued.
    var isBehind: Bool {
        lock.withLock { $0.lastCPUFrameMs > 16.7 || $0.framesInFlight >= 3 }
    }

    func recordInterval(seconds: Double) {
        guard seconds > 0 else { return }
        lock.withLock { s in
            let instantaneous = 1 / seconds
            s.fps = s.fps == 0 ? instantaneous : s.fps * 0.9 + instantaneous * 0.1
            s.lastInterval = seconds
        }
    }

    func recordCPUFrame(ms: Double) {
        lock.withLock { $0.lastCPUFrameMs = ms }
    }

    func frameScheduled() {
        lock.withLock { $0.framesInFlight += 1 }
    }

    func frameCompleted() {
        lock.withLock { $0.framesInFlight = max(0, $0.framesInFlight - 1) }
    }
}
