import XCTest
import simd
@testable import MapCore

/// Deterministic 64-bit PRNG (SplitMix64) so the large-insert test never flakes.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `[lower, upper)`.
    mutating func nextFloat(_ lower: Float, _ upper: Float) -> Float {
        let unit = Float(next() >> 40) / Float(1 << 24)   // 24 random bits → [0, 1)
        return lower + unit * (upper - lower)
    }
}

final class VoxelGridTests: XCTestCase {

    private func pt(_ x: Float, _ y: Float, _ z: Float, _ color: UInt32 = 0xFF00_0000) -> PackedPoint {
        PackedPoint(x: x, y: y, z: z, color: color)
    }

    /// Key of the cell containing the origin at any cell size:
    /// (1 << 20) | ((1 << 20) << 21) | ((1 << 20) << 42) = 2²⁰ + 2⁴¹ + 2⁶²
    /// = 1_048_576 + 2_199_023_255_552 + 4_611_686_018_427_387_904 = 4_611_688_217_451_692_032
    private let originKey: Int64 = 4_611_688_217_451_692_032

    // MARK: - Config

    func testDefaultConfig() {
        let config = VoxelGrid.Config.default
        XCTAssertEqual(config.cellSize, 0.02)
        XCTAssertEqual(config.maxPoints, 3_000_000)
        XCTAssertEqual(config.coarsenedCellSize, 0.03)
        XCTAssertEqual(config, VoxelGrid.Config())
        XCTAssertEqual(VoxelGrid.Config(cellSize: 0.05, maxPoints: 10, coarsenedCellSize: 0.1).maxPoints, 10)
    }

    func testFreshGrid() {
        let grid = VoxelGrid()
        XCTAssertEqual(grid.state, .accepting)
        XCTAssertTrue(grid.isAccepting)
        XCTAssertEqual(grid.cellSize, 0.02)
        XCTAssertEqual(grid.count, 0)
        XCTAssertTrue(grid.bounds.isEmpty)
        XCTAssertEqual(grid.config, .default)
        XCTAssertFalse(grid.contains(SIMD3<Float>(0, 0, 0)))
    }

    // MARK: - Keys

    func testKeyOfOriginCellAt2cm() {
        let expected = (Int64(1) << 20) | ((Int64(1) << 20) << 21) | ((Int64(1) << 20) << 42)
        XCTAssertEqual(expected, originKey)
        XCTAssertEqual(VoxelGrid.key(for: SIMD3<Float>(0, 0, 0), cellSize: 0.02), originKey)
        // Any point strictly inside the origin cell floors to index 0 on every axis.
        XCTAssertEqual(VoxelGrid.key(for: SIMD3<Float>(0.019, 0.0199, 0.001), cellSize: 0.02), originKey)
    }

    func testKeyFloorsPerAxis() {
        let cell: Float = 0.02
        let origin = VoxelGrid.key(for: SIMD3<Float>(0, 0, 0), cellSize: cell)
        // 0.019 / 0.02 = 0.95 → floor 0 → same cell as the origin
        XCTAssertEqual(VoxelGrid.key(for: SIMD3<Float>(0.019, 0, 0), cellSize: cell), origin)
        // 0.02 / 0.02 = 1.0 exactly → x index 1 → key = origin + 1
        XCTAssertEqual(VoxelGrid.key(for: SIMD3<Float>(0.02, 0, 0), cellSize: cell), origin + 1)
        // −0.001 / 0.02 = −0.05 → floor −1 (not truncation to 0) → key = origin − 1
        XCTAssertEqual(VoxelGrid.key(for: SIMD3<Float>(-0.001, 0, 0), cellSize: cell), origin - 1)
        XCTAssertNotEqual(VoxelGrid.key(for: SIMD3<Float>(-0.001, 0, 0), cellSize: cell), origin)
        // −0.03 / 0.02 = −1.5 → floor −2 → origin − 2
        XCTAssertEqual(VoxelGrid.key(for: SIMD3<Float>(-0.03, 0, 0), cellSize: cell), origin - 2)
        // y index 1 lives 21 bits up: origin + (1 << 21) = origin + 2_097_152
        XCTAssertEqual(VoxelGrid.key(for: SIMD3<Float>(0, 0.02, 0), cellSize: cell), origin + 2_097_152)
        // z index 1 lives 42 bits up: origin + (1 << 42) = origin + 4_398_046_511_104
        XCTAssertEqual(VoxelGrid.key(for: SIMD3<Float>(0, 0, 0.02), cellSize: cell), origin + 4_398_046_511_104)
        // y index −1: origin − (1 << 21)
        XCTAssertEqual(VoxelGrid.key(for: SIMD3<Float>(0, -0.01, 0), cellSize: cell), origin - 2_097_152)
    }

