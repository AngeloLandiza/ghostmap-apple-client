# Decisions

Every non-obvious choice in RoomMapper and why. Newest additions at the bottom of each section.

## Toolchain and project

- **Xcode 27 beta via `DEVELOPER_DIR`.** The Mac's `xcode-select` points at the Command Line Tools and only `/Applications/Xcode-beta.app` is installed. Every `xcodebuild`, `xcrun` and `swift` call is prefixed with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` instead of asking for `sudo xcode-select`.
- **Metal toolchain is a downloadable component in Xcode 26+.** `xcodebuild -downloadComponent MetalToolchain` (839 MB) was required before any `.metal` file would compile.
- **Deployment target iOS 18.0**, the lower of the requested 18.0 and the device's installed iOS 27.0. `@Observable`, `OSAllocatedUnfairLock<State>` and `ContinuousClock` are all available there.
- **Team ID `RZ5NX26K3B`** was inferred from the signing certificate's OU and an existing project; automatic signing with `-allowProvisioningUpdates` created the team profile without any interactive step.
- **XcodeGen generates `RoomMapper.xcodeproj`; the project file is git-ignored.** `project.yml` is the source of truth; `xcodegen generate` is a one-liner in the README. No hand-written pbxproj.
- **Swift 6 language mode in both MapCore and the app.** The spec allowed Swift 5 mode; Swift 6 mode was chosen so that the "no data races" requirement is enforced by the compiler. The delegate protocols (`ARSessionDelegate`, `MTKViewDelegate`) are not main-actor annotated in the iOS 27 SDK, so their methods are `nonisolated` and hop in with `MainActor.assumeIsolated`, which is sound because `ARSession.delegateQueue` is the main queue and `MTKView` draws on the main thread.
- **A tiny C file for the memory gauge.** `mach_task_self_` is a C global that Swift 6 strict concurrency refuses to read; `App/Support/MemoryFootprint.c` wraps `task_info(TASK_VM_INFO).phys_footprint` so the status strip and logs can report the same number as Xcode's memory gauge.
- **Portrait-only UI.** The capture screen is locked to portrait so that one `displayTransform` / `viewMatrix(for: .portrait)` path is exercised and tested; the camera image and depth map are landscape-native and are rotated for display only.

## Geometry and capture

- **Pixel centers.** Unprojection uses `(u + 0.5, v + 0.5)`; the hand-computed expectations in `UnprojectionTests` assume this.
- **Camera-space flip `(X, −Y, −depth)`.** Image space is x-right/y-down/z-forward; ARKit's camera frame is x-right/y-up/−z-forward. The CPU path (`Intrinsics.unproject`) and the vertex shader apply the same flip, then `camera.transform`.
- **Intrinsics are scaled from the video format to the depth map** (`sx = 256/W`, `sy = 192/H`) and stored per keyframe already scaled, so a reader never needs the color resolution.
- **Video format rule:** among formats with ≥ 30 fps, prefer 4:3 aspect (matches the depth map), the smallest width ≥ 1280, and 60 fps at that size. On iPhone 16 Pro Max this is expected to select 1920×1440@60; the chosen format is logged at session start.
- **Keyframe policy thresholds** are exactly the spec's 0.15 m / 12° / 0.75 s and require `.normal` tracking. The first frame with normal tracking is always a keyframe. **Thermal `.serious` halves the rate by doubling all three thresholds** (`Mode.halved`), which is deterministic and unit-testable, rather than dropping every other candidate (which would not actually halve the rate because a dropped candidate re-triggers on the next frame). **`.critical` pauses** keyframes (`Mode.paused`) and the Ghost Map shows a warning.
- **The ≤ 2 ms callback copies only what a keyframe needs.** Non-keyframes do no copies at all: the four textures are created through `CVMetalTextureCache` (zero copy). Keyframes copy depth (196 KB) and confidence (49 KB) row by row and sample luma/chroma at each depth pixel (3 × 49 KB) instead of copying the 4 MB YCbCr planes; YCbCr→RGB conversion happens later on the processor actor.
- **No snapshot pool.** A keyframe allocates ~400 KB of arrays at ≤ 3 keyframes/s; that is ~1 MB/s of large allocations and not worth a pool's complexity.
- **Keyframe back-pressure:** at most two keyframes are in flight on the processor actor; further candidates are dropped and counted (`droppedKeyframes` in the finalize log line) rather than queued without bound.
- **Confidence gate default = medium (≥ 1)**, high-only available as a setting; the live preview shader uses the same threshold.
- **Marker origin extension point:** `MapManifest.origin` (`OriginDescriptor`) and the constant `frame: "world:session-start"`. A marker implementation would store `origin.type = "marker"` and write `T_marker⁻¹ · camera.transform` poses. Nothing else in the pipeline assumes the origin.

