import ARKit
import CoreVideo
import MapCore
import Metal
import simd
import UIKit

/// Per-frame GPU-side data handed from the AR callback to the main renderer. Main-actor only; not
/// Sendable because it holds `CVMetalTexture` references that keep the pixel buffers alive.
struct FrameTextures {
    let y: MTLTexture
    let cbcr: MTLTexture
    let depth: MTLTexture
    let confidence: MTLTexture
    let refs: [CVMetalTexture]
    let cameraToWorld: simd_float4x4
    let viewProjection: simd_float4x4
    /// Normalized view coordinates → normalized image coordinates (inverse of `displayTransform`).
    let displayToImage: simd_float3x3
    let intrinsicsInverse: simd_float3x3
    let depthWidth: Int
    let depthHeight: Int
    let timestamp: TimeInterval
}

/// Fixed-size ring of durations (milliseconds) for p95 / max reporting.
struct DurationRing: Sendable {
    private var values: [Double]
    private var index = 0
    private(set) var filled = 0

    init(capacity: Int) {
        values = Array(repeating: 0, count: max(capacity, 1))
    }

    mutating func push(_ v: Double) {
        values[index] = v
        index = (index + 1) % values.count
        filled = min(filled + 1, values.count)
    }

    func percentile(_ p: Double) -> Double {
        guard filled > 0 else { return 0 }
        let sorted = values[0..<filled].sorted()
        let i = min(filled - 1, max(0, Int(Double(filled - 1) * p)))
        return sorted[i]
    }

    var maximum: Double { filled > 0 ? (values[0..<filled].max() ?? 0) : 0 }

    mutating func reset() {
        index = 0
        filled = 0
    }
}

extension TrackingState {
    init(_ state: ARCamera.TrackingState) {
        switch state {
        case .normal:
            self = .normal
        case .notAvailable:
            self = .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing: self = .limited(.initializing)
            case .excessiveMotion: self = .limited(.excessiveMotion)
            case .insufficientFeatures: self = .limited(.insufficientFeatures)
            case .relocalizing: self = .limited(.relocalizing)
            @unknown default: self = .limited(.unknown)
            }
        }
    }
}

extension ARFrame.WorldMappingStatus {
    var label: String {
        switch self {
        case .notAvailable: return "not available"
        case .limited: return "limited"
        case .extending: return "extending"
        case .mapped: return "mapped"
        @unknown default: return "unknown"
        }
    }
}

/// Owns the `ARSession`, runs the keyframe policy inside the delegate callback, publishes per-frame
/// textures for the renderer and hands keyframe snapshots to the processor. Everything is on the main
/// actor: the session delivers callbacks on the main queue and the delegate methods hop in with
/// `MainActor.assumeIsolated`.
@MainActor
final class ARSessionController: NSObject, ARSessionDelegate {
    nonisolated static var isSupported: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    let session = ARSession()
    let context: MetalContext
    var logger: SessionLogger
    var policy = KeyframePolicy()
    /// Drawable size of the main Metal view in pixels; set by the renderer.
    var viewportSize = CGSize.zero
    var onKeyframe: ((KeyframeSnapshot) -> Void)?
    var onTrackingChange: ((TrackingState, TrackingState) -> Void)?
    /// Back-pressure gate: when it returns false the frame is skipped *before* the policy commits its
    /// state, so no keyframe candidate is lost and the extraction copy is not paid for a dropped frame.
    var canAcceptKeyframe: (() -> Bool)?
    /// True while a recording is active (mirrors `isIntakeEnabled`). ARKit then relocalizes into the
    /// same world frame after an interruption instead of resuming with a new origin.
    private(set) var shouldRelocalize = false

    private(set) var latestFrame: FrameTextures?
    private(set) var tracking: TrackingState = .notAvailable
    private(set) var worldMappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    private(set) var isIntakeEnabled = false
    private(set) var isRunning = false
    private(set) var frameCount = 0
    private(set) var keyframeCandidates = 0
    private(set) var firstFrameTimestamp: TimeInterval?
    private(set) var initialForward: SIMD3<Float>?
    private(set) var latestCameraTransform: simd_float4x4?
    private(set) var latestDepthIntrinsics: Intrinsics?
    private(set) var videoFormatDescription = "default"
    private(set) var lastError: String?
    private(set) var trackingLimitedSince: Date?
    /// Set when an interruption ends while a recording is active; cleared once tracking is `.normal`
    /// again (i.e. ARKit relocalized into the pre-interruption frame).
    private(set) var relocalizingSince: Date?
    private(set) var interruptionCount = 0
    private var durations = DurationRing(capacity: 600)

