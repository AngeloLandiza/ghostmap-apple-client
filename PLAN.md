# RoomMapper — Build Plan

Local-first iOS room mapper for iPhone 16 Pro Max (ARKit VIO + LiDAR). Single phone, every map stored on the phone, live status in a translucent Ghost Map panel. This is the standalone example of the iOS component in `swarm-mapping-mvp-plan.md` §6, with no backend, marker origin, collaboration, meshes, or third-party code.

## 0. Environment (discovered 2026-09-03)

| Item | Value |
|---|---|
| Xcode | 27.0 beta (27A5237l) at `/Applications/Xcode-beta.app`; `xcode-select` points at CLT, so every build uses `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` |
| Swift | 6.4 toolchain, Swift 6 language mode in both MapCore and App |
| iOS SDK | 27.0 |
| Device | iPhone 16 Pro Max (iPhone17,2), iOS 27.0 (24A5418b); CoreDevice id `E443E243-AC0B-5711-8C10-5579D6DCB366`; hardware UDID `00008140-001C75E83601801C` |
| Deployment target | iOS 18.0 (lower of 18.0 and device 27.0) |
| Team ID | `RZ5NX26K3B` (certificate OU); bundle id `tech.alandiza.roommapper` |
| Tooling | XcodeGen 2.46.0 → `RoomMapper.xcodeproj`; `swift test` on macOS for MapCore |
| Device state | Developer Mode **disabled** at discovery (must be enabled before T0) |

## 1. File tree

```
RoomMapper (repo root)
├── project.yml                         # XcodeGen; app target + local package dependency
├── PLAN.md  README.md  DECISIONS.md  FORMAT.md  TESTING.md
├── Packages/MapCore/                   # SwiftPM, Foundation/simd/Compression only; builds & tests on macOS
│   ├── Package.swift
│   ├── Sources/MapCore/
│   │   ├── Geometry/   Pose.swift  Intrinsics.swift  Unprojection.swift
│   │   ├── Keyframes/  TrackingState.swift  KeyframeRecord.swift  KeyframePolicy.swift
│   │   ├── Cloud/      PackedPoint.swift  PointCloud.swift  VoxelGrid.swift  Decimation.swift
│   │   ├── Codec/      DepthCodec.swift  PLYWriter.swift (writer + reader)  CRC32.swift
│   │   └── Storage/    MapError.swift  MapManifest.swift  KeyframeLog.swift  MapStore.swift  CloudRebuilder.swift
│   └── Tests/MapCoreTests/  one test file per source file above
├── App/
│   ├── RoomMapperApp.swift             # @main, root navigation, launch-time recovery of interrupted maps
│   ├── Capture/
│   │   ├── ARSessionController.swift   # @MainActor ARSessionDelegate; ≤2 ms callback; publishes FrameTextures + StatusModel
│   │   ├── FrameExtractor.swift        # copies depth/conf/Y/CbCr planes for keyframes into pooled buffers
│   │   ├── KeyframeProcessor.swift     # actor: unproject + color + VoxelGrid + SharedPointBuffer append + log write
│   │   ├── CaptureSession.swift        # orchestrates one recording: create map, start AR, stop/finalize with progress
│   │   ├── ThermalMonitor.swift        # ProcessInfo.thermalState → KeyframePolicy.Mode, logged
│   │   └── SessionLogger.swift         # session.log text writer (serial) + os.Logger categories
│   ├── Rendering/
│   │   ├── ShaderTypes.h               # shared C structs (bridging header + Metal)
│   │   ├── Shaders.metal               # camera quad, live depth points, global cloud points, lines
│   │   ├── MetalContext.swift          # device, queue, library, CVMetalTextureCache
│   │   ├── SharedPointBuffer.swift     # double-buffered MTLBuffer of PackedPoint, append/replace/snapshot, lock-protected
│   │   ├── TrajectoryBuffer.swift      # append-only MTLBuffer of keyframe positions
│   │   ├── PointCloudPipeline.swift    # pipeline states, depth stencil, sampler
│   │   ├── MetalRenderer.swift         # main MTKView delegate (60 fps): camera feed + live points + global cloud
│   │   ├── GhostMapRenderer.swift      # second MTKView delegate (≤30 fps): cloud (stride) + trajectory + frustum; offscreen thumbnail
│   │   └── OrbitCamera.swift           # top-down ortho / orbit camera math, auto-framing, gestures
│   ├── UI/
│   │   ├── MapListView.swift  CaptureView.swift  GhostMapView.swift  MapDetailView.swift
│   │   ├── StatusModel.swift           # @Observable @MainActor status snapshot (≥4 Hz)
│   │   ├── MetalViewRepresentable.swift
│   │   └── UnsupportedDeviceView.swift
│   └── Resources/Info.plist
```

