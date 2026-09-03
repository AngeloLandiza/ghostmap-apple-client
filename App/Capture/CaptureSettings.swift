import Foundation
import MapCore

/// User-adjustable capture and display options, persisted in UserDefaults.
struct CaptureSettings: Sendable, Equatable {
    var highConfidenceOnly = false
    var showLivePoints = true
    var showGlobalCloudInMainView = true
    var ghostAutoOrbit = false
    /// 1 cm voxels and denser keyframes (0.10 m / 8° / 0.5 s).
    var highResolution = false
    /// 4K color capture at 30 fps instead of 1920×1440 at 60 fps.
    var highResolutionColor = false

    /// Depth confidence gate used for the global cloud (0 low, 1 medium, 2 high).
    var minConfidence: UInt8 { highConfidenceOnly ? 2 : 1 }

    var mapConfig: DynamicVoxelMap.Config { highResolution ? .highResolution : .default }

    var policyConfig: KeyframePolicy.Config {
        var c = KeyframePolicy.Config.default
        if highResolution {
            c.translationThresholdMeters = 0.10
            c.rotationThresholdDegrees = 8
            c.maxInterval = 0.5
        }
        return c
    }

    private static let key = "tech.alandiza.roommapper.captureSettings"

    static func load(defaults: UserDefaults = .standard) -> CaptureSettings {
        guard let d = defaults.dictionary(forKey: key) else { return CaptureSettings() }
        var s = CaptureSettings()
        s.highConfidenceOnly = d["highConfidenceOnly"] as? Bool ?? s.highConfidenceOnly
        s.showLivePoints = d["showLivePoints"] as? Bool ?? s.showLivePoints
        s.showGlobalCloudInMainView = d["showGlobalCloudInMainView"] as? Bool ?? s.showGlobalCloudInMainView
        s.ghostAutoOrbit = d["ghostAutoOrbit"] as? Bool ?? s.ghostAutoOrbit
        s.highResolution = d["highResolution"] as? Bool ?? s.highResolution
        s.highResolutionColor = d["highResolutionColor"] as? Bool ?? s.highResolutionColor
        return s
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set([
            "highConfidenceOnly": highConfidenceOnly,
            "showLivePoints": showLivePoints,
            "showGlobalCloudInMainView": showGlobalCloudInMainView,
            "ghostAutoOrbit": ghostAutoOrbit,
            "highResolution": highResolution,
            "highResolutionColor": highResolutionColor,
        ], forKey: CaptureSettings.key)
    }
}
