# RoomMapper on-disk format

This document describes every byte RoomMapper writes for a map, precisely enough to write an
independent reader (a Python example is at the end). It is the contract implemented by
`Packages/MapCore/Sources/MapCore/Storage/` and `Codec/`; the Swift code is the reference
implementation, this file is the specification.

All multi-byte integers and floats in the binary files are **little-endian**. Floats are IEEE 754
binary32 (`f32`) or binary64 (`f64`).

## 1. Directory layout

Every map is one directory under the app's map root
(`<Application Support>/Maps/` on the phone, visible through Files because the app enables file
sharing). The directory name is the map id: an uppercase UUID string such as
`6BA7B810-9DAD-11D1-80B4-00C04FD430C8`.

```
Maps/
└── 6BA7B810-9DAD-11D1-80B4-00C04FD430C8/
    ├── manifest.json          required   metadata (section 2)
    ├── keyframes.bin          usually    append-only keyframe log (section 3)
    ├── cloud.ply              finalized  binary PLY point cloud (section 4)
    ├── thumbnail.png          finalized  512×512 PNG preview (section 5)
    ├── worldmap.arworldmap    optional   archived ARKit ARWorldMap (section 5)
    └── session.log            usually    UTF-8 text log of the recording (section 5)
```

| File | Written when | Missing means |
|---|---|---|
| `manifest.json` | at creation, rewritten at every status change (atomically) | not a map; the directory is skipped by the map list |
| `keyframes.bin` | created when recording starts, appended once per keyframe | recording never produced a keyframe |
| `cloud.ply` | at finalize (or by *Rebuild* from the keyframe log) | recording was interrupted before finalize (`status` is `failed` or `recording`) |
| `thumbnail.png` | at finalize / rebuild | same as above |
| `worldmap.arworldmap` | at finalize, only when ARKit reported a fully mapped session | `has_world_map` is `false` |
| `session.log` | throughout the recording | nothing was logged |

`manifest.json` is always written with an atomic replace (temporary file + rename), so a reader
never sees a partial manifest. `cloud.ply` is also written to a temporary file and renamed into
place. `keyframes.bin` is the only file that grows in place; section 3.4 explains how to read one
that was cut short by a crash.

## 2. `manifest.json`

UTF-8 JSON object, pretty-printed with sorted keys, slashes not escaped. Unknown keys must be
ignored by readers; keys marked *optional* are absent (not `null`) when they have no value.

| Key | JSON type | Description |
|---|---|---|
| `map_id` | string | Uppercase UUID; equals the directory name. |
| `version` | integer | Manifest schema version. Currently `1`. |
| `name` | string | User-visible name. Defaults to `"Room — Sep 2, 14:05"` style (month, day, 24-hour time). |
| `frame` | string | Name of the coordinate frame. `"world:session-start"`: ARKit world frame, gravity-aligned (+y up), origin at the pose where the session started, meters. |
| `origin` | object | `{"type": "session-start"}` today. A marker-based origin will use `{"type": "marker", "marker_id": "tag36h11_0"}`. `marker_id` is optional. |
| `bbox` | object, *optional* | `{"min": [x, y, z], "max": [x, y, z]}` in meters, axis-aligned bounds of `cloud.ply`. Absent until finalized. |
| `point_count` | integer | Number of vertices in `cloud.ply` (0 until finalized). |
| `keyframe_count` | integer | Number of records in `keyframes.bin`. |
| `created_at` | string | ISO 8601 UTC timestamp, e.g. `"2026-09-02T14:05:00Z"`. |
| `duration_s` | number | Recording length in seconds. |
| `device_model` | string | Hardware identifier, e.g. `"iPhone17,2"`. |
| `ios_version` | string | e.g. `"27.0"`. |
| `app_version` | string | e.g. `"1.0"`. |
| `status` | string | One of `"recording"`, `"finalizing"`, `"saved"`, `"failed"`. |
| `encodings` | object | Names of the encodings used by the other files; see below. |
| `size_bytes` | integer, *optional* | Total size of the map directory when last finalized. |
| `has_world_map` | boolean | Whether `worldmap.arworldmap` exists. |
| `voxel_size_m` | number | Cell size of the deduplication grid that produced `cloud.ply` (0.02 or 0.03 after coarsening). |
| `finalize_s` | number, *optional* | How long finalize took, in seconds. |

