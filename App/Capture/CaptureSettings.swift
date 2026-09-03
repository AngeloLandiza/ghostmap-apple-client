import Foundation
import MapCore

/// Performance ↔ quality preset. Drives voxel size, keyframe density, sample stride, carve rate and draw budgets.
enum QualityPreset: String, CaseIterable, Sendable {
    case performance
    case balanced
    case quality

    var label: String {
        switch self {
        case .performance: return "Performance (3 cm, fast)"
        case .balanced: return "Balanced (2 cm)"
        case .quality: return "Quality (1 cm, dense)"
        }
    }
}

/// How aggressively the map removes geometry that is no longer observed.
enum DynamicSensitivity: String, CaseIterable, Sendable {
    case conservative
    case normal
    case aggressive

    var label: String {
        switch self {
        case .conservative: return "Conservative (keeps more)"
        case .normal: return "Normal"
        case .aggressive: return "Aggressive (clears fast)"
        }
    }
}

/// User-adjustable capture and display options, persisted in UserDefaults.
struct CaptureSettings: Sendable, Equatable {
    var highConfidenceOnly = false
    var showLivePoints = true
    var showGlobalCloudInMainView = true
    var ghostAutoOrbit = false
    var quality: QualityPreset = .balanced
    var dynamicSensitivity: DynamicSensitivity = .normal
    /// 4K color capture at 30 fps instead of 1920×1440 at 60 fps.
    var highResolutionColor = false

    /// Depth confidence gate used for the global cloud (0 low, 1 medium, 2 high).
    var minConfidence: UInt8 { highConfidenceOnly ? 2 : 1 }

    var highResolution: Bool { quality == .quality }

    var mapConfig: DynamicVoxelMap.Config {
        var c = DynamicVoxelMap.Config()
        switch quality {
        case .performance:
            c.cellSize = 0.03
            c.coarsenedCellSize = 0.045
            c.maxPoints = 1_500_000
            c.maxFusionWeight = 12
        case .balanced:
            break
        case .quality:
            c.cellSize = 0.01
            c.coarsenedCellSize = 0.02
            c.maxFusionWeight = 8
        }
        switch dynamicSensitivity {
        case .conservative:
            c.missDecrement = 2
            c.mediumMissDecrement = 1
            c.unmeasuredMissDecrement = 0
            c.deathThreshold = -8
            c.maxUnconfirmedAge = 48
        case .normal:
            break
        case .aggressive:
            c.missDecrement = 6
            c.mediumMissDecrement = 4
            c.unmeasuredMissDecrement = 2
            c.deathThreshold = -2
            c.maxOccupancy = 8
            c.maxUnconfirmedAge = 12
        }
        return c
    }

    var policyConfig: KeyframePolicy.Config {
        var c = KeyframePolicy.Config.default
        switch quality {
        case .performance:
            c.translationThresholdMeters = 0.20
            c.rotationThresholdDegrees = 15
            c.maxInterval = 1.0
        case .balanced:
            break
        case .quality:
            c.translationThresholdMeters = 0.10
            c.rotationThresholdDegrees = 8
            c.maxInterval = 0.5
        }
        return c
    }

    /// Sample every Nth depth pixel in u and v when unprojecting keyframes.
    var unprojectionStride: Int { quality == .performance ? 2 : 1 }

    /// Seconds between depth-only carve frames while no keyframe is emitted.
    var carveInterval: TimeInterval {
        switch quality {
        case .performance: return 0.5
        case .balanced: return 0.25
        case .quality: return 0.2
        }
    }

    var mainViewMaxPoints: Int {
        switch quality {
        case .performance: return 400_000
        case .balanced: return 1_000_000
        case .quality: return 1_500_000
        }
    }

    var ghostMaxPoints: Int {
        switch quality {
        case .performance: return 150_000
        case .balanced: return 250_000
        case .quality: return 400_000
        }
    }

    private static let key = "tech.alandiza.roommapper.captureSettings"

    static func load(defaults: UserDefaults = .standard) -> CaptureSettings {
        guard let d = defaults.dictionary(forKey: key) else { return CaptureSettings() }
        var s = CaptureSettings()
        s.highConfidenceOnly = d["highConfidenceOnly"] as? Bool ?? s.highConfidenceOnly
        s.showLivePoints = d["showLivePoints"] as? Bool ?? s.showLivePoints
        s.showGlobalCloudInMainView = d["showGlobalCloudInMainView"] as? Bool ?? s.showGlobalCloudInMainView
        s.ghostAutoOrbit = d["ghostAutoOrbit"] as? Bool ?? s.ghostAutoOrbit
        s.highResolutionColor = d["highResolutionColor"] as? Bool ?? s.highResolutionColor
        if let q = d["quality"] as? String, let preset = QualityPreset(rawValue: q) { s.quality = preset }
        else if d["highResolution"] as? Bool == true { s.quality = .quality }
        if let ds = d["dynamicSensitivity"] as? String, let v = DynamicSensitivity(rawValue: ds) { s.dynamicSensitivity = v }
        return s
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set([
            "highConfidenceOnly": highConfidenceOnly,
            "showLivePoints": showLivePoints,
            "showGlobalCloudInMainView": showGlobalCloudInMainView,
            "ghostAutoOrbit": ghostAutoOrbit,
            "highResolutionColor": highResolutionColor,
            "quality": quality.rawValue,
            "dynamicSensitivity": dynamicSensitivity.rawValue,
        ], forKey: CaptureSettings.key)
    }
}