## Point cloud

- **Voxel key packing:** `floor(p / cell)` per axis, offset by 2²⁰, 21 bits per axis packed into an `Int64`. Range ±20 971 m at 2 cm — effectively unlimited for a room, and the offset keeps keys non-negative so `Int64.min` can be the empty sentinel.
- **Custom open-addressing `VoxelKeySet`** instead of `Set<Int64>`: predictable memory (8 bytes per slot, power-of-two capacity, ≤ 0.7 load) and no per-insert allocation; at 3 M keys it holds 4.19 M or 8.39 M slots (33–67 MB) depending on when the last rehash happens.
- **Cap and coarsen state machine:** `.accepting` (2 cm) → `.capReached` at 3 M → `coarsen()` rebuilds the key set at 3 cm from the existing points, keeping the first sample per coarse cell → `.coarsened` → `.full` at 3 M again, after which `insert` returns nothing. The processor re-inserts the keyframe that hit the cap after coarsening so no keyframe is lost.
- **Single GPU-resident copy of the cloud.** `SharedPointBuffer` holds the points in a `storageModeShared` `MTLBuffer` that both renderers draw from and that PLY export reads directly; MapCore's `VoxelGrid` keeps only the key set. A second buffer is allocated lazily only when the cloud is rebuilt after coarsening. The known hazard is that the GPU may still read the previously active buffer for one frame after the swap; coarsening happens at most once per session so the swap can never race a second rebuild.
- **Ghost Map and main view decimate by stride in the vertex stage** (`vertex i` reads point `i × stride`), never by copying: ≤ 250 k points in the compact panel, ≤ 1 M when expanded and in the main view.
- **Rebuilt clouds are gray.** The keyframe log intentionally carries no color (spec: "color only in the PLY"; adding even 256×192 YCbCr would exceed the 60 MB budget), so `CloudRebuilder` tints points by confidence (high 210, medium 150).

## Rendering

- **Full-range BT.601 YCbCr→RGB** matrix from Apple's ARKit Metal samples, applied both in the shaders and on the CPU for keyframe colors, so the live preview and the stored cloud agree.
- **Point sprites are round** (fragment discards outside the disc) with alpha blending that yields premultiplied output, so the Ghost Map's `MTKView` composites correctly over `.ultraThinMaterial`.
- **Uniform ring buffers (3 slots)** with a three-deep in-flight semaphore in the main renderer; two-deep in the Ghost Map renderer. The Ghost Map skips a frame whenever the main renderer's last CPU frame exceeded 16.7 ms or three main frames are queued (`RenderClock.isBehind`).
- **Ghost camera "north"** is the first normal-tracking frame's forward vector projected onto the ground plane; top-down mode uses it as the screen-up vector so the panel is oriented to the way the session started. Auto-framing smooths center/radius with a 3 s⁻¹ exponential so the view does not jump as the bounding box grows.
- **Thumbnails are the Ghost Map's top-down render** at 512×512 into a shared-storage texture read back on the CPU; no separate thumbnail pipeline.

## Storage

- **Maps live under `Documents/Maps/<mapID>/`, not Application Support.** `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` expose only the app's Documents directory in the Files app; keeping the spec's "visible in the Files app" requirement was judged more important than the literal path. Everything else about the layout matches the spec.
- **`keyframes.bin` records are written with a single `write` call each and end in a CRC32**, so a crash leaves either a complete record or a partial tail. `KeyframeLogReader.scan` stops at the first truncated or corrupt record without throwing; a writer that reopens a log truncates the partial tail before appending.
- **Little-endian on disk, always**, documented in FORMAT.md, with the Apple-platform memory layout written directly (the codec asserts nothing about host endianness because every Apple platform is little-endian).
- **LZFSE for depth (u16 mm) and confidence (u8)** through the Compression framework; encode buffers are sized `src + 4096` because LZFSE stores incompressible blocks raw with a small header.
- **`ARWorldMap` is saved only when `worldMappingStatus == .mapped`**, with a 6 s timeout, and never blocks the save; failures are logged and `has_world_map` stays false.
- **Finalize order:** stop intake → drain in-flight keyframes → world map → PLY (streamed straight from the GPU buffer) → thumbnail → fsync log → manifest. Progress is reported per step. The AR session keeps running through finalize so `getCurrentWorldMap` can succeed, and stays running afterward for a quick next scan.
- **`status == recording|finalizing` on launch → `failed`**, plus a Rebuild action in the list that runs `CloudRebuilder` over the log and regenerates PLY, thumbnail and manifest.
- **Session log** is a plain text file with ISO 8601 timestamps and `[category]` tags, mirrored to `os.Logger` (subsystem `tech.alandiza.roommapper`, categories `capture`, `cloud`, `storage`, `render`, `thermal`, `app`).