`encodings` (all four keys always present):

| Key | Value | Meaning |
|---|---|---|
| `depth` | `"u16mm+lzfse"` | depth = unsigned 16-bit millimeters, row-major, LZFSE-compressed |
| `confidence` | `"u8+lzfse"` | confidence = one byte per pixel (0 low, 1 medium, 2 high), LZFSE-compressed |
| `cloud` | `"ply-binary-little-endian-xyzrgb"` | section 4 |
| `keyframe_log` | `"smkf-v1"` | section 3 |

Status life cycle: `recording` → `finalizing` → `saved`. If the app is killed while a map is
`recording` or `finalizing`, the next launch marks it `failed`; a failed map with a
`keyframes.bin` can be rebuilt (`cloud.ply` regenerated from the log) and becomes `saved`.

Example (a finished map):

```json
{
  "app_version" : "1.0",
  "bbox" : {
    "max" : [3.1, 2.4, 4.2],
    "min" : [-2.7, -1.3, -3.9]
  },
  "created_at" : "2026-09-02T14:05:00Z",
  "device_model" : "iPhone17,2",
  "duration_s" : 181.25,
  "encodings" : {
    "cloud" : "ply-binary-little-endian-xyzrgb",
    "confidence" : "u8+lzfse",
    "depth" : "u16mm+lzfse",
    "keyframe_log" : "smkf-v1"
  },
  "finalize_s" : 2.8,
  "frame" : "world:session-start",
  "has_world_map" : true,
  "ios_version" : "27.0",
  "keyframe_count" : 321,
  "map_id" : "6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
  "name" : "Room — Sep 2, 14:05",
  "origin" : {
    "type" : "session-start"
  },
  "point_count" : 1234567,
  "size_bytes" : 55000000,
  "status" : "saved",
  "version" : 1,
  "voxel_size_m" : 0.02
}
```

A reader must reject a manifest whose `map_id` is not a UUID or whose `status` is not one of the
four values; the app treats such a directory as unreadable and hides it.

## 3. `keyframes.bin` — the "SMKF" keyframe log

An append-only container: a fixed 16-byte header followed by records back to back, with no index
and no footer. Each record is one keyframe: its pose, intrinsics, tracking state and the compressed
depth and confidence maps. Records are never modified after being written.

### 3.1 Header (16 bytes)

| Offset | Size | Type | Field | Value |
|---|---|---|---|---|
| 0 | 4 | bytes | magic | `53 4D 4B 46` = ASCII `"SMKF"` |
| 4 | 2 | u16 | version | `1` |
| 6 | 2 | u16 | headerSize | `16` (offset of the first record) |
| 8 | 4 | u32 | flags | `0` (reserved; readers ignore) |
| 12 | 4 | u32 | reserved | `0` (readers ignore) |

The exact bytes of a version-1 header are
`53 4D 4B 46 01 00 10 00 00 00 00 00 00 00 00 00`. A reader must refuse a file whose magic
differs, whose version is not 1, or that is shorter than 16 bytes. A version-1 file always has
`headerSize == 16`.

### 3.2 Record

Let `R` be the offset of the record and `P = R + 4` the offset of its payload. `D` and `C` are the
sizes of the compressed depth and confidence blocks.

