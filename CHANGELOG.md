# Changelog

## 0.2.0 — 2026-09-04 (feature/phase2-parties)

Ghostmap accounts, cloud maps and collaborative parties (Phase 2 §5).

- **Account**: Settings gains a backend URL field (with a "Test connection" check) and Google
  sign-in through `ASWebAuthenticationSession` with PKCE — no client secret, no password seen by
  the app. Signing in as this phone gets a 30-day device token that may upload maps and stream
  keyframes; signing in as a viewer gets a 7-day watch-only token. The token and this phone's
  identity live in the keychain.
- **Cloud upload**: a map can upload to the backend automatically after it saves (Settings →
  *Upload maps to cloud*, off by default) or on demand from a new Upload / Re-upload button in the
  map detail screen. `App/Cloud/MapUploader.swift` registers the map, `PUT`s every file that
  exists to its signed URL (a resumable `POST` + `PUT` straight from disk for the large
  `cloud.ply` and `keyframes.bin`, a single `PUT` for the rest), then finalizes with the manifest;
  progress and any error show inline, and the map list gains a cloud badge. `MapManifest` gains an
  optional `cloud_map_id`, written back once an upload succeeds so a re-upload updates the same
  cloud record instead of creating a second one.
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
- **Marker origin**: a printable 20 cm high-contrast marker (`docs/ghostmap-marker.pdf`,
  regenerated with `scripts/rm.sh marker`) detected as an `ARReferenceImage`; while it is in view
  poses are expressed in its frame (`aligned: true`) instead of the raw ARKit world pose, which is
  what lets several phones' clouds land on top of each other in a party.
- **Tests**: the app's first XCUITest target, `RoomMapperUITests` (`scripts/rm.sh test-ui`),
  covering launch → map list, Settings' backend/account fields and the party screen's local
  invite-code validation, with all network traffic stubbed via a `-uiTesting` launch argument
  (`App/Support/UITestSupport.swift`) so it never depends on a real backend or the test bench's
  network. `scripts/rm.sh` also gains `test-unit` (an alias for the existing `test`) alongside it.
- MapCore gains `PartyCode`, `PartyColor`, `InlinePoints`, `AblyWire`, `ServerSentEventParser` and
  `MapManifest.cloudMapId`, all unit tested (464 MapCore tests, up from 444).

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