## 2. Architecture

```
ARSession (main thread delegate)
   │  session(_:didUpdate:)  — copy pose/intrinsics/tracking; CVMetalTextureCache lookups (no copies);
   │  KeyframePolicy.evaluate (pure, <10 µs); on keyframe: memcpy depth+conf+Y+CbCr into pooled snapshot (~4 MB, <1 ms)
   ├──▶ MetalRenderer (main, 60 fps)  ← FrameTextures {Y, CbCr, depth, conf, camera matrices}
   ├──▶ StatusModel (main, throttled to 5 Hz)
   └──▶ KeyframeProcessor (actor)  ← KeyframeSnapshot
            ├─ Unprojector (MapCore): depth mm + intrinsics + pose → world positions (conf ≥ medium)
            ├─ YCbCr sampler → PackedPoint color
            ├─ VoxelGrid (MapCore): 2 cm dedupe, 3 M cap → coarsen once to 3 cm → full
            ├─ SharedPointBuffer.append (Metal shared storage; readers see count only after write)
            ├─ TrajectoryBuffer.append(pose.translation)
            └─ StorageQueue (serial): KeyframeLogWriter.append(record)   [depth u16mm+LZFSE, conf u8+LZFSE]
GhostMapRenderer (main, ≤30 fps, skips when main renderer is behind) ← SharedPointBuffer.snapshot(), TrajectoryBuffer, latest camera pose
Finalize: stop intake → getCurrentWorldMap (if .mapped) ‖ PLY from SharedPointBuffer → thumbnail (offscreen ghost render) → fsync log → manifest saved → session.pause()
```

Isolation: `ARSessionController`, renderers, views, `StatusModel` are `@MainActor`. `KeyframeProcessor` is an `actor`. Storage is a serial `DispatchQueue` wrapped by `StorageQueue` (`@unchecked Sendable`), owning the `KeyframeLogWriter`. Metal objects cross actors only inside `@unchecked Sendable` wrappers whose invariants are documented (append-only + count published last; double-buffer swap under a lock).

Coordinate conventions: world = ARKit world (gravity-aligned, origin at session start, `frame: "world:session-start"`). Camera space = ARKit camera (x right, y up, −z forward). Depth pixel (u,v) with depth d and depth-scaled intrinsics gives camera point `(X, −Y, −d)` where `X=(u+0.5−cx)/fx·d`, `Y=(v+0.5−cy)/fy·d` (pixel centers). `p_world = camera.transform · [X, −Y, −d, 1]`. Intrinsics are scaled from the video format size to 256×192 by `sx = 256/W`, `sy = 192/H`. The UI is portrait-locked; the camera image is landscapeRight-native and is displayed through `frame.displayTransform(for: .portrait, viewportSize:)`; live points use `viewMatrix(for: .portrait)` and `projectionMatrix(for: .portrait, …)`.

Marker-origin extension point: `MapManifest.origin` (`OriginDescriptor`, today `{type: "session-start"}`) and `CaptureSession.worldFromOrigin: Pose` (identity today). A marker implementation sets `worldFromOrigin = T_marker` and stores `origin.type = "marker"`; every keyframe pose written to the log is `worldFromOrigin⁻¹ · camera.transform`. Upload extension point: `MapStore` exposes the map directory and file URLs; an uploader would consume `keyframes.bin` records + `manifest.json` exactly as the MVP plan's §5.2 message, with `depth.ref` pointing at the LZFSE payload.