    func testKeyDependsOnCellSize() {
        // 0.021 / 0.02 = 1.05 → x index 1; 0.021 / 0.03 = 0.7 → x index 0
        let p = SIMD3<Float>(0.021, 0, 0)
        XCTAssertEqual(VoxelGrid.key(for: p, cellSize: 0.02), originKey + 1)
        XCTAssertEqual(VoxelGrid.key(for: p, cellSize: 0.03), originKey)
        // 1 m at 2 cm is index 50: 1.0 / 0.02 = 50 → origin + 50
        XCTAssertEqual(VoxelGrid.key(for: SIMD3<Float>(1, 0, 0), cellSize: 0.02), originKey + 50)
    }

    func testKeyIsAlwaysNonNegativeAndNeverTraps() {
        // Far outside the ±20 971 m range: 1e9 / 0.02 = 5e10 cells → wraps via the 21-bit mask but stays ≥ 0
        XCTAssertGreaterThanOrEqual(VoxelGrid.key(for: SIMD3<Float>(1e9, -1e9, 3e8), cellSize: 0.02), 0)
        // Non-finite coordinates are pinned instead of trapping in Int64(Float).
        XCTAssertGreaterThanOrEqual(VoxelGrid.key(for: SIMD3<Float>(.infinity, -.infinity, .nan), cellSize: 0.02), 0)
        // NaN behaves like 0 on its axis.
        XCTAssertEqual(VoxelGrid.key(for: SIMD3<Float>(.nan, 0, 0), cellSize: 0.02), originKey)
        // The largest possible key, index 2²¹−1 on every axis, is still below Int64.max:
        // (2²¹−1) · (1 + 2²¹ + 2⁴²) = 2⁶³ − 1 → never the Int64.min sentinel.
        let maxIndex: Int64 = (1 << 21) - 1
        let maxKey = maxIndex | (maxIndex << 21) | (maxIndex << 42)
        XCTAssertEqual(maxKey, Int64.max)
        XCTAssertNotEqual(maxKey, VoxelKeySet.emptySentinel)
    }

    // MARK: - Insert

    func testInsertKeepsFirstSamplePerCell() {
        var grid = VoxelGrid()
        let first = pt(0.005, 0.005, 0.005, 1)
        let second = pt(0.015, 0.015, 0.015, 2)   // same 2 cm cell: every coordinate floors to 0
        let accepted = grid.insert([first, second])
        XCTAssertEqual(accepted, [first])
        XCTAssertEqual(grid.count, 1)
        XCTAssertEqual(grid.state, .accepting)
        XCTAssertTrue(grid.contains(first.position))
        XCTAssertTrue(grid.contains(second.position), "the rejected point's cell is occupied")
        XCTAssertTrue(grid.contains(SIMD3<Float>(0, 0, 0)))
        // Only the first point contributes to the bounds.
        XCTAssertEqual(grid.bounds.min, SIMD3<Float>(0.005, 0.005, 0.005))
        XCTAssertEqual(grid.bounds.max, SIMD3<Float>(0.005, 0.005, 0.005))

        // A later batch into the same cell is rejected too.
        XCTAssertEqual(grid.insert([pt(0.001, 0.001, 0.001, 3)]), [])
        XCTAssertEqual(grid.count, 1)
    }

