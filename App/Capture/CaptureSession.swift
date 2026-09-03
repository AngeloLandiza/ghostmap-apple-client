import ARKit
import Foundation
import MapCore
import Observation
import UIKit
import os

enum DeviceInfo {
    /// Hardware identifier such as "iPhone17,2".
    @MainActor static var model: String {
        var sys = utsname()
        uname(&sys)
        let id = withUnsafeBytes(of: &sys.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return id.isEmpty ? UIDevice.current.model : id
    }

    static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

struct TimeoutError: Error {}

/// Waits at most `seconds` for `task` and then gives up.
///
/// A `withThrowingTaskGroup` race cannot do this: the group awaits every child before rethrowing, so a
/// child parked in a continuation that ignores cancellation (ARKit's `getCurrentWorldMap`) makes the
/// "timeout" wait for the full operation anyway. Here the caller is resumed by whichever of the task
/// and the timer finishes first; the loser is abandoned and its result dropped.
func withDeadline<T: Sendable>(seconds: Double, awaiting task: Task<T, Error>) async throws -> T {
    let resumed = OSAllocatedUnfairLock(initialState: false)
    return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            let first = resumed.withLock { (done: inout Bool) -> Bool in
                if done { return false }
                done = true
                return true
            }
            if first { c.resume(throwing: TimeoutError()) }
        }
        Task {
            let result = await task.result
            timer.cancel()
            let first = resumed.withLock { (done: inout Bool) -> Bool in
                if done { return false }
                done = true
                return true
            }
            if first { c.resume(with: result) }
        }
    }
}

/// Orchestrates one capture: preview → recording → finalize → saved. Owns the AR controller, the GPU
/// buffers, both renderers, the keyframe processor and the storage queue, and drives the status strip.
@Observable
@MainActor
final class CaptureSession {
    enum Phase: Equatable {
        case idle
        case preview
        case recording
        case finalizing
        case saved
        case failed(String)
    }

    enum FinalizeStep: String, CaseIterable, Sendable {
        case stoppingIntake = "Stopping capture"
        case worldMap = "Saving ARKit world map"
        case writingCloud = "Writing point cloud"
        case thumbnail = "Rendering thumbnail"
        case syncingLog = "Syncing keyframe log"
        case manifest = "Writing manifest"
    }

    /// Deadline for the ARKit world map during finalize; keeps the whole finalize inside its 5 s budget.
    static let worldMapDeadline: Double = 3
    /// Seconds without normal tracking after an interruption before the strip warns the user.
    static let relocalizationWarningSeconds: TimeInterval = 10

    let env: AppEnvironment
    let controller: ARSessionController
    let pointBuffer: SharedPointBuffer
    let trajectory: TrajectoryBuffer
    let clock = RenderClock()
    let mainRenderer: MetalRenderer
    let ghostRenderer: GhostMapRenderer
    let status = StatusModel()

    private(set) var phase: Phase = .idle
    private(set) var finalizeStep: FinalizeStep?
    private(set) var finalizeProgress: Double = 0
    private(set) var manifest: MapManifest?
    private(set) var savedMapID: MapID?
    private(set) var cloudStats = CloudStats()
    private(set) var droppedKeyframes = 0
    private(set) var ghostExpanded = false

    private var processor: KeyframeProcessor?
    private var storage: StorageQueue?
    private var logger: SessionLogger
    private var recordingStart: Date?
    private var recordingEnd: Date?
    private var statusTask: Task<Void, Never>?
    private var inFlightKeyframes = 0
    private var logStatus = StorageQueue.Status(records: 0, bytes: 0, errors: 0)
    private var northSet = false
    /// Set synchronously before `startRecording`'s first `await` so a second tap cannot create a
    /// second map while the storage queue is still opening.
    private var isStarting = false

    var settings: CaptureSettings {
        didSet { applySettings(previous: oldValue) }
    }