    init(context: MetalContext, logger: SessionLogger) {
        self.context = context
        self.logger = logger
        super.init()
        session.delegate = self
        session.delegateQueue = nil // main queue
    }

    var callbackP95Ms: Double { durations.percentile(0.95) }
    var callbackMaxMs: Double { durations.maximum }

    // MARK: Lifecycle

    /// Starts world tracking with scene depth. Safe to call again to reset tracking.
    func start(highResolutionColor: Bool = false) {
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        config.worldAlignment = .gravity
        config.planeDetection = []
        config.sceneReconstruction = []   // v1 feature flag: meshes are out of scope
        config.environmentTexturing = .none
        config.isAutoFocusEnabled = true
        config.isLightEstimationEnabled = false
        if highResolutionColor, let format = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
            config.videoFormat = format
            videoFormatDescription = ARSessionController.describe(format) + " 4K"
        } else if let format = ARSessionController.chooseVideoFormat() {
            config.videoFormat = format
            videoFormatDescription = ARSessionController.describe(format)
        }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        firstFrameTimestamp = nil
        initialForward = nil
        durations.reset()
        logger.log(.capture, "AR session started: videoFormat=\(videoFormatDescription) semantics=sceneDepth alignment=gravity")
    }

    func pause() {
        guard isRunning else { return }
        session.pause()
        isRunning = false
        latestFrame = nil
        logger.log(.capture, "AR session paused after \(frameCount) frames; callback p95=\(String(format: "%.2f", callbackP95Ms)) ms max=\(String(format: "%.2f", callbackMaxMs)) ms")
    }

    /// Enables or disables keyframe emission. Enabling resets the policy so the first frame is a keyframe.
    func setIntake(_ enabled: Bool) {
        isIntakeEnabled = enabled
        shouldRelocalize = enabled
        if enabled {
            policy.reset()
            keyframeCandidates = 0
            interruptionCount = 0
            relocalizingSince = nil
        }
    }

    struct WorldMapBox: @unchecked Sendable {
        // Invariant: the box is produced on the main queue and consumed once by the awaiting task.
        let map: ARWorldMap
    }

    /// Best-effort `ARWorldMap` capture. Callers should check `worldMappingStatus == .mapped` first.
    func currentWorldMap() async throws -> WorldMapBox {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<WorldMapBox, Error>) in
            session.getCurrentWorldMap { map, error in
                if let map {
                    c.resume(returning: WorldMapBox(map: map))
                } else {
                    c.resume(throwing: error ?? MapError.io("world map unavailable"))
                }
            }
        }
    }

    // MARK: Video format

    /// Smallest 4:3 format with width ≥ 1280 at ≥ 30 fps, preferring 60 fps at that size; falls back to any ≥ 30 fps format.
    nonisolated static func chooseVideoFormat() -> ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        func aspect(_ f: ARConfiguration.VideoFormat) -> Double { f.imageResolution.width / max(f.imageResolution.height, 1) }
        let fourByThree = formats.filter { $0.framesPerSecond >= 30 && $0.imageResolution.width >= 1280 && abs(aspect($0) - 4.0 / 3.0) < 0.05 }
        let pool = fourByThree.isEmpty ? formats.filter { $0.framesPerSecond >= 30 } : fourByThree
        let sorted = pool.sorted { a, b in
            if a.imageResolution.width != b.imageResolution.width { return a.imageResolution.width < b.imageResolution.width }
            return a.framesPerSecond > b.framesPerSecond
        }
        return sorted.first ?? formats.first
    }

    nonisolated static func describe(_ f: ARConfiguration.VideoFormat) -> String {
        "\(Int(f.imageResolution.width))x\(Int(f.imageResolution.height))@\(f.framesPerSecond)"
    }

    // MARK: ARSessionDelegate (main queue)

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { self.handle(frame) }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state = TrackingState(camera.trackingState)
        MainActor.assumeIsolated { self.updateTracking(state) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = String(describing: error)
        MainActor.assumeIsolated {
            self.lastError = message
            self.latestFrame = nil
            self.logger.log(.capture, "AR session failed: \(message)", level: .error)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated {
            self.interruptionCount += 1
            self.logger.log(.capture, "AR session interrupted (#\(self.interruptionCount)) at candidate \(self.keyframeCandidates); relocalization=\(self.shouldRelocalize)", level: .default)
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated {
            if self.shouldRelocalize, !self.tracking.isNormal {
                self.relocalizingSince = Date()
            }
            self.logger.log(.capture, "AR session interruption ended; tracking=\(self.tracking.label), waiting for relocalization=\(self.relocalizingSince != nil)", level: .default)
        }
    }

    /// Returning true while a recording is active makes ARKit relocalize into the *same* world frame
    /// after an interruption. Tracking goes `.limited(.relocalizing)` in the meantime and the keyframe
    /// policy's `.normal` gate holds intake until the old frame is recovered, so a map never mixes two
    /// world origins. Outside a recording the cheaper reset is fine.
    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        MainActor.assumeIsolated { self.shouldRelocalize }
    }

    /// Seconds spent relocalizing after an interruption, or nil when not relocalizing.
    var relocalizingSeconds: TimeInterval? {
        relocalizingSince.map { Date().timeIntervalSince($0) }
    }

    // MARK: Frame handling (≤ 2 ms budget)

    private func updateTracking(_ state: TrackingState) {
        guard state != tracking else { return }
        let old = tracking
        tracking = state
        if state.isNormal {
            trackingLimitedSince = nil
            if let since = relocalizingSince {
                logger.log(.capture, "relocalized into the recording's world frame after \(String(format: "%.1f", Date().timeIntervalSince(since))) s", level: .default)
                relocalizingSince = nil
            }
        } else {
            if trackingLimitedSince == nil { trackingLimitedSince = Date() }
            if shouldRelocalize, relocalizingSince == nil, state == .limited(.relocalizing) {
                relocalizingSince = Date()
            }
        }
        logger.log(.capture, "tracking: \(old.label) → \(state.label)")
        onTrackingChange?(old, state)
    }

    private func handle(_ frame: ARFrame) {
        let start = ContinuousClock.now
        defer {
            let d = ContinuousClock.now - start
            durations.push(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }

        frameCount += 1
        let camera = frame.camera
        updateTracking(TrackingState(camera.trackingState))
        worldMappingStatus = frame.worldMappingStatus
        latestCameraTransform = camera.transform
        if firstFrameTimestamp == nil { firstFrameTimestamp = frame.timestamp }
        if initialForward == nil, tracking.isNormal {
            let c2 = camera.transform.columns.2
            initialForward = -SIMD3<Float>(c2.x, c2.y, c2.z)
        }

        guard let sceneDepth = frame.sceneDepth, let confidenceMap = sceneDepth.confidenceMap else { return }
        let depthMap = sceneDepth.depthMap
        let dw = CVPixelBufferGetWidth(depthMap)
        let dh = CVPixelBufferGetHeight(depthMap)
        guard dw > 0, dh > 0 else { return }

        let k = camera.intrinsics
        let res = camera.imageResolution
        let full = Intrinsics(fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y,
                              width: Int(res.width), height: Int(res.height))
        let depthIntrinsics = full.scaled(toWidth: dw, height: dh)
        latestDepthIntrinsics = depthIntrinsics

        // Textures for the live preview: zero-copy through the texture cache.
        if viewportSize.width > 0, viewportSize.height > 0,
           let y = context.makeTexture(from: frame.capturedImage, plane: 0, pixelFormat: .r8Unorm),
           let cbcr = context.makeTexture(from: frame.capturedImage, plane: 1, pixelFormat: .rg8Unorm),
           let depth = context.makeTexture(from: depthMap, plane: 0, pixelFormat: .r32Float),
           let conf = context.makeTexture(from: confidenceMap, plane: 0, pixelFormat: .r8Uint) {
            let view = camera.viewMatrix(for: .portrait)
            let proj = camera.projectionMatrix(for: .portrait, viewportSize: viewportSize, zNear: 0.01, zFar: 50)
            let display = frame.displayTransform(for: .portrait, viewportSize: viewportSize).inverted()
            latestFrame = FrameTextures(
                y: y.texture, cbcr: cbcr.texture, depth: depth.texture, confidence: conf.texture,
                refs: [y.ref, cbcr.ref, depth.ref, conf.ref],
                cameraToWorld: camera.transform,
                viewProjection: proj * view,
                displayToImage: RenderMath.matrix(from: display),
                intrinsicsInverse: depthIntrinsics.inverseMatrix,
                depthWidth: dw, depthHeight: dh,
                timestamp: frame.timestamp)
        }

        // Keyframe policy (pure MapCore logic). Back-pressure is checked before `evaluate` so a frame
        // that could not be processed does not consume the policy's translation/rotation budget.
        guard isIntakeEnabled else { return }
        if let canAccept = canAcceptKeyframe, !canAccept() { return }
        let decision = policy.evaluate(pose: Pose(matrix: camera.transform), timestamp: frame.timestamp, tracking: tracking)
        if case .keyframe = decision {
            keyframeCandidates += 1
            if let snapshot = FrameExtractor.snapshot(from: frame, intrinsics: depthIntrinsics, tracking: tracking) {
                onKeyframe?(snapshot)
            } else {
                logger.log(.capture, "keyframe snapshot failed (unexpected pixel format)", level: .error)
            }
        }
    }
}