## 3. MapCore API contract (implemented against the foundation files in `Sources/MapCore`)

Foundation (written first, compiled before fan-out): `Pose`, `Intrinsics`, `PackedPoint`, `TrackingState`, `KeyframeRecord`, `BoundingBox`, `MapID`, `MapStatus`, `MapManifest`, `MapError`, `CRC32`.

### Geometry/Unprojection.swift
```swift
public enum Unprojector {
  public struct Options: Sendable, Equatable {
    public var minConfidence: UInt8 = 1       // 0 low, 1 medium, 2 high
    public var minDepthMeters: Float = 0.1
    public var maxDepthMeters: Float = 5.0
    public var stride: Int = 1                // sample every Nth pixel in u and v
    public init(...)
  }
  public struct Result: Sendable, Equatable { public var positions: [SIMD3<Float>]; public var pixelIndices: [Int32] }  // pixelIndex = v*width+u
  public static func unproject(depthMillimeters: [UInt16], confidence: [UInt8], intrinsics: Intrinsics, pose: Pose, options: Options = .init()) -> Result
  public static func unproject(record: KeyframeRecord, options: Options = .init()) -> Result
  public static func unprojectPacked(record: KeyframeRecord, options: Options = .init(), color: (Int32) -> UInt32) -> [PackedPoint]
}
```
Rules: skip pixels with depth 0, confidence < minConfidence, depth outside [min,max]. Depth is `Float(mm)/1000`. Uses `Intrinsics.unproject(u:v:depth:)` (which applies the +0.5 pixel-center offset and the (X, −Y, −Z) flip) then `pose.transform`.

### Keyframes/KeyframePolicy.swift
```swift
public struct KeyframePolicy: Sendable {
  public struct Config: Sendable, Equatable {
    public var translationThresholdMeters: Float = 0.15
    public var rotationThresholdDegrees: Float = 12
    public var maxInterval: TimeInterval = 0.75
    public var requireNormalTracking: Bool = true
    public static let `default`: Config
  }
  public enum Mode: Sendable, Equatable { case normal, halved, paused }   // halved = thermal .serious (thresholds ×2), paused = .critical
  public enum Reason: Sendable, Equatable { case first, translation, rotation, elapsed }
  public enum SkipReason: Sendable, Equatable { case paused, trackingNotNormal, belowThresholds }
  public enum Decision: Sendable, Equatable { case keyframe(Reason), skip(SkipReason) }
  public var config: Config
  public var mode: Mode
  public private(set) var lastKeyframePose: Pose?
  public private(set) var lastKeyframeTime: TimeInterval?
  public private(set) var keyframeCount: Int
  public init(config: Config = .default)
  public mutating func evaluate(pose: Pose, timestamp: TimeInterval, tracking: TrackingState) -> Decision
  public mutating func reset()
}
```
Order of gates: paused → tracking → first → translation (strict >) → rotation (strict >, degrees) → elapsed (≥ maxInterval) → belowThresholds. `halved` doubles all three thresholds. A keyframe decision updates last pose/time/count.

### Cloud/VoxelGrid.swift
```swift
public struct VoxelGrid: Sendable {
  public struct Config: Sendable, Equatable { public var cellSize: Float = 0.02; public var maxPoints: Int = 3_000_000; public var coarsenedCellSize: Float = 0.03; public static let `default`: Config }
  public enum State: Sendable, Equatable { case accepting, capReached, coarsened, full }
  public private(set) var state: State
  public private(set) var cellSize: Float
  public private(set) var count: Int
  public private(set) var bounds: BoundingBox
  public var config: Config { get }
  public init(config: Config = .default)
  public static func key(for p: SIMD3<Float>, cellSize: Float) -> Int64   // floor(p/cell) per axis + 2^20 offset, 21 bits per axis packed x | y<<21 | z<<42
  public func contains(_ p: SIMD3<Float>) -> Bool
  /// First sample per cell wins. Returns accepted points in input order. Stops at maxPoints and sets state .capReached (from .accepting) or .full (from .coarsened). Returns [] when state is .capReached or .full.
  public mutating func insert(_ points: [PackedPoint]) -> [PackedPoint]
  public mutating func insert(_ points: UnsafeBufferPointer<PackedPoint>) -> [PackedPoint]
  /// Rebuilds the key set at coarsenedCellSize from the existing points (first sample per coarse cell, original order). State → .coarsened. Allowed only from .capReached; from any other state it is a no-op returning all points.
  public mutating func coarsen(existingPoints: UnsafeBufferPointer<PackedPoint>) -> [PackedPoint]
  public var isAccepting: Bool   // state == .accepting || state == .coarsened
}
```
Internally an open-addressing `VoxelKeySet` (power-of-two capacity, linear probing, `Int64.min` empty sentinel, grows at 0.7 load). No `Set<Int64>`.

