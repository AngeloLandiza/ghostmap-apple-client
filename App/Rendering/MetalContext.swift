import CoreVideo
import Metal
import MetalKit
import os

/// Typed rendering errors.
enum RenderError: Error, Sendable {
    case noDevice
    case noCommandQueue
    case noLibrary
    case textureCacheCreationFailed(Int32)
    case functionNotFound(String)
    case pipelineCreationFailed(String)
    case bufferAllocationFailed(bytes: Int)
    case offscreenTargetFailed
    case imageCreationFailed
}

/// The Metal device, command queue, shader library and CVMetalTextureCache shared by every renderer.
///
/// Thread-safety invariant: `MTLDevice`, `MTLCommandQueue`, `MTLLibrary` and `CVMetalTextureCache`
/// are documented by Apple as safe to use from multiple threads, and this class only holds immutable
/// references to them, so it is safe to mark `@unchecked Sendable`.
final class MetalContext: @unchecked Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary
    let textureCache: CVMetalTextureCache

    static let logger = Logger(subsystem: "tech.alandiza.roommapper", category: "render")

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RenderError.noCommandQueue }
        guard let library = device.makeDefaultLibrary() else { throw RenderError.noLibrary }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw RenderError.textureCacheCreationFailed(status) }
        self.device = device
        self.commandQueue = queue
        self.library = library
        self.textureCache = cache
        queue.label = "tech.alandiza.roommapper.render"
        MetalContext.logger.info("Metal device: \(device.name, privacy: .public)")
    }

    func makeFunction(_ name: String) throws -> MTLFunction {
        guard let f = library.makeFunction(name: name) else { throw RenderError.functionNotFound(name) }
        return f
    }

    /// Wraps one plane of a pixel buffer as a Metal texture through the texture cache (no copy).
    /// The returned `CVMetalTexture` must be retained for as long as the `MTLTexture` is in use.
    func makeTexture(from pixelBuffer: CVPixelBuffer, plane: Int, pixelFormat: MTLPixelFormat) -> (texture: MTLTexture, ref: CVMetalTexture)? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var ref: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, pixelFormat, width, height, plane, &ref)
        guard status == kCVReturnSuccess, let ref, let texture = CVMetalTextureGetTexture(ref) else {
            MetalContext.logger.error("CVMetalTextureCacheCreateTextureFromImage failed: \(status)")
            return nil
        }
        return (texture, ref)
    }

    /// Flushes textures that are no longer referenced (call once per frame).
    func flushTextureCache() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}
