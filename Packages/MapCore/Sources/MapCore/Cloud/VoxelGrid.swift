import simd

// MARK: - VoxelKeySet

/// Open-addressing hash set of voxel keys, specialised for the non-negative `Int64` keys produced by
/// `VoxelGrid.key(for:cellSize:)`.
///
/// Layout: one flat `[Int64]` whose capacity is always a power of two. Empty slots hold
/// `emptySentinel` (`Int64.min`), which no real key can equal because every key is non-negative.
/// Lookup uses Fibonacci hashing — multiply the key by `0x9E3779B97F4A7C15` (2⁶⁴ / φ) and keep the top
/// `log2(capacity)` bits — followed by linear probing. The table doubles (and rehashes every key) as
/// soon as the load factor exceeds `maxLoadFactor`.
///
/// This is a plain value type over an array, so it is `Sendable` and copy-on-write like `Array`.
struct VoxelKeySet: Sendable {
    /// Marks an unused slot. Safe because valid keys are never negative.
    static let emptySentinel = Int64.min
    /// Capacity of a set created with `init()`.
    static let initialCapacity = 1 << 16
    /// Smallest capacity `init(capacity:)` will produce.
    static let minimumCapacity = 16
    /// The table grows once `count / capacity` exceeds this value.
    static let maxLoadFactor = 0.7
    /// 2⁶⁴ / φ, the multiplier of Fibonacci hashing.
    static let hashMultiplier: UInt64 = 0x9E37_79B9_7F4A_7C15

    /// The slot array; `capacity == slots.count`, a power of two.
    private(set) var slots: [Int64]
    /// Number of distinct keys stored.
    private(set) var count: Int
    /// `capacity - 1`, used to wrap probe indices.
    private var mask: Int
    /// `64 - log2(capacity)`: right shift that turns the 64-bit hash into a slot index.
    private var shift: UInt64
    /// Largest `count` allowed before the table grows (`floor(capacity * 0.7)`).
    private var growThreshold: Int

    /// Creates an empty set with `initialCapacity` slots.
    init() {
        self.init(capacity: VoxelKeySet.initialCapacity)
    }

    /// Creates an empty set whose capacity is `capacity` rounded up to a power of two (at least
    /// `minimumCapacity`).
    init(capacity: Int) {
        let rounded = VoxelKeySet.roundUpToPowerOfTwo(Swift.max(capacity, VoxelKeySet.minimumCapacity))
        slots = [Int64](repeating: VoxelKeySet.emptySentinel, count: rounded)
        count = 0
        mask = rounded - 1
        shift = UInt64(64 - rounded.trailingZeroBitCount)
        growThreshold = VoxelKeySet.threshold(forCapacity: rounded)
    }

    /// Number of slots (always a power of two).
    var capacity: Int { slots.count }

    /// Current load factor `count / capacity`.
    var loadFactor: Double { Double(count) / Double(capacity) }

    /// True when `key` has been inserted.
    func contains(_ key: Int64) -> Bool {
        var index = VoxelKeySet.homeSlot(for: key, shift: shift)
        while true {
            let slot = slots[index]
            if slot == key { return true }
            if slot == VoxelKeySet.emptySentinel { return false }
            index = (index &+ 1) & mask
        }
    }

    /// Inserts `key`. Returns `true` when the key was not present before, `false` when it already was.
    @discardableResult
    mutating func insert(_ key: Int64) -> Bool {
        var index = VoxelKeySet.homeSlot(for: key, shift: shift)
        while true {
            let slot = slots[index]
            if slot == key { return false }
            if slot == VoxelKeySet.emptySentinel { break }
            index = (index &+ 1) & mask
        }
        slots[index] = key
        count += 1
        if count > growThreshold {
            grow()
        }
        return true
    }