### Cloud/PointCloud.swift, Cloud/Decimation.swift
```swift
public struct PointCloud: Sendable, Equatable {
  public var points: [PackedPoint]; public private(set) var bounds: BoundingBox
  public init(points: [PackedPoint] = []); public mutating func append(contentsOf: [PackedPoint]); public var count: Int
  public static func bounds(of points: UnsafeBufferPointer<PackedPoint>) -> BoundingBox
}
public enum Decimation {
  public static func stride(count: Int, target: Int) -> Int          // smallest s ≥ 1 with ceil(count/s) ≤ target; target ≤ 0 → count (draw nothing) guarded as max(1,…)
  public static func decimatedCount(count: Int, stride: Int) -> Int  // ceil(count/stride)
  public static func decimate(_ points: [PackedPoint], target: Int) -> [PackedPoint]
}
```

### Codec/DepthCodec.swift
```swift
public enum DepthCodec {
  public static func quantize(depthMeters: [Float]) -> [UInt16]                 // round(m*1000) clamped 1...65535; NaN/inf/≤0 → 0
  public static func quantize(depthMeters: UnsafeBufferPointer<Float>) -> [UInt16]
  public static func dequantize(_ mm: [UInt16]) -> [Float]                      // /1000, 0 → 0
  public static func compress(_ bytes: UnsafeRawBufferPointer) throws -> Data   // LZFSE via Compression
  public static func decompress(_ data: Data, expectedByteCount: Int) throws -> Data  // throws decompressionFailed on size mismatch
  public static func encodeDepth(_ mm: [UInt16]) throws -> Data                 // little-endian u16 bytes → LZFSE
  public static func decodeDepth(_ data: Data, pixelCount: Int) throws -> [UInt16]
  public static func encodeConfidence(_ c: [UInt8]) throws -> Data
  public static func decodeConfidence(_ data: Data, pixelCount: Int) throws -> [UInt8]
}
```

### Codec/PLYWriter.swift
```swift
public enum PLYWriter {
  public static func header(pointCount: Int, comments: [String] = []) -> String
  // "ply\nformat binary_little_endian 1.0\n[comment …\n]element vertex N\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
  public static func encode(points: [PackedPoint], comments: [String] = []) -> Data       // header + 15 bytes/point
  public static func write(points: UnsafeBufferPointer<PackedPoint>, to url: URL, comments: [String] = []) throws  // chunked (65 536 points per write), atomic (temp file + rename)
  public static func write(points: [PackedPoint], to url: URL, comments: [String] = []) throws
}
public enum PLYReader {
  public static func read(data: Data) throws -> PointCloud   // accepts our header (any comment lines); MapError.invalidPLY otherwise
  public static func read(url: URL) throws -> PointCloud
}
```

