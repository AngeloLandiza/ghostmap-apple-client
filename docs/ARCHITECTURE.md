# Architecture

## Modules

```
Packages/MapCore (Swift package, no UIKit/ARKit/Metal; tested on macOS)
  Geometry/   Pose (SE(3)), Intrinsics (scale, project, unproject), Unprojector, MarkerOrigin (world_from_origin, AlignedPose)
  Keyframes/  TrackingState, KeyframeRecord, KeyframePolicy (0.15 m / 12° / 0.75 s, thermal modes)
  Cloud/      PackedPoint (16 B, matches the Metal vertex), DynamicVoxelMap, VoxelGrid (static, used by rebuild), Decimation
  Codec/      DepthCodec (u16 mm + LZFSE), PLYWriter / PLYReader, CRC32
  Storage/    MapManifest, KeyframeLog (append-only "SMKF" records), MapStore, CloudRebuilder, MapError
  Backend/    PKCE + Base64URL, GoogleOAuth (authorization URL, callback, token body), SnakeCase + GhostmapJSON coders, JSONValue, RetryPolicy, BackendURL
  Party/      PartyCode (invite codes, ghostmap:// links), PartyColor (the backend's palette, tinting), InlinePoints (points_inline select/encode/decode), AblyWire (token shapes, SSE envelopes, REST auth), ServerSentEventParser, TrackingState wire names

App (iOS, Swift 6 language mode)
  Capture/    ARSessionController, FrameExtractor, KeyframeProcessor (actor), StorageQueue, CaptureSession, ThermalMonitor, SessionLogger, CaptureSettings, MapRebuildService, MarkerReference
  Rendering/  MetalContext, PointCloudPipeline, Shaders.metal + ShaderTypes.h, SharedPointBuffer, TrajectoryBuffer, MetalRenderer, GhostMapRenderer, OrbitCamera (GhostCamera), RenderClock, RenderMath
  Cloud/      GhostmapAPI (actor over URLSession), GhostmapModels (DTOs), GoogleSignIn (ASWebAuthenticationSession + PKCE), AccountStore (@Observable), Keychain (SecItem), CloudSettings,
              PartySession (@Observable, the party this phone is in), AblyRealtime (actor: SSE subscribe + REST publish), KeyframeStreamer (actor: signed uploads + registration), PeerCloudStore / PeerCloud (a SharedPointBuffer per peer)
  UI/         MapListView, CaptureView, GhostMapView (overlay, panel, status strip), MapDetailView, SettingsView, PartyView (+ PartyBadge, PartyQRCode), MetalViewRepresentable, StatusModel, UnsupportedDeviceView
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

## Data flow in a party

```
POST /v1/sessions (origin = marker when marker mode is on)   ┐
POST /v1/sessions/join { code }                              ├─ PartySession (@Observable @MainActor)
POST /v1/sessions/:id/leave | /end                           ┘     owns the party, the peers and the streamer

recording, per keyframe (after KeyframeProcessor has integrated it)
   CaptureSession.handleKeyframe: AlignedPose from MarkerOrigin (main actor, before dispatch)
        │  StreamedKeyframe { pose (origin frame), aligned, intrinsics, tracking, depth mm, confidence,
        │                     points_inline = InlinePoints.select(appended + updates) ≤ 2 000, re-framed }
        ▼
   KeyframeStreamer (actor, queue of 10, drops the oldest)
        ├─ POST /v1/sessions/:id/upload-urls   (≤ 5 keyframes per round, kinds depth + confidence)
        ├─ PUT  <signed GCS url>               (DepthCodec.encodeDepth / encodeConfidence — the same LZFSE payloads as keyframes.bin)
        └─ POST /v1/sessions/:id/keyframes     (the backend fans them out on the Ably channel)

