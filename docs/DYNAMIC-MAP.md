# The dynamic voxel map

`DynamicVoxelMap` (MapCore) replaces a static "first sample wins" grid with a map that keeps up with a changing room. It is the visibility-based family of methods (OctoMap ray updates, Removert-style discrepancy checks) applied incrementally on the phone at keyframe rate, plus a confirmation gate that keeps transient observations out of the rendered cloud.

## Per-voxel state

Each voxel is a `PackedPoint` (fused position and color, 16 bytes, mirrored in the GPU buffer at the same index) plus 4 bytes of `VoxelMeta`: an `occupancy` score (log-odds style, Int8), a `weight` (number of observations, drives the running mean and confirmation) and `lastSeen` (integration index). An open-addressing hash map goes from packed voxel key (21 bits per axis, cell = 2 cm by default) to index; 4096-point chunks carry axis-aligned bounds for frustum culling.

## Integration (one frame)

1. **Carve.** For every chunk whose box intersects the camera frustum, project each live voxel into the frame's depth image (`camFromWorld`, then `u = fx·x/d + cx`, `v = fy·(−y)/d + cy`). Compare the measured depth at that pixel with the voxel's depth `d`, with margin `max(4 cm, 3 % · d)`:
   - measured beyond the voxel → **miss**: −4 (high confidence), −2 (medium), or −1 when the pixel has no usable measurement;
   - measured within the margin → **support**: +2, one more observation, and confirmation if reached;
   - measured nearer (occlusion) → no evidence.
   Unconfirmed voxels die on their first miss; confirmed ones when the score reaches −4 (max score 12). Dead voxels are parked at y = −10⁶ in the GPU buffer immediately.
2. **Insert.** Each sample of the keyframe is keyed to a cell. An existing live voxel fuses the sample into a weight-capped running mean (cap 12; 8 in Quality mode) and gains +2; a dead voxel in that cell is revived; a new cell is appended (parked until confirmed). A cell accepts one observation per frame.
3. **Sweep.** Every 8 integrations, unconfirmed voxels older than 24 integrations are dropped.
4. **Cap.** At 3 M voxels the map coarsens once (2 cm → 3 cm) by re-keying and fusing; if it fills again it stops accepting until carving frees space.
5. **Compact.** When dead voxels exceed 2 % (min 2 000), live voxels are packed, keys are recomputed from fused positions (exact, since a mean of samples inside a cell stays inside it), chunk bounds rebuilt, and the GPU buffer replaced.

## Confirmation gating

A voxel is rendered and counted only once `weight ≥ 2`, i.e. it was observed in two separate integrations (sample fusion or projection support). Consequences: a person walking through, a hand, LiDAR flying pixels at depth edges and any single-frame noise never appear; a static surface appears on the second keyframe that sees it (typically within 0.3–0.75 s).

## Carve-only frames

Keyframes are emitted on motion (15 cm / 12°) or every 0.75 s, which is too slow to clear ghosts while standing still. `ARSessionController` therefore sends depth-only snapshots every 0.25 s (0.5 s in Performance, 0.2 s in Quality) between keyframes; they carve but add nothing, are not logged, and do not count as keyframes.

## Parameters by preset

| | Performance | Balanced | Quality |
|---|---|---|---|
| Cell size | 3 cm | 2 cm | 1 cm |
| Point cap | 1.5 M | 3 M | 3 M |
| Depth sample stride | 2 | 1 | 1 |
| Keyframe thresholds | 20 cm / 15° / 1.0 s | 15 cm / 12° / 0.75 s | 10 cm / 8° / 0.5 s |
| Carve interval | 0.5 s | 0.25 s | 0.2 s |
| Main view / Ghost Map draw budget | 0.4 M / 150 k | 1 M / 250 k | 1.5 M / 400 k |

| Dynamic sensitivity | high / medium / unmeasured miss | death | max score | unconfirmed age |
|---|---|---|---|---|
| Conservative | −2 / −1 / 0 | −8 | 12 | 48 |
| Normal | −4 / −2 / −1 | −4 | 12 | 24 |
| Aggressive | −6 / −4 / −2 | −2 | 8 | 12 |

## Costs

Carving visits only in-view chunks: typically 100 k–500 k projections per frame, a few milliseconds on the processor actor. Memory per voxel ≈ 20 B on the CPU plus 16 B on the GPU plus hash slots (12 B × ≤ 2× voxels); a 3 M-voxel map is roughly 150 MB CPU + 96 MB GPU (two buffers).

## Tests

`DynamicVoxelMapTests` cover projection/unprojection round trip, confirmation on the second observation, carving and compaction of an object that leaves, purging of transient observations, coarsening at the cap, no carving behind the camera, and slow erosion by unmeasured pixels.
