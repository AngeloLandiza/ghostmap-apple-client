import Foundation

// MARK: - Format constants

/// Constants and byte layout of `keyframes.bin`, the append-only keyframe log ("SMKF" container,
/// version 1). The complete byte-level specification lives in `FORMAT.md`; in short:
///
/// - A 16-byte header: magic `"SMKF"`, `u16 version = 1`, `u16 headerSize = 16`, `u32 flags = 0`,
///   `u32 reserved = 0`.
/// - Then records back to back. Each record is `u32 payloadLength` followed by exactly that many
///   payload bytes. The payload is `u32 seq`, `f64 timestamp`, `16 × f32` column-major pose,
///   `f32 fx fy cx cy`, `u16 width height`, `u8 trackingState`, `u8 trackingReason`,
///   `u8 depthEncoding (0)`, `u8 confidenceEncoding (0)`, `u32 depthBytes` + LZFSE depth,
///   `u32 confidenceBytes` + LZFSE confidence, and a trailing `u32 crc32` over every payload byte
///   before it.
/// - Every integer and float is little-endian.
public enum KeyframeLogFormat {
    /// The four magic bytes at offset 0 of every log: ASCII `"SMKF"`.
    public static let magic: [UInt8] = [0x53, 0x4D, 0x4B, 0x46]
    /// The only container version this module reads and writes.
    public static let version: UInt16 = 1
    /// Size of the file header in bytes; the first record starts at this offset.
    public static let headerSize = 16

    /// Wire value of `depthEncoding` for `u16mm+lzfse`, the only depth encoding of version 1.
    static let depthEncodingLZFSE: UInt8 = 0
    /// Wire value of `confidenceEncoding` for `u8+lzfse`, the only confidence encoding of version 1.
    static let confidenceEncodingLZFSE: UInt8 = 0

    /// Size of the `u32 payloadLength` field that precedes every payload.
    static let lengthFieldSize = 4
    /// Size of the trailing `u32 crc32`.
    static let crcSize = 4

    /// Payload byte offsets of the fixed fields (see `FORMAT.md`).
    enum PayloadOffset {
        static let seq = 0
        static let timestamp = 4
        static let pose = 12
        static let fx = 76
        static let fy = 80
        static let cx = 84
        static let cy = 88
        static let width = 92
        static let height = 94
        static let trackingState = 96
        static let trackingReason = 97
        static let depthEncoding = 98
        static let confidenceEncoding = 99
        static let depthBytes = 100
        static let depthData = 104
    }

    /// Bytes from the start of the payload up to and including the `u32 depthBytes` field:
    /// 4 + 8 + 64 + 16 + 4 + 4 + 4 = 104.
    static let payloadPrefixSize = 104
    /// Smallest legal payload: the prefix, an empty depth block, the `u32 confidenceBytes` field,
    /// an empty confidence block and the CRC: 104 + 4 + 4 = 112.
    static let minimumPayloadSize = payloadPrefixSize + 4 + crcSize

    /// Largest `width × height` a record may declare: 2²⁴ = 16 777 216 pixels, far above the
    /// 256 × 192 = 49 152 LiDAR depth map. `width` and `height` are `u16`, so a crafted or foreign
    /// file can declare 65535 × 65535 ≈ 4.29 G pixels; decoding one would ask the allocator for
    /// `pixelCount × 2` bytes (8.6 GB) before the codec could report the size mismatch, which is a
    /// memory-pressure kill rather than the `.corrupt` result the format promises.
    static let maxPixelCount = 1 << 24

    /// The exact 16 header bytes written at the start of a new log.
    static var headerBytes: [UInt8] {
        var bytes = magic
        bytes.append(contentsOf: littleEndianBytes(version))
        bytes.append(contentsOf: littleEndianBytes(UInt16(headerSize)))
        bytes.append(contentsOf: littleEndianBytes(UInt32(0)))   // flags
        bytes.append(contentsOf: littleEndianBytes(UInt32(0)))   // reserved
        return bytes
    }

