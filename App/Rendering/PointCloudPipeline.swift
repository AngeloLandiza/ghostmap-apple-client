import Metal
import MetalKit

/// All render pipeline and depth-stencil states used by the renderers, built once per Metal view format.
final class PointCloudPipeline: @unchecked Sendable {
    // Invariant: pipeline and depth-stencil state objects are immutable and thread-safe per Apple's docs.
    let cameraQuad: MTLRenderPipelineState
    let livePoints: MTLRenderPipelineState
    let cloudPoints: MTLRenderPipelineState
    let lines: MTLRenderPipelineState
    let depthWrite: MTLDepthStencilState
    let depthReadOnly: MTLDepthStencilState
    let depthDisabled: MTLDepthStencilState
    let colorFormat: MTLPixelFormat
    let depthFormat: MTLPixelFormat

    init(context: MetalContext, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat, sampleCount: Int = 1) throws {
        self.colorFormat = colorFormat
        self.depthFormat = depthFormat

        func make(_ label: String, vertex: String, fragment: String, blending: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = try context.makeFunction(vertex)
            d.fragmentFunction = try context.makeFunction(fragment)
            d.rasterSampleCount = sampleCount
            d.depthAttachmentPixelFormat = depthFormat
            guard let ca = d.colorAttachments[0] else { throw RenderError.pipelineCreationFailed(label) }
            ca.pixelFormat = colorFormat
            ca.isBlendingEnabled = blending
            if blending {
                ca.rgbBlendOperation = .add
                ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = .sourceAlpha
                ca.sourceAlphaBlendFactor = .one
                ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do {
                return try context.device.makeRenderPipelineState(descriptor: d)
            } catch {
                throw RenderError.pipelineCreationFailed("\(label): \(error)")
            }
        }

        cameraQuad = try make("CameraQuad", vertex: "rm_camera_vertex", fragment: "rm_camera_fragment", blending: false)
        livePoints = try make("LivePoints", vertex: "rm_live_point_vertex", fragment: "rm_point_fragment", blending: true)
        cloudPoints = try make("CloudPoints", vertex: "rm_cloud_vertex", fragment: "rm_point_fragment", blending: true)
        lines = try make("Lines", vertex: "rm_line_vertex", fragment: "rm_line_fragment", blending: true)

        func depthState(_ label: String, compare: MTLCompareFunction, write: Bool) throws -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.label = label
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            guard let s = context.device.makeDepthStencilState(descriptor: d) else { throw RenderError.pipelineCreationFailed(label) }
            return s
        }
        depthWrite = try depthState("DepthWrite", compare: .less, write: true)
        depthReadOnly = try depthState("DepthReadOnly", compare: .less, write: false)
        depthDisabled = try depthState("DepthDisabled", compare: .always, write: false)
    }
}
