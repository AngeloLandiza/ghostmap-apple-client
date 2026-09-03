import simd

/// Per-voxel bookkeeping stored alongside each point (4 bytes).
struct VoxelMeta: Sendable, Equatable {
    /// Log-odds-style occupancy score; `Int8.min` marks a dead voxel awaiting compaction.
    var occupancy: Int8
    /// Number of distinct observations (saturating); drives the running mean and confirmation.
    var weight: UInt8
    /// Integration index of the last supporting observation.
    var lastSeen: UInt16

    static let dead = VoxelMeta(occupancy: Int8.min, weight: 0, lastSeen: 0)
    var isDead: Bool { occupancy == Int8.min }
}

/// Open-addressing hash map from packed voxel key to point index (linear probing, power-of-two capacity).
struct VoxelIndexMap: Sendable {
    private var keys: [Int64]
    private var values: [Int32]
    private var mask: Int
    private(set) var count = 0
    static let empty = Int64.min

    init(capacity: Int = 1 << 16) {
        var c = 1024
        while c < capacity { c <<= 1 }
        keys = Array(repeating: VoxelIndexMap.empty, count: c)
        values = Array(repeating: -1, count: c)
        mask = c - 1
    }

    @inline(__always)
    private static func slot(_ key: Int64, mask: Int) -> Int {
        Int(truncatingIfNeeded: (UInt64(bitPattern: key) &* 0x9E37_79B9_7F4A_7C15) >> 29) & mask
    }

    @inline(__always)
    func find(_ key: Int64) -> Int32? {
        var i = VoxelIndexMap.slot(key, mask: mask)
        while true {
            let k = keys[i]
            if k == key { return values[i] }
            if k == VoxelIndexMap.empty { return nil }
            i = (i + 1) & mask
        }
    }

    mutating func set(_ key: Int64, _ value: Int32) {
        if (count + 1) * 10 > keys.count * 7 { grow() }
        var i = VoxelIndexMap.slot(key, mask: mask)
        while true {
            let k = keys[i]
            if k == key {
                values[i] = value
                return
            }
            if k == VoxelIndexMap.empty {
                keys[i] = key
                values[i] = value
                count += 1
                return
            }
            i = (i + 1) & mask
        }
    }

    private mutating func grow() {
        let oldKeys = keys
        let oldValues = values
        let c = keys.count * 2
        keys = Array(repeating: VoxelIndexMap.empty, count: c)
        values = Array(repeating: -1, count: c)
        mask = c - 1
        count = 0
        for i in 0..<oldKeys.count where oldKeys[i] != VoxelIndexMap.empty {
            set(oldKeys[i], oldValues[i])
        }
    }

    mutating func removeAll(capacity: Int) {
        var c = 1024
        while c < capacity { c <<= 1 }
        keys = Array(repeating: VoxelIndexMap.empty, count: c)
        values = Array(repeating: -1, count: c)
        mask = c - 1
        count = 0
    }

    var slotBytes: Int { keys.count * 12 }
}

/// A confirmation-gated voxel map for dynamic environments.
///
/// * **Confirmation.** A voxel is only *shown* (and only counted) once it has been observed in
///   `confirmHits` separate integrations. Anything seen once — a person walking through, LiDAR flying
///   pixels, a hand — never reaches the rendered cloud, and unconfirmed voxels that are not re-observed
///   within `maxUnconfirmedAge` integrations are dropped.
/// * **Fusion.** Repeated observations fuse into a weight-capped running mean of position and color.
/// * **Carving.** Every integration projects the in-view voxels (chunk-culled) into the depth image. A
///   ray that measures well beyond the voxel is a miss (weighted by ARKit confidence), a pixel with no
///   usable measurement is a weak miss, and a measurement near the voxel is support. Unconfirmed voxels
///   die on their first miss; confirmed voxels die when their log-odds score drops below the death
///   threshold. Dead voxels are parked out of view immediately and physically removed at compaction.
/// * **Carve-only integrations** (empty `samples`) let the app carve at a steady rate between keyframes.
public struct DynamicVoxelMap: Sendable {
    public struct Config: Sendable, Equatable {
        public var cellSize: Float = 0.02
        public var maxPoints: Int = 3_000_000
        public var coarsenedCellSize: Float = 0.03
        public var chunkSize: Int = 4096
        /// Score added when a sample lands in the cell or a projection confirms it.
        public var hitIncrement: Int8 = 2
        /// Score removed when a high-confidence ray passes through the cell.
        public var missDecrement: Int8 = 4
        /// Score removed when a medium-confidence ray passes through the cell.
        public var mediumMissDecrement: Int8 = 2
        /// Score removed when an in-view voxel has no usable measurement at all.
        public var unmeasuredMissDecrement: Int8 = 1
        public var initialOccupancy: Int8 = 2
        public var maxOccupancy: Int8 = 12
        /// At or below this score a confirmed voxel dies.
        public var deathThreshold: Int8 = -4
        /// Observations needed before a voxel is shown.
        public var confirmHits: UInt8 = 2
        /// Unconfirmed voxels not re-observed within this many integrations are dropped.
        public var maxUnconfirmedAge: UInt16 = 24
        /// Every this many integrations, sweep the whole map for stale unconfirmed voxels.
        public var unconfirmedSweepInterval: UInt16 = 8
        /// Running-mean cap: smaller adapts faster to slow changes, larger denoises more.
        public var maxFusionWeight: UInt8 = 12
        /// Minimum ARKit confidence (0 low, 1 medium, 2 high) of a depth pixel allowed to carve.
        public var carveMinConfidence: UInt8 = 1
        public var depthMarginMeters: Float = 0.04
        public var depthMarginRatio: Float = 0.03
        public var carveMinDepth: Float = 0.15
        public var carveMaxDepth: Float = 8.0
        public var compactionDeadFraction: Float = 0.02
        public var minCompactionDead: Int = 2_000

