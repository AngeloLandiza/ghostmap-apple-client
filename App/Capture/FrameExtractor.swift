import ARKit
import CoreVideo
import MapCore
import simd

/// Everything copied out of an `ARFrame` for one keyframe. Holds no ARKit objects.
struct KeyframeSnapshot: Sendable {
    let timestamp: TimeInterval
    /// `ARCamera.transform` (world_from_camera).
    let cameraTransform: simd_float4x4
    /// Intrinsics scaled to the depth map resolution.
    let intrinsics: Intrinsics
    let tracking: TrackingState
    let width: Int
    let height: Int
    /// Depth in meters, row-major `width × height`.
    let depthMeters: [Float]
    /// ARKit confidence 0/1/2, row-major.
    let confidence: [UInt8]
    /// Luma and chroma sampled (nearest) at each depth pixel; empty when the image format is unexpected.
    let luma: [UInt8]
    let chromaCb: [UInt8]
    let chromaCr: [UInt8]

    var hasColor: Bool { luma.count == width * height }
}

/// Copies the parts of an `ARFrame` a keyframe needs into plain Swift arrays. Runs on the ARKit
/// delegate thread and costs well under a millisecond (≈ 0.25 MB of depth/confidence plus 49 152
/// nearest-neighbour color samples); it never retains the frame.
enum FrameExtractor {
    static func snapshot(from frame: ARFrame, intrinsics: Intrinsics, tracking: TrackingState) -> KeyframeSnapshot? {
        guard let sceneDepth = frame.sceneDepth, let confidenceMap = sceneDepth.confidenceMap else { return nil }
        let depthMap = sceneDepth.depthMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width == intrinsics.width, height == intrinsics.height,
              CVPixelBufferGetWidth(confidenceMap) == width, CVPixelBufferGetHeight(confidenceMap) == height,
              CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidenceMap) == kCVPixelFormatType_OneComponent8 else {
            return nil
        }
        let count = width * height

        // Depth (Float32) — row-wise copy to honor bytesPerRow padding.
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        let depth = [Float](unsafeUninitializedCapacity: count) { dst, initialized in
            initialized = 0
            guard let base = CVPixelBufferGetBaseAddress(depthMap), let out = dst.baseAddress else { return }
            let stride = CVPixelBufferGetBytesPerRow(depthMap)
            for row in 0..<height {
                let src = base.advanced(by: row * stride).assumingMemoryBound(to: Float.self)
                out.advanced(by: row * width).update(from: src, count: width)
            }
            initialized = count
        }
        CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        guard depth.count == count else { return nil }

        // Confidence (UInt8).
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        let confidence = [UInt8](unsafeUninitializedCapacity: count) { dst, initialized in
            initialized = 0
            guard let base = CVPixelBufferGetBaseAddress(confidenceMap), let out = dst.baseAddress else { return }
            let stride = CVPixelBufferGetBytesPerRow(confidenceMap)
            for row in 0..<height {
                let src = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                out.advanced(by: row * width).update(from: src, count: width)
            }
            initialized = count
        }
        CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
        guard confidence.count == count else { return nil }

        // Color: nearest-neighbour samples of the bi-planar YCbCr image at each depth pixel center.
        var luma: [UInt8] = []
        var cb: [UInt8] = []
        var cr: [UInt8] = []
        let image = frame.capturedImage
        let format = CVPixelBufferGetPixelFormatType(image)
        if (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
           CVPixelBufferGetPlaneCount(image) == 2 {
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let iw = CVPixelBufferGetWidthOfPlane(image, 0)
            let ih = CVPixelBufferGetHeightOfPlane(image, 0)
            let cw = CVPixelBufferGetWidthOfPlane(image, 1)
            let ch = CVPixelBufferGetHeightOfPlane(image, 1)
            if let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0), let cBase = CVPixelBufferGetBaseAddressOfPlane(image, 1), iw > 0, ih > 0, cw > 0, ch > 0 {
                let yStride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
                let cStride = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
                let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
                let cPtr = cBase.assumingMemoryBound(to: UInt8.self)
                let sx = Float(iw) / Float(width)
                let sy = Float(ih) / Float(height)
                luma = [UInt8](repeating: 0, count: count)
                cb = [UInt8](repeating: 0, count: count)
                cr = [UInt8](repeating: 0, count: count)
                luma.withUnsafeMutableBufferPointer { lp in
                    cb.withUnsafeMutableBufferPointer { cbp in
                        cr.withUnsafeMutableBufferPointer { crp in
                            var i = 0
                            for v in 0..<height {
                                let iy = min(ih - 1, Int((Float(v) + 0.5) * sy))
                                let cy = min(ch - 1, iy / 2)
                                let yRow = yPtr.advanced(by: iy * yStride)
                                let cRow = cPtr.advanced(by: cy * cStride)
                                for u in 0..<width {
                                    let ix = min(iw - 1, Int((Float(u) + 0.5) * sx))
                                    let cx = min(cw - 1, ix / 2)
                                    lp[i] = yRow[ix]
                                    cbp[i] = cRow[cx * 2]
                                    crp[i] = cRow[cx * 2 + 1]
                                    i += 1
                                }
                            }
                        }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
        }

        return KeyframeSnapshot(
            timestamp: frame.timestamp,
            cameraTransform: frame.camera.transform,
            intrinsics: intrinsics,
            tracking: tracking,
            width: width,
            height: height,
            depthMeters: depth,
            confidence: confidence,
            luma: luma,
            chromaCb: cb,
            chromaCr: cr)
    }
}