## Process

- **Feature branches → `dev` → `release/ios-client-arkit-vslam`**, merged with `git commit-tree` plus fast-forward pushes rather than checking out `dev`. The repository sits in an iCloud-synced `~/Documents`; a checkout that deleted and re-created files produced `Pose 2.swift`-style duplicates that broke the build once, so the working tree is never switched to a branch with a different file set.
- **MapCore was implemented by parallel agents in isolated worktrees against the API contract in PLAN.md §3**, then integrated, reviewed through four lenses (spec, tests, bugs, concurrency/performance) with two adversarial verifiers per finding, and fixed. The app layer was written as one coherent unit because ARKit/Metal/SwiftUI isolation crosses every file.

## Dynamic environments and resolution (added 2026-09-03)

- **`DynamicVoxelMap` replaces the first-sample-wins `VoxelGrid` in the live pipeline.** Each voxel keeps a weight-capped running mean of position and color (denoising plus slow adaptation) and a log-odds occupancy score. Every keyframe first *carves*: existing voxels inside the keyframe's frustum are projected into its depth image and receive a miss when a high-confidence ray demonstrably passes through them (measured depth > voxel depth + margin) or support when they are re-observed. Voxels whose score drops to the death threshold are parked out of view immediately and physically removed at the next compaction. This is the visibility-based approach of OctoMap ray updates and Removert-style discrepancy checks, applied incrementally at keyframe rate on the phone; ERASOR-style scan-ratio tests were not adopted because they need local submaps rather than a single depth image.
- **Parameters:** initial score 2, hit +2, miss −4, max 12, death ≤ −4. A freshly seen voxel dies after two clean misses (noise, people walking through); a well-observed object that leaves dies within four keyframes (~1.3 s at 3 kf/s). Misses require ARKit confidence *high* because confidence drops at depth discontinuities, which limits erosion of thin structures. Depth margin = max(4 cm, 3 % of depth).
- **Chunk culling:** 4096-point chunks carry axis-aligned bounds tested against the frustum via their eight corners, so the carving pass only visits points in view. Dead voxels are compacted when they exceed 2 % of the map (min 2 000), which rebuilds the hash (keys recomputed from fused positions, exact because a mean of samples inside a cell stays inside it) and the chunk bounds. `.full` is no longer permanent: compaction frees capacity.
- **GPU mirror updates in place.** Fused positions and parked voxels are written into the shared point buffer at their index; a renderer can see one torn point for one frame, which is cosmetic. Compaction and coarsening swap buffers as before. `VoxelGrid` remains for `CloudRebuilder` (static recovery from the log) and its tests.
- **High-resolution mode:** 1 cm voxels (coarsening to 2 cm at the 3 M cap), keyframe thresholds 0.10 m / 8° / 0.5 s, fusion weight cap 8. ARKit scene depth stays 256×192; resolution beyond that comes from multi-view fusion, not from the sensor. A separate **4K color** toggle uses `recommendedVideoFormatFor4KResolution` (30 fps) for sharper point colors at the cost of the 60 fps preview; the AR session restarts when it is toggled outside a recording.
- **Perspective point size** (∝ 1/depth, clamped) in the live and cloud shaders; orthographic top-down views keep a constant size.
- **Debug builds now compile with `-O`** so on-device numbers reflect optimized code; Release adds whole-module optimization.

## Confirmation-gated dynamic map (replaces the first dynamic map, 2026-09-03)