    /// Doubles the capacity and re-inserts every key.
    private mutating func grow() {
        let newCapacity = capacity * 2
        let newMask = newCapacity - 1
        let newShift = UInt64(64 - newCapacity.trailingZeroBitCount)
        var newSlots = [Int64](repeating: VoxelKeySet.emptySentinel, count: newCapacity)
        newSlots.withUnsafeMutableBufferPointer { target in
            for key in slots where key != VoxelKeySet.emptySentinel {
                var index = VoxelKeySet.homeSlot(for: key, shift: newShift)
                while target[index] != VoxelKeySet.emptySentinel {
                    index = (index &+ 1) & newMask
                }
                target[index] = key
            }
        }
        slots = newSlots
        mask = newMask
        shift = newShift
        growThreshold = VoxelKeySet.threshold(forCapacity: newCapacity)
    }

    /// Fibonacci hash: the top `64 - shift` bits of `key * hashMultiplier`.
    @inline(__always)
    private static func homeSlot(for key: Int64, shift: UInt64) -> Int {
        Int(truncatingIfNeeded: (UInt64(bitPattern: key) &* hashMultiplier) >> shift)
    }

    /// `floor(capacity * maxLoadFactor)` computed in integers: `capacity * 7 / 10`.
    private static func threshold(forCapacity capacity: Int) -> Int {
        capacity * 7 / 10
    }

    /// Smallest power of two that is ≥ `value` (`value` must be ≥ 1).
    private static func roundUpToPowerOfTwo(_ value: Int) -> Int {
        if value <= 1 { return 1 }
        let highestBit = Int.bitWidth - 1 - (value - 1).leadingZeroBitCount
        return 1 << (highestBit + 1)
    }
}

// MARK: - VoxelGrid

/// Deduplicates a stream of points on a regular grid: the first sample that lands in a cell is kept and
/// every later sample in that cell is dropped. Cells are addressed by the packed keys produced by
/// `key(for:cellSize:)`, stored in an open-addressing `VoxelKeySet`.
///
/// Lifecycle (see `State`): the grid starts `.accepting` at `config.cellSize`. When `count` reaches
/// `config.maxPoints` it becomes `.capReached` and drops everything until the owner calls
/// `coarsen(existingPoints:)`, which rebuilds the key set at `config.coarsenedCellSize` and returns the
/// surviving points (state `.coarsened`). Reaching the cap a second time makes the grid `.full`, after
/// which no further point is ever accepted.
///
/// The grid only stores keys, not points; the caller owns the accepted point storage (for example a
/// `PointCloud` or a Metal buffer) and hands it back for coarsening.
public struct VoxelGrid: Sendable {
    /// Tunables of a grid. The defaults implement the product spec: 2 cm cells, a 3 M point cap and a
    /// single coarsening step to 3 cm.
    public struct Config: Sendable, Equatable {
        /// Edge length in meters of a cell while `.accepting`.
        public var cellSize: Float
        /// Maximum number of accepted points before the state changes to `.capReached` / `.full`.
        public var maxPoints: Int
        /// Cell edge length in meters used after `coarsen(existingPoints:)`.
        public var coarsenedCellSize: Float

        /// The product defaults: `cellSize` 0.02, `maxPoints` 3 000 000, `coarsenedCellSize` 0.03.
        public static let `default` = Config()

        /// Creates a configuration; every parameter defaults to the product value.
        public init(cellSize: Float = 0.02, maxPoints: Int = 3_000_000, coarsenedCellSize: Float = 0.03) {
            self.cellSize = cellSize
            self.maxPoints = maxPoints
            self.coarsenedCellSize = coarsenedCellSize
        }
    }

    /// Where the grid is in its lifecycle.
    public enum State: Sendable, Equatable {
        /// Fresh grid at `config.cellSize`; `insert` accepts new cells.
        case accepting
        /// `maxPoints` reached at the fine cell size; `insert` drops everything until `coarsen` is called.
        case capReached
        /// Rebuilt at `config.coarsenedCellSize`; `insert` accepts new cells again.
        case coarsened
        /// `maxPoints` reached after coarsening; the grid never accepts another point.
        case full
    }

