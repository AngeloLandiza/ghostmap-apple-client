# Architecture

## Modules

```
Packages/MapCore (Swift package, no UIKit/ARKit/Metal; tested on macOS)
  Geometry/   Pose (SE(3)), Intrinsics (scale, project, unproject), Unprojector
  Keyframes/  TrackingState, KeyframeRecord, KeyframePolicy (0.15 m / 12° / 0.75 s, thermal modes)
  Cloud/      PackedPoint (16 B, matches the Metal vertex), DynamicVoxelMap, VoxelGrid (static, used by rebuild), Decimation
  Codec/      DepthCodec (u16 mm + LZFSE), PLYWriter / PLYReader, CRC32
  Storage/    MapManifest, KeyframeLog (append-only "SMKF" records), MapStore, CloudRebuilder, MapError
  Backend/    PKCE + Base64URL, GoogleOAuth (authorization URL, callback, token body), SnakeCase + GhostmapJSON coders, JSONValue, RetryPolicy, BackendURL

App (iOS, Swift 6 language mode)
  Capture/    ARSessionController, FrameExtractor, KeyframeProcessor (actor), StorageQueue, CaptureSession, ThermalMonitor, SessionLogger, CaptureSettings, MapRebuildService
  Rendering/  MetalContext, PointCloudPipeline, Shaders.metal + ShaderTypes.h, SharedPointBuffer, TrajectoryBuffer, MetalRenderer, GhostMapRenderer, OrbitCamera (GhostCamera), RenderClock, RenderMath
  Cloud/      GhostmapAPI (actor over URLSession), GhostmapModels (DTOs), GoogleSignIn (ASWebAuthenticationSession + PKCE), AccountStore (@Observable), Keychain (SecItem), CloudSettings
  UI/         MapListView, CaptureView, GhostMapView (overlay, panel, status strip), MapDetailView, SettingsView, MetalViewRepresentable, StatusModel, UnsupportedDeviceView
  Support/    MemoryFootprint.c (phys_footprint), bridging header
```

## Data flow during a recording

```
ARSession (main queue) ──didUpdate frame──▶ ARSessionController.handle (≤ 2 ms budget)
   ├─ tracking / world-mapping status, camera transform, depth-scaled intrinsics
   ├─ four zero-copy Metal textures (Y, CbCr, depth, confidence) → FrameTextures → MetalRenderer (60 fps)
   ├─ KeyframePolicy.evaluate → keyframe? → FrameExtractor.snapshot (depth, confidence, luma/chroma at depth resolution)
   └─ otherwise every 0.25 s → depth-only carve snapshot
                    │
                    ▼  (≤ 2 in flight, extra dropped and counted)
KeyframeProcessor (actor)
   ├─ DepthCodec.quantize → KeyframeRecord
   ├─ Unprojector.unprojectPacked (pixel centers, (X, −Y, −Z) flip, pose) with YCbCr→RGB colors
   ├─ DynamicVoxelMap.integrate: carve in-view voxels, fuse/insert samples, confirm, sweep, compact
   ├─ SharedPointBuffer.update / append / replaceAll (GPU mirror), TrajectoryBuffer.append
   └─ StorageQueue.append(record) → KeyframeLogWriter (serial queue, LZFSE, CRC, one write per record)

GhostMapRenderer (≤ 30 fps, skips when the main renderer is behind) reads SharedPointBuffer, TrajectoryBuffer, camera pose
CaptureSession status loop (5 Hz) → StatusModel → Ghost Map strip
```

## Concurrency model

- `ARSessionController`, both renderers, `CaptureSession`, `StatusModel` and all views are `@MainActor`. `ARSessionDelegate` and `MTKViewDelegate` are not actor-annotated in the SDK, so their methods are `nonisolated` and hop in with `MainActor.assumeIsolated` (the session's delegate queue is the main queue; MTKView draws on the main thread).
- `KeyframeProcessor` is an actor: all voxel-map mutation happens there.
- `StorageQueue` is a serial `DispatchQueue` owning the `KeyframeLogWriter`; `SessionLogger` has its own serial queue.
- Metal objects cross isolation only inside `@unchecked Sendable` wrappers whose invariants are documented in code: `SharedPointBuffer` (lock-guarded state, append-beyond-count then publish, double buffer swap for whole replacements, in-place updates accepted as one-frame cosmetic tearing), `TrajectoryBuffer`, `MetalContext`, `PointCloudPipeline`, `RenderClock`.
- No `DispatchQueue.main.async` anywhere; no force-unwraps in the app.

## Rendering

- `Shaders.metal`: camera quad (YCbCr→RGB), live depth points (one vertex per depth pixel, unprojected on the GPU with K⁻¹ and the camera transform), global cloud points (strided reads from the shared buffer, perspective point size), lines (trajectory, frustum).
- `ShaderTypes.h` is shared between Swift and MSL; `RMPointVertex` is byte-identical to `MapCore.PackedPoint`.
- The Ghost Map is a second `MTKView` (non-opaque, over `.ultraThinMaterial`) with `preferredFramesPerSecond = 30` and a frame-skip rule tied to `RenderClock.isBehind`. Thumbnails are the same renderer drawing top-down into an offscreen texture.

## Storage flow

`Documents/Maps/<mapID>/` — `manifest.json`, `keyframes.bin` (written incrementally, fsynced at finalize), `cloud.ply` (streamed from the GPU buffer), `thumbnail.png`, `worldmap.arworldmap` (only when ARKit reports `.mapped`, 6 s timeout), `session.log`. On launch, maps still marked `recording`/`finalizing` become `failed` and can be rebuilt from the log. Byte layout: FORMAT.md.

## Extension points

- **Marker origin** (swarm plan §6): `MapManifest.origin` / `frame` and the pose written per keyframe in `KeyframeProcessor` (`camera.transform` today). A marker implementation detects an `ARImageAnchor`, sets `origin = {type: "marker", marker_id}` and writes `T_marker⁻¹ · camera.transform`.
- **Upload** (swarm plan §5.2, §7): `MapStore` exposes every file URL; keyframe records already carry the plan's live-keyframe fields and `manifest.json` mirrors the map artifact manifest. `AppEnvironment.api` already speaks the whole map flow — `createMap` → `SignedUpload` tickets (`resumable` for `cloud.ply` and `keyframes.bin`) → `finalizeMap` — so the uploader only has to move bytes and report progress.
- **Parties** (Phase 2 §2): `GhostmapAPI` covers create / by-code / join / leave / end / keyframe upload-urls / register keyframes / realtime token; `AccountStore.deviceIdentity` is the identity the backend binds participants to. The `ghostmap://` URL scheme is registered but not yet handled.
- **Meshes**: `ARSessionController.start` sets `sceneReconstruction = []`; enabling it and consuming `ARMeshAnchor` is the flagged next step.
- **Relocalization**: `worldmap.arworldmap` is saved but not yet used as `initialWorldMap`.
