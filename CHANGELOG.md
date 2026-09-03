# Changelog

## 0.1.0 — 2026-09-03 (release/ios-client-arkit-vslam)

First release of Ghostmap (codename RoomMapper).

- ARKit + LiDAR capture with a 60 fps Metal live preview and a ≤ 2 ms main-thread AR callback.
- Keyframe policy (0.15 m / 12° / 0.75 s, thermal halving/pausing) with an append-only, crash-safe keyframe log (u16 mm depth + confidence, LZFSE, CRC per record).
- Confirmation-gated dynamic voxel map: weighted fusion, confidence-weighted free-space carving at 4 Hz, transient purging, compaction, coarsening at the 3 M cap.
- Ghost Map overlay: top-down or orbit, trajectory, frustum, 5 Hz status strip, expand / shrink / gestures, frame skipping when the main view is behind.
- Map library with thumbnails, rename, delete, 3D detail viewer, PLY export and rebuild-from-log recovery; maps visible in the Files app.
- Quality presets (Performance / Balanced / Quality), dynamic-object sensitivity, 4K color and high-confidence-depth options.
- `scripts/rm.sh` pipeline (setup, gen, test, build, install, launch, run, pull-maps, devices, clean).
- MapCore package with 324 unit tests; Swift 6 language mode throughout.
