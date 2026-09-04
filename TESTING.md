# Testing log

Human-in-the-loop device tests. Every entry records date, build, test id, what was done, outcome, measured numbers and follow-ups. Unit tests (`swift test` in `Packages/MapCore`) run on the Mac before any device test. `RoomMapperUITests` (`scripts/rm.sh test-ui`) runs on the connected device alongside the device tests below — it needs no camera, so it is not gated on a T0–T3 session the way those are.

## Budgets (from the spec)

| Budget | Target | How it is measured |
|---|---|---|
| Main view frame rate | 60 fps steady, ≥ 30 fps while a keyframe is processed | `RenderClock` EMA of draw intervals, shown as `fps` in the Ghost Map strip |
| AR callback | ≤ 2 ms p95 on the main thread | `ContinuousClock` around `session(_:didUpdate:)`, 600-sample ring, `cb` in the strip and the finalize log line |
| Resident memory | ≤ 500 MB at the 3 M point cap | `task_vm_info.phys_footprint` sampled at 5 Hz (`mem` in the expanded strip) |
| On-disk size | ≤ 60 MB for a 3-minute scan | `size_bytes` in `manifest.json` and the map list |
| Finalize | ≤ 5 s for a 3-minute scan, with progress | `finalize_s` in `manifest.json`, finalize log line |

## Unit tests

| Date | Build | Result |
|---|---|---|
| 2026-09-03 | MapCore @ feature/mapcore | `swift test`: 317 tests, 0 failures, 0 warnings (macOS, Swift 6.4) |
| 2026-09-04 | MapCore @ feature/phase2-parties | `swift test`: 464 tests, 0 failures, 0 warnings (macOS, Swift 6.4) — adds `MapManifest.cloudMapId` coverage (`testCloudMapIdRoundTrip`, plus the existing key-count and round-trip tests) |

## UI tests (`RoomMapperUITests`)

New in Phase 2 §5 — the app's first XCUITest target (`scripts/rm.sh test-ui`), added because the
account/upload/party screens are worth checking mechanically and none of them need the camera.
Every launch passes `-uiTesting`, which stubs all network traffic
(`App/Support/UITestSupport.swift`) so these never depend on the test bench's network or a real
backend deployment. Runs on the connected device only — the simulator cannot run ARKit, so the
device is already required for everything else in this file.

| Test | Verifies |
|---|---|
| `testLaunchesToMapList` | The app opens straight to the map list with Scan and Settings reachable — no login wall. |
| `testSettingsShowsBackendURLFieldAndSignInButton` | Settings shows the backend URL field and offers Sign in with Google, entirely signed out. |
| `testPartyScreenRejectsMalformedCodeWithoutNetworking` | A malformed invite code never enables the lookup button — `PartyCode.isValid` gates it locally before any network call. |

| Date | Build | Result |
|---|---|---|
| _pending_ | | Not yet run on a connected device from this change; `xcodebuild build-for-testing` for the `RoomMapperUITests` target succeeds (see the PR/commit that added this section). |

## Device tests

| Date | Build | Test | Outcome | Numbers | Follow-ups |
|---|---|---|---|---|---|
| 2026-09-03 | dev c9fe7c7 | T0/T1 informal | App launched, captured and saved a room (reported by the owner) | not recorded | ghost points of removed objects remained → replaced the static grid with `DynamicVoxelMap` (5bf537f) |
| 2026-09-03 | dev 5bf537f | T1 informal | Dynamic map v1 still left ghosts | not recorded | carving required high confidence and ran only on keyframes → confirmation-gated map + 4 Hz carve frames (e1e5cd4) |
| 2026-09-03 | dev e1e5cd4 | T0 informal | Ghost Map framed wrongly (tiny cloud) | not recorded | parked points polluted the bounds → fixed (6c540b3) |
| _pending_ | | T2 Persistence | | | |
| _pending_ | | T3 Endurance | | | |
| _pending_ | | T4 Cloud upload | Upload a map from its detail screen and from the auto-upload setting; verify the cloud badge, the map on the dashboard, and a re-upload after a rename. | | |

## Planned test sequence

- **T0 Smoke (~30 s):** install, launch, camera permission, AR session starts; Ghost Map shows `normal` tracking and a growing point count while the phone is held still, then panned slowly.
- **T1 Capture (60–90 s):** walk slowly around the room, tap Stop, map saves. Verify keyframe count, point count, save time, file sizes.
- **T2 Persistence:** kill and relaunch; the map appears in the list with thumbnail and stats; the detail viewer renders it; PLY export via the share sheet works (AirDrop to Mac or Save to Files).
- **T3 Endurance (5 min):** continuous capture. Verify memory stays under budget, FPS holds, thermal state transitions and the policy response behave as designed.
- **T4 Cloud upload:** sign in as this phone, capture a small map, upload it from the detail screen; verify progress, the cloud badge, and that it appears in `GET /v1/maps` (or the dashboard). Rename it and re-upload; verify the cloud map id stays the same (`cloud_map_id` in `manifest.json` is unchanged) rather than a second map appearing.