- **Why the first version left ghosts on the device:** carving only trusted *high* ARKit confidence, which indoors is rare beyond arm's reach, so free-space evidence was mostly ignored; carving ran only on keyframes (every 0.75 s when standing still); and every single observation was rendered immediately.
- **Confirmation gating.** A voxel is stored on its first observation but parked out of view; it is shown only after `confirmHits` (2) separate integrations observe it (sample fusion or projection support). Voxels seen once — people walking through, hands, flying pixels — never render, and unconfirmed voxels not re-observed within `maxUnconfirmedAge` (24) integrations are dropped by a periodic sweep.
- **Confidence-weighted carving.** In-view voxels get a miss of −4 (high-confidence ray beyond them), −2 (medium), or −1 (pixel with no usable measurement); unconfirmed voxels die on their first miss, confirmed ones at score ≤ −4 from a max of 12. Occlusion (measurement nearer than the voxel) is still neutral so static geometry behind a person survives. Carve range extended to 8 m.
- **Carve-only frames at 4 Hz.** Between keyframes the controller sends depth-only snapshots (no color sampling, nothing written to the log, no trajectory point) so stale voxels clear even when the phone is still. They count toward `keyframeIndex` (the age clock) but not toward keyframes.
- **Settings.** `Quality` preset (Performance 3 cm / stride 2 / 1.5 M cap, Balanced 2 cm, Quality 1 cm with denser keyframes) and `Dynamic objects` sensitivity (Conservative / Normal / Aggressive: miss weights, death threshold and unconfirmed age) are exposed in the capture settings menu and persisted; they also set the draw budgets (main view 0.4/1/1.5 M points, Ghost Map 150/250/400 k) and the carve interval (0.5/0.25/0.2 s).

## Account and backend API client (Phase 2 §5, added 2026-09-04)

- **Both wire spellings decode into the same model.** `ghostmap-backend` serialises hand-written
  payloads as `snake_case` (`share_url`, `next_cursor`, `device_id` on participants) but returns
  database rows straight from Drizzle, whose keys are the lower-camel form of the same column
  names (`pointCount`, `parentMapId`, `inviteCode`). `MapCore.SnakeCase.toCamelCase` therefore
  deliberately does **not** uppercase acronyms — `device_id` → `deviceId`, not `deviceID` — because
  that is exactly the form Drizzle emits, so one set of DTOs reads both, and keeps reading them if
  the backend later normalises everything to `snake_case`. Requests are always encoded as
  `snake_case`, which is what the server's zod validators expect. Swift property names read a
  little less idiomatically (`deviceId`, `pictureUrl`) as the price.
- **Opaque JSON subtrees are exempt from key conversion.** `GhostmapJSON.opaqueKeys` =
  `headers`, `token_request`/`tokenRequest`, `manifest`, `details`. Without this, GCS header names
  (`Content-Type`, `x-goog-resumable`) and the Ably token request (`keyName`, `mac`, `nonce`) would
  be rewritten and become unusable. The strategy inspects the whole coding path, so *everything*
  below one of those keys passes through verbatim.
- **Only idempotent requests are retried.** `RetryPolicy` (3 attempts, 0.5 s → 1 s, half jitter,
  capped at 8 s) is applied to `GET`s, `upload-urls`, `finalize`, `join`, `leave`, `end`,
  `realtime/token` and `PATCH`/`DELETE` on a map; `POST /v1/maps`, `POST /v1/sessions` and
  `POST /v1/sessions/:id/keyframes` are never repeated automatically because a repeat would create
  a second map, a second party or duplicate keyframe rows. Retries cover 5xx/408/429 and transient
  transport errors, and honour `Retry-After` when it is longer than the computed backoff.
- **The token is read from the keychain per request**, not cached in the actor, so signing out
  takes effect on the next call with no invalidation dance. The read is a synchronous `SecItem`
  lookup inside the actor; it is a few hundred microseconds and only happens once per request.
- **`ISO8601DateFormatter` is built per timestamp** rather than shared: it is not `Sendable`, and a
  response carries a handful of dates at most.
- **Errors are typed end to end.** `GhostmapAPIError`, `GoogleSignInError`, `KeychainError` and
  `BackendURL.ValidationError` are used with Swift 6 typed `throws`, so a caller sees the exact
  failure set. `WireString` (role, status, participant kind, join rejection, file name) keeps
  unknown server values decodable instead of failing the whole response.
- **PKCE, the OAuth URL, the callback parsing, the snake_case mapping, the retry schedule and the
  backend-URL validation all live in `MapCore/Backend/`** with unit tests; `App/Cloud/` only does
  `ASWebAuthenticationSession`, `URLSession` and the keychain. `Cloud/` inside MapCore already
  means *point cloud*, hence the separate `Backend/` directory.
