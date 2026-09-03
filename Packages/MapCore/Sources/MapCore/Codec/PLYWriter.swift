import Foundation

/// Writes `cloud.ply`: a binary little-endian PLY with one `vertex` element whose properties are
/// `float x`, `float y`, `float z`, `uchar red`, `uchar green`, `uchar blue`. Every vertex record is
/// exactly 15 bytes (three little-endian IEEE 754 binary32 values followed by three bytes) with no
/// padding; `PackedPoint.a` is not stored. The manifest names this encoding
/// `ply-binary-little-endian-xyzrgb`.
public enum PLYWriter {
    /// Bytes per vertex record: 3 × float32 + 3 × uchar.
    internal static let vertexByteSize = 15

    /// Vertices per `FileHandle` write while streaming (65 536 × 15 = 983 040 bytes per chunk).
    internal static let chunkVertexCount = 65_536

    /// The exact header for `pointCount` vertices:
    ///
    ///     ply
    ///     format binary_little_endian 1.0
    ///     comment <text>            (one line per entry of `comments`, newlines stripped)
    ///     element vertex <pointCount>
    ///     property float x
    ///     property float y
    ///     property float z
    ///     property uchar red
    ///     property uchar green
    ///     property uchar blue
    ///     end_header
    ///
    /// Each line, including `end_header`, ends with a single `\n`.
    public static func header(pointCount: Int, comments: [String] = []) -> String {
        var text = "ply\nformat binary_little_endian 1.0\n"
        for comment in comments {
            text += "comment \(sanitized(comment))\n"
        }
        text += "element vertex \(pointCount)\n"
        text += "property float x\nproperty float y\nproperty float z\n"
        text += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        text += "end_header\n"
        return text
    }

    /// Removes every `\n` and `\r` so a comment can never terminate the header early.
    internal static func sanitized(_ comment: String) -> String {
        String(String.UnicodeScalarView(comment.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }))
    }

    /// The complete file for `points`: `header(pointCount:comments:)` as UTF-8 followed by
    /// `points.count` 15-byte vertex records.
    public static func encode(points: [PackedPoint], comments: [String] = []) -> Data {
        let head = header(pointCount: points.count, comments: comments)
        var data = Data(capacity: head.utf8.count + points.count * vertexByteSize)
        data.append(contentsOf: head.utf8)
        guard !points.isEmpty else { return data }
        let bodySize = points.count * vertexByteSize
        let body = [UInt8](unsafeUninitializedCapacity: bodySize) { buffer, initializedCount in
            initializedCount = 0
            guard let base = buffer.baseAddress else { return }
            points.withUnsafeBufferPointer { encodeVertices($0, into: UnsafeMutableRawPointer(base)) }
            initializedCount = bodySize
        }
        data.append(contentsOf: body)
        return data
    }

    /// Stores `points.count` consecutive 15-byte records at `destination`, which must have room for
    /// `points.count * vertexByteSize` bytes. Floats are written as little-endian bit patterns.
    internal static func encodeVertices(_ points: UnsafeBufferPointer<PackedPoint>, into destination: UnsafeMutableRawPointer) {
        var offset = 0
        for point in points {
            destination.storeBytes(of: point.x.bitPattern.littleEndian, toByteOffset: offset, as: UInt32.self)
            destination.storeBytes(of: point.y.bitPattern.littleEndian, toByteOffset: offset + 4, as: UInt32.self)
            destination.storeBytes(of: point.z.bitPattern.littleEndian, toByteOffset: offset + 8, as: UInt32.self)
            destination.storeBytes(of: point.r, toByteOffset: offset + 12, as: UInt8.self)
            destination.storeBytes(of: point.g, toByteOffset: offset + 13, as: UInt8.self)
            destination.storeBytes(of: point.b, toByteOffset: offset + 14, as: UInt8.self)
            offset += vertexByteSize
        }
    }

    /// Streams `points` to `url` as a PLY file, atomically: the header and 65 536-vertex chunks are
    /// written through a `FileHandle` into a hidden temporary file in the same directory (a single
    /// reusable chunk buffer, no per-point allocation), the file is fsynced, and it then replaces any
    /// existing file at `url` in one step (`FileManager.replaceItemAt`, or a rename when `url` does
    /// not exist yet). Readers therefore never observe a partially written `cloud.ply`. Failures are
    /// reported as `MapError.io` and leave no temporary file behind.
    public static func write(points: UnsafeBufferPointer<PackedPoint>, to url: URL, comments: [String] = []) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw MapError.io("cannot create temporary file \(temporaryURL.path)")
        }
        var temporaryFileExists = true
        defer {
            if temporaryFileExists { try? fileManager.removeItem(at: temporaryURL) }
        }

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try stream(points: points, comments: comments, to: handle)
                try handle.synchronize()
            } catch {
                try? handle.close()
                throw error
            }
            try handle.close()
        } catch {
            throw MapError.io("writing \(url.lastPathComponent): \(error.localizedDescription)")
        }

        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL, backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
            temporaryFileExists = false
        } catch {
            throw MapError.io("replacing \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Array convenience for `write(points:to:comments:)`.
    public static func write(points: [PackedPoint], to url: URL, comments: [String] = []) throws {
        try points.withUnsafeBufferPointer { try write(points: $0, to: url, comments: comments) }
    }

    /// Writes the header and then the vertex records in `chunkVertexCount` batches through `handle`,
    /// reusing one chunk buffer for every batch.
    internal static func stream(points: UnsafeBufferPointer<PackedPoint>, comments: [String], to handle: FileHandle) throws {
        try handle.write(contentsOf: Data(header(pointCount: points.count, comments: comments).utf8))
        guard !points.isEmpty else { return }
        var chunk = [UInt8](repeating: 0, count: chunkVertexCount * vertexByteSize)
        var start = 0
        while start < points.count {
            let count = min(chunkVertexCount, points.count - start)
            let batch = UnsafeBufferPointer(rebasing: points[start ..< start + count])
            try chunk.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { throw MapError.io("chunk buffer unavailable") }
                encodeVertices(batch, into: base)
                let used = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(raw)[0 ..< count * vertexByteSize])
                try handle.write(contentsOf: used)
            }
            start += count
        }
    }
}