| Offset | Size | Type | Field | Notes |
|---|---|---|---|---|
| R + 0 | 4 | u32 | payloadLength | number of bytes that follow this field, CRC included: `112 + D + C` |
| P + 0 | 4 | u32 | seq | keyframe sequence number, starts at 0 within a map, strictly increasing |
| P + 4 | 8 | f64 | timestamp | seconds; `ARFrame.timestamp` (device uptime clock), monotonic within a map |
| P + 12 | 64 | 16 × f32 | pose | `world_from_camera` 4×4 matrix in **column-major** order (see 3.3) |
| P + 76 | 4 | f32 | fx | focal length in pixels, for the `width × height` depth image |
| P + 80 | 4 | f32 | fy | |
| P + 84 | 4 | f32 | cx | principal point in pixels (image-space, +v down) |
| P + 88 | 4 | f32 | cy | |
| P + 92 | 2 | u16 | width | depth/confidence image width in pixels (256 on the iPhone 16 Pro Max) |
| P + 94 | 2 | u16 | height | image height (192) |
| P + 96 | 1 | u8 | trackingState | 0 normal, 1 limited, 2 not available |
| P + 97 | 1 | u8 | trackingReason | limited reason: 0 initializing, 1 excessive motion, 2 insufficient features, 3 relocalizing, 4 unknown; always 0 when not limited |
| P + 98 | 1 | u8 | depthEncoding | `0` = `u16mm+lzfse` (only value in version 1) |
| P + 99 | 1 | u8 | confidenceEncoding | `0` = `u8+lzfse` (only value in version 1) |
| P + 100 | 4 | u32 | depthBytes | `D` |
| P + 104 | D | bytes | depth | LZFSE stream that decodes to exactly `width × height × 2` bytes |
| P + 104 + D | 4 | u32 | confidenceBytes | `C` |
| P + 108 + D | C | bytes | confidence | LZFSE stream that decodes to exactly `width × height` bytes |
| P + 108 + D + C | 4 | u32 | crc32 | CRC-32 of the `108 + D + C` payload bytes before this field |

Total record size on disk: `4 + payloadLength = 116 + D + C` bytes. The fixed part of the payload
(everything except the two variable blocks) is 112 bytes, so `payloadLength ≥ 112` always.

**CRC-32.** The IEEE 802.3 polynomial (`0xEDB88320` reflected, initial value `0xFFFFFFFF`, final
XOR `0xFFFFFFFF`) — identical to `zlib.crc32` in Python and `crc32` in zlib. It covers every payload
byte from `seq` up to (not including) the `crc32` field; the `payloadLength` field is **not**
covered.

**LZFSE.** Both blocks are produced by Apple's Compression framework,
`compression_encode_buffer(..., COMPRESSION_LZFSE)`, and are plain LZFSE streams (they begin with
a `bvx2`/`bvxn`/`bvx-` block magic and end with `bvx$`). Decode with
`compression_decode_buffer(..., COMPRESSION_LZFSE)` or any LZFSE implementation (e.g.
`liblzfse`). The decoded size is known from `width` and `height`; a stream that decodes to a
different size is corrupt. An empty image (`width × height == 0`) has `D == C == 0`.

**Depth.** The decoded depth block is `width × height` little-endian `u16` values in row-major
order (`index = v × width + u`, `v` = row from the top, `u` = column from the left). Each value is
the depth along the optical axis in **millimeters**, produced from ARKit's `sceneDepth` map as
`round(meters × 1000)` clamped to `1…65535`. **`0` means "no depth"** and must be skipped. The
capture pipeline additionally ignores depths outside `0.1 m … 5.0 m` and pixels below medium
confidence when building the cloud; a reader may choose its own thresholds.

**Confidence.** `width × height` bytes, same order: `0` low, `1` medium, `2` high (ARKit
`ARConfidenceLevel`).

### 3.3 Geometry

`pose` is ARKit's `camera.transform` expressed in the map frame: it maps camera-space points to
world-space points. The 16 floats are the matrix in column-major order, i.e. floats 0–3 are the
first column, 4–7 the second, 8–11 the third and 12–15 the fourth (the translation is floats
12, 13, 14). With `M` the 4×4 matrix and a camera-space point `c`, `w = M · [c, 1]`.

Camera space follows ARKit: `+x` right, `+y` up, `−z` forward (into the scene). The intrinsics
describe the depth image with `+v` pointing down, so the unprojection of pixel `(u, v)` (integer
column and row) with depth `d` meters is, using pixel centers:

```
X = (u + 0.5 − cx) / fx · d
Y = (v + 0.5 − cy) / fy · d
camera point = (X, −Y, −d)
world point  = M · [X, −Y, −d, 1]
```

