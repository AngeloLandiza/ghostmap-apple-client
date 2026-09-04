# Ghostmap

*Codename RoomMapper.* A local-first iPhone app that maps a room with LiDAR and keeps the map honest while the room changes.

Point the phone around a room and Ghostmap builds a colored 3D point cloud on the device, in real time, with no server, no account and no network. The **Ghost Map** in the corner shows the whole map as it grows, and the map itself forgets what is no longer there: people walking through, a chair that was moved, a door that opened.

Built for iPhone 16 Pro Max (any iPhone or iPad with a LiDAR scanner works), iOS 18 or later.

## What it does

- **Live capture** with ARKit world tracking and scene depth: camera feed plus the current frame's depth as colored points, at 60 fps.
- **Dynamic global map**: a voxel map that fuses repeated observations, shows geometry only after it has been seen twice, and carves away anything the depth camera can see through. Ghosts of moved objects disappear within seconds.
- **Ghost Map panel**: a translucent miniature of the entire map in the top-right corner, top-down or orbiting, with the walked trajectory and the camera frustum. Tap to expand, long-press to change view, swipe down to shrink. A status strip shows tracking, keyframes, points, time, size, thermal state and frame rate.
- **Quality and performance presets**, a dynamic-object sensitivity setting, optional 4K color and a high-confidence-depth mode.
- **Marker origin**: print the 20 cm marker in `docs/ghostmap-marker.pdf`, point the phone at it, and poses are expressed in the marker's frame — the shared origin collaborative sessions need. The status strip shows `Marker: aligned / lost / none`.
- **Everything stays on the phone**: each map is a folder with a manifest, an append-only keyframe log (LiDAR depth and confidence, compressed), a PLY point cloud, a thumbnail, a best-effort ARKit world map and a session log. Maps are visible in the Files app.
- **Map library**: thumbnails, editable names, stats, a 3D viewer with orbit / pan / zoom, PLY export through the share sheet, delete, and recovery of interrupted recordings from the keyframe log.
- **Cloud, account and parties** (all optional): sign in with Google to upload a map to the
  Ghostmap backend — automatically after it saves, or on demand from its detail screen — and to
  start or join a **party**, where several phones stream keyframes into one shared, live point
  cloud. See [docs/USAGE.md](docs/USAGE.md).

## Quick start

Requirements: macOS with Xcode 26 or 27 (the Metal toolchain component is downloaded on first setup), Homebrew, and an iPhone with LiDAR connected over USB with Developer Mode enabled.

```bash
git clone https://github.com/AngeloLandiza/apple-VSLAM-client.git && cd apple-VSLAM-client
scripts/rm.sh setup     # XcodeGen + Metal toolchain (once)
scripts/rm.sh all       # unit tests, signed build, install, launch with the console attached
```

On the first launch trust the developer profile on the phone (Settings → General → VPN & Device Management) and allow camera access. Then tap **Scan**, press the red button, walk slowly around the room, press the square to stop, and open the saved map from the list.

More commands: `scripts/rm.sh test-unit | test-ui | build | run | marker | pull-maps | devices | clean`. `test-ui` runs `RoomMapperUITests` on the connected device (no camera needed; see TESTING.md). To use Xcode instead, run `scripts/rm.sh gen` and open `RoomMapper.xcodeproj`. Signing is automatic; set your team in `project.yml` if it differs.

## How it works, in one paragraph

Every ARKit frame is drawn immediately from GPU textures (no copies). A keyframe policy picks frames after 15 cm of motion, 12° of rotation or 0.75 s; each keyframe's 256×192 depth map is unprojected on a background actor, colored from the camera image and fused into a 2 cm voxel map. Between keyframes, depth-only frames at 4 Hz carve free space so stale voxels are removed even when the phone is still. The map lives in one GPU buffer that the main view, the Ghost Map and the PLY exporter all read. Every keyframe is appended to an on-disk log as it happens, so a crash never loses more than the last frame.

Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/DYNAMIC-MAP.md](docs/DYNAMIC-MAP.md).

## Documentation

| Document | What it covers |
|---|---|
| [docs/USAGE.md](docs/USAGE.md) | Using the app: capture screen, Ghost Map gestures, settings, account sign-in, cloud upload, parties, marker printing, map library, export, recovery, logs |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Modules, data flow, concurrency model, rendering, storage flow, extension points |
| [docs/DYNAMIC-MAP.md](docs/DYNAMIC-MAP.md) | The confirmation-gated voxel map: fusion, carving, parameters, presets |
| [docs/ghostmap-marker.pdf](docs/ghostmap-marker.pdf) | The printable 20 cm origin marker (print at 100 %); regenerate with `scripts/rm.sh marker` |
| [FORMAT.md](FORMAT.md) | On-disk format of a map, precise enough for a Python reader |
| [DECISIONS.md](DECISIONS.md) | Every non-obvious engineering decision and why |
| [TESTING.md](TESTING.md) | Budgets, unit-test status and the device test log |
| [PLAN.md](PLAN.md) | The original build plan and MapCore API contract |
| [CHANGELOG.md](CHANGELOG.md) | Release notes |

## Project layout

```
scripts/rm.sh            build / test / run pipeline
project.yml              XcodeGen spec (RoomMapper.xcodeproj is generated, not committed)
Packages/MapCore/        pure Swift package: geometry, keyframe policy, voxel maps, codecs, storage, backend, party wire formats; 464 unit tests
App/                     iOS app: Capture (ARKit, keyframe processing), Rendering (Metal), Cloud (backend client, upload, parties, Ably), UI (SwiftUI), Support
App/Marker/              the origin marker PNG copied into the app bundle (generated by scripts/make-marker.py)
RoomMapperUITests/       XCUITest target covering launch, Settings and party-code validation (scripts/rm.sh test-ui)
docs/                    documentation
```

## Status

Version 0.2.0. Compiles in Swift 6 language mode; MapCore's unit tests pass on macOS. Device testing so far has been informal (capture, Ghost Map, dynamic removal); measured budget numbers are still to be recorded in TESTING.md.

Known limitations: if the app is interrupted mid-recording (call, app switch) ARKit may re-anchor and later points can land in a shifted frame; rebuilt clouds are gray because the keyframe log carries no color; LiDAR depth is 256×192, so fine detail comes from multi-view fusion rather than the sensor; no relocalization into a stored map yet.

Marker-based origins, cloud upload and collaborative parties are all implemented — accounts,
upload with progress and a cloud badge, and live multi-phone sessions over the marker's shared
origin. See [docs/USAGE.md](docs/USAGE.md) for how to use them and [DECISIONS.md](DECISIONS.md)
for the non-obvious choices behind them.