        public init() {}

        public static let `default` = Config()

        /// 1 cm cells (coarsening to 2 cm at the cap); pairs with denser keyframes in the app.
        public static let highResolution: Config = {
            var c = Config()
            c.cellSize = 0.01
            c.coarsenedCellSize = 0.02
            c.maxFusionWeight = 8
            return c
        }()
    }

    public struct PointUpdate: Sendable, Equatable {
        public var index: Int32
        public var point: PackedPoint
    }

    /// What changed in one `integrate` call, in the form the GPU mirror needs.
    public struct Integration: Sendable {
        /// New entries, index-aligned with `points`; unconfirmed ones are parked out of view.
        public var appended: [PackedPoint] = []
        public var updates: [PointUpdate] = []
        public var fused = 0
        public var confirmed = 0
        public var supported = 0
        public var missed = 0
        public var killed = 0
        public var dropped = 0
        /// When true the caller must replace its whole mirror with `renderablePoints`.
        public var compacted = false
        public var state: VoxelGrid.State = .accepting
        public var liveCount = 0
        public var confirmedCount = 0
    }

    public private(set) var config: Config
    public private(set) var cellSize: Float
    public private(set) var state: VoxelGrid.State = .accepting
    /// Index-aligned with the GPU buffer (CPU truth; unconfirmed entries hold their real position).
    public private(set) var points: [PackedPoint] = []
    private var meta: [VoxelMeta] = []
    private var index: VoxelIndexMap
    private var chunkMin: [SIMD3<Float>] = []
    private var chunkMax: [SIMD3<Float>] = []
    public private(set) var deadCount = 0
    public private(set) var confirmedCount = 0
    public private(set) var keyframeIndex: UInt16 = 0
    public private(set) var bounds = BoundingBox.empty
    public private(set) var compactions = 0

    static let parkedPosition = SIMD3<Float>(0, -1.0e6, 0)
    static let parked = PackedPoint(position: parkedPosition, color: 0)

    public init(config: Config = .default) {
        self.config = config
        self.cellSize = config.cellSize
        self.index = VoxelIndexMap(capacity: 1 << 16)
    }

    public var count: Int { points.count }
    public var liveCount: Int { points.count - deadCount }
    public var estimatedBytes: Int { points.count * 20 + index.slotBytes + chunkMin.count * 32 }

    /// `points` with unconfirmed and dead voxels parked out of view — what the GPU should hold.
    public var renderablePoints: [PackedPoint] {
        var out = points
        let threshold = config.confirmHits
        for i in 0..<out.count where meta[i].isDead || meta[i].weight < threshold {
            out[i] = DynamicVoxelMap.parked
        }
        return out
    }

    @inline(__always)
    private func isConfirmed(_ m: VoxelMeta) -> Bool { !m.isDead && m.weight >= config.confirmHits }

    // MARK: Integration