- **The client id is a build input, not a secret.** `GhostmapGoogleClientID` in Info.plist ships
  empty; with no usable id `GoogleSignIn.init` fails and the Settings screen explains why the
  button is disabled. iOS OAuth clients have no client secret, so nothing secret is embedded.
  The reversed-client-id URL scheme is registered in `CFBundleURLTypes` next to the `ghostmap://`
  scheme that the party join links will use.
- **The device identity is a UUID in the keychain** (`kSecAttrAccessibleAfterFirstUnlock`, not
  synchronised to iCloud — a token belongs to one phone), mirrored into `UserDefaults` so a
  keychain that is unavailable (simulator without an entitlement) still yields a stable id for the
  install instead of a new device row per launch. Signing out clears the credentials and keeps the
  identity.
- **Signing in as "this phone" is a choice.** With the device identity the backend returns a
  30-day `device` token that may upload maps and stream keyframes; without it, a 7-day `user`
  token that may only view. The toggle is in Settings and defaults to on.
- **The app-layer DTOs have no XCTest target** (the project has none, and MapCore is for pure
  logic). `scripts/api-smoke/main.swift` compiles the models against MapCore on the Mac and asserts
  they decode payloads shaped like the real ones; the header says how to run it.

## Marker origin (Phase 2 §5, added 2026-09-04)

- **The marker is generated, not drawn.** `scripts/make-marker.py` (stdlib only: `zlib`, `struct`)
  renders `App/Marker/ghostmap-marker.png` — 2000 × 2000 px, 8-bit RGB, `pHYs` = 10 000 px/m so
  "print at 100 %" gives exactly 20 cm — and `docs/ghostmap-marker.pdf`, an A4 page carrying the
  same square at 566.93 pt with a measuring bar. The PDF embeds the *same* zlib stream as the PNG's
  `IDAT` via `/Predictor 15`, so there is no second image encoder to maintain. Both files are
  committed: the PNG is a build input, and asking every user to run Python before printing would be
  worse than 34 KB in git.
- **Determinism over `random`.** The 8 × 8 payload comes from a hand-written xorshift64\*, not
  `random.Random`, so the bytes never depend on the Python build. The generator retries until the
  grid is 40–60 % black, differs from all three of its rotations, has ≥ 2 cells of each colour in
  every row and column, and contains no uniform 3 × 3 block — the last one because large flat areas
  are exactly what makes ARKit grade a reference image as low quality. `--check` re-derives
  everything and diffs it against the files on disk.
- **The orientation corner is explicit.** The top-left 2 × 2 cells are forced black and the other
  three corners white. The seeded interior is already rotationally unique, but a corner a human can
  see makes "which way up" obvious when taping the sheet to a wall, and it keeps the guarantee if
  the seed ever changes. A 2-unit (4 mm) white gap separates the payload from the black frame so
  payload cells never fuse with it.
- **Folder reference, not an asset catalog.** `ARReferenceImage` needs a `CGImage`, and asset
  catalogs would only add a build step. project.yml adds `App/Marker` as a folder reference in the
  resources phase, so the file lands at `Marker/ghostmap-marker.png` in the bundle unmodified (no
  PNG re-encoding) and `MarkerReference` reads it with `Bundle.main.url(forResource:…)`. The loader
  also falls back to the bundle root so a flattened resource build keeps working. Decoding costs
  ~16 MB of resident memory for the lifetime of the AR configuration; that is the price of a 2000 px
  reference image and is paid once per session.
- **`.lost` still counts as aligned.** `MarkerOrigin.State` is `.none` / `.tracking` / `.lost`, and
  `isAligned` is true for both `.tracking` and `.lost`. Once ARKit has placed the image anchor the
  world→origin transform stays valid whether or not the marker is in view — the anchor lives in the
  world frame — so poses stay in the marker frame and the wire `aligned` flag stays `true`. `.lost`
  only tells the user that drift is no longer being corrected, which is why the chip goes amber
  rather than grey. Only `.none` (nothing ever seen) sends `aligned: false`.
- **A stale-timeout demotes the origin.** ARKit does not reliably deliver a final `isTracked == false`
  anchor update, so `MarkerOrigin.tick(timestamp:staleAfter:)` runs in the frame callback (two float
  comparisons, well inside the 2 ms budget) and drops `.tracking` to `.lost` after 1 s without a
  tracked observation. `didRemove` maps to the same `.lost`, never back to `.none`.
