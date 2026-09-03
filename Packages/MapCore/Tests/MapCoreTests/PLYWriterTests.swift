import Foundation
import MapCore
import XCTest

/// Deterministic SplitMix64 generator so the large round-trip payload is reproducible.
private struct PLYTestRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class PLYWriterTests: XCTestCase {
    private static let headerForTwoWithComment =
        "ply\n" +
        "format binary_little_endian 1.0\n" +
        "comment made by RoomMapper\n" +
        "element vertex 2\n" +
        "property float x\n" +
        "property float y\n" +
        "property float z\n" +
        "property uchar red\n" +
        "property uchar green\n" +
        "property uchar blue\n" +
        "end_header\n"

    private static let samplePoints: [PackedPoint] = [
        PackedPoint(position: SIMD3<Float>(1.5, -2, 0.25), r: 10, g: 20, b: 30),
        PackedPoint(position: SIMD3<Float>(-0.125, 3, 1e-3), r: 255, g: 0, b: 128),
        PackedPoint(position: SIMD3<Float>(0, 0, 0), r: 0, g: 0, b: 0),
    ]

    /// Header text with the standard six properties and `count` vertices, but an arbitrary format line.
    private static func header(format: String, count: Int) -> String {
        "ply\n\(format)\nelement vertex \(count)\n" +
            "property float x\nproperty float y\nproperty float z\n" +
            "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
    }

    /// The 15 record bytes of `point`.
    private static func record(_ point: PackedPoint) -> [UInt8] {
        Array(PLYWriter.encode(points: [point]).suffix(15))
    }

