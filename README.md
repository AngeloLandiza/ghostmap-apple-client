# RoomMapper

A local-first iOS room mapper for iPhone 16 Pro Max. It uses ARKit world tracking (visual-inertial odometry) plus the LiDAR scene-depth API to build a colored point cloud of a room, stores every map on the phone, and shows the map's live status in a translucent **Ghost Map** panel in the top-right corner of the capture screen. No backend, no network, no third-party dependencies.

This is the standalone, single-phone example of the iOS component described in the swarm-mapping MVP plan (§6 "iOS Client Design"). Marker-based origins, collaborative sessions, mesh reconstruction and uploads are deliberately out of scope; the extension points for them are listed at the end.

## What it does

- **Capture:** `ARWorldTrackingConfiguration` with `sceneDepth`, gravity alignment, no plane detection or scene reconstruction. Every frame is drawn live (camera feed + the frame's depth as colored points). A keyframe is emitted when the camera moved > 0.15 m, rotated > 12°, or 0.75 s elapsed, and tracking is normal.
- **Global cloud (dynamic):** each keyframe is unprojected on the CPU with the depth-scaled intrinsics and colored from the camera image, then fused into a 2 cm voxel map (1 cm in high-resolution mode) that keeps a running mean per cell and a log-odds occupancy score. Every keyframe also carves free space: voxels the new depth image sees through lose score and are removed, so people walking through or furniture that moves does not leave ghosts. The cloud is capped at 3 M points; at the cap it is coarsened once and carving keeps freeing capacity.
- **Settings:** a Quality preset (Performance / Balanced / Quality), a Dynamic-objects sensitivity (Conservative / Normal / Aggressive) and a 4K color toggle live in the capture screen's settings menu. New geometry is shown only after it has been seen twice; anything the depth image sees through is carved away at 4 Hz.
- **Ghost Map:** a second Metal view sharing the same GPU point buffer, drawing ≤ 250 k strided points at 55 % opacity, the keyframe trajectory and the camera frustum, top-down (north = initial heading) or orbiting. Tap to expand with orbit/pan/zoom, tap again or swipe down to shrink, long-press to switch top-down/orbit. A status strip updates at 5 Hz.
- **Persistence:** every map is a directory under `Documents/Maps/<mapID>/` (visible in the Files app) with `manifest.json`, an append-only `keyframes.bin` (LZFSE depth + confidence, CRC per record), `cloud.ply`, `thumbnail.png`, a best-effort `worldmap.arworldmap` and `session.log`. See [FORMAT.md](FORMAT.md).
- **Map list and detail:** thumbnails, editable names, stats, status; a detail viewer with orbit/pan/zoom; PLY export through the share sheet; delete; and a Rebuild action that recovers the cloud from the keyframe log after a crash.

## Repository layout

```
project.yml                 XcodeGen spec (generates RoomMapper.xcodeproj)
Packages/MapCore/           Pure-Swift package (Foundation, simd, Compression only); builds and tests on macOS
App/                        iOS app target: Capture, Rendering, UI, Support, Resources
PLAN.md                     Architecture, data flow, MapCore API contract
DECISIONS.md                Every non-obvious choice and why
FORMAT.md                   On-disk format, precise enough for a Python reader
TESTING.md                  Human-in-the-loop test log and measured budgets
```

## Build and run on the device

Requirements: macOS with Xcode 27 (beta at the time of writing), the Metal toolchain component, XcodeGen, and an iPhone with LiDAR (tested on iPhone 16 Pro Max, iOS 27.0). ARKit does not run in the Simulator; nothing here targets it.

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer   # only if xcode-select points elsewhere
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain                             # once, Xcode 26+
xcodegen generate
```

Run the MapCore unit tests on the Mac:

```bash
cd Packages/MapCore && swift test --scratch-path /tmp/mapcore-build   # scratch dir outside iCloud-synced folders
```

Build, install and launch on the phone (find the identifiers with `xcrun devicectl list devices`; use the hardware UDID for `xcodebuild` and the CoreDevice identifier for `devicectl`):

```bash
xcodebuild -project RoomMapper.xcodeproj -scheme RoomMapper \
  -destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates \
  -derivedDataPath /tmp/roommapper-dd build
xcrun devicectl device install app --device <COREDEVICE-ID> /tmp/roommapper-dd/Build/Products/Debug-iphoneos/RoomMapper.app
xcrun devicectl device process launch --device <COREDEVICE-ID> --console tech.alandiza.roommapper
```

Build outputs must live outside iCloud-synced folders (hence `/tmp`): files created inside `~/Documents` pick up Finder/iCloud extended attributes and `codesign` refuses them with "resource fork, Finder information, or similar detritus not allowed".

Before the first run: unlock the phone and keep it unlocked, enable Developer Mode (Settings → Privacy & Security → Developer Mode), and after the first install trust the developer profile (Settings → General → VPN & Device Management). Signing is automatic with the team ID in `project.yml`.

## Human-in-the-loop test protocol

Compiling and `swift test` never need permission. Anything that installs or launches on the phone is preceded by a short Test Brief (what is being tested, what the tester should do and for how long, what success looks like) and an explicit "Ready to test?" gate. After each test the tester's observations and the pulled logs are recorded in [TESTING.md](TESTING.md). Small tests early (T0 smoke) beat one big test at the end.

## Budgets and how they are measured

| Budget | Target | Source |
|---|---|---|
| Main view | 60 fps; ≥ 30 fps while a keyframe is processed | `fps` in the Ghost Map strip (EMA of draw intervals) |
| AR delegate callback | ≤ 2 ms p95 on the main thread | `cb` in the strip; p95 and max in the finalize log line |
| Memory | ≤ 500 MB at 3 M points | `mem` in the expanded strip (`phys_footprint`) |
| Disk | ≤ 60 MB per 3-minute scan | `size_bytes` in `manifest.json` |
| Finalize | ≤ 5 s with progress | `finalize_s` in `manifest.json` |

Measured values are recorded in TESTING.md after each device test.

## Logs

`os.Logger` subsystem `tech.alandiza.roommapper` with categories `capture`, `cloud`, `storage`, `render`, `thermal`, `app`. Each map also has a `session.log` with thermal transitions, tracking changes, timings and the budget numbers of that session. Launching with `devicectl … --console` streams the os_log output to the Mac.

## Extension points

- **Marker origin (MVP plan §6):** `MapManifest.origin` / `frame` and the pose written per keyframe in `KeyframeProcessor` (today `camera.transform`). A marker implementation detects an `ARImageAnchor`, stores `origin = {type: "marker", marker_id: …}` and writes `T_marker⁻¹ · camera.transform`.
- **Upload path (MVP plan §5.2, §7):** `MapStore` exposes every file URL; `keyframes.bin` records already contain the plan's live-keyframe fields (seq, timestamp, pose, intrinsics, tracking state, LZFSE depth and confidence) and `manifest.json` mirrors the map artifact manifest.
- **Meshes:** `ARSessionController.start()` sets `sceneReconstruction = []`; enabling it and handling `ARMeshAnchor` is the flagged v2 step.