    /// Checks the header of a complete file image. Throws `MapError.truncatedRecord(offset: 0)` when
    /// fewer than 4 bytes exist or the magic is present but the header is shorter than
    /// `headerSize`, `MapError.invalidMagic` when the first four bytes are not `"SMKF"`,
    /// `MapError.unsupportedVersion` for any version other than `version`, and
    /// `MapError.corruptRecord(offset: 0, …)` when `headerSize` is not 16. `flags` and `reserved`
    /// are ignored.
    static func validateHeader(_ raw: UnsafeRawBufferPointer) throws {
        guard raw.count >= magic.count else {
            throw MapError.truncatedRecord(offset: 0)
        }
        for (index, byte) in magic.enumerated() where raw[index] != byte {
            throw MapError.invalidMagic
        }
        guard raw.count >= headerSize else {
            throw MapError.truncatedRecord(offset: 0)
        }
        let fileVersion = raw.u16(at: 4)
        guard fileVersion == version else {
            throw MapError.unsupportedVersion(fileVersion)
        }
        let fileHeaderSize = raw.u16(at: 6)
        guard Int(fileHeaderSize) == headerSize else {
            throw MapError.corruptRecord(offset: 0, reason: "unexpected header size \(fileHeaderSize)")
        }
    }

    /// Serializes `record` as one complete on-disk record: the `u32 payloadLength` field, the
    /// payload and its CRC. Depth and confidence are compressed with `DepthCodec`.
    ///
    /// Throws `MapError.sizeMismatch` when the depth or confidence array does not cover
    /// `record.pixelCount`, `MapError.io` when the intrinsics' width or height does not fit in 16
    /// bits, and `MapError.compressionFailed` from the codec.
    static func encodeRecord(_ record: KeyframeRecord) throws -> [UInt8] {
        let pixelCount = record.pixelCount
        guard record.depthMillimeters.count == pixelCount else {
            throw MapError.sizeMismatch(expected: pixelCount, actual: record.depthMillimeters.count)
        }
        guard record.confidence.count == pixelCount else {
            throw MapError.sizeMismatch(expected: pixelCount, actual: record.confidence.count)
        }
        let width = record.intrinsics.width
        let height = record.intrinsics.height
        guard width >= 0, width <= Int(UInt16.max), height >= 0, height <= Int(UInt16.max) else {
            throw MapError.io("keyframe \(record.seq): image size \(width)×\(height) does not fit the u16 width/height fields")
        }

        let depth = try DepthCodec.encodeDepth(record.depthMillimeters)
        let confidence = try DepthCodec.encodeConfidence(record.confidence)
        let payloadLength = minimumPayloadSize + depth.count + confidence.count

        var bytes: [UInt8] = []
        bytes.reserveCapacity(lengthFieldSize + payloadLength)
        bytes.append(contentsOf: littleEndianBytes(UInt32(payloadLength)))

        let payloadStart = bytes.count
        bytes.append(contentsOf: littleEndianBytes(record.seq))
        bytes.append(contentsOf: littleEndianBytes(record.timestamp.bitPattern))
        for value in record.pose.columnMajorArray {
            bytes.append(contentsOf: littleEndianBytes(value.bitPattern))
        }
        let intrinsics = record.intrinsics
        bytes.append(contentsOf: littleEndianBytes(intrinsics.fx.bitPattern))
        bytes.append(contentsOf: littleEndianBytes(intrinsics.fy.bitPattern))
        bytes.append(contentsOf: littleEndianBytes(intrinsics.cx.bitPattern))
        bytes.append(contentsOf: littleEndianBytes(intrinsics.cy.bitPattern))
        bytes.append(contentsOf: littleEndianBytes(UInt16(width)))
        bytes.append(contentsOf: littleEndianBytes(UInt16(height)))
        bytes.append(record.tracking.rawState)
        bytes.append(record.tracking.rawReason)
        bytes.append(depthEncodingLZFSE)
        bytes.append(confidenceEncodingLZFSE)
        bytes.append(contentsOf: littleEndianBytes(UInt32(depth.count)))
        bytes.append(contentsOf: depth)
        bytes.append(contentsOf: littleEndianBytes(UInt32(confidence.count)))
        bytes.append(contentsOf: confidence)

        let crc = CRC32.checksum(bytes[payloadStart...])
        bytes.append(contentsOf: littleEndianBytes(crc))
        return bytes
    }

    /// The bytes of `value` in little-endian order.
    @inline(__always)
    static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Array($0) }
    }
}