    init(env: AppEnvironment) throws {
        self.env = env
        self.settings = env.settings
        let base = SessionLogger(fileURL: nil)
        self.logger = base
        self.pointBuffer = try SharedPointBuffer(device: env.context.device, capacity: VoxelGrid.Config.default.maxPoints)
        self.trajectory = try TrajectoryBuffer(device: env.context.device)
        let controller = ARSessionController(context: env.context, logger: base)
        self.controller = controller
        self.mainRenderer = try MetalRenderer(context: env.context, pipeline: env.pipeline, controller: controller,
                                              pointBuffer: pointBuffer, clock: clock, settings: env.settings)
        self.ghostRenderer = try GhostMapRenderer(context: env.context, pipeline: env.pipeline, pointBuffer: pointBuffer,
                                                  trajectory: trajectory, clock: clock)
        ghostRenderer.camera.autoOrbit = env.settings.ghostAutoOrbit
        if env.settings.ghostAutoOrbit { ghostRenderer.camera.mode = .orbit }
        ghostRenderer.cameraTransformProvider = { [weak controller] in controller?.latestCameraTransform }
        controller.onKeyframe = { [weak self] snapshot in self?.handleKeyframe(snapshot) }
        controller.canAcceptKeyframe = { [weak self] in (self?.inFlightKeyframes ?? 2) < 2 }
        env.thermal.onChange = { [weak self] old, new in self?.thermalChanged(from: old, to: new) }
    }

    // MARK: Lifecycle

    func startPreview() {
        guard phase == .idle else { return }
        controller.policy.mode = ThermalMonitor.policyMode(for: env.thermal.state)
        controller.start(highResolutionColor: settings.highResolutionColor)
        phase = .preview
        startStatusLoop()
    }

    func teardown() {
        statusTask?.cancel()
        statusTask = nil
        controller.pause()
        env.thermal.onChange = nil
    }

    var canStart: Bool { phase == .preview || phase == .saved || { if case .failed = phase { return true } else { return false } }() }
    var isRecording: Bool { phase == .recording }
    var isFinalizing: Bool { phase == .finalizing }

    func startRecording() async {
        guard canStart, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        let id = MapID()
        let now = Date()
        let manifest = MapManifest(
            mapID: id,
            name: MapManifest.defaultName(for: now),
            createdAt: now,
            deviceModel: DeviceInfo.model,
            iosVersion: UIDevice.current.systemVersion,
            appVersion: DeviceInfo.appVersion,
            status: .recording,
            voxelSizeMeters: settings.mapConfig.cellSize)
        do {
            _ = try env.store.create(manifest: manifest)
            let log = SessionLogger(fileURL: env.store.url(for: .sessionLog, in: id))
            logger = log
            controller.logger = log
            let storage = StorageQueue(logger: log)
            try await storage.open(url: env.store.url(for: .keyframeLog, in: id))
            self.storage = storage
            pointBuffer.removeAll()
            trajectory.removeAll()
            processor = KeyframeProcessor(pointBuffer: pointBuffer, trajectory: trajectory, storage: storage,
                                          logger: log, mapConfig: settings.mapConfig, minConfidence: settings.minConfidence,
                                          unprojectionStride: settings.unprojectionStride)
            controller.policy.config = settings.policyConfig
            controller.carveInterval = settings.carveInterval
            mainRenderer.maxCloudPoints = settings.mainViewMaxPoints
            ghostRenderer.maxPoints = ghostExpanded ? settings.ghostMaxPoints * 4 : settings.ghostMaxPoints
            cloudStats = CloudStats()
            droppedKeyframes = 0
            inFlightKeyframes = 0
            logStatus = StorageQueue.Status(records: 0, bytes: 0, errors: 0)
            self.manifest = manifest
            savedMapID = nil
            recordingStart = now
            recordingEnd = nil
            if let forward = controller.initialForward {
                ghostRenderer.camera.setNorth(fromForward: forward)
                northSet = true
            }
            controller.policy.mode = ThermalMonitor.policyMode(for: env.thermal.state)
            controller.setIntake(true)
            phase = .recording
            let c = controller.policy.config
            log.log(.app, "recording started map=\(id) name=\"\(manifest.name)\" device=\(manifest.deviceModel) ios=\(manifest.iosVersion) app=\(manifest.appVersion) videoFormat=\(controller.videoFormatDescription) thermal=\(ThermalMonitor.label(for: env.thermal.state)) policyMode=\(controller.policy.mode) minConfidence=\(settings.minConfidence) thresholds=\(c.translationThresholdMeters)m/\(c.rotationThresholdDegrees)deg/\(c.maxInterval)s voxel=\(settings.mapConfig.cellSize)m cap=\(settings.mapConfig.maxPoints) quality=\(settings.quality.rawValue) dynamics=\(settings.dynamicSensitivity.rawValue) stride=\(settings.unprojectionStride) carveInterval=\(settings.carveInterval)")
        } catch {
            phase = .failed("Could not start recording: \(error)")
            logger.log(.app, "recording start failed: \(error)", level: .error)
        }
    }