    /// Integrates one frame: carves with its depth image, then inserts its samples (none for carve-only frames).
    public mutating func integrate(samples: [PackedPoint],
                                   depthMillimeters: [UInt16],
                                   confidence: [UInt8],
                                   intrinsics: Intrinsics,
                                   pose: Pose,
                                   minCarveConfidence: UInt8? = nil) -> Integration {
        keyframeIndex &+= 1
        var result = Integration()

        if depthMillimeters.count == intrinsics.pixelCount, confidence.count == intrinsics.pixelCount, !points.isEmpty {
            carve(depthMillimeters: depthMillimeters, confidence: confidence, intrinsics: intrinsics, pose: pose,
                  minConfidence: minCarveConfidence ?? config.carveMinConfidence, result: &result)
        }
        if !samples.isEmpty {
            insert(samples, result: &result)
        }
        if config.unconfirmedSweepInterval > 0, keyframeIndex % config.unconfirmedSweepInterval == 0 {
            sweepStale(result: &result)
        }

        if points.count >= config.maxPoints {
            if state == .accepting {
                coarsen()
                result.compacted = true
            }
            if points.count >= config.maxPoints { state = .full }
        }
        let threshold = max(config.minCompactionDead, Int(Float(points.count) * config.compactionDeadFraction))
        if deadCount >= threshold {
            compact()
            result.compacted = true
        }
        if state == .full, points.count < config.maxPoints {
            state = cellSize > config.cellSize ? .coarsened : .accepting
        }
        if result.compacted {
            result.appended.removeAll()
            result.updates.removeAll()
        }
        result.state = state
        result.liveCount = liveCount
        result.confirmedCount = confirmedCount
        return result
    }

    private mutating func insert(_ samples: [PackedPoint], result: inout Integration) {
        let hitInc = config.hitIncrement
        let maxOcc = config.maxOccupancy
        let maxW = config.maxFusionWeight
        let confirmHits = config.confirmHits
        let kf = keyframeIndex
        result.appended.reserveCapacity(samples.count / 2)
        for s in samples {
            let key = VoxelGrid.key(for: s.position, cellSize: cellSize)
            if let found = index.find(key) {
                let i = Int(found)
                var m = meta[i]
                if m.isDead {
                    // Revive in place: something reappeared here before compaction ran. Stays parked until confirmed.
                    points[i] = s
                    m = VoxelMeta(occupancy: config.initialOccupancy, weight: 1, lastSeen: kf)
                    meta[i] = m
                    deadCount -= 1
                    extendChunk(i, s.position)
                    if confirmHits <= 1 {
                        confirmedCount += 1
                        bounds.formUnion(s.position)
                        result.updates.append(PointUpdate(index: found, point: s))
                    }
                    continue
                }
                if m.lastSeen == kf { continue }   // one observation per cell per frame
                let wasConfirmed = m.weight >= confirmHits
                let w = Float(min(m.weight, maxW))
                let old = points[i]
                let inv = 1 / (w + 1)
                let p = (old.position * w + s.position) * inv
                let r = UInt8((Float(old.r) * w + Float(s.r)) * inv + 0.5)
                let g = UInt8((Float(old.g) * w + Float(s.g)) * inv + 0.5)
                let b = UInt8((Float(old.b) * w + Float(s.b)) * inv + 0.5)
                let fused = PackedPoint(position: p, r: r, g: g, b: b)
                points[i] = fused
                m.weight = m.weight == 255 ? 255 : m.weight + 1
                m.occupancy = min(maxOcc, m.occupancy &+ hitInc)
                m.lastSeen = kf
                meta[i] = m
                result.fused += 1
                if m.weight >= confirmHits {
                    if !wasConfirmed {
                        confirmedCount += 1
                        result.confirmed += 1
                        bounds.formUnion(p)
                    }
                    result.updates.append(PointUpdate(index: found, point: fused))
                }
            } else if points.count < config.maxPoints {
                let i = points.count
                points.append(s)
                meta.append(VoxelMeta(occupancy: config.initialOccupancy, weight: 1, lastSeen: kf))
                index.set(key, Int32(i))
                extendChunk(i, s.position)
                if confirmHits <= 1 {
                    confirmedCount += 1
                    bounds.formUnion(s.position)
                    result.appended.append(s)
                } else {
                    result.appended.append(DynamicVoxelMap.parked)
                }
            } else {
                result.dropped += 1
            }
        }
    }

    // MARK: Carving