World space is the ARKit world frame described by the manifest's `frame`: gravity-aligned with
`+y` up, origin and heading fixed at session start, units meters.

### 3.4 Crash recovery

The writer builds each record completely in memory and appends it with a single `write`, then
`fsync`s at finalize and at the end of the session. If the app dies mid-write the file ends with a
**partial tail** (part of one record); nothing earlier is affected, and records are never
interleaved.

Reader rule, applied from offset 16 onwards:

1. If no bytes remain, the file is complete.
2. If 1–3 bytes remain, or `payloadLength` runs past the end of the file, the record at this offset
   is **truncated**. Stop; every earlier record is valid.
3. Otherwise verify the record: `payloadLength ≥ 112`, the CRC matches, `108 + D + C + 4 ==
   payloadLength`, both encoding bytes are `0`, and (when decoding) both LZFSE blocks decode to the
   expected sizes. Any failure marks the record **corrupt**. Stop; every earlier record is valid.
4. Accept the record and continue at `R + 4 + payloadLength`.

**Records after a truncated or corrupt record are ignored**, even if they would parse. A writer
that reopens an existing log performs the same walk (with full LZFSE validation) and
**truncates the file to the end of the last valid record** before appending, so the log is
self-healing: after a crash, the next recording session or rebuild sees only complete records.
`MapCore.KeyframeLogReader.scan` reports the offset of the bad record in `truncatedAtOffset` or
`corruptedAtOffset` rather than throwing; only a bad header throws.

### 3.5 Sizes

A 256×192 keyframe has 98 304 raw depth bytes and 49 152 confidence bytes; LZFSE typically brings
a record to 60–100 KB. At the default keyframe policy (≈ 1–3 keyframes/s) a 3-minute recording is
tens of megabytes.

## 4. `cloud.ply`

Binary little-endian PLY 1.0 with a single `vertex` element and exactly six properties. Header
lines end with `\n`; `comment` lines may appear anywhere after the first line. Bytes after the
last vertex are ignored by RoomMapper's reader.

```
ply
format binary_little_endian 1.0
comment <free text, no newlines>      (zero or more)
element vertex <N>
property float x
property float y
property float z
property uchar red
property uchar green
property uchar blue
end_header
```

Immediately after the `end_header\n` line come `N` vertex records of exactly 15 bytes each, no
padding:

| Offset | Size | Type | Field |
|---|---|---|---|
| 0 | 4 | f32 | x (meters, world frame) |
| 4 | 4 | f32 | y |
| 8 | 4 | f32 | z |
| 12 | 1 | u8 | red |
| 13 | 1 | u8 | green |
| 14 | 1 | u8 | blue |

Colors come from the camera image (BT.601 full-range YCbCr → RGB) during live capture. A cloud
produced by *Rebuild* from `keyframes.bin` has no color source and uses a confidence-tinted gray:
`210,210,210` for high-confidence pixels and `150,150,150` for medium ones. Vertices are stored in
acceptance order (keyframe by keyframe, row-major within a keyframe) after voxel deduplication at
`voxel_size_m`; there is no guaranteed spatial ordering.

## 5. Other files

- **`thumbnail.png`** — a standard PNG, 512×512 pixels, rendered top-down from the point cloud at
  finalize/rebuild time. Purely a preview; nothing is derived from it.
- **`worldmap.arworldmap`** — ARKit's `ARWorldMap` serialized with `NSKeyedArchiver`
  (`requiringSecureCoding: true`). Only ARKit on an Apple device can decode it; treat it as an
  opaque blob. Present only when the manifest's `has_world_map` is `true`.
- **`session.log`** — UTF-8 text, one event per line, human-readable (session start/stop, video
  format chosen, thermal transitions, keyframe/cloud statistics, finalize timings, errors). Not
  intended for machine parsing; its exact line format may change between app versions.

## 6. Reference reader in Python (illustrative)

The snippet below reads a map directory with the standard library plus NumPy and an LZFSE
decoder. It is written for clarity, not speed, and mirrors the reader rule of section 3.4.

