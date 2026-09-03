import Compression
import Foundation

/// Depth and confidence codec for keyframe payloads: depth in meters is quantized to unsigned
/// 16-bit millimeters and confidence is one byte per pixel; both are compressed with LZFSE through
/// Apple's Compression framework (manifest encodings `u16mm+lzfse` and `u8+lzfse`).
///
/// On-disk byte order is little-endian regardless of the host: `encodeDepth` serializes each
/// millimeter value as two little-endian bytes before compression and `decodeDepth` reads them back
/// as little-endian, so the payload is identical on every platform (all Apple platforms happen to be
/// little-endian, which makes the conversion a no-op there).
public enum DepthCodec {
    /// Extra destination capacity handed to the LZFSE encoder on top of the source size. LZFSE stores
    /// incompressible input as raw blocks with a small fixed overhead (about 1.1 KB per 100 KB), so
    /// `count + encodeSlack` always fits the worst case for keyframe-sized inputs.
    internal static let encodeSlack = 4096

    // MARK: Quantization

    /// Quantizes depth in meters to millimeters: `round(m * 1000)` clamped to `1...65535`.
    /// Non-finite or non-positive input maps to `0`, the "no depth" value; a real positive depth never
    /// becomes `0` (anything below 0.5 mm rounds up to 1 mm) and anything above 65.535 m saturates.
    public static func quantize(depthMeters: [Float]) -> [UInt16] {
        depthMeters.withUnsafeBufferPointer { quantize(depthMeters: $0) }
    }

    /// Buffer variant of `quantize(depthMeters:)` with identical semantics, for callers holding a
    /// depth map in unmanaged memory.
    public static func quantize(depthMeters: UnsafeBufferPointer<Float>) -> [UInt16] {
        var millimeters = [UInt16](repeating: 0, count: depthMeters.count)
        for i in 0..<depthMeters.count {
            millimeters[i] = quantizeOne(depthMeters[i])
        }
        return millimeters
    }

    /// Quantizes one sample. Non-finite / non-positive → 0; otherwise schoolbook-rounded millimeters
    /// clamped to `1...65535`. The `>= 65535` test is done in `Float` so that huge inputs (whose
    /// `meters * 1000` overflows to `+inf`) saturate instead of trapping in the `Int` conversion.
    @inline(__always)
    internal static func quantizeOne(_ meters: Float) -> UInt16 {
        guard meters.isFinite, meters > 0 else { return 0 }
        let millimeters = (meters * 1000).rounded()
        if millimeters >= 65535 { return 65535 }
        return UInt16(max(1, Int(millimeters)))
    }

    /// Converts millimeters back to meters (`Float(mm) / 1000`); `0` stays `0`.
    public static func dequantize(_ millimeters: [UInt16]) -> [Float] {
        millimeters.map { Float($0) / 1000 }
    }

    // MARK: LZFSE

    /// Compresses `bytes` with LZFSE. Empty input yields empty `Data` without touching the encoder.
    /// Throws `MapError.compressionFailed` if the encoder produces no output.
    public static func compress(_ bytes: UnsafeRawBufferPointer) throws -> Data {
        guard bytes.count > 0, let source = bytes.baseAddress else { return Data() }
        let capacity = bytes.count + encodeSlack
        let encoded = try [UInt8](unsafeUninitializedCapacity: capacity) { destination, initializedCount in
            initializedCount = 0
            guard let target = destination.baseAddress else { throw MapError.compressionFailed }
            let written = compression_encode_buffer(
                target, capacity,
                source.assumingMemoryBound(to: UInt8.self), bytes.count,
                nil, COMPRESSION_LZFSE
            )
            guard written > 0 else { throw MapError.compressionFailed }
            initializedCount = written
        }
        return Data(encoded)
    }