- **The local map is still session-start.** `KeyframeProcessor` keeps writing `camera.transform`
  and `manifest.origin` stays `session-start`: `keyframes.bin` and `cloud.ply` are a single-phone
  artifact and rewriting them into a frame that may only appear halfway through a recording would
  break rebuild. The marker frame is applied at *upload* time — `CaptureSession.alignedPose(…)` /
  `cloudOrigin` — which is what the party contract actually asks for.
- **Detection images live in the configuration**, so changing the marker toggle or size re-runs the
  session (`.resetTracking`) exactly like the 4K toggle, and only outside a recording; restarting
  mid-recording would split the map's world frame. A missing or undecodable PNG disables the marker
  origin and surfaces one warning line — capture itself never fails for it.
- **Marker detection defaults to on.** One reference image with `maximumNumberOfTrackedImages = 1`
  is cheap, and a party created while the setting was quietly off would upload unaligned poses that
  nobody notices until the clouds do not line up. The strip's grey `Marker: none` chip makes the
  state visible, and the toggle is one tap away in the capture menu.

## Parties (Phase 2 §5, added 2026-09-04)

- **Ably without the Ably SDK.** The no-third-party rule means no `ably-cocoa`, so `AblyRealtime`
  speaks the two pieces of Ably's protocol the app needs: subscribing over the **SSE adapter**
  (`GET https://realtime.ably.io/sse?channels=…&v=1.2&accessToken=…` read by a streaming
  `URLSession` data task via `URLSession.bytes(for:)`) and publishing over **REST**
  (`POST https://rest.ably.io/channels/<channel>/messages`). Both are documented, versioned Ably
  HTTP endpoints, so this does not depend on SDK internals.
- **The token needs one extra hop.** `POST /v1/realtime/token` returns a signed Ably *TokenRequest*
  (`keyName`, `nonce`, `mac`, …), which is what an SDK's `authCallback` would consume — it is not a
  token. `AblyRealtime` does what the SDK would: `POST https://rest.ably.io/keys/<keyName>/requestToken`
  with that object, and uses the `token` it gets back. `AblyWire.tokenSource` also accepts a
  `TokenDetails` object or a bare token string, so a backend that starts returning either keeps
  working. REST auth is `Authorization: Bearer <base64 of the token>`, per Ably's token auth.
- **Presence is read-only from here.** Ably can only be *entered* into presence over a realtime
  (WebSocket) connection; the REST API exposes presence for reading (`GET /channels/:ch/presence`),
  which `AblyRealtime.presenceMembers()` uses, but there is no REST "enter". So this phone does not
  appear in Ably presence. It announces itself the two ways it can: the backend publishes a
  `participant joined` message on join, and the phone publishes `pose` messages carrying its
  `device_id`. The party screen's live dots come from those poses (a peer is "streaming" while its
  last message is under 15 s old), not from Ably presence. Entering presence properly needs either a
  WebSocket implementation or the SDK; neither is worth it for a dot.
- **Reconnect, do not fail.** The SSE loop reconnects with doubling backoff capped at 30 s, resumes
  from the last event id (`&lastEvent=`), and drops the cached token on 401/403 so the next attempt
  fetches a fresh one. Losing the channel is reported as `degraded` in the UI, never as a failure:
  keyframes keep uploading over the API, only the *live* view of peers is affected. The only
  non-retryable case is `notConfigured` (the deployment has no Ably), which stops the loop.
- **Poses are published on movement, not on a metronome.** The publish loop ticks every 100 ms —
  the contract's 10 Hz ceiling — but only sends when the camera moved more than 1 cm or turned more
  than 1°, plus a 1 s heartbeat. A phone sitting on a table therefore costs 1 message/s instead of
  10, which matters because Ably's free tier is counted in messages.
- **`points_inline` is "what this keyframe confirmed", not "what it saw".** `DynamicVoxelMap`
  parks unconfirmed and dead voxels out of view, and a voxel needs two observations before it is
  shown, so `Integration.appended` alone would be almost entirely parked entries.
  `InlinePoints.select` takes the renderable points from **both** `appended` and `updates` — the
  latter is where a keyframe's freshly confirmed and re-fused voxels appear — then decimates to
  2 000 with a uniform stride. Positions are re-expressed in the party origin frame with the same
  transform as the pose, so a viewer can draw them without touching the pose.