// MARK: - Raw buffer reads

extension UnsafeRawBufferPointer {
    /// Little-endian `UInt16` at `offset` (unaligned).
    @inline(__always)
    func u16(at offset: Int) -> UInt16 {
        UInt16(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    /// Little-endian `UInt32` at `offset` (unaligned).
    @inline(__always)
    func u32(at offset: Int) -> UInt32 {
        UInt32(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    /// Little-endian `UInt64` at `offset` (unaligned).
    @inline(__always)
    func u64(at offset: Int) -> UInt64 {
        UInt64(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    /// Little-endian IEEE 754 binary32 at `offset`.
    @inline(__always)
    func f32(at offset: Int) -> Float {
        Float(bitPattern: u32(at: offset))
    }

    /// Little-endian IEEE 754 binary64 at `offset`.
    @inline(__always)
    func f64(at offset: Int) -> Double {
        Double(bitPattern: u64(at: offset))
    }
}

// MARK: - Writer

/// Appends keyframe records to a `keyframes.bin` log.
///
/// The writer is deliberately not `Sendable`: exactly one owner (the app's serial storage queue)
/// creates it, calls `append`, `sync` and `close` on it, and never shares it. Each `append` builds
/// the complete record in memory and issues a single `write`, so a crash at any moment leaves
/// either a complete record or a partial tail at the end of the file — never interleaved garbage.
/// Reopening a log validates the header, walks the records, drops any partial or corrupt tail, and
/// continues appending after the last complete valid record.
public final class KeyframeLogWriter {
    /// Number of complete records in the file (existing ones after reopening plus appended ones).
    public private(set) var recordCount: Int
    /// Size of the file in bytes: header plus every complete record.
    public private(set) var byteCount: Int64

    /// Location of the log.
    let url: URL
    /// The open file. Module-internal (not `private`) only so tests can force write failures on it.
    let handle: FileHandle
    private var isClosed = false

    /// Opens `url` for appending.
    ///
    /// A missing or empty file is created with the 16-byte header. An existing non-empty file is
    /// read in full and validated: a bad header throws `MapError.invalidMagic`,
    /// `MapError.unsupportedVersion` or `MapError.truncatedRecord(offset: 0)`; otherwise the records
    /// are walked with full CRC and LZFSE validation, everything after the last complete valid
    /// record is truncated away, `recordCount`/`byteCount` reflect the surviving records, and the
    /// file position is at the end. File-system failures throw `MapError.io`.
    public init(url: URL) throws {
        self.url = url
        let fileManager = FileManager.default

        var existing = Data()
        if fileManager.fileExists(atPath: url.path) {
            do {
                existing = try Data(contentsOf: url)
            } catch {
                throw MapError.io("reading \(url.lastPathComponent): \(error.localizedDescription)")
            }
        } else {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw MapError.io("cannot create \(url.path)")
            }
        }

        if existing.isEmpty {
            let handle = try KeyframeLogWriter.openForWriting(url)
            do {
                try handle.write(contentsOf: KeyframeLogFormat.headerBytes)
            } catch {
                try? handle.close()
                throw MapError.io("writing header to \(url.lastPathComponent): \(error.localizedDescription)")
            }
            self.handle = handle
            self.recordCount = 0
            self.byteCount = Int64(KeyframeLogFormat.headerSize)
            return
        }

        // Validate before touching the file so a foreign file is never truncated.
        try existing.withUnsafeBytes { try KeyframeLogFormat.validateHeader($0) }
        let scan = try KeyframeLogReader.walk(existing, decodeDepth: true) { _ in }
        let validEnd = scan.validByteCount

        let handle = try KeyframeLogWriter.openForWriting(url)
        do {
            if validEnd < Int64(existing.count) {
                try handle.truncate(atOffset: UInt64(validEnd))
            }
            _ = try handle.seekToEnd()
        } catch {
            try? handle.close()
            throw MapError.io("preparing \(url.lastPathComponent) for append: \(error.localizedDescription)")
        }
        self.handle = handle
        self.recordCount = scan.recordCount
        self.byteCount = validEnd
    }

    deinit {
        if !isClosed {
            try? handle.close()
        }
    }

    /// Serializes `record` (compressing depth and confidence with `DepthCodec`) and appends it with
    /// one write. Returns the byte offset at which the record's `payloadLength` field starts, which
    /// equals `byteCount` before the call. `recordCount` and `byteCount` are updated only after the
    /// write succeeds.
    ///
    /// Throws `MapError.sizeMismatch` when the record's arrays do not cover its pixel count,
    /// `MapError.io` after `close()` or on a write failure, and codec errors.
    ///
    /// A write that fails after putting some bytes on disk would leave a partial record that every
    /// reader stops at, orphaning every record appended after it. To keep the "readable up to the
    /// last complete record" invariant, a failed write rolls the file back to `byteCount` before
    /// rethrowing; if that rollback also fails the writer latches closed, so later `append` calls
    /// throw instead of writing past a partial tail.
    @discardableResult
    public func append(_ record: KeyframeRecord) throws -> Int64 {
        guard !isClosed else { throw MapError.io("keyframe log \(url.lastPathComponent) is closed") }
        let bytes = try KeyframeLogFormat.encodeRecord(record)
        let offset = byteCount
        do {
            try handle.write(contentsOf: bytes)
        } catch {
            if !rollBackToLastCompleteRecord() {
                isClosed = true
            }
            throw MapError.io("appending keyframe \(record.seq) to \(url.lastPathComponent): \(error.localizedDescription)")
        }
        byteCount += Int64(bytes.count)
        recordCount += 1
        return offset
    }

    /// Discards everything on disk after the last complete record (`byteCount`) and repositions the
    /// file offset there, so the next `append` lands at `byteCount` exactly as the writer reports.
    /// Returns `false` when the file system refused the truncate or the seek, in which case the
    /// writer can no longer guarantee where its bytes would land.
    @discardableResult
    func rollBackToLastCompleteRecord() -> Bool {
        do {
            try handle.truncate(atOffset: UInt64(byteCount))
            try handle.seek(toOffset: UInt64(byteCount))
            return true
        } catch {
            return false
        }
    }

    /// Flushes the file to stable storage (`fsync`). No-op after `close()`.
    public func sync() throws {
        guard !isClosed else { return }
        do {
            try handle.synchronize()
        } catch {
            throw MapError.io("syncing \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Syncs and closes the file. Further `append` calls throw `MapError.io`. Calling `close()`
    /// again is a no-op.
    public func close() throws {
        guard !isClosed else { return }
        isClosed = true
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw MapError.io("closing \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func openForWriting(_ url: URL) throws -> FileHandle {
        do {
            return try FileHandle(forWritingTo: url)
        } catch {
            throw MapError.io("opening \(url.lastPathComponent) for writing: \(error.localizedDescription)")
        }
    }
}

// MARK: - Scan result

/// Outcome of walking a keyframe log.
///
/// `recordCount` complete valid records were found. A partial record at the end of the file is
/// reported in `truncatedAtOffset`; a record whose CRC or structure is wrong (or whose LZFSE
/// payload fails to decode) is reported in `corruptedAtOffset`. Both hold the byte offset of that
/// record's `payloadLength` field, and at most one of them is set because walking stops at the
/// first bad record. Everything after a bad record is ignored.
public struct KeyframeLogScan: Sendable, Equatable {
    /// The decoded records, in file order. Empty for `KeyframeLogReader.forEachRecord`.
    public var records: [KeyframeRecord]
    /// Number of complete valid records found (independent of whether `records` was filled).
    public var recordCount: Int
    /// Offset of the partial record at the end of the file, if any.
    public var truncatedAtOffset: Int64?
    /// Offset of the first corrupt record, if any.
    public var corruptedAtOffset: Int64?
    /// Total size of the file in bytes, including any bad tail.
    public var byteCount: Int64

    /// Creates a scan result; every field defaults to the empty-log value.
    public init(records: [KeyframeRecord] = [],
                recordCount: Int = 0,
                truncatedAtOffset: Int64? = nil,
                corruptedAtOffset: Int64? = nil,
                byteCount: Int64 = 0) {
        self.records = records
        self.recordCount = recordCount
        self.truncatedAtOffset = truncatedAtOffset
        self.corruptedAtOffset = corruptedAtOffset
        self.byteCount = byteCount
    }

    /// Number of bytes that hold the header and the complete valid records: the offset of the bad
    /// tail when there is one, otherwise `byteCount`.
    var validByteCount: Int64 {
        truncatedAtOffset ?? corruptedAtOffset ?? byteCount
    }
}

// MARK: - Reader

/// Reads `keyframes.bin` logs written by `KeyframeLogWriter`.
///
/// Both entry points read the whole file into memory (logs are tens of megabytes at most) and walk
/// it record by record. Walking never throws for a damaged tail: it stops at the first partial or
/// corrupt record and reports it in the returned `KeyframeLogScan`. Only an unreadable file or a
/// bad header throws (`MapError.io`, `MapError.invalidMagic`, `MapError.unsupportedVersion`,
/// `MapError.truncatedRecord(offset: 0)`).
public enum KeyframeLogReader {
    /// Reads every complete valid record. With `decodeDepth == false` the records' `depthMillimeters`
    /// and `confidence` arrays are left empty (the LZFSE blocks are not decoded), which makes a
    /// metadata-only pass cheap; the CRC is verified either way.
    public static func scan(url: URL, decodeDepth: Bool = true) throws -> KeyframeLogScan {
        let data = try readFile(url)
        var records: [KeyframeRecord] = []
        var scan = try walk(data, decodeDepth: decodeDepth) { records.append($0) }
        scan.records = records
        return scan
    }

    /// Streams every complete valid record (depth decoded) to `body` in file order and returns the
    /// scan with `records` empty. An error thrown by `body` stops the walk and propagates.
    public static func forEachRecord(url: URL, _ body: (KeyframeRecord) throws -> Void) throws -> KeyframeLogScan {
        let data = try readFile(url)
        return try walk(data, decodeDepth: true, body)
    }

    /// Loads the whole file; a read failure is `MapError.io`.
    static func readFile(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw MapError.io("reading \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Result of parsing the record that starts at one offset.
    enum Step {
        case record(KeyframeRecord, next: Int)
        case truncated
        case corrupt(String)
        case end
    }

    /// Validates the header of `data` and walks its records, handing each complete valid one to
    /// `body`. See `KeyframeLogScan` for how the tail is reported.
    static func walk(_ data: Data, decodeDepth: Bool, _ body: (KeyframeRecord) throws -> Void) throws -> KeyframeLogScan {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> KeyframeLogScan in
            try KeyframeLogFormat.validateHeader(raw)
            var scan = KeyframeLogScan(byteCount: Int64(raw.count))
            var offset = KeyframeLogFormat.headerSize
            while true {
                switch parseRecord(raw, at: offset, decodeDepth: decodeDepth) {
                case .end:
                    return scan
                case .truncated:
                    scan.truncatedAtOffset = Int64(offset)
                    return scan
                case .corrupt:
                    scan.corruptedAtOffset = Int64(offset)
                    return scan
                case .record(let record, let next):
                    try body(record)
                    scan.recordCount += 1
                    offset = next
                }
            }
        }
    }

    /// Parses the record whose `payloadLength` field starts at `offset`.
    ///
    /// - `.end` when no bytes remain.
    /// - `.truncated` when 1–3 bytes remain (a partial length field) or the declared payload runs
    ///   past the end of the file.
    /// - `.corrupt` when the payload is shorter than `minimumPayloadSize`, the CRC does not match,
    ///   the inner `depthBytes`/`confidenceBytes` lengths do not add up to the payload length, an
    ///   encoding byte is unknown, `width × height` exceeds `maxPixelCount`, or (with `decodeDepth`)
    ///   an LZFSE block fails to decode.
    static func parseRecord(_ raw: UnsafeRawBufferPointer, at offset: Int, decodeDepth: Bool) -> Step {
        typealias F = KeyframeLogFormat
        let remaining = raw.count - offset
        if remaining == 0 { return .end }
        if remaining < F.lengthFieldSize { return .truncated }

        let payloadLength = Int(raw.u32(at: offset))
        let payloadStart = offset + F.lengthFieldSize
        guard payloadLength <= raw.count - payloadStart else { return .truncated }
        guard payloadLength >= F.minimumPayloadSize else {
            return .corrupt("payload length \(payloadLength) is below the minimum \(F.minimumPayloadSize)")
        }
        let payloadEnd = payloadStart + payloadLength
        let crcOffset = payloadEnd - F.crcSize
        let storedCRC = raw.u32(at: crcOffset)
        let computedCRC = CRC32.checksum(UnsafeRawBufferPointer(rebasing: raw[payloadStart ..< crcOffset]))
        guard storedCRC == computedCRC else {
            return .corrupt("crc mismatch: stored \(storedCRC), computed \(computedCRC)")
        }

        let depthBytes = Int(raw.u32(at: payloadStart + F.PayloadOffset.depthBytes))
        let depthStart = payloadStart + F.PayloadOffset.depthData
        // depth block + confidenceBytes field must fit before the CRC.
        guard depthBytes <= crcOffset - depthStart - 4 else {
            return .corrupt("depthBytes \(depthBytes) exceeds the payload")
        }
        let confidenceLengthOffset = depthStart + depthBytes
        let confidenceBytes = Int(raw.u32(at: confidenceLengthOffset))
        let confidenceStart = confidenceLengthOffset + 4
        guard confidenceStart + confidenceBytes == crcOffset else {
            return .corrupt("depthBytes \(depthBytes) + confidenceBytes \(confidenceBytes) do not match payload length \(payloadLength)")
        }

        let depthEncoding = raw[payloadStart + F.PayloadOffset.depthEncoding]
        let confidenceEncoding = raw[payloadStart + F.PayloadOffset.confidenceEncoding]
        guard depthEncoding == F.depthEncodingLZFSE else {
            return .corrupt("unsupported depth encoding \(depthEncoding)")
        }
        guard confidenceEncoding == F.confidenceEncodingLZFSE else {
            return .corrupt("unsupported confidence encoding \(confidenceEncoding)")
        }

        var poseValues: [Float] = []
        poseValues.reserveCapacity(16)
        for i in 0..<16 {
            poseValues.append(raw.f32(at: payloadStart + F.PayloadOffset.pose + i * 4))
        }
        guard let pose = Pose(columnMajorArray: poseValues) else {
            return .corrupt("pose has \(poseValues.count) entries")
        }
        let width = Int(raw.u16(at: payloadStart + F.PayloadOffset.width))
        let height = Int(raw.u16(at: payloadStart + F.PayloadOffset.height))
        // Both are u16, so the product cannot overflow Int, but it can be absurd; reject it before
        // any decode buffer is sized from it.
        guard width * height <= F.maxPixelCount else {
            return .corrupt("image size \(width)×\(height) exceeds the \(F.maxPixelCount) pixel limit")
        }
        let intrinsics = Intrinsics(
            fx: raw.f32(at: payloadStart + F.PayloadOffset.fx),
            fy: raw.f32(at: payloadStart + F.PayloadOffset.fy),
            cx: raw.f32(at: payloadStart + F.PayloadOffset.cx),
            cy: raw.f32(at: payloadStart + F.PayloadOffset.cy),
            width: width,
            height: height
        )
        let tracking = TrackingState(
            rawState: raw[payloadStart + F.PayloadOffset.trackingState],
            rawReason: raw[payloadStart + F.PayloadOffset.trackingReason]
        )

        var depthMillimeters: [UInt16] = []
        var confidence: [UInt8] = []
        if decodeDepth {
            guard let base = raw.baseAddress else { return .corrupt("empty buffer") }
            let pixelCount = width * height
            do {
                depthMillimeters = try DepthCodec.decodeDepth(
                    Data(bytes: base + depthStart, count: depthBytes), pixelCount: pixelCount)
                confidence = try DepthCodec.decodeConfidence(
                    Data(bytes: base + confidenceStart, count: confidenceBytes), pixelCount: pixelCount)
            } catch {
                return .corrupt("lzfse decode failed: \(error)")
            }
        }

        let record = KeyframeRecord(
            seq: raw.u32(at: payloadStart + F.PayloadOffset.seq),
            timestamp: raw.f64(at: payloadStart + F.PayloadOffset.timestamp),
            pose: pose,
            intrinsics: intrinsics,
            tracking: tracking,
            depthMillimeters: depthMillimeters,
            confidence: confidence
        )
        return .record(record, next: payloadEnd)
    }
}