    /// Decompresses an LZFSE payload that must decode to exactly `expectedByteCount` bytes.
    ///
    /// The decoder is given one byte of slack beyond `expectedByteCount`, so a stream that is longer
    /// than expected is detected (reported as `actual: expectedByteCount + 1`) instead of being
    /// silently truncated; a shorter or corrupt stream reports the number of bytes actually decoded
    /// (`0` for garbage). `expectedByteCount == 0` with empty `data` yields empty `Data`; with
    /// non-empty `data` it throws with `actual` set to the payload size. A negative
    /// `expectedByteCount`, `Int.max` (whose slack byte would overflow), or empty `data` with a
    /// positive expectation, throws with `actual: 0`.
    /// Every failure is `MapError.decompressionFailed(expected:actual:)`.
    public static func decompress(_ data: Data, expectedByteCount: Int) throws -> Data {
        if expectedByteCount == 0 {
            if data.isEmpty { return Data() }
            throw MapError.decompressionFailed(expected: 0, actual: data.count)
        }
        guard expectedByteCount > 0, expectedByteCount < Int.max, !data.isEmpty else {
            throw MapError.decompressionFailed(expected: expectedByteCount, actual: 0)
        }
        let capacity = expectedByteCount + 1
        let decoded = try [UInt8](unsafeUninitializedCapacity: capacity) { destination, initializedCount in
            initializedCount = 0
            guard let target = destination.baseAddress else {
                throw MapError.decompressionFailed(expected: expectedByteCount, actual: 0)
            }
            let produced = data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let sourceBase = source.baseAddress else { return 0 }
                return compression_decode_buffer(
                    target, capacity,
                    sourceBase.assumingMemoryBound(to: UInt8.self), source.count,
                    nil, COMPRESSION_LZFSE
                )
            }
            guard produced == expectedByteCount else {
                throw MapError.decompressionFailed(expected: expectedByteCount, actual: produced)
            }
            initializedCount = produced
        }
        return Data(decoded)
    }

    // MARK: Depth

    /// Serializes millimeter depth as little-endian `UInt16` bytes and compresses them with LZFSE.
    /// Empty input yields empty `Data`.
    public static func encodeDepth(_ millimeters: [UInt16]) throws -> Data {
        let littleEndian = millimeters.map { $0.littleEndian }
        return try littleEndian.withUnsafeBytes { try compress($0) }
    }

    /// Inverse of `encodeDepth`: decompresses `data` to exactly `pixelCount * 2` bytes and rebuilds
    /// the millimeter values from little-endian pairs. Throws `MapError.decompressionFailed` when the
    /// payload does not decode to that size (wrong `pixelCount`, garbage, or a negative / overflowing
    /// `pixelCount`, in which case `expected` carries the offending pixel count).
    public static func decodeDepth(_ data: Data, pixelCount: Int) throws -> [UInt16] {
        guard pixelCount >= 0, pixelCount <= Int.max / 2 else {
            throw MapError.decompressionFailed(expected: pixelCount, actual: 0)
        }
        let raw = try decompress(data, expectedByteCount: pixelCount * 2)
        var millimeters = [UInt16](repeating: 0, count: pixelCount)
        raw.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            for i in 0..<pixelCount {
                millimeters[i] = UInt16(littleEndian: source.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
            }
        }
        return millimeters
    }

    // MARK: Confidence

    /// Compresses one confidence byte per pixel (0 low, 1 medium, 2 high) with LZFSE.
    /// Empty input yields empty `Data`.
    public static func encodeConfidence(_ confidence: [UInt8]) throws -> Data {
        try confidence.withUnsafeBytes { try compress($0) }
    }

    /// Inverse of `encodeConfidence`: decompresses `data` to exactly `pixelCount` bytes. Throws
    /// `MapError.decompressionFailed` on any size mismatch or a negative `pixelCount`.
    public static func decodeConfidence(_ data: Data, pixelCount: Int) throws -> [UInt8] {
        guard pixelCount >= 0 else {
            throw MapError.decompressionFailed(expected: pixelCount, actual: 0)
        }
        let raw = try decompress(data, expectedByteCount: pixelCount)
        return [UInt8](raw)
    }
}