live channel  session:<id>
   AblyRealtime (actor)
        ├─ subscribe: URLSession streaming data task → SSE → ServerSentEventParser → AblyWire.message
        │             reconnect with doubling backoff ≤ 30 s, resume with &lastEvent, refresh the token on 401/403
        ├─ publish:   POST https://rest.ably.io/channels/<ch>/messages  ("pose", ≤ 10 Hz, only when moved)
        └─ token:     POST /v1/realtime/token → Ably TokenRequest → POST /keys/<keyName>/requestToken
        │
        ▼  AsyncStream<AblyRealtimeEvent>
   PartySession.handle
        ├─ "keyframes" → PeerCloudStore → PeerCloud.ingest (InlinePoints.decode, tinted with the party colour)
        ├─ "pose"      → PeerCloud.latestPose
        ├─ "participant" / "session ended" → refresh or tear down
        └─ counters → StatusSnapshot → Ghost Map strip

MetalRenderer and GhostMapRenderer draw each PeerCloud through viewProjection · world_from_origin
(small points, 70 % alpha; GhostMapRenderer also draws one frustum per peer in their colour)
```

## Concurrency model

- `ARSessionController`, both renderers, `CaptureSession`, `StatusModel` and all views are `@MainActor`. `ARSessionDelegate` and `MTKViewDelegate` are not actor-annotated in the SDK, so their methods are `nonisolated` and hop in with `MainActor.assumeIsolated` (the session's delegate queue is the main queue; MTKView draws on the main thread).
- `KeyframeProcessor` is an actor: all voxel-map mutation happens there.
- `AblyRealtime` and `KeyframeStreamer` are actors: the SSE stream, the token exchange, LZFSE encoding for the party and every upload happen off the main actor. `PartySession`, `PeerCloudStore` and `PeerCloud` are `@MainActor` — realtime events arrive there through an `AsyncStream`, and the decode of one message is bounded by the contract (≤ 2 000 points × ≤ 50 keyframes) so it stays inside a frame.
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

- **Marker origin** (Phase 2 §5, implemented): `ARSessionController` adds the bundled `Marker/ghostmap-marker.png` as an `ARReferenceImage` (`physicalWidth` from `CaptureSettings.markerPhysicalWidth`, `maximumNumberOfTrackedImages = 1`) and feeds every `ARImageAnchor` add/update/remove into `MapCore.MarkerOrigin`. `CaptureSession.alignedPose(worldFromCamera:)` returns `origin_from_camera = world_from_origin⁻¹ · camera.transform` with the wire `aligned` flag, and `cloudOrigin` is the `{type: "marker", marker_id}` descriptor for `POST /v1/sessions` and `POST /v1/maps`. The *local* map is unchanged: `keyframes.bin`, `cloud.ply` and `manifest.origin` stay in the session-start world frame; the marker frame is applied at upload time.
- **Upload** (swarm plan §5.2, §7): `MapStore` exposes every file URL; keyframe records already carry the plan's live-keyframe fields and `manifest.json` mirrors the map artifact manifest. `AppEnvironment.api` already speaks the whole map flow — `createMap` → `SignedUpload` tickets (`resumable` for `cloud.ply` and `keyframes.bin`) → `finalizeMap` — so the uploader only has to move bytes and report progress.
- **Parties** (Phase 2 §2 and §5, implemented): `PartySession` owns create / join by code / leave / rejoin / end, the Ably subscription and the peers; `KeyframeStreamer` streams this phone's keyframes while recording; `PeerCloudStore` holds one `SharedPointBuffer` per peer and both renderers draw them. `ghostmap://join/<code>` is handled in `RootView`/`AppEnvironment.handle(url:)`. Not done: entering Ably presence (needs a WebSocket — see DECISIONS.md), catch-up of a party joined late via `GET /v1/sessions/:id/keyframes?since_id=…`, and `POST /v1/sessions/:id/merge` from the phone.
- **Meshes**: `ARSessionController.start` sets `sceneReconstruction = []`; enabling it and consuming `ARMeshAnchor` is the flagged next step.
- **Relocalization**: `worldmap.arworldmap` is saved but not yet used as `initialWorldMap`.