    /// Number of bits per axis in a packed key.
    static let axisBits: Int64 = 21
    /// Mask selecting one axis' bits: `2²¹ − 1`.
    static let axisMask: Int64 = (1 << axisBits) - 1
    /// Offset added to each axis' cell index so that negative cells pack as non-negative values: `2²⁰`.
    static let axisOffset: Int64 = 1 << 20
    /// Largest magnitude a scaled coordinate is allowed to reach before being pinned (2³⁰, exact in
    /// `Float`). Anything beyond this is far outside the addressable ±2²⁰ cells anyway.
    static let scaledCoordinateLimit: Float = 1_073_741_824

    /// Current lifecycle state.
    public private(set) var state: State
    /// Cell edge length currently in use: `config.cellSize` until coarsened, then
    /// `config.coarsenedCellSize`.
    public private(set) var cellSize: Float
    /// Number of occupied cells (accepted points).
    public private(set) var count: Int
    /// Axis-aligned bounds of every accepted point; `.empty` while `count == 0`.
    public private(set) var bounds: BoundingBox
    /// The configuration the grid was created with.
    public let config: Config

    private var keySet: VoxelKeySet

    /// Creates an empty `.accepting` grid at `config.cellSize`.
    public init(config: Config = .default) {
        self.config = config
        self.state = .accepting
        self.cellSize = config.cellSize
        self.count = 0
        self.bounds = .empty
        self.keySet = VoxelKeySet()
    }

    /// True while `insert` can still accept points: `state == .accepting || state == .coarsened`.
    public var isAccepting: Bool {
        state == .accepting || state == .coarsened
    }

    /// Packs the cell containing `p` into one `Int64`.
    ///
    /// Per axis the cell index is `floor(coordinate / cellSize)` (floor, so negative coordinates land
    /// in the cell below zero rather than being truncated towards it), offset by `2²⁰` and masked to
    /// 21 bits. The three indices are packed as `x | (y << 21) | (z << 42)`, which is always
    /// non-negative. With 2 cm cells the addressable range per axis is `±2²⁰ · 0.02 m ≈ ±20 971 m`;
    /// coordinates beyond that are pinned to the first or last cell of the axis. Non-finite coordinates cannot address a cell
    /// and are pinned instead of trapping (NaN acts like 0, ±∞ like the far end of the range).
    public static func key(for p: SIMD3<Float>, cellSize: Float) -> Int64 {
        key(x: p.x, y: p.y, z: p.z, cellSize: cellSize)
    }

    /// Scalar form of `key(for:cellSize:)` used by the hot loops (avoids building a `SIMD3`).
    @inline(__always)
    static func key(x: Float, y: Float, z: Float, cellSize: Float) -> Int64 {
        let ix = axisIndex(x / cellSize)
        let iy = axisIndex(y / cellSize)
        let iz = axisIndex(z / cellSize)
        return ix | (iy << axisBits) | (iz << (2 * axisBits))
    }

    /// `floor(scaled)` offset by `axisOffset`, in `0 ..< 2^axisBits`.
    /// `Int64(Float)` traps on NaN and on magnitudes ≥ 2⁶³, so the value is pinned into
    /// `±scaledCoordinateLimit` first, and the resulting cell index is then clamped into the
    /// representable range: masking it instead would wrap ±∞ (and every magnitude above
    /// `axisOffset`, since `scaledCoordinateLimit` is a multiple of 2^axisBits) onto the origin
    /// cell, where a single degenerate point would squat on a cell real samples need.
    @inline(__always)
    private static func axisIndex(_ scaled: Float) -> Int64 {
        var value = scaled
        if value.isNaN {
            value = 0
        } else if value > scaledCoordinateLimit {
            value = scaledCoordinateLimit
        } else if value < -scaledCoordinateLimit {
            value = -scaledCoordinateLimit
        }
        let cell = Int64(value.rounded(.down))
        let clamped = Swift.min(Swift.max(cell, -axisOffset), axisOffset - 1)
        return clamped &+ axisOffset
    }

