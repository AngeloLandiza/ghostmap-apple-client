import Foundation

/// User-adjustable capture and display options, persisted in UserDefaults.
struct CaptureSettings: Sendable, Equatable {
    var highConfidenceOnly = false
    var showLivePoints = true
    var showGlobalCloudInMainView = true
    var ghostAutoOrbit = false

    /// Depth confidence gate used for the global cloud (0 low, 1 medium, 2 high).
    var minConfidence: UInt8 { highConfidenceOnly ? 2 : 1 }

    private static let key = "tech.alandiza.roommapper.captureSettings"

    static func load(defaults: UserDefaults = .standard) -> CaptureSettings {
        guard let d = defaults.dictionary(forKey: key) else { return CaptureSettings() }
        var s = CaptureSettings()
        s.highConfidenceOnly = d["highConfidenceOnly"] as? Bool ?? s.highConfidenceOnly
        s.showLivePoints = d["showLivePoints"] as? Bool ?? s.showLivePoints
        s.showGlobalCloudInMainView = d["showGlobalCloudInMainView"] as? Bool ?? s.showGlobalCloudInMainView
        s.ghostAutoOrbit = d["ghostAutoOrbit"] as? Bool ?? s.ghostAutoOrbit
        return s
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set([
            "highConfidenceOnly": highConfidenceOnly,
            "showLivePoints": showLivePoints,
            "showGlobalCloudInMainView": showGlobalCloudInMainView,
            "ghostAutoOrbit": ghostAutoOrbit,
        ], forKey: CaptureSettings.key)
    }
}