    func testInsertAcceptsNeighbouringCells() {
        var grid = VoxelGrid()
        let a = pt(0.005, 0, 0, 1)   // x index 0
        let b = pt(0.025, 0, 0, 2)   // x index 1
        let c = pt(0.005, 0.025, 0, 3)   // y index 1
        let d = pt(0.005, 0, 0.025, 4)   // z index 1
        XCTAssertEqual(grid.insert([a, b, c, d]), [a, b, c, d])
        XCTAssertEqual(grid.count, 4)
        XCTAssertTrue(grid.contains(SIMD3<Float>(0.039, 0.019, 0.019)))    // (1, 0, 0) cell
        XCTAssertFalse(grid.contains(SIMD3<Float>(0.045, 0.045, 0.045)))   // (2, 2, 2) cell
        XCTAssertFalse(grid.contains(SIMD3<Float>(-0.001, 0, 0)))          // (−1, 0, 0) cell
    }

    func testInsertSeparatesCellsAcrossZero() {
        var grid = VoxelGrid()
        let negative = pt(-0.001, 0, 0, 1)   // floor(−0.05) = −1
        let positive = pt(0.001, 0, 0, 2)    // floor(0.05) = 0
        XCTAssertEqual(grid.insert([negative, positive]), [negative, positive])
        XCTAssertEqual(grid.count, 2)
    }

    func testBoundsAfterInserts() {
        var grid = VoxelGrid()
        _ = grid.insert([pt(0.005, 0.005, 0.005)])
        _ = grid.insert([pt(0.025, -0.01, 0.5)])
        // min = (min(0.005, 0.025), min(0.005, −0.01), min(0.005, 0.5)) = (0.005, −0.01, 0.005)
        XCTAssertEqual(grid.bounds.min, SIMD3<Float>(0.005, -0.01, 0.005))
        // max = (max(0.005, 0.025), max(0.005, −0.01), max(0.005, 0.5)) = (0.025, 0.005, 0.5)
        XCTAssertEqual(grid.bounds.max, SIMD3<Float>(0.025, 0.005, 0.5))

        // A rejected duplicate (same cell as the first point) must not move the bounds even though it lies
        // further out.
        XCTAssertEqual(grid.insert([pt(0.019, 0.019, 0.019)]), [])
        XCTAssertEqual(grid.bounds.min, SIMD3<Float>(0.005, -0.01, 0.005))
        XCTAssertEqual(grid.bounds.max, SIMD3<Float>(0.025, 0.005, 0.5))
    }

    func testInsertEmptyBatch() {
        var grid = VoxelGrid()
        XCTAssertEqual(grid.insert([]), [])
        XCTAssertEqual(grid.state, .accepting)
        XCTAssertEqual(grid.count, 0)
        XCTAssertTrue(grid.bounds.isEmpty)
    }

    func testArrayOverloadForwardsToBufferOverload() {
        let points = (0..<10).map { pt(Float($0) * 0.03, 0, 0, UInt32($0)) }   // 10 distinct x cells
        var viaArray = VoxelGrid()
        var viaBuffer = VoxelGrid()
        let a = viaArray.insert(points)
        let b = points.withUnsafeBufferPointer { viaBuffer.insert($0) }
        XCTAssertEqual(a, points)
        XCTAssertEqual(a, b)
        XCTAssertEqual(viaArray.count, viaBuffer.count)
        XCTAssertEqual(viaArray.bounds, viaBuffer.bounds)
        XCTAssertEqual(viaArray.state, viaBuffer.state)
    }

    // MARK: - Cap