    private mutating func carve(depthMillimeters: [UInt16], confidence: [UInt8], intrinsics k: Intrinsics, pose: Pose,
                                minConfidence: UInt8, result: inout Integration) {
        let m = pose.inverse.matrix
        let c0 = m.columns.0, c1 = m.columns.1, c2 = m.columns.2, c3 = m.columns.3
        let w = k.width, h = k.height
        let fw = Float(w), fh = Float(h)
        let minD = config.carveMinDepth, maxD = config.carveMaxDepth
        let marginM = config.depthMarginMeters, marginR = config.depthMarginRatio
        let missHigh = config.missDecrement, missMedium = config.mediumMissDecrement, missNone = config.unmeasuredMissDecrement
        let hitInc = config.hitIncrement, maxOcc = config.maxOccupancy
        let death = config.deathThreshold
        let confirmHits = config.confirmHits
        let maxAge = config.maxUnconfirmedAge
        let kf = keyframeIndex
        let chunkSize = config.chunkSize
        let pad = SIMD3<Float>(repeating: cellSize)

        depthMillimeters.withUnsafeBufferPointer { depth in
            confidence.withUnsafeBufferPointer { conf in
                for c in 0..<chunkMin.count {
                    if isChunkOutside(min: chunkMin[c] - pad, max: chunkMax[c] + pad, c0: c0, c1: c1, c2: c2, c3: c3, k: k) { continue }
                    let start = c * chunkSize
                    let end = min(start + chunkSize, points.count)
                    for i in start..<end {
                        var mt = meta[i]
                        if mt.isDead { continue }
                        let confirmed = mt.weight >= confirmHits
                        if !confirmed, kf &- mt.lastSeen > maxAge {
                            kill(i, result: &result)
                            continue
                        }
                        let p = points[i]
                        let pc = c0 * p.x + c1 * p.y + c2 * p.z + c3
                        let d = -pc.z
                        if d < minD || d > maxD { continue }
                        let u = k.fx * pc.x / d + k.cx
                        let v = k.fy * (-pc.y) / d + k.cy
                        if u < 0 || v < 0 || u >= fw || v >= fh { continue }
                        let pi = Int(v) * w + Int(u)
                        let mm = depth[pi]
                        let cf = conf[pi]
                        var decrement: Int8 = 0
                        if mm == 0 || cf < minConfidence {
                            decrement = missNone
                        } else {
                            let measured = Float(mm) * 0.001
                            let margin = max(marginM, marginR * d)
                            if measured > d + margin {
                                decrement = cf >= 2 ? missHigh : missMedium
                            } else if abs(measured - d) <= margin {
                                if mt.lastSeen != kf {
                                    mt.weight = mt.weight == 255 ? 255 : mt.weight + 1
                                    mt.occupancy = min(maxOcc, mt.occupancy &+ hitInc)
                                    mt.lastSeen = kf
                                    meta[i] = mt
                                    result.supported += 1
                                    if !confirmed, mt.weight >= confirmHits {
                                        confirmedCount += 1
                                        result.confirmed += 1
                                        bounds.formUnion(p.position)
                                        result.updates.append(PointUpdate(index: Int32(i), point: p))
                                    }
                                }
                                continue
                            }
                            // Otherwise the voxel is occluded by something nearer: no evidence either way.
                        }
                        if decrement > 0 {
                            result.missed += 1
                            if !confirmed {
                                kill(i, result: &result)
                            } else {
                                mt.occupancy = mt.occupancy &- decrement
                                if mt.occupancy <= death {
                                    kill(i, result: &result)
                                } else {
                                    meta[i] = mt
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @inline(__always)
    private mutating func kill(_ i: Int, result: inout Integration) {
        if isConfirmed(meta[i]) {
            confirmedCount -= 1
            result.updates.append(PointUpdate(index: Int32(i), point: DynamicVoxelMap.parked))
        }
        meta[i] = .dead
        points[i] = DynamicVoxelMap.parked
        deadCount += 1
        result.killed += 1
    }

    /// Drops unconfirmed voxels that were never re-observed, wherever they are.
    private mutating func sweepStale(result: inout Integration) {
        let maxAge = config.maxUnconfirmedAge
        let confirmHits = config.confirmHits
        let kf = keyframeIndex
        for i in 0..<meta.count {
            let mt = meta[i]
            if mt.isDead || mt.weight >= confirmHits { continue }
            if kf &- mt.lastSeen > maxAge { kill(i, result: &result) }
        }
    }

    /// Conservative frustum test on an axis-aligned box using its 8 corners in camera space.
    @inline(__always)
    private func isChunkOutside(min lo: SIMD3<Float>, max hi: SIMD3<Float>,
                                c0: SIMD4<Float>, c1: SIMD4<Float>, c2: SIMD4<Float>, c3: SIMD4<Float>, k: Intrinsics) -> Bool {
        var allNear = true, allFar = true, allLeft = true, allRight = true, allUp = true, allDown = true
        let fw = Float(k.width), fh = Float(k.height)
        for n in 0..<8 {
            let x = (n & 1) == 0 ? lo.x : hi.x
            let y = (n & 2) == 0 ? lo.y : hi.y
            let z = (n & 4) == 0 ? lo.z : hi.z
            let pc = c0 * x + c1 * y + c2 * z + c3
            let d = -pc.z
            if d >= config.carveMinDepth { allNear = false }
            if d <= config.carveMaxDepth { allFar = false }
            if d <= 0 {
                allLeft = false; allRight = false; allUp = false; allDown = false
                continue
            }
            let u = k.fx * pc.x / d + k.cx
            let v = k.fy * (-pc.y) / d + k.cy
            if u >= 0 { allLeft = false }
            if u < fw { allRight = false }
            if v >= 0 { allUp = false }
            if v < fh { allDown = false }
        }
        return allNear || allFar || allLeft || allRight || allUp || allDown
    }

    // MARK: Maintenance

    @inline(__always)
    private mutating func extendChunk(_ i: Int, _ p: SIMD3<Float>) {
        let c = i / config.chunkSize
        if c == chunkMin.count {
            chunkMin.append(p)
            chunkMax.append(p)
        } else {
            chunkMin[c] = simd_min(chunkMin[c], p)
            chunkMax[c] = simd_max(chunkMax[c], p)
        }
    }

    /// Drops dead voxels and rebuilds the hash and chunk bounds. Keys are recomputed from positions,
    /// which is exact because a weighted mean of samples inside a cell stays inside that cell.
    private mutating func compact() {
        var newPoints: [PackedPoint] = []
        var newMeta: [VoxelMeta] = []
        newPoints.reserveCapacity(liveCount)
        newMeta.reserveCapacity(liveCount)
        for i in 0..<points.count where !meta[i].isDead {
            newPoints.append(points[i])
            newMeta.append(meta[i])
        }
        points = newPoints
        meta = newMeta
        deadCount = 0
        compactions += 1
        rebuildIndexAndChunks()
    }

    /// Re-keys every live voxel into coarser cells, fusing collisions.
    private mutating func coarsen() {
        let newCell = cellSize < config.coarsenedCellSize ? config.coarsenedCellSize : cellSize * 1.5
        var newPoints: [PackedPoint] = []
        var newMeta: [VoxelMeta] = []
        var newIndex = VoxelIndexMap(capacity: points.count)
        newPoints.reserveCapacity(liveCount)
        newMeta.reserveCapacity(liveCount)
        for i in 0..<points.count where !meta[i].isDead {
            let p = points[i]
            let key = VoxelGrid.key(for: p.position, cellSize: newCell)
            if let found = newIndex.find(key) {
                let j = Int(found)
                let a = newPoints[j]
                var am = newMeta[j]
                let bm = meta[i]
                let wa = Float(am.weight), wb = Float(bm.weight)
                let inv = 1 / (wa + wb)
                let pos = (a.position * wa + p.position * wb) * inv
                let r = UInt8((Float(a.r) * wa + Float(p.r) * wb) * inv + 0.5)
                let g = UInt8((Float(a.g) * wa + Float(p.g) * wb) * inv + 0.5)
                let b = UInt8((Float(a.b) * wa + Float(p.b) * wb) * inv + 0.5)
                newPoints[j] = PackedPoint(position: pos, r: r, g: g, b: b)
                am.weight = UInt8(min(255, Int(am.weight) + Int(bm.weight)))
                am.occupancy = max(am.occupancy, bm.occupancy)
                am.lastSeen = max(am.lastSeen, bm.lastSeen)
                newMeta[j] = am
            } else {
                newIndex.set(key, Int32(newPoints.count))
                newPoints.append(p)
                newMeta.append(meta[i])
            }
        }
        cellSize = newCell
        points = newPoints
        meta = newMeta
        index = newIndex
        deadCount = 0
        state = .coarsened
        rebuildChunks()
    }

    private mutating func rebuildIndexAndChunks() {
        index.removeAll(capacity: max(points.count * 2, 1 << 16))
        for i in 0..<points.count {
            index.set(VoxelGrid.key(for: points[i].position, cellSize: cellSize), Int32(i))
        }
        rebuildChunks()
    }

    private mutating func rebuildChunks() {
        chunkMin.removeAll(keepingCapacity: true)
        chunkMax.removeAll(keepingCapacity: true)
        bounds = .empty
        confirmedCount = 0
        for i in 0..<points.count {
            let p = points[i].position
            extendChunk(i, p)
            if isConfirmed(meta[i]) {
                confirmedCount += 1
                bounds.formUnion(p)
            }
        }
    }
}