/// Reads the PLY files `PLYWriter` produces (binary little-endian, exactly the six `vertex`
/// properties `float x y z` and `uchar red green blue`, any number of `comment` lines).
public enum PLYReader {
    /// The vertex properties, in the only order the reader accepts.
    internal static let expectedProperties: [(type: String, name: String)] = [
        ("float", "x"), ("float", "y"), ("float", "z"),
        ("uchar", "red"), ("uchar", "green"), ("uchar", "blue"),
    ]

    /// Parses a complete PLY file held in memory. The header is read line by line up to
    /// `end_header\n` (a trailing `\r` on a line is tolerated); it must start with `ply`, declare
    /// `format binary_little_endian 1.0`, contain exactly one `element vertex N` and the six
    /// properties in order, and may contain `comment` lines anywhere. Anything else throws
    /// `MapError.invalidPLY(reason)`, as does a body shorter than `N × 15` bytes; bytes after the
    /// last record are ignored. Colors are read with alpha 255. `data` may be a slice.
    public static func read(data: Data) throws -> PointCloud {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> PointCloud in
            let (vertexCount, bodyStart) = try parseHeader(raw)
            let (bodyBytes, overflow) = vertexCount.multipliedReportingOverflow(by: PLYWriter.vertexByteSize)
            guard !overflow else {
                throw MapError.invalidPLY("vertex count \(vertexCount) is too large")
            }
            let available = raw.count - bodyStart
            guard available >= bodyBytes else {
                throw MapError.invalidPLY("truncated body: expected \(bodyBytes) bytes for \(vertexCount) vertices, found \(available)")
            }
            var points = [PackedPoint]()
            points.reserveCapacity(vertexCount)
            var offset = bodyStart
            for _ in 0..<vertexCount {
                let x = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                let y = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
                let z = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self)))
                let color = PackedPoint.packColor(r: raw[offset + 12], g: raw[offset + 13], b: raw[offset + 14])
                points.append(PackedPoint(x: x, y: y, z: z, color: color))
                offset += PLYWriter.vertexByteSize
            }
            return PointCloud(points: points)
        }
    }

    /// Loads `url` (memory-mapped when safe) and delegates to `read(data:)`.
    /// An unreadable file throws `MapError.io`.
    public static func read(url: URL) throws -> PointCloud {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw MapError.io("reading \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return try read(data: data)
    }

    /// Validates the header and returns the vertex count and the byte offset of the first record.
    internal static func parseHeader(_ raw: UnsafeRawBufferPointer) throws -> (vertexCount: Int, bodyStart: Int) {
        var lineStart = 0
        var lineNumber = 0
        var sawFormat = false
        var vertexCount: Int?
        var propertyIndex = 0

        while true {
            guard let newline = raw[lineStart...].firstIndex(of: 0x0A) else {
                throw MapError.invalidPLY(lineNumber == 0 ? "missing ply magic" : "missing end_header")
            }
            var lineEnd = newline
            if lineEnd > lineStart, raw[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            let line = String(decoding: raw[lineStart ..< lineEnd], as: UTF8.self)
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            lineStart = newline + 1
            lineNumber += 1

            if lineNumber == 1 {
                guard tokens == ["ply"] else { throw MapError.invalidPLY("missing ply magic") }
                continue
            }
            guard let keyword = tokens.first else {
                throw MapError.invalidPLY("empty header line \(lineNumber)")
            }
            switch keyword {
            case "comment":
                continue
            case "format":
                guard !sawFormat else { throw MapError.invalidPLY("duplicate format line") }
                guard tokens == ["format", "binary_little_endian", "1.0"] else {
                    throw MapError.invalidPLY("unsupported format: \(line)")
                }
                sawFormat = true
            case "element":
                guard sawFormat else { throw MapError.invalidPLY("element before format") }
                guard vertexCount == nil else { throw MapError.invalidPLY("only one element (vertex) is supported: \(line)") }
                guard tokens.count == 3, tokens[1] == "vertex", let count = Int(tokens[2]), count >= 0 else {
                    throw MapError.invalidPLY("expected 'element vertex N': \(line)")
                }
                vertexCount = count
            case "property":
                guard vertexCount != nil else { throw MapError.invalidPLY("property before element vertex") }
                guard propertyIndex < expectedProperties.count else {
                    throw MapError.invalidPLY("unexpected extra property: \(line)")
                }
                let expected = expectedProperties[propertyIndex]
                guard tokens.count == 3, tokens[1] == expected.type, tokens[2] == expected.name else {
                    throw MapError.invalidPLY("expected 'property \(expected.type) \(expected.name)', found: \(line)")
                }
                propertyIndex += 1
            case "end_header":
                guard tokens == ["end_header"] else { throw MapError.invalidPLY("malformed end_header line") }
                guard sawFormat else { throw MapError.invalidPLY("missing format line") }
                guard let count = vertexCount else { throw MapError.invalidPLY("missing element vertex") }
                guard propertyIndex == expectedProperties.count else {
                    throw MapError.invalidPLY("expected \(expectedProperties.count) vertex properties, found \(propertyIndex)")
                }
                return (count, lineStart)
            default:
                throw MapError.invalidPLY("unexpected header line: \(line)")
            }
        }
    }
}
