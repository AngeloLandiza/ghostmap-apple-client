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