    func testCapReachedStopsAcceptingAndDropsTheRest() {
        var grid = VoxelGrid(config: .init(cellSize: 0.02, maxPoints: 5, coarsenedCellSize: 0.03))
        // x = 0.01 + 0.02·i sits at the centre of cell i → 8 distinct cells
        let points = (0..<8).map { pt(0.01 + 0.02 * Float($0), 0, 0, UInt32($0)) }
        let accepted = grid.insert(points)
        XCTAssertEqual(accepted, Array(points[0..<5]), "first five accepted, remaining three dropped")
        XCTAssertEqual(grid.count, 5)
        XCTAssertEqual(grid.state, .capReached)
        XCTAssertFalse(grid.isAccepting)
        XCTAssertTrue(grid.contains(points[4].position))
        XCTAssertFalse(grid.contains(points[5].position))

        // Everything is rejected now, even a point in a brand-new cell.
        XCTAssertEqual(grid.insert([pt(1, 1, 1)]), [])
        XCTAssertEqual(grid.count, 5)
        XCTAssertEqual(grid.state, .capReached)
        // min x = 0.01, max x = 0.01 + 0.02·4 = 0.09
        XCTAssertEqual(grid.bounds.min, SIMD3<Float>(0.01, 0, 0))
        XCTAssertEqual(grid.bounds.max.x, 0.09, accuracy: 1e-6)
    }

    func testCapReachedExactlyAtBatchEnd() {
        var grid = VoxelGrid(config: .init(cellSize: 0.02, maxPoints: 2, coarsenedCellSize: 0.03))
        XCTAssertEqual(grid.insert([pt(0.01, 0, 0)]).count, 1)
        XCTAssertEqual(grid.state, .accepting)
        XCTAssertEqual(grid.insert([pt(0.03, 0, 0)]).count, 1)
        XCTAssertEqual(grid.state, .capReached, "count == maxPoints flips the state at once")
        XCTAssertEqual(grid.count, 2)
    }

    func testDuplicatesDoNotCountTowardsTheCap() {
        var grid = VoxelGrid(config: .init(cellSize: 0.02, maxPoints: 2, coarsenedCellSize: 0.03))
        // Three samples in cell 0 then one in cell 1: only two distinct cells → cap reached with the 4th point.
        let accepted = grid.insert([pt(0.001, 0, 0, 1), pt(0.002, 0, 0, 2), pt(0.003, 0, 0, 3), pt(0.03, 0, 0, 4)])
        XCTAssertEqual(accepted.map(\.color), [1, 4])
        XCTAssertEqual(grid.count, 2)
        XCTAssertEqual(grid.state, .capReached)
    }

    func testZeroMaxPointsReachesCapOnFirstInsert() {
        var grid = VoxelGrid(config: .init(cellSize: 0.02, maxPoints: 0, coarsenedCellSize: 0.03))
        XCTAssertEqual(grid.state, .accepting)
        XCTAssertEqual(grid.insert([pt(0, 0, 0)]), [])
        XCTAssertEqual(grid.count, 0)
        XCTAssertEqual(grid.state, .capReached)
    }

    // MARK: - Coarsen

    func testCoarsenLifecycle() {
        var grid = VoxelGrid(config: .init(cellSize: 0.02, maxPoints: 2, coarsenedCellSize: 0.03))
        let a = pt(0.019, 0, 0, 1)   // 0.019 / 0.02 = 0.95 → cell 0 at 2 cm; 0.019 / 0.03 = 0.63 → cell 0 at 3 cm
        let b = pt(0.021, 0, 0, 2)   // 0.021 / 0.02 = 1.05 → cell 1 at 2 cm; 0.021 / 0.03 = 0.70 → cell 0 at 3 cm
        let accepted = grid.insert([a, b])
        XCTAssertEqual(accepted, [a, b])
        XCTAssertEqual(grid.state, .capReached)

        let kept = accepted.withUnsafeBufferPointer { grid.coarsen(existingPoints: $0) }
        XCTAssertEqual(kept, [a], "both collapse into one 3 cm cell; the first survives")
        XCTAssertEqual(grid.state, .coarsened)
        XCTAssertTrue(grid.isAccepting)
        XCTAssertEqual(grid.cellSize, 0.03)
        XCTAssertEqual(grid.count, 1)
        XCTAssertEqual(grid.bounds.min, SIMD3<Float>(0.019, 0, 0))
        XCTAssertEqual(grid.bounds.max, SIMD3<Float>(0.019, 0, 0))
        XCTAssertTrue(grid.contains(b.position), "b's coarse cell is the same as a's")
        XCTAssertFalse(grid.contains(SIMD3<Float>(0.05, 0, 0)))   // 0.05 / 0.03 = 1.67 → cell 1

        // Refill to the cap: one more distinct coarse cell → count 2 == maxPoints → .full
        let c = pt(0.05, 0, 0, 3)
        XCTAssertEqual(grid.insert([c]), [c])
        XCTAssertEqual(grid.count, 2)
        XCTAssertEqual(grid.state, .full)
        XCTAssertFalse(grid.isAccepting)
        // max x is now 0.05
        XCTAssertEqual(grid.bounds.max, SIMD3<Float>(0.05, 0, 0))

        // Nothing is accepted any more.
        XCTAssertEqual(grid.insert([pt(0.1, 0, 0, 4)]), [])   // 0.1 / 0.03 = 3.33 → cell 3, a new cell, still rejected
        XCTAssertEqual(grid.count, 2)
        XCTAssertEqual(grid.state, .full)

        // coarsen in .full is a no-op that hands back everything it was given.
        let all = [a, c]
        let unchanged = all.withUnsafeBufferPointer { grid.coarsen(existingPoints: $0) }
        XCTAssertEqual(unchanged, all)
        XCTAssertEqual(grid.state, .full)
        XCTAssertEqual(grid.count, 2)
        XCTAssertEqual(grid.cellSize, 0.03)
    }