LZFSE options:

- `pip install pyliblzfse` — provides `lzfse.decompress(bytes) -> bytes` on every platform.
- On macOS you can call Apple's own decoder through `ctypes` (`lzfse_decompress_ctypes` below);
  `COMPRESSION_LZFSE` is the constant `0x801`. (Any pyobjc route ends up calling the same
  `libcompression` function.)

```python
import json
import pathlib
import struct
import zlib

import numpy as np

try:
    import lzfse                       # pip install pyliblzfse

    def lzfse_decompress(blob: bytes, expected_size: int) -> bytes:
        out = lzfse.decompress(blob)
        if len(out) != expected_size:
            raise ValueError(f"lzfse decoded {len(out)} bytes, expected {expected_size}")
        return out
except ImportError:                    # macOS fallback: Apple's libcompression via ctypes
    import ctypes

    _lib = ctypes.CDLL("/usr/lib/libcompression.dylib")
    _lib.compression_decode_buffer.restype = ctypes.c_size_t
    _lib.compression_decode_buffer.argtypes = [
        ctypes.c_char_p, ctypes.c_size_t,      # dst, dst_size
        ctypes.c_char_p, ctypes.c_size_t,      # src, src_size
        ctypes.c_void_p, ctypes.c_int,         # scratch, algorithm
    ]
    COMPRESSION_LZFSE = 0x801

    def lzfse_decompress(blob: bytes, expected_size: int) -> bytes:
        dst = ctypes.create_string_buffer(expected_size + 1)   # +1 detects over-long streams
        n = _lib.compression_decode_buffer(dst, expected_size + 1, blob, len(blob), None, COMPRESSION_LZFSE)
        if n != expected_size:
            raise ValueError(f"lzfse decoded {n} bytes, expected {expected_size}")
        return dst.raw[:expected_size]


HEADER = struct.Struct("<4sHHII")                 # magic, version, headerSize, flags, reserved
FIXED = struct.Struct("<Id16f4fHHBBBBI")          # 104 bytes: seq, timestamp, pose[16], fx fy cx cy,
                                                  # width, height, state, reason, depthEnc, confEnc, depthBytes
MIN_PAYLOAD = FIXED.size + 4 + 4                  # + confidenceBytes field + crc = 112

TRACKING_STATE = {0: "normal", 1: "limited", 2: "notAvailable"}
LIMITED_REASON = {0: "initializing", 1: "excessiveMotion", 2: "insufficientFeatures", 3: "relocalizing", 4: "unknown"}


def read_keyframes(path):
    """Yields dicts for every complete valid record; prints where a bad tail starts."""
    data = pathlib.Path(path).read_bytes()
    if len(data) < HEADER.size:
        raise ValueError("file too short for the header")
    magic, version, header_size, _flags, _reserved = HEADER.unpack_from(data, 0)
    if magic != b"SMKF":
        raise ValueError("bad magic")
    if version != 1 or header_size != 16:
        raise ValueError(f"unsupported version {version} / header size {header_size}")

    offset = header_size
    while True:
        remaining = len(data) - offset
        if remaining == 0:
            return
        if remaining < 4:
            print(f"truncated record at {offset}")
            return
        (payload_len,) = struct.unpack_from("<I", data, offset)
        start, end = offset + 4, offset + 4 + payload_len
        if end > len(data):
            print(f"truncated record at {offset}")
            return
        payload = data[start:end]
        if payload_len < MIN_PAYLOAD:
            print(f"corrupt record at {offset}: payload too short")
            return
        (stored_crc,) = struct.unpack_from("<I", payload, payload_len - 4)
        if zlib.crc32(payload[: payload_len - 4]) != stored_crc:
            print(f"corrupt record at {offset}: crc mismatch")
            return

        f = FIXED.unpack_from(payload, 0)
        seq, timestamp = f[0], f[1]
        pose = np.array(f[2:18], dtype=np.float32).reshape(4, 4, order="F")   # column-major → M[row, col]
        fx, fy, cx, cy = f[18:22]
        width, height = f[22:24]
        state, reason, depth_enc, conf_enc, depth_len = f[24:29]
        if depth_enc != 0 or conf_enc != 0:
            print(f"corrupt record at {offset}: unknown encoding")
            return

        p = FIXED.size
        depth_blob = payload[p : p + depth_len]
        p += depth_len
        (conf_len,) = struct.unpack_from("<I", payload, p)
        p += 4
        conf_blob = payload[p : p + conf_len]
        p += conf_len
        if p != payload_len - 4:
            print(f"corrupt record at {offset}: inner lengths do not add up")
            return

        n = width * height
        try:
            depth = np.frombuffer(lzfse_decompress(depth_blob, n * 2), dtype="<u2").reshape(height, width)
            conf = np.frombuffer(lzfse_decompress(conf_blob, n), dtype=np.uint8).reshape(height, width)
        except ValueError as e:
            print(f"corrupt record at {offset}: {e}")
            return

        yield {
            "offset": offset,
            "seq": seq,
            "timestamp": timestamp,
            "pose": pose,                        # world_from_camera, 4×4
            "intrinsics": (fx, fy, cx, cy, width, height),
            "tracking": TRACKING_STATE.get(state, "?"),
            "tracking_reason": LIMITED_REASON.get(reason, "?") if state == 1 else None,
            "depth_mm": depth,                   # uint16 (height, width), 0 = no depth
            "confidence": conf,                  # uint8  (height, width), 0/1/2
        }
        offset = end


def unproject(record, min_confidence=1, min_depth_m=0.1, max_depth_m=5.0):
    """World-space points (N, 3) for one record, using the same rules as the app."""
    fx, fy, cx, cy, width, height = record["intrinsics"]
    d = record["depth_mm"].astype(np.float32) / 1000.0
    keep = (record["depth_mm"] != 0) & (record["confidence"] >= min_confidence) & (d >= min_depth_m) & (d <= max_depth_m)
    v, u = np.nonzero(keep)
    d = d[v, u]
    X = (u + 0.5 - cx) / fx * d
    Y = (v + 0.5 - cy) / fy * d
    cam = np.stack([X, -Y, -d, np.ones_like(d)], axis=1)          # (N, 4) camera space
    world = cam @ record["pose"].T                                 # M · c for every row
    return world[:, :3]


def read_ply(path):
    """Returns (xyz float32 (N, 3), rgb uint8 (N, 3)) from cloud.ply."""
    data = pathlib.Path(path).read_bytes()
    header_end = data.index(b"end_header\n") + len(b"end_header\n")
    header = data[:header_end].decode("ascii").split("\n")
    if header[0] != "ply" or "format binary_little_endian 1.0" not in header:
        raise ValueError("unexpected PLY header")
    count = next(int(line.split()[2]) for line in header if line.startswith("element vertex"))
    vertex = np.dtype([("x", "<f4"), ("y", "<f4"), ("z", "<f4"), ("r", "u1"), ("g", "u1"), ("b", "u1")])
    body = np.frombuffer(data, dtype=vertex, count=count, offset=header_end)
    xyz = np.stack([body["x"], body["y"], body["z"]], axis=1)
    rgb = np.stack([body["r"], body["g"], body["b"]], axis=1)
    return xyz, rgb


if __name__ == "__main__":
    import sys

    map_dir = pathlib.Path(sys.argv[1])
    manifest = json.loads((map_dir / "manifest.json").read_text())
    print(manifest["name"], manifest["status"], manifest["keyframe_count"], "keyframes")

    for record in read_keyframes(map_dir / "keyframes.bin"):
        pts = unproject(record)
        print(f"seq {record['seq']:5d}  t={record['timestamp']:.3f}  {record['tracking']:<12}  {len(pts)} points")

    if (map_dir / "cloud.ply").exists():
        xyz, rgb = read_ply(map_dir / "cloud.ply")
        print("cloud:", len(xyz), "points, bounds", xyz.min(axis=0), xyz.max(axis=0))
```

The snippet is illustrative: it loads whole files into memory, does no streaming, and prints
rather than raises on a bad tail, exactly like `KeyframeLogReader.scan`.