    private func handleKeyframe(_ snapshot: KeyframeSnapshot) {
        guard phase == .recording, let processor else { return }
        guard inFlightKeyframes < 2 else {
            if !snapshot.isCarveOnly { droppedKeyframes += 1 }
            return
        }
        inFlightKeyframes += 1
        ghostRenderer.setDepthIntrinsics(snapshot.intrinsics)
        // Explicit priority: the task is created inside the AR callback on the main thread, so without
        // it the actor work would inherit user-interactive QoS and fight the 60 fps render loop.
        Task(priority: .utility) { [weak self] in
            let stats = await processor.process(snapshot)
            guard let self else { return }
            self.cloudStats = stats
            self.inFlightKeyframes -= 1
        }
    }

    func stopRecording() async {
        guard phase == .recording, var manifest, let storage, let processor else { return }
        let t0 = Date()
        recordingEnd = t0
        phase = .finalizing
        let id = manifest.mapID
        let store = env.store
        logger.log(.app, "finalize started")
        manifest.status = .finalizing
        try? store.saveManifest(manifest)
        self.manifest = manifest
        do {
            setStep(.stoppingIntake, 0.05)
            controller.setIntake(false)
            var waited = 0
            while inFlightKeyframes > 0 && waited < 150 {
                try await Task.sleep(for: .milliseconds(20))
                waited += 1
            }
            let stats = await processor.stats
            cloudStats = stats

            setStep(.worldMap, 0.15)
            var hasWorldMap = false
            if controller.worldMappingStatus == .mapped {
                let controller = self.controller
                let worldMapURL = store.url(for: .worldMap, in: id)
                // Request, archive and write off the main actor; the deadline is real (the finalize
                // continues without the map) and a map that arrives late is dropped, not written.
                let abandoned = OSAllocatedUnfairLock(initialState: false)
                let request = Task.detached(priority: .userInitiated) { () async throws -> Int in
                    let box = try await controller.currentWorldMap()
                    let data = try NSKeyedArchiver.archivedData(withRootObject: box.map, requiringSecureCoding: true)
                    guard !abandoned.withLock({ $0 }) else { throw TimeoutError() }
                    try data.write(to: worldMapURL, options: .atomic)
                    return data.count
                }
                do {
                    let bytes = try await withDeadline(seconds: CaptureSession.worldMapDeadline, awaiting: request)
                    hasWorldMap = true
                    logger.log(.storage, "worldmap.arworldmap saved (\(bytes) bytes)")
                } catch {
                    abandoned.withLock { $0 = true }
                    logger.log(.storage, "world map skipped: \(error)", level: .default)
                }
            } else {
                logger.log(.storage, "world map skipped: mapping status is \(controller.worldMappingStatus.label)")
            }

            setStep(.writingCloud, 0.35)
            let plyURL = store.url(for: .cloud, in: id)
            let buffer = pointBuffer
            let comments = ["RoomMapper map \(id.rawValue)", "frame world:session-start", "voxel \(stats.cellSize) m"]
            let plyStart = Date()
            try await Task.detached(priority: .userInitiated) {
                try buffer.withPoints { try PLYWriter.write(points: $0, to: plyURL, comments: comments) }
            }.value
            logger.log(.storage, "cloud.ply written: \(stats.points) points in \(String(format: "%.2f", Date().timeIntervalSince(plyStart))) s")

            setStep(.thumbnail, 0.65)
            if let image = ghostRenderer.renderThumbnail(size: 512), let png = UIImage(cgImage: image).pngData() {
                try png.write(to: store.url(for: .thumbnail, in: id), options: .atomic)
            } else {
                logger.log(.render, "thumbnail render failed", level: .error)
            }

            setStep(.syncingLog, 0.8)
            let finalLog = try await storage.finish()
            logStatus = finalLog

            setStep(.manifest, 0.92)
            manifest.status = .saved
            manifest.pointCount = stats.points
            manifest.keyframeCount = finalLog.records
            manifest.bbox = stats.bounds.isEmpty ? nil : stats.bounds
            manifest.durationSeconds = t0.timeIntervalSince(recordingStart ?? t0)
            manifest.hasWorldMap = hasWorldMap
            manifest.voxelSizeMeters = stats.cellSize
            manifest.finalizeSeconds = Date().timeIntervalSince(t0)
            manifest.sizeBytes = store.directorySize(id: id) + 2048
            try store.saveManifest(manifest)
            self.manifest = manifest
            savedMapID = id
            setStep(.manifest, 1)
            phase = .saved
            logger.log(.app, "finalize done in \(String(format: "%.2f", manifest.finalizeSeconds ?? 0)) s: points=\(manifest.pointCount) keyframes=\(manifest.keyframeCount) candidates=\(controller.keyframeCandidates) dropped=\(droppedKeyframes) logErrors=\(finalLog.errors) size=\(manifest.sizeBytes ?? 0)B duration=\(String(format: "%.1f", manifest.durationSeconds))s callbackP95=\(String(format: "%.2f", controller.callbackP95Ms))ms callbackMax=\(String(format: "%.2f", controller.callbackMaxMs))ms processMax=\(String(format: "%.1f", stats.maxProcessMs))ms grid=\(stats.gridState) memMB=\(rm_physical_footprint_bytes() / 1_048_576) worldMap=\(hasWorldMap)")
        } catch {
            // Flush and fsync the log before giving up: Rebuild reads exactly this file.
            logStatus = (try? await storage.finish()) ?? logStatus
            manifest.status = .failed
            manifest.keyframeCount = logStatus.records
            try? store.saveManifest(manifest)
            self.manifest = manifest
            phase = .failed("Finalize failed: \(error)")
            logger.log(.app, "finalize failed: \(error)", level: .error)
        }
        self.processor = nil
        self.storage = nil
        await logger.close()
        let base = SessionLogger(fileURL: nil)
        logger = base
        controller.logger = base
        finalizeStep = nil
    }

