import Foundation
import MapCore

/// Observes `ProcessInfo.thermalState` and maps it to the keyframe policy mode.
@MainActor
final class ThermalMonitor {
    private(set) var state: ProcessInfo.ThermalState
    var onChange: ((ProcessInfo.ThermalState, ProcessInfo.ThermalState) -> Void)?
    // nonisolated(unsafe): only written in init and read in deinit; never touched concurrently.
    nonisolated(unsafe) private var token: NSObjectProtocol?

    init() {
        state = ProcessInfo.processInfo.thermalState
        token = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let new = ProcessInfo.processInfo.thermalState
                let old = self.state
                guard new != old else { return }
                self.state = new
                self.onChange?(old, new)
            }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    /// Product rule: `.serious` halves the keyframe rate, `.critical` pauses keyframe processing.
    nonisolated static func policyMode(for state: ProcessInfo.ThermalState) -> KeyframePolicy.Mode {
        switch state {
        case .nominal, .fair: return .normal
        case .serious: return .halved
        case .critical: return .paused
        @unknown default: return .halved
        }
    }

    nonisolated static func label(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