### Storage/KeyframeLog.swift  (binary spec in FORMAT.md; summary)
Header 16 bytes: `"SMKF"`, u16 version=1, u16 headerSize=16, u32 flags=0, u32 reserved=0.
Record: u32 payloadLength, then payload: u32 seq, f64 timestamp, 16×f32 pose (column-major), f32 fx fy cx cy, u16 width height, u8 trackingState, u8 trackingReason, u8 depthEncoding(0), u8 confidenceEncoding(0), u32 depthBytes + bytes, u32 confidenceBytes + bytes, u32 crc32 (IEEE, over payload bytes before the crc). All little-endian.
```swift
public enum KeyframeLogFormat { public static let magic: [UInt8] = [0x53,0x4D,0x4B,0x46]; public static let version: UInt16 = 1; public static let headerSize = 16 }
public final class KeyframeLogWriter {   // not Sendable; owned by one serial queue
  public init(url: URL) throws            // creates with header, or validates and appends to an existing file (truncating a partial tail record)
  public private(set) var recordCount: Int; public private(set) var byteCount: Int64
  @discardableResult public func append(_ record: KeyframeRecord) throws -> Int64   // returns record offset; compresses with DepthCodec; writes length+payload in one write
  public func sync() throws               // fsync
  public func close() throws
}
public struct KeyframeLogScan: Sendable, Equatable { public var records: [KeyframeRecord]; public var recordCount: Int; public var truncatedAtOffset: Int64?; public var corruptedAtOffset: Int64? ; public var byteCount: Int64 }
public enum KeyframeLogReader {
  public static func scan(url: URL, decodeDepth: Bool = true) throws -> KeyframeLogScan             // reads all complete records, stops at truncated/corrupt tail without throwing
  public static func forEachRecord(url: URL, _ body: (KeyframeRecord) throws -> Void) throws -> KeyframeLogScan  // streaming; scan.records is empty
}
```

### Storage/MapStore.swift
```swift
public enum MapFile: String, CaseIterable, Sendable { case manifest = "manifest.json", keyframeLog = "keyframes.bin", cloud = "cloud.ply", thumbnail = "thumbnail.png", worldMap = "worldmap.arworldmap", sessionLog = "session.log" }
public struct MapSummary: Sendable, Equatable { public var manifest: MapManifest; public var directoryURL: URL; public var sizeBytes: Int64; public var hasThumbnail: Bool; public var hasCloud: Bool }
public final class MapStore: Sendable {
  public let rootURL: URL                                   // …/Documents/Maps
  public init(rootURL: URL) throws                          // creates directory
  public func directoryURL(for id: MapID) -> URL
  public func url(for file: MapFile, in id: MapID) -> URL
  public func create(manifest: MapManifest) throws -> URL   // mkdir + writes manifest (status must be .recording)
  public func saveManifest(_ manifest: MapManifest) throws  // atomic write
  public func loadManifest(id: MapID) throws -> MapManifest
  public func list() throws -> [MapSummary]                 // newest first; skips unreadable dirs
  public func delete(id: MapID) throws
  public func rename(id: MapID, to name: String) throws
  public func directorySize(id: MapID) -> Int64
  public func markInterruptedRecordings() throws -> [MapID] // recording|finalizing → failed
  public func exists(id: MapID) -> Bool
}
```

### Storage/CloudRebuilder.swift
```swift
public enum CloudRebuilder {
  public struct Result: Sendable { public var cloud: PointCloud; public var keyframeCount: Int; public var gridState: VoxelGrid.State; public var scan: KeyframeLogScan }
  public static func rebuild(logURL: URL, gridConfig: VoxelGrid.Config = .default, options: Unprojector.Options = .init(), progress: ((Int) -> Void)? = nil) throws -> Result
  // Color: confidence-tinted gray (high → 210, medium → 150) because the log carries no color.
}
```

## 4. App design details

