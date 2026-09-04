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

The strip at the bottom shows: tracking state (green normal, amber limited with reason, red unavailable) and ARKit world-mapping status; **Marker: aligned / lost / none** while marker detection is on (see *Marker origin* below); keyframes, points, elapsed time and estimated size on disk; thermal state (green to red) and the main view's frame rate with the AR callback's 95th-percentile time. Expanded, it adds Ghost Map fps, keyframe processing time, memory, voxel grid state, policy mode, video format and log size. A warning line appears for thermal throttling, a full map, prolonged tracking loss or log write errors.

## Settings

- **Quality**: *Performance* (3 cm voxels, every second depth pixel, lighter draw budgets, 1.5 M point cap), *Balanced* (2 cm, default), *Quality* (1 cm voxels, keyframes every 10 cm / 8° / 0.5 s, larger draw budgets).
- **Dynamic objects**: how fast geometry that is no longer observed disappears. *Conservative* keeps briefly seen things, *Normal* clears a removed object in a few seconds, *Aggressive* in about a second (walls may flicker in poor lighting).
- **High-confidence depth only**: use only ARKit's highest depth confidence for the map (cleaner edges, fewer points).
- **Live depth points**, **Global cloud in main view**, **Ghost Map auto-orbit**: display toggles.
- **4K color (30 fps)**: sharper point colors at the cost of the 60 fps preview.
- **Marker origin (20 cm)**: watch for the printed marker and use it as the origin of uploaded poses. The size in brackets is what is set in the map-list settings. Toggling it restarts the camera, so it is disabled while recording.

## Marker origin

Parties need every phone to agree on where the room's origin is. A printed marker provides it: each
phone that sees the same sheet expresses its poses in the marker's frame, so the point clouds land
on top of each other instead of wherever each phone happened to start.

**Print it.** `docs/ghostmap-marker.pdf` is an A4 page with the marker at exactly 20 cm; print it at
100 % (*Actual size* / *Scale 100 %*, never *Fit to page*) and check the bar under the square really
measures 20.0 cm. Without a PDF printer, print `App/Marker/ghostmap-marker.png` scaled so the outer
black square plus its white margin is 20 cm wide. Matte paper tracks better than glossy; tape it
flat — a curled or folded sheet moves the origin. Regenerate either file with
`scripts/rm.sh marker` (or `python3 scripts/make-marker.py`); it is deterministic, so the output is
byte-identical every time and every phone can use the same sheet.

**Use it.** Tape the marker where everyone can see it, open the capture screen and point the phone
at it from about 0.5–2 m until the strip reads `Marker: aligned`. From then on:

| Strip | Meaning |
|---|---|
| `Marker: none` (grey) | No marker seen yet — uploads carry the ARKit world pose and `aligned: false`. |
| `Marker: aligned` (green) | The marker is in view and the origin is being refreshed. |
| `Marker: lost` (amber) | The marker is out of view. The origin still holds and uploads stay `aligned: true`; only drift is no longer being corrected. Re-aim at the marker now and then on long captures. |

The chip disappears when marker detection is turned off. If the printed marker is larger or smaller
than 20 cm, set **Marker size** in the map-list settings — a wrong size puts the origin at the wrong
distance and scales nothing else, so poses drift away from the other phones.

## Settings (gear, top left of the map list)

The gear in the map list toolbar opens the backend and account settings. Everything here is
optional — with no backend and no account the app captures to the phone exactly as before.

**Backend.** The address of the Ghostmap API, `https://ghostmap-backend.vercel.app` by default.
`https://` is added when you leave the scheme off, a trailing slash is trimmed, and an address with
a query or fragment is rejected. **Test connection** calls `GET /health` and shows the version and
region, or the reason it failed. **Default** puts the production URL back.

**Account.** *Sign in with Google* opens Google's consent screen in a system browser sheet
(`ASWebAuthenticationSession`), and the app exchanges the authorization code for an id token using
PKCE — no password ever reaches the app, and there is no client secret in the build. The id token
goes to `POST /v1/auth/google`, which returns the backend token the app stores in the keychain.

- **Sign in as this phone** (on by default) sends this phone's identity and gets a 30-day *device*
  token that may upload maps and join parties as a mapper. Off, you get a 7-day *user* token that
  can only watch.
- **Always choose account** uses a private browser session, so the Google account chooser appears
  every time instead of reusing the browser's signed-in account.
- The account card shows the name, email, token role and expiry. **Sign out** forgets the token;
  the phone's identity stays, so signing in again reuses the same device on the backend.

**Marker origin.** *Use a printed marker* turns image detection on (default on) and *Marker size*
is the printed width of the marker's outer square, 20 cm by default. See *Marker origin* above for
printing and use.

**This phone.** The device name reported to the backend and the first eight characters of the
identity UUID kept in the keychain.

### Enabling Google sign-in in a build

The button is disabled until the build carries an iOS OAuth client id. In the Google Cloud console,
create an **iOS** OAuth client for bundle id `tech.alandiza.roommapper`, then in
`App/Resources/Info.plist`:

1. put the client id (`123456789012-abcdefg.apps.googleusercontent.com`) in `GhostmapGoogleClientID`;
2. replace `com.googleusercontent.apps.REPLACE_WITH_CLIENT_ID` in `CFBundleURLTypes` with the
   reversed client id (`com.googleusercontent.apps.123456789012-abcdefg`).

The redirect URI Google needs is that reversed id followed by `:/oauthredirect`. The backend must
list the same client id in its `GOOGLE_CLIENT_IDS` environment variable. Neither value is a secret —
iOS OAuth clients have no client secret.

## Map library

Each map shows a top-down thumbnail, name (rename via swipe or long press), point and keyframe counts, duration, size and status. Swipe left to delete.

**Detail view**: drag to orbit, pinch to zoom, two-finger drag to pan; the menu switches top-down / orbit, resets the view, renames or deletes. **Export** shares `cloud.ply` (binary PLY with x y z r g b) via AirDrop, Files, Mail, etc. It opens in MeshLab, CloudCompare, Blender and Open3D.

**Recovery**: if the app was killed mid-recording, the map appears as *failed* with a **Rebuild** button that reconstructs the cloud from the keyframe log. Rebuilt clouds are gray (the log stores depth, not color).

## Files and logs

Maps live in the app's Documents folder: Files app → On My iPhone → RoomMapper → Maps → `<map id>/` with `manifest.json`, `keyframes.bin`, `cloud.ply`, `thumbnail.png`, `worldmap.arworldmap` (when ARKit reached "mapped") and `session.log`. See FORMAT.md for the byte layout. `scripts/rm.sh pull-maps` copies all of them to the Mac.

`session.log` records the video format, thresholds, thermal and tracking transitions, keyframe log errors, and a finalize summary with points, keyframes, dropped keyframes, duration, callback timing, processing time and memory. The same lines go to the unified log under subsystem `tech.alandiza.roommapper` (categories `capture`, `cloud`, `storage`, `render`, `thermal`, `app`; backend and sign-in
lines use `cloud`), which `scripts/rm.sh launch` streams to the terminal.