    private func assertInvalidPLY(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PLYReader.read(data: data), file: file, line: line) { error in
            guard let mapError = error as? MapError, case .invalidPLY = mapError else {
                XCTFail("expected MapError.invalidPLY, got \(error)", file: file, line: line)
                return
            }
        }
    }

    private func assertIO(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let mapError = error as? MapError, case .io = mapError else {
                XCTFail("expected MapError.io, got \(error)", file: file, line: line)
                return
            }
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PLYWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? -1
    }

    /// 100 000 deterministic points with finite coordinates and alpha 255 (PLY carries no alpha).
    private static func generatedPoints(count: Int) -> [PackedPoint] {
        var rng = PLYTestRNG(seed: 0x5EED)
        var points: [PackedPoint] = []
        points.reserveCapacity(count)
        for _ in 0..<count {
            let x = Float(Int(rng.next() % 20001) - 10000) / 1000
            let y = Float(Int(rng.next() % 20001) - 10000) / 1000
            let z = Float(Int(rng.next() % 20001) - 10000) / 1000
            let color = rng.next()
            points.append(PackedPoint(
                position: SIMD3<Float>(x, y, z),
                r: UInt8(truncatingIfNeeded: color),
                g: UInt8(truncatingIfNeeded: color >> 8),
                b: UInt8(truncatingIfNeeded: color >> 16)
            ))
        }
        return points
    }

    // MARK: - header

    func testHeaderTwoPointsOneComment() {
        XCTAssertEqual(PLYWriter.header(pointCount: 2, comments: ["made by RoomMapper"]), Self.headerForTwoWithComment)
    }

    func testHeaderWithoutComments() {
        let expected = "ply\nformat binary_little_endian 1.0\nelement vertex 0\n" +
            "property float x\nproperty float y\nproperty float z\n" +
            "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
        XCTAssertEqual(PLYWriter.header(pointCount: 0), expected)
        // ply + format + element + 6 properties + end_header = 10 lines; one comment adds one line.
        XCTAssertEqual(PLYWriter.header(pointCount: 0).split(separator: "\n").count, 10)
        XCTAssertEqual(Self.headerForTwoWithComment.split(separator: "\n").count, 11)
    }

    func testHeaderStripsNewlinesFromComments() {
        let header = PLYWriter.header(pointCount: 1, comments: ["a\nb", "c\r\nd", "\n", "plain"])
        XCTAssertTrue(header.hasPrefix("ply\nformat binary_little_endian 1.0\ncomment ab\ncomment cd\ncomment \ncomment plain\nelement vertex 1\n"))
        // A comment can never inject a second end_header line before the real one: the newlines are
        // removed, so "x\nend_header\n" becomes the single comment line "comment xend_header".
        let injected = PLYWriter.header(pointCount: 1, comments: ["x\nend_header\n"])
        XCTAssertEqual(injected.split(separator: "\n").filter { $0 == "end_header" }.count, 1)
        XCTAssertTrue(injected.contains("comment xend_header\n"))
        let roundTrip = try? PLYReader.read(data: PLYWriter.encode(points: [Self.samplePoints[0]], comments: ["x\nend_header\n"]))
        XCTAssertEqual(roundTrip?.points, [Self.samplePoints[0]])
    }

    // MARK: - encode

    func testEncodeLengthForTwoPoints() {
        let points = Array(Self.samplePoints.prefix(2))
        let data = PLYWriter.encode(points: points, comments: ["made by RoomMapper"])
        // header bytes + 2 records × 15 bytes = header + 30.
        XCTAssertEqual(data.count, Self.headerForTwoWithComment.utf8.count + 30)
        XCTAssertEqual(String(decoding: data.prefix(Self.headerForTwoWithComment.utf8.count), as: UTF8.self), Self.headerForTwoWithComment)
    }

    func testFirstRecordBytes() {
        let point = PackedPoint(position: SIMD3<Float>(1.5, -2, 0.25), r: 10, g: 20, b: 30)
        let data = PLYWriter.encode(points: [point])
        let headerLength = PLYWriter.header(pointCount: 1).utf8.count
        XCTAssertEqual(data.count, headerLength + 15)
        let record = Array(data.suffix(15))
        // 1.5 = 0x3FC00000 (sign 0, exponent 127, mantissa .1) → little-endian 00 00 C0 3F
        XCTAssertEqual(record[0], 0x00)
        XCTAssertEqual(record[1], 0x00)
        XCTAssertEqual(record[2], 0xC0)
        XCTAssertEqual(record[3], 0x3F)
        // -2 = 0xC0000000 (sign 1, exponent 128, mantissa 0) → 00 00 00 C0
        XCTAssertEqual(record[4], 0x00)
        XCTAssertEqual(record[5], 0x00)
        XCTAssertEqual(record[6], 0x00)
        XCTAssertEqual(record[7], 0xC0)
        // 0.25 = 0x3E800000 (sign 0, exponent 125, mantissa 0) → 00 00 80 3E
        XCTAssertEqual(record[8], 0x00)
        XCTAssertEqual(record[9], 0x00)
        XCTAssertEqual(record[10], 0x80)
        XCTAssertEqual(record[11], 0x3E)
        // r g b = 10 20 30 = 0A 14 1E
        XCTAssertEqual(record[12], 0x0A)
        XCTAssertEqual(record[13], 0x14)
        XCTAssertEqual(record[14], 0x1E)
    }

    func testEncodeDropsAlpha() {
        // Alpha 7 is not part of the record; the bytes equal those of the same point with alpha 255.
        let opaque = PackedPoint(position: SIMD3<Float>(1, 2, 3), r: 4, g: 5, b: 6, a: 255)
        let translucent = PackedPoint(position: SIMD3<Float>(1, 2, 3), r: 4, g: 5, b: 6, a: 7)
        XCTAssertEqual(PLYWriter.encode(points: [opaque]), PLYWriter.encode(points: [translucent]))
    }

    func testEncodeEmpty() {
        XCTAssertEqual(PLYWriter.encode(points: []), Data(PLYWriter.header(pointCount: 0).utf8))
    }

    // MARK: - read (in memory)

    func testReadRoundTripInMemory() throws {
        let cloud = try PLYReader.read(data: PLYWriter.encode(points: Self.samplePoints))
        XCTAssertEqual(cloud.count, 3)
        XCTAssertEqual(cloud.points, Self.samplePoints)
        XCTAssertEqual(cloud.points[0].a, 255)
    }

    func testReadIgnoresComments() throws {
        let data = PLYWriter.encode(points: Self.samplePoints, comments: ["first", "", "third comment with spaces"])
        let cloud = try PLYReader.read(data: data)
        XCTAssertEqual(cloud.points, Self.samplePoints)
    }

    func testReadZeroVertices() throws {
        XCTAssertEqual(try PLYReader.read(data: PLYWriter.encode(points: [])).count, 0)
        // Header only, with trailing junk after end_header: nothing to read, so it is ignored.
        XCTAssertEqual(try PLYReader.read(data: Data(PLYWriter.header(pointCount: 0).utf8) + Data([1, 2, 3])).count, 0)
    }

    func testReadToleratesCRLFAndTrailingBytes() throws {
        let point = Self.samplePoints[0]
        let crlfHeader = PLYWriter.header(pointCount: 1).replacingOccurrences(of: "\n", with: "\r\n")
        let data = Data(crlfHeader.utf8) + Data(Self.record(point)) + Data([0xAA, 0xBB])
        let cloud = try PLYReader.read(data: data)
        XCTAssertEqual(cloud.points, [point])
    }

    func testReadAcceptsDataSlice() throws {
        // A Data slice whose startIndex is not 0 must be parsed relative to its own first byte.
        let padded = Data([0xFF, 0xFF, 0xFF]) + PLYWriter.encode(points: Self.samplePoints)
        let slice = padded[3...]
        XCTAssertEqual(slice.startIndex, 3)
        XCTAssertEqual(try PLYReader.read(data: slice).points, Self.samplePoints)
    }

    func testReadRejectsAsciiFormat() {
        let data = Data(Self.header(format: "format ascii 1.0", count: 0).utf8)
        assertInvalidPLY(data)
        assertInvalidPLY(Data(Self.header(format: "format binary_big_endian 1.0", count: 0).utf8))
        assertInvalidPLY(Data(Self.header(format: "format binary_little_endian 2.0", count: 0).utf8))
    }

    func testReadRejectsMissingEndHeader() {
        let full = PLYWriter.encode(points: [Self.samplePoints[0]])
        let header = PLYWriter.header(pointCount: 1)
        let withoutEnd = header.replacingOccurrences(of: "end_header\n", with: "")
        let data = Data(withoutEnd.utf8) + full.suffix(15)
        assertInvalidPLY(data)
        // Header cut off mid-way (no trailing newline at all).
        assertInvalidPLY(Data("ply\nformat binary_little_endian 1.0\nelement vertex 1".utf8))
    }

    func testReadRejectsTruncatedBody() {
        let full = PLYWriter.encode(points: Array(Self.samplePoints.prefix(2)))
        // Header claims 2 vertices (30 bytes) but only 29 body bytes remain.
        assertInvalidPLY(full.dropLast(1))
        // Only one complete record (15 bytes) for a 2-vertex header.
        assertInvalidPLY(full.dropLast(15))
        // Header only.
        assertInvalidPLY(Data(PLYWriter.header(pointCount: 2).utf8))
    }

    func testReadRejectsMalformedHeaders() {
        let record = Self.record(Self.samplePoints[0])
        func file(_ header: String) -> Data { Data(header.utf8) + Data(record) }

        // Empty input and missing magic.
        assertInvalidPLY(Data())
        assertInvalidPLY(file("PLY\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"))
        // Missing format line.
        assertInvalidPLY(file("ply\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"))
        // Missing element line.
        assertInvalidPLY(file("ply\nformat binary_little_endian 1.0\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"))
        // Wrong property order (red before z).
        assertInvalidPLY(file("ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float x\nproperty float y\nproperty uchar red\nproperty float z\nproperty uchar green\nproperty uchar blue\nend_header\n"))
        // Wrong property type (double x).
        assertInvalidPLY(file("ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty double x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"))
        // Only five properties.
        assertInvalidPLY(file("ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nend_header\n"))
        // Extra seventh property.
        assertInvalidPLY(file("ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar alpha\nend_header\n"))
        // Second element.
        assertInvalidPLY(file("ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nelement face 0\nend_header\n"))
        // Non-vertex element.
        assertInvalidPLY(file("ply\nformat binary_little_endian 1.0\nelement face 1\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"))
        // Negative and non-integer vertex counts.
        assertInvalidPLY(file(Self.header(format: "format binary_little_endian 1.0", count: -1)))
        assertInvalidPLY(file("ply\nformat binary_little_endian 1.0\nelement vertex one\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"))
        // Unknown keyword.
        assertInvalidPLY(file("ply\nformat binary_little_endian 1.0\nobj_info x\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"))
        // Blank header line.
        assertInvalidPLY(file("ply\nformat binary_little_endian 1.0\n\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"))
    }

    // MARK: - write / read (files)

    func testWriteReadRoundTrip100kPoints() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cloud.ply")
        let points = Self.generatedPoints(count: 100_000)

        try points.withUnsafeBufferPointer { try PLYWriter.write(points: $0, to: url, comments: ["round trip"]) }

        // File size = header bytes + 100 000 × 15 = header + 1 500 000.
        let headerLength = PLYWriter.header(pointCount: 100_000, comments: ["round trip"]).utf8.count
        XCTAssertEqual(try fileSize(url), headerLength + 1_500_000)
        // The streamed file is byte-identical to the in-memory encoding.
        XCTAssertEqual(try Data(contentsOf: url), PLYWriter.encode(points: points, comments: ["round trip"]))
        // No temporary file survives.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["cloud.ply"])

        let cloud = try PLYReader.read(url: url)
        XCTAssertEqual(cloud.count, 100_000)
        XCTAssertTrue(cloud.points == points, "points must round-trip in order with identical values")
        XCTAssertEqual(cloud.points[0], points[0])
        XCTAssertEqual(cloud.points[65_535], points[65_535])   // last point of the first chunk
        XCTAssertEqual(cloud.points[65_536], points[65_536])   // first point of the second chunk
        XCTAssertEqual(cloud.points[99_999], points[99_999])
    }

    func testWriteExactChunkBoundary() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cloud.ply")
        for count in [65_536, 65_537, 1] {
            let points = Self.generatedPoints(count: count)
            try PLYWriter.write(points: points, to: url)
            XCTAssertEqual(try fileSize(url), PLYWriter.header(pointCount: count).utf8.count + count * 15)
            let cloud = try PLYReader.read(url: url)
            XCTAssertEqual(cloud.count, count)
            XCTAssertTrue(cloud.points == points)
        }
    }

    func testWriteReplacesExistingFileAndLeavesNoTemporaries() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cloud.ply")

        try PLYWriter.write(points: Self.samplePoints, to: url)
        XCTAssertEqual(try PLYReader.read(url: url).count, 3)

        let two = Array(Self.samplePoints.suffix(2))
        try PLYWriter.write(points: two, to: url)
        let cloud = try PLYReader.read(url: url)
        XCTAssertEqual(cloud.points, two)
        XCTAssertEqual(try fileSize(url), PLYWriter.header(pointCount: 2).utf8.count + 30)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["cloud.ply"])

        // Empty cloud overwrites too.
        try PLYWriter.write(points: [], to: url)
        XCTAssertEqual(try PLYReader.read(url: url).count, 0)
        XCTAssertEqual(try fileSize(url), PLYWriter.header(pointCount: 0).utf8.count)
    }

    func testWriteToMissingDirectoryThrowsIO() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("missing", isDirectory: true).appendingPathComponent("cloud.ply")
        assertIO { try PLYWriter.write(points: Self.samplePoints, to: url) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testReadMissingFileThrowsIO() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        assertIO { _ = try PLYReader.read(url: directory.appendingPathComponent("nope.ply")) }
    }
}
