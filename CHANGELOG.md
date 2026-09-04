# Changelog

## Unreleased (feature/phase2-parties)

- **Parties**: create, join by code or `ghostmap://join/<code>` link, rejoin, leave and end, from a
  Party button on the map list and the capture screen. Party screen shows the code, a CoreImage QR
  code of the share link, the participant list with colours and live dots, and this phone's counters.
- **Keyframe streaming**: while recording in a party each keyframe gets batched signed upload URLs,
  its LZFSE depth and confidence payloads go straight to storage, and the row is registered with up
  to 2 000 confirmed inline points, poses in the marker origin frame when aligned. Bounded queue of
  ten, oldest dropped and counted.
- **Live peers**: an SSE subscription to the Ably channel (streaming `URLSession`, no SDK) feeds a
  `SharedPointBuffer` per peer; both renderers draw peers' points tinted with their party colour and
  a frustum per peer, and the Ghost Map strip gains a party line.
- **Pose publishing** over Ably REST at up to 10 Hz, sent only when the camera actually moved.
- MapCore gains `PartyCode`, `PartyColor`, `InlinePoints`, `AblyWire` and `ServerSentEventParser`,
  all unit tested (463 MapCore tests, up from 444).

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