- **A bounded queue that drops the oldest.** `KeyframeStreamer` holds ten keyframes; an eleventh
  evicts the *oldest*, because a live viewer wants the newest data and a stalled uplink otherwise
  grows without limit. Drops are counted and shown in the Ghost Map strip. Nothing in the capture
  path ever awaits the network: `CaptureSession` hands the keyframe to the actor and returns.
- **A failed upload still registers the keyframe.** If the signed-URL call or a PUT fails, the round
  still `POST`s the keyframe rows so peers get the inline points and the pose; only the depth blob is
  missing (counted as `partial`). Depth is for the offline merge, inline points are for the live
  view, and losing the first should not cost the second.
- **The party frame is resolved on the main actor, at capture time.** `CaptureSession.handleKeyframe`
  computes `AlignedPose` from the marker origin *before* dispatching to the processor: by the time
  the actor finishes, the origin may have moved (or been lost). The processor hands back the
  quantized depth it already produced, so the streamer never quantizes a second time.
- **Peers are drawn through `world_from_origin`.** Peers publish in the party's origin (marker)
  frame; this phone renders in its ARKit world frame. Rather than transform every incoming point,
  the renderers multiply the view-projection by `world_from_origin` for peer draws — one matrix
  multiply per frame instead of a pass over the cloud. Before this phone has seen the marker the
  transform is identity and the strip says so, because peers genuinely cannot be placed yet.
- **One `SharedPointBuffer` per peer, with a CPU ring behind it.** Each peer gets its own 150 000-point
  buffer, which keeps the draw call per peer trivial and lets a peer be removed without touching the
  others. A CPU copy in insertion order backs it so the *oldest* points are dropped when it fills;
  the wrap does a `replaceAll` roughly once every 25 s per peer, far enough apart that the buffer's
  double-buffer swap is never re-entered inside a frame (the invariant that type documents).
- **Peers' points are tinted, not recoloured.** `PartyColor.tinted` blends 55 % of the party colour
  into the captured colour: enough that whose points are whose is obvious at a glance, little enough
  that the room is still recognisable. The eight colours are the backend's palette, and when a
  participant row carries no colour the join index picks one, so peers stay distinguishable offline.
- **The invite code folds `0` → `O` and `1` → `I`.** Neither digit exists in RFC 4648 base32, so the
  substitution can never turn one valid code into a different valid code — it can only rescue a code
  someone typed off a screen. Everything else matches the backend's `normalizeInviteCode`.
- **`ghostmap://join/<code>` is handled by the app, not by a route table.** `PartyCode.code(from:)`
  accepts the app scheme and any `…/join/<code>` share link, and only when the segment before the
  code is `join`, so an unrelated deep link cannot look like an invite. A link that arrives before
  `AppEnvironment` finishes starting is held in `RootView` and replayed.
- **The party outlives the capture screen.** `PartySession` lives on `AppEnvironment`, so leaving the
  capture screen does not leave the party, and the map list shows the code in its toolbar. The
  membership (session id + code) is written to `UserDefaults` so a relaunch can offer **Rejoin** —
  the one operation the backend guarantees is always allowed.
- **Wire logic lives in MapCore.** `PartyCode`, `PartyColor`, `InlinePoints`, `AblyWire` and the SSE
  parser (`ServerSentEventParser`) are pure and unit tested (the app itself had no test target of
  any kind at the time — `RoomMapperUITests` below is UI-level, not a substitute for unit-testing
  internals). The SSE
  parser implements the WHATWG field rules — sticky `id`, one optional space after the colon,
  multi-line `data`, `:` comments as Ably's heartbeat — so reconnect resumption and heartbeat
  handling are testable without a network.

## Cloud upload (Phase 2 §5, added 2026-09-04)

- **Progress is a `@MainActor` closure, not a polled snapshot.** `KeyframeStreamer` (parties) is
  polled every 500 ms from an `@Observable` wrapper because it runs continuously and nobody is
  waiting on one specific call. `MapUploader.upload` is one bounded call a screen is actively
  watching, so it takes an `onProgress: @MainActor @Sendable (MapUploadProgress) -> Void` and
  `await`s it at each step instead — the actor hops to `MainActor` to hand the update over and does
  nothing else there, so `AppEnvironment` can write straight into its `@Observable` `uploadStatus`
  dictionary with no separate poll loop, no timer to leak, and no chance of missing a fast step.