    func testCoarsenIsNoOpWhileAccepting() {
        var grid = VoxelGrid()
        let a = pt(0.019, 0, 0, 1)
        let b = pt(0.021, 0, 0, 2)
        _ = grid.insert([a, b])
        let result = [a, b].withUnsafeBufferPointer { grid.coarsen(existingPoints: $0) }
        XCTAssertEqual(result, [a, b], "returned unchanged, no coarse dedupe")
        XCTAssertEqual(grid.state, .accepting)
        XCTAssertEqual(grid.cellSize, 0.02)
        XCTAssertEqual(grid.count, 2)
    }

    func testCoarsenRebuildsFromTheGivenPointsNotTheOldKeys() {
        var grid = VoxelGrid(config: .init(cellSize: 0.02, maxPoints: 1, coarsenedCellSize: 0.03))
        _ = grid.insert([pt(0.01, 0, 0, 1)])
        XCTAssertEqual(grid.state, .capReached)

        // Rebuild from an empty buffer: the grid forgets the old cell entirely.
        let empty: [PackedPoint] = []
        let kept = empty.withUnsafeBufferPointer { grid.coarsen(existingPoints: $0) }
        XCTAssertEqual(kept, [])
        XCTAssertEqual(grid.state, .coarsened)
        XCTAssertEqual(grid.count, 0)
        XCTAssertTrue(grid.bounds.isEmpty)
        XCTAssertFalse(grid.contains(SIMD3<Float>(0.01, 0, 0)))

        // Rebuild from a different point set than what was inserted: keys come from the buffer.
        var other = VoxelGrid(config: .init(cellSize: 0.02, maxPoints: 1, coarsenedCellSize: 0.03))
        _ = other.insert([pt(0.01, 0, 0, 1)])
        let replacement = [pt(1, 1, 1, 7), pt(1.01, 1.01, 1.01, 8), pt(-1, -1, -1, 9)]
        // 1 / 0.03 = 33.3 → 33; 1.01 / 0.03 = 33.67 → 33 (same cell); −1 / 0.03 = −33.3 → −34
        let keptOther = replacement.withUnsafeBufferPointer { other.coarsen(existingPoints: $0) }
        XCTAssertEqual(keptOther.map(\.color), [7, 9])
        XCTAssertEqual(other.count, 2)
        XCTAssertEqual(other.bounds.min, SIMD3<Float>(-1, -1, -1))
        XCTAssertEqual(other.bounds.max, SIMD3<Float>(1, 1, 1))
        XCTAssertFalse(other.contains(SIMD3<Float>(0.01, 0, 0)), "the original 2 cm cell is gone")
        // 1.015 / 0.03 = 33.83 → cell 33 on every axis, the same coarse cell as (1, 1, 1)
        XCTAssertTrue(other.contains(SIMD3<Float>(1.015, 1.015, 1.015)))
    }