    /// True when the cell containing `p` (at the current `cellSize`) is already occupied.
    public func contains(_ p: SIMD3<Float>) -> Bool {
        keySet.contains(VoxelGrid.key(for: p, cellSize: cellSize))
    }

    /// Inserts `points` in order; the first sample per cell wins. Returns the accepted points in input
    /// order. Stops as soon as `count` reaches `config.maxPoints` (the rest of the batch is dropped)
    /// and moves the state to `.capReached` (from `.accepting`) or `.full` (from `.coarsened`).
    /// Returns `[]` immediately when the state is `.capReached` or `.full`.
    public mutating func insert(_ points: [PackedPoint]) -> [PackedPoint] {
        points.withUnsafeBufferPointer { self.insert($0) }
    }

    /// Buffer form of `insert(_:)` with identical semantics; use it to feed points straight from a
    /// shared Metal buffer or a decoded depth frame without an intermediate array.
    public mutating func insert(_ points: UnsafeBufferPointer<PackedPoint>) -> [PackedPoint] {
        guard isAccepting else { return [] }
        let maxPoints = config.maxPoints
        if count >= maxPoints {
            reachCap()
            return []
        }
        guard let base = points.baseAddress, !points.isEmpty else { return [] }

        var accepted: [PackedPoint] = []
        accepted.reserveCapacity(Swift.min(points.count, maxPoints - count))

        let cell = cellSize
        var minX = bounds.min.x, minY = bounds.min.y, minZ = bounds.min.z
        var maxX = bounds.max.x, maxY = bounds.max.y, maxZ = bounds.max.z
        var accepting = true
        var i = 0
        let n = points.count
        while accepting && i < n {
            let point = base[i]
            i += 1
            let key = VoxelGrid.key(x: point.x, y: point.y, z: point.z, cellSize: cell)
            guard keySet.insert(key) else { continue }
            accepted.append(point)
            if point.x < minX { minX = point.x }
            if point.y < minY { minY = point.y }
            if point.z < minZ { minZ = point.z }
            if point.x > maxX { maxX = point.x }
            if point.y > maxY { maxY = point.y }
            if point.z > maxZ { maxZ = point.z }
            count += 1
            if count >= maxPoints {
                accepting = false
            }
        }
        bounds = BoundingBox(min: SIMD3<Float>(minX, minY, minZ), max: SIMD3<Float>(maxX, maxY, maxZ))
        if !accepting {
            reachCap()
        }
        return accepted
    }

    /// Rebuilds the key set at `config.coarsenedCellSize` from `existingPoints` (in order, first sample
    /// per coarse cell wins), recomputes `count` and `bounds`, sets `cellSize` and moves the state to
    /// `.coarsened`. Returns the points that survived, in their original order. Allowed only from
    /// `.capReached`; from any other state it is a no-op that returns `Array(existingPoints)`.
    public mutating func coarsen(existingPoints: UnsafeBufferPointer<PackedPoint>) -> [PackedPoint] {
        guard state == .capReached else { return Array(existingPoints) }
        let coarse = config.coarsenedCellSize
        var rebuilt = VoxelKeySet()
        var kept: [PackedPoint] = []
        kept.reserveCapacity(existingPoints.count)
        var newBounds = BoundingBox.empty
        if let base = existingPoints.baseAddress {
            let n = existingPoints.count
            var i = 0
            while i < n {
                let point = base[i]
                i += 1
                let key = VoxelGrid.key(x: point.x, y: point.y, z: point.z, cellSize: coarse)
                guard rebuilt.insert(key) else { continue }
                kept.append(point)
                newBounds.formUnion(SIMD3<Float>(point.x, point.y, point.z))
            }
        }
        keySet = rebuilt
        cellSize = coarse
        count = kept.count
        bounds = newBounds
        state = .coarsened
        return kept
    }

    /// Transition taken when `count` reaches `config.maxPoints`.
    private mutating func reachCap() {
        state = (state == .accepting) ? .capReached : .full
    }
}