- **Only `cloud.ply` failing aborts the upload.** The backend's `POST /v1/maps/:id/finalize`
  refuses to finalize without it (`API.md`), so there is no point calling finalize if it did not
  land. Every other file (manifest, thumbnail, log, world map) is best-effort, same as
  `KeyframeStreamer`'s depth payload: a map with a missing thumbnail is still a saved map, and
  finalize's `present` list on the backend already degrades gracefully to whatever actually
  uploaded.
- **Upload tickets are matched to files by path suffix, not by an explicit field.** `SignedUpload`
  (API.md) carries `path`, not a `file` enum — the backend names objects
  `maps/<mapId>/<filename>` (`mapObjectPath` in ghostmap-backend's `gcs.ts`), and `CloudMapFile`'s
  raw values are exactly those filenames, so `ticket.path.hasSuffix("/" + file.rawValue)` finds the
  right ticket without the wire format needing to change.
- **Resumable uploads read from disk, never load the point cloud into `Data`.** `cloud.ply` and
  `keyframes.bin` can be tens of megabytes; every other file is small enough that
  `Data(contentsOf:)` plus a single `PUT` (mirroring `GhostmapAPI.performOnce`'s `session.data(for:)`
  shape) is simplest. For the two large files, `MapUploader` follows GCS's resumable protocol
  (`API.md`): an empty-body `POST` opens the session, its `Location` header is where the bytes
  actually go, and *that* `PUT` uses `URLSession.uploadTask(with:fromFile:)` — a
  completion-handler API bridged with `withCheckedContinuation` since there is no `async` overload
  that reads from a file URL instead of `Data`. No chunking: one `PUT` of the whole file, same as
  the plan called for.
- **Progress is file-granularity, not byte-granularity.** Getting byte-level progress out of
  `uploadTask(with:fromFile:)` needs a `URLSessionTaskDelegate` (KVO on the task's `Progress` object
  races the completion handler firing). "Uploading cloud.ply…" plus a completed/total fraction over
  six files is enough for the UI this needs — a delegate class for a smoother progress bar was not
  worth it here.
- **Re-upload reuses the cloud map id instead of creating a second one.** With
  `manifest.cloudMapId` already set, `MapUploader.upload` calls `POST /v1/maps/:id/upload-urls` on
  the existing id rather than `POST /v1/maps` — exactly what that endpoint is for ("fresh tickets
  for files that expired or failed", API.md) — then finalizes the same record again. The Upload
  button in `MapDetailView` becomes **Re-upload** once a cloud id exists, so retrying a failed
  attempt or pushing a rename does not pile up duplicate cloud maps for one phone recording.
  `manifest.json`'s `cloud_map_id` is what makes this possible across relaunches; it is optional
  and omitted (not `null`) until the first successful upload, matching every other optional field
  in the manifest.
- **`-uiTesting` stubs the network from inside the app, not from the test process.** XCUITest
  drives the app as a separate process over the accessibility tree; it cannot inject a URL protocol
  into that process from outside. So `RoomMapperApp.init()` calls
  `UITestSupport.activateIfNeeded()` before `AppEnvironment` builds any `URLSession`, and — only
  when the `-uiTesting` launch argument is present — it registers `UITestStubURLProtocol` globally.
  `URLProtocol.registerClass` is honored by every `URLSession` built from a `.default`
  configuration (which is all of them here: `GhostmapAPI`, `KeyframeStreamer`, `MapUploader`), so
  no session needs to know the stub exists. None of the three `RoomMapperUITests` need a real
  response (the flows they cover — map list, Settings, a malformed party code — never get past
  local validation), so the stub answers `/health` with a plausible body and everything else with a
  501, loud enough that a future test relying on more would fail fast instead of hanging on a real
  request.
- **The UI test target shares the app's scheme instead of getting its own.** XcodeGen's
  `RoomMapper.scheme.testTargets: [RoomMapperUITests]` adds a Test action to the existing
  `RoomMapper` scheme, and `TEST_TARGET_NAME: RoomMapper` on the test target's settings is what
  lets a UI test bundle run inside the app's process rather than needing one of its own. This is
  what makes `xcodebuild test -scheme RoomMapper -only-testing:RoomMapperUITests`
  (`scripts/rm.sh test-ui`) work without a second generated scheme to keep in sync.