    private func setStep(_ step: FinalizeStep, _ progress: Double) {
        finalizeStep = step
        finalizeProgress = progress
        logger.log(.app, "finalize: \(step.rawValue)")
    }

    // MARK: Ghost map controls

    func setGhostExpanded(_ expanded: Bool) {
        ghostExpanded = expanded
        ghostRenderer.maxPoints = expanded ? settings.ghostMaxPoints * 4 : settings.ghostMaxPoints
        ghostRenderer.pointSizePx = expanded ? 4 : 3
        ghostRenderer.pointAlpha = expanded ? 0.8 : 0.55
        ghostRenderer.skipWhenMainIsBehind = !expanded
    }

    func toggleGhostMode() {
        let mode: GhostCamera.Mode = ghostRenderer.camera.mode == .topDown ? .orbit : .topDown
        ghostRenderer.camera.mode = mode
        if mode == .topDown, settings.ghostAutoOrbit { settings.ghostAutoOrbit = false }
    }

    func resetGhostView() {
        ghostRenderer.camera.resetView()
    }

    // MARK: Settings & thermal

    private func applySettings(previous: CaptureSettings) {
        if previous.highResolutionColor != settings.highResolutionColor, phase == .preview || phase == .saved {
            controller.start(highResolutionColor: settings.highResolutionColor)
        }
        mainRenderer.settings = settings
        mainRenderer.maxCloudPoints = settings.mainViewMaxPoints
        ghostRenderer.maxPoints = ghostExpanded ? settings.ghostMaxPoints * 4 : settings.ghostMaxPoints
        controller.carveInterval = settings.carveInterval
        ghostRenderer.camera.autoOrbit = settings.ghostAutoOrbit
        // The toggle only rotates in orbit mode, so it selects the mode too (long-press still overrides).
        if settings.ghostAutoOrbit {
            ghostRenderer.camera.mode = .orbit
        } else if ghostRenderer.camera.mode == .orbit {
            ghostRenderer.camera.mode = .topDown
        }
        env.settings = settings
        if let processor {
            let c = settings.minConfidence
            Task { await processor.setMinConfidence(c) }
        }
    }

