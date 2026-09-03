# Using Ghostmap

## Capture screen

Tap **Scan** in the map list. The camera feed appears with the current frame's LiDAR points overlaid; the map is not being recorded yet.

- **Red button** starts a recording. Walk slowly (about half a metre per second), keep surfaces 0.5–4 m away, and sweep the phone across walls, floor and furniture. Revisiting an area denoises it.
- **Square** stops and saves. Saving takes a few seconds and shows its steps (world map, point cloud, thumbnail, log sync, manifest).
- **✓ / ✕** returns to the list. It is disabled while recording or saving.
- **Slider icon** opens settings (see below). Quality and dynamic settings can only be changed before a recording starts; 4K color restarts the camera when toggled.

## Ghost Map (top-right panel)

| Gesture | Effect |
|---|---|
| Tap | Expand to full screen / shrink back |
| Long press | Toggle top-down and orbit views |
| Drag (expanded) | Orbit, or pan in top-down view |
| Two-finger drag (expanded) | Pan |
| Pinch (expanded) | Zoom |
| Fast swipe down (expanded) | Shrink |

Top-down view is oriented so the direction you were facing when the session started is up. Yellow line: the path of keyframes. Cyan pyramid: where the camera is now. Points are drawn at 55 % opacity so the camera feed stays readable.

The strip at the bottom shows: tracking state (green normal, amber limited with reason, red unavailable) and ARKit world-mapping status; keyframes, points, elapsed time and estimated size on disk; thermal state (green to red) and the main view's frame rate with the AR callback's 95th-percentile time. Expanded, it adds Ghost Map fps, keyframe processing time, memory, voxel grid state, policy mode, video format and log size. A warning line appears for thermal throttling, a full map, prolonged tracking loss or log write errors.

## Settings

- **Quality**: *Performance* (3 cm voxels, every second depth pixel, lighter draw budgets, 1.5 M point cap), *Balanced* (2 cm, default), *Quality* (1 cm voxels, keyframes every 10 cm / 8° / 0.5 s, larger draw budgets).
- **Dynamic objects**: how fast geometry that is no longer observed disappears. *Conservative* keeps briefly seen things, *Normal* clears a removed object in a few seconds, *Aggressive* in about a second (walls may flicker in poor lighting).
- **High-confidence depth only**: use only ARKit's highest depth confidence for the map (cleaner edges, fewer points).
- **Live depth points**, **Global cloud in main view**, **Ghost Map auto-orbit**: display toggles.
- **4K color (30 fps)**: sharper point colors at the cost of the 60 fps preview.

## Map library

Each map shows a top-down thumbnail, name (rename via swipe or long press), point and keyframe counts, duration, size and status. Swipe left to delete.

**Detail view**: drag to orbit, pinch to zoom, two-finger drag to pan; the menu switches top-down / orbit, resets the view, renames or deletes. **Export** shares `cloud.ply` (binary PLY with x y z r g b) via AirDrop, Files, Mail, etc. It opens in MeshLab, CloudCompare, Blender and Open3D.

**Recovery**: if the app was killed mid-recording, the map appears as *failed* with a **Rebuild** button that reconstructs the cloud from the keyframe log. Rebuilt clouds are gray (the log stores depth, not color).

## Files and logs

Maps live in the app's Documents folder: Files app → On My iPhone → RoomMapper → Maps → `<map id>/` with `manifest.json`, `keyframes.bin`, `cloud.ply`, `thumbnail.png`, `worldmap.arworldmap` (when ARKit reached "mapped") and `session.log`. See FORMAT.md for the byte layout. `scripts/rm.sh pull-maps` copies all of them to the Mac.

`session.log` records the video format, thresholds, thermal and tracking transitions, keyframe log errors, and a finalize summary with points, keyframes, dropped keyframes, duration, callback timing, processing time and memory. The same lines go to the unified log under subsystem `tech.alandiza.roommapper` (categories `capture`, `cloud`, `storage`, `render`, `thermal`, `app`), which `scripts/rm.sh launch` streams to the terminal.