    // MARK: - Large seeded insert

    func testLargeSeededInsertMatchesIndependentSetAndIsFast() {
        let pointCount = 200_000
        var rng = SplitMix64(state: 0xC0FF_EE00_DEAD_BEEF)
        var points: [PackedPoint] = []
        points.reserveCapacity(pointCount)
        for i in 0..<pointCount {
            // Uniform in [−1, 1)³ → 100³ = 1 M cells at 2 cm, so a fair share of collisions.
            points.append(pt(rng.nextFloat(-1, 1), rng.nextFloat(-1, 1), rng.nextFloat(-1, 1), UInt32(i)))
        }

        // Independent expectation using Swift's own hashed collections.
        var seen = Set<Int64>()
        var expectedAccepted: [PackedPoint] = []
        for p in points where seen.insert(VoxelGrid.key(for: p.position, cellSize: 0.02)).inserted {
            expectedAccepted.append(p)
        }
        XCTAssertGreaterThan(seen.count, 150_000, "sanity: most cells are distinct")
        XCTAssertLessThan(seen.count, pointCount, "sanity: some cells collide")

        var grid = VoxelGrid()
        let clock = ContinuousClock()
        let start = clock.now
        let accepted = grid.insert(points)
        let elapsed = clock.now - start

        XCTAssertLessThan(elapsed, .seconds(1), "200 000 inserts took \(elapsed)")
        XCTAssertEqual(grid.count, seen.count)
        XCTAssertEqual(accepted.count, seen.count)
        XCTAssertEqual(accepted, expectedAccepted, "first sample per cell, in input order")
        XCTAssertEqual(grid.state, .accepting)

        // Bounds equal the min/max over the accepted points.
        var expectedBounds = BoundingBox.empty
        for p in expectedAccepted { expectedBounds.formUnion(p.position) }
        XCTAssertEqual(grid.bounds, expectedBounds)

        // contains() agrees with the set for every input point (accepted or not) and for far-away cells.
        for p in points.prefix(2_000) {
            XCTAssertTrue(grid.contains(p.position))
        }
        XCTAssertFalse(grid.contains(SIMD3<Float>(100, 100, 100)))
        XCTAssertFalse(grid.contains(SIMD3<Float>(-3, 0, 0)))
    }

    // MARK: - VoxelKeySet

    func testKeySetSentinelAndDefaults() {
        XCTAssertEqual(VoxelKeySet.emptySentinel, Int64.min)
        XCTAssertEqual(VoxelKeySet.initialCapacity, 65_536)   // 1 << 16
        let set = VoxelKeySet()
        XCTAssertEqual(set.capacity, 65_536)
        XCTAssertEqual(set.count, 0)
        XCTAssertEqual(set.loadFactor, 0)
        XCTAssertFalse(set.contains(0))
        XCTAssertFalse(set.contains(Int64.max))
        XCTAssertTrue(set.slots.allSatisfy { $0 == Int64.min })
    }

    func testKeySetCapacityRoundsUpToPowerOfTwo() {
        XCTAssertEqual(VoxelKeySet(capacity: 20).capacity, 32)
        XCTAssertEqual(VoxelKeySet(capacity: 64).capacity, 64)
        XCTAssertEqual(VoxelKeySet(capacity: 65).capacity, 128)
        XCTAssertEqual(VoxelKeySet(capacity: 1).capacity, 16, "minimum capacity")
        XCTAssertEqual(VoxelKeySet(capacity: 0).capacity, 16)
    }

    func testKeySetInsertAndContains() {
        var set = VoxelKeySet(capacity: 16)
        XCTAssertTrue(set.insert(5))
        XCTAssertFalse(set.insert(5), "second insert of the same key reports it was already present")
        XCTAssertEqual(set.count, 1)
        XCTAssertTrue(set.contains(5))
        XCTAssertFalse(set.contains(6))
        XCTAssertTrue(set.insert(0))
        XCTAssertTrue(set.insert(Int64.max))
        XCTAssertEqual(set.count, 3)
        XCTAssertTrue(set.contains(0))
        XCTAssertTrue(set.contains(Int64.max))
        XCTAssertEqual(set.slots.filter { $0 != Int64.min }.sorted(), [0, 5, Int64.max])
    }