    private func thermalChanged(from old: ProcessInfo.ThermalState, to new: ProcessInfo.ThermalState) {
        let mode = ThermalMonitor.policyMode(for: new)
        controller.policy.mode = mode
        logger.log(.thermal, "thermal: \(ThermalMonitor.label(for: old)) → \(ThermalMonitor.label(for: new)); keyframe policy mode = \(mode)", level: .default)
    }

    // MARK: Status loop (5 Hz)

    private func startStatusLoop() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                await self.refreshStatus()
            }
        }
    }

    private func refreshStatus() async {
        if let storage { logStatus = await storage.status() }
        if !northSet, let forward = controller.initialForward {
            ghostRenderer.camera.setNorth(fromForward: forward)
            northSet = true
        }
        var s = status.snapshot
        s.tracking = controller.tracking
        s.worldMapping = controller.worldMappingStatus.label
        s.keyframes = cloudStats.keyframes
        s.points = pointBuffer.count
        // Quantized to the displayed resolution so the Equatable check below can actually short-circuit
        // and the strip does not re-lay out 5×/s while nothing visible changes.
        s.elapsed = (recordingStart.map { (recordingEnd ?? Date()).timeIntervalSince($0) } ?? 0).rounded(.down)
        s.logBytes = logStatus.bytes
        s.estimatedDiskBytes = logStatus.bytes + Int64(s.points) * 15 + 200_000
        s.thermal = env.thermal.state
        s.policyMode = controller.policy.mode
        s.fps = (clock.fps * 10).rounded() / 10
        s.ghostFPS = (ghostRenderer.fps * 10).rounded() / 10
        s.callbackP95Ms = (controller.callbackP95Ms * 100).rounded() / 100
        s.callbackMaxMs = (controller.callbackMaxMs * 100).rounded() / 100
        s.processMs = (cloudStats.lastProcessMs * 10).rounded() / 10
        s.memoryMB = (Double(rm_physical_footprint_bytes()) / 1_048_576).rounded()
        s.gridState = cloudStats.gridState
        s.isRecording = phase == .recording
        s.videoFormat = controller.videoFormatDescription
        s.warning = warning(for: s)
        if s != status.snapshot { status.snapshot = s }
    }

    private func warning(for s: StatusSnapshot) -> String? {
        switch s.thermal {
        case .critical: return "Thermal critical — keyframes paused"
        case .serious: return "Thermal serious — keyframe rate halved"
        default: break
        }
        if let error = controller.lastError { return "AR session error: \(error)" }
        if let seconds = controller.relocalizingSeconds, seconds > CaptureSession.relocalizationWarningSeconds {
            return "Relocalizing after an interruption (\(Int(seconds)) s) — return to an already scanned area"
        }
        if s.gridState == .full { return "Cloud full (\(Format.count(VoxelGrid.Config.default.maxPoints))) — new points ignored" }
        if let since = controller.trackingLimitedSince, !s.tracking.isNormal {
            let t = Date().timeIntervalSince(since)
            if t > 5 { return "Tracking \(s.tracking.label) for \(Int(t)) s" }
        }
        if logStatus.errors > 0 { return "Keyframe log write errors: \(logStatus.errors)" }
        if s.gridState == .coarsened { return "Cloud coarsened to \(Int((cloudStats.cellSize * 100).rounded())) cm" }
        return nil
    }
}
