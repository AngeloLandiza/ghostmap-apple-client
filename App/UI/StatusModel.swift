import Foundation
import MapCore
import Observation

/// Everything the Ghost Map status strip shows. Updated at 5 Hz by `CaptureSession`.
struct StatusSnapshot: Sendable, Equatable {
    var tracking: TrackingState = .notAvailable
    var worldMapping = "not available"
    var keyframes = 0
    var points = 0
    var elapsed: TimeInterval = 0
    var estimatedDiskBytes: Int64 = 0
    var logBytes: Int64 = 0
    var thermal: ProcessInfo.ThermalState = .nominal
    var policyMode: KeyframePolicy.Mode = .normal
    var fps: Double = 0
    var ghostFPS: Double = 0
    var callbackP95Ms: Double = 0
    var callbackMaxMs: Double = 0
    var processMs: Double = 0
    var memoryMB: Double = 0
    var gridState: VoxelGrid.State = .accepting
    var isRecording = false
    var warning: String?
    var videoFormat = ""
}

/// Observable holder so SwiftUI redraws the strip only when the snapshot changes.
@Observable
@MainActor
final class StatusModel {
    var snapshot = StatusSnapshot()
}

enum Format {
    static func count(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    static func bytes(_ b: Int64) -> String {
        let d = Double(b)
        if d >= 1_073_741_824 { return String(format: "%.2f GB", d / 1_073_741_824) }
        if d >= 1_048_576 { return String(format: "%.1f MB", d / 1_048_576) }
        if d >= 1024 { return String(format: "%.0f KB", d / 1024) }
        return "\(b) B"
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