    func testKeySetGrowsWhenLoadExceedsPointSeven() {
        var set = VoxelKeySet(capacity: 16)
        for key in Int64(0)..<11 { set.insert(key * 1_000) }
        // 11 / 16 = 0.6875 ≤ 0.7 → no growth yet
        XCTAssertEqual(set.count, 11)
        XCTAssertEqual(set.capacity, 16)

        set.insert(11_000)
        // 12 / 16 = 0.75 > 0.7 → doubled to 32
        XCTAssertEqual(set.count, 12)
        XCTAssertEqual(set.capacity, 32)
        XCTAssertEqual(set.loadFactor, 0.375)   // 12 / 32
        for key in Int64(0)..<12 {
            XCTAssertTrue(set.contains(key * 1_000), "key \(key * 1_000) survived the rehash")
        }
        for key in Int64(12)..<20 {
            XCTAssertFalse(set.contains(key * 1_000))
        }
        // Every stored key appears exactly once in the table.
        XCTAssertEqual(set.slots.filter { $0 != Int64.min }.count, 12)
    }

    func testKeySetRepeatedGrowthPreservesEveryKey() {
        var set = VoxelKeySet(capacity: 16)
        for key in Int64(0)..<1_000 { set.insert(key) }
        XCTAssertEqual(set.count, 1_000)
        // Growth points (count > capacity·7/10): 12@16 → 23@32 → 45@64 → 90@128 → 180@256 → 359@512
        // → 717@1024 → capacity 2048; 2048·7/10 = 1433 ≥ 1000 so it stays there.
        XCTAssertEqual(set.capacity, 2_048)
        for key in Int64(0)..<1_000 {
            XCTAssertTrue(set.contains(key))
        }
        XCTAssertFalse(set.contains(1_000))
        XCTAssertFalse(set.contains(-1))
        XCTAssertEqual(set.slots.filter { $0 != Int64.min }.count, 1_000)
        // Re-inserting everything is a no-op.
        for key in Int64(0)..<1_000 { XCTAssertFalse(set.insert(key)) }
        XCTAssertEqual(set.count, 1_000)
    }

    func testKeySetHandlesRealVoxelKeys() {
        // Voxel keys are large, sparse values (≈ 2⁶²); make sure Fibonacci hashing spreads them and
        // linear probing finds them after growth.
        var set = VoxelKeySet(capacity: 16)
        var keys: [Int64] = []
        for x in 0..<8 {
            for y in 0..<8 {
                for z in 0..<8 {
                    // Cell centres ((i + 0.5) · 0.02) so Float rounding can never cross a cell boundary.
                    let centre = (SIMD3<Float>(Float(x), Float(y), Float(z)) + 0.5) * 0.02
                    keys.append(VoxelGrid.key(for: centre, cellSize: 0.02))
                }
            }
        }
        XCTAssertEqual(Set(keys).count, 512, "8³ distinct cells")
        for key in keys { XCTAssertTrue(set.insert(key)) }
        XCTAssertEqual(set.count, 512)
        // 512 / 0.7 = 731 → 1024 slots
        XCTAssertEqual(set.capacity, 1_024)
        for key in keys { XCTAssertTrue(set.contains(key)) }
        XCTAssertFalse(set.contains(VoxelGrid.key(for: SIMD3<Float>(8.5, 0.5, 0.5) * 0.02, cellSize: 0.02)))
    }

    func testKeySetIsValueType() {
        var a = VoxelKeySet(capacity: 16)
        a.insert(1)
        var b = a
        b.insert(2)
        XCTAssertTrue(a.contains(1))
        XCTAssertFalse(a.contains(2), "mutating the copy must not affect the original")
        XCTAssertTrue(b.contains(1))
        XCTAssertTrue(b.contains(2))
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 2)
    }
}