- **ARSessionController**: `ARWorldTrackingConfiguration`, `frameSemantics = [.sceneDepth]`, `worldAlignment = .gravity`, `planeDetection = []`, `sceneReconstruction = []`. Video format: among formats with fps ≥ 30, prefer 4:3, smallest width ≥ 1280, prefer 60 fps at that size (logged). Guard `supportsFrameSemantics(.sceneDepth)`. Delegate on main; the callback is `nonisolated` and hops in with `MainActor.assumeIsolated`. Measures its own duration and keeps a p95 estimate for the status strip and TESTING.md.
- **FrameExtractor**: pool of 3 `KeyframeSnapshot`s (depth Float32 256×192, confidence UInt8, Y plane, CbCr plane + strides + sizes). `vImage`-free memcpy per row. Snapshot returned to the pool by the processor.
- **KeyframeProcessor** (actor): quantize depth → `KeyframeRecord`; `Unprojector.unprojectPacked` with a YCbCr→RGB sampler (BT.601 full-range as ARKit delivers); `VoxelGrid.insert`; on `.capReached` → `coarsen(existingPoints: buffer)` → `SharedPointBuffer.replaceAll`; append accepted points; update trajectory; enqueue log append. Emits `CloudStats {points, keyframes, gridState, bounds, logBytes}` to StatusModel.
- **SharedPointBuffer**: two `MTLBuffer`s of 3 M × 16 B (`storageModeShared`), active index + count behind an `os_unfair_lock`; `append` copies into the active buffer past `count` then publishes; `replaceAll` writes the inactive buffer and swaps. `snapshot()` returns (buffer, count) for a frame.
- **Renderers**: `MetalRenderer` draws camera quad (YCbCr→RGB), live depth points (49 152 vertices, depth/conf textures via `CVMetalTextureCache`), global cloud (stride so ≤ 1 M drawn, 35 % opacity by default, toggle). `GhostMapRenderer` on an `MTKView` with `preferredFramesPerSecond = 30`, `isPaused`-free frame skipping when the main renderer's last frame exceeded 16.7 ms or has 3 command buffers in flight; draws cloud with stride ≤ 250 k at 55 % alpha, trajectory polyline, camera frustum; top-down ortho auto-framed to bounds with north = initial heading; optional slow orbit at 35 ° tilt; expanded mode with orbit/pan/zoom; `renderThumbnail(size: 512) -> CGImage` offscreen.
- **Thermal**: `.nominal/.fair → .normal`, `.serious → .halved`, `.critical → .paused` + Ghost Map warning; every transition logged to os_log and session.log.
- **Storage flow**: `MapStore` under `Documents/Maps`; Info.plist enables file sharing + open-in-place. Launch: `markInterruptedRecordings()`; failed maps with a log offer **Rebuild** (CloudRebuilder → PLY + thumbnail → saved).
- **UI**: `MapListView` (thumbnail, editable name, points, keyframes, duration, size, status), `CaptureView` (Metal view + Start/Stop + Ghost Map overlay + settings: high-only confidence, orbit toggle, draw-global toggle), `GhostMapView` (36 % width square, 16 pt inset, ultraThinMaterial, 12 pt radius, status strip ≥ 4 Hz, tap expand / swipe-down shrink / long-press mode toggle; `allowsHitTesting` scoped so Start/Stop is never covered), `MapDetailView` (PLY → Metal buffer, orbit/pan/zoom, ShareLink export, Delete with confirmation).

## 5. Budgets (measured and logged)
60 fps main view (≥ 30 fps during keyframe processing) — renderer frame timer. AR callback ≤ 2 ms p95 — `ContinuousClock` in the callback, p95 over a 600-sample ring. Memory ≤ 500 MB at cap — `task_vm_info.phys_footprint` sampled at 1 Hz. Disk ≤ 60 MB for 3 min — manifest `size_bytes`. Finalize ≤ 5 s — timed, progress in UI.

## 6. Test plan (HITL)
T0 Smoke (30 s) → T1 Capture (60–90 s) → T2 Persistence (relaunch, list, detail, export) → T3 Endurance (5 min). Each preceded by a Test Brief and "Ready to test?"; results in TESTING.md.

## 7. Build order & branches
1. `feature/plan-and-scaffold`: PLAN.md, MapCore skeleton + foundation types, docs skeleton.
2. `feature/mapcore`: all MapCore modules + tests, `swift test` green on macOS.
3. `feature/app-capture-preview`: project.yml, Info.plist, AR session, Metal live preview; device build.
4. `feature/app-keyframe-cloud`: keyframe pipeline, voxel grid, shared buffer, thermal.
5. `feature/app-ghost-map`: Ghost Map renderer + view + status strip.
6. `feature/app-storage`: capture session finalize, list, detail, export, delete, rebuild.
7. `feature/docs`: README, DECISIONS, FORMAT, TESTING.
Each merges to `dev` (pushed) when it compiles and its tests pass; `dev` → `release/ios-client-arkit-vslam` after T0–T3.
