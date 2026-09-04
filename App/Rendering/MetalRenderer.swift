import MapCore
import Metal
import MetalKit
import simd

/// Main capture view renderer (60 fps): camera feed, the current frame's depth as colored points, and
/// the accumulated global cloud (strided to ≤ 1 M points).
@MainActor
final class MetalRenderer: NSObject, MTKViewDelegate {
    static let uniformSlotBytes = 4096
    static let cloudUniformOffset = 512
    /// Party peers get one 256-byte uniform block each, after the local blocks.
    static let peerUniformOffset = 1024
    static let peerUniformStride = 256

    private let context: MetalContext
    private let pipeline: PointCloudPipeline
    private let controller: ARSessionController
    private let pointBuffer: SharedPointBuffer
    let clock: RenderClock
    var settings: CaptureSettings
    var livePointSizePx: Float = 9
    var cloudPointSizePx: Float = 5
    var cloudAlpha: Float = 0.35
    var maxCloudPoints = 1_000_000

    // MARK: Party peers

    /// The other phones in the party, drawn small and translucent in their own colours.
    var peers: PeerCloudStore?
    /// `world_from_origin`: peers stream poses and points in the party's origin frame, so their
    /// clouds are lifted into this phone's ARKit world frame before drawing. Identity while this
    /// phone has not seen the marker, which is also when the strip warns that peers may not line up.
    var peerOriginToWorld = matrix_identity_float4x4
    var peerPointSizePx: Float = 3
    var peerAlpha: Float = 0.7
    var maxPeerPoints = 150_000

    private let inflight = DispatchSemaphore(value: 3)
    private let uniformRing: [MTLBuffer]
    private var ringIndex = 0
    private var lastDraw: ContinuousClock.Instant?

    init(context: MetalContext, pipeline: PointCloudPipeline, controller: ARSessionController,
         pointBuffer: SharedPointBuffer, clock: RenderClock, settings: CaptureSettings) throws {
        self.context = context
        self.pipeline = pipeline
        self.controller = controller
        self.pointBuffer = pointBuffer
        self.clock = clock
        self.settings = settings
        var ring: [MTLBuffer] = []
        for i in 0..<3 {
            guard let b = context.device.makeBuffer(length: MetalRenderer.uniformSlotBytes, options: .storageModeShared) else {
                throw RenderError.bufferAllocationFailed(bytes: MetalRenderer.uniformSlotBytes)
            }
            b.label = "MainUniforms.\(i)"
            ring.append(b)
        }
        uniformRing = ring
        super.init()
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { controller.viewportSize = size }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(in: view) }
    }

    private func drawFrame(in view: MTKView) {
        let start = ContinuousClock.now
        if let last = lastDraw {
            let d = start - last
            clock.recordInterval(seconds: Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
        lastDraw = start
        if controller.viewportSize == .zero { controller.viewportSize = view.drawableSize }

        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor else { return }
        guard inflight.wait(timeout: .now() + .milliseconds(50)) == .success else { return }
        clock.frameScheduled()
        guard let cb = context.commandQueue.makeCommandBuffer() else {
            inflight.signal()
            clock.frameCompleted()
            return
        }
        cb.label = "MainFrame"
        let sem = inflight
        let clk = clock
        cb.addCompletedHandler { _ in
            sem.signal()
            clk.frameCompleted()
        }
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else {
            cb.commit()
            return
        }

        let slot = uniformRing[ringIndex]
        ringIndex = (ringIndex + 1) % uniformRing.count
        let uniformsIndex = Int(RMBufferIndexUniforms.rawValue)

        if let frame = controller.latestFrame {
            let live = RMLiveUniforms(
                viewProjection: frame.viewProjection,
                cameraToWorld: frame.cameraToWorld,
                intrinsicsInverse: frame.intrinsicsInverse,
                displayTransform: frame.displayToImage,
                depthWidth: UInt32(frame.depthWidth),
                depthHeight: UInt32(frame.depthHeight),
                pointSize: livePointSizePx,
                confidenceThreshold: Float(settings.minConfidence),
                minDepth: 0.05,
                maxDepth: 5.0,
                alpha: 1.0)
            slot.contents().storeBytes(of: live, as: RMLiveUniforms.self)

            enc.pushDebugGroup("CameraFeed")
            enc.setRenderPipelineState(pipeline.cameraQuad)
            enc.setDepthStencilState(pipeline.depthDisabled)
            enc.setVertexBuffer(slot, offset: 0, index: uniformsIndex)
            enc.setFragmentTexture(frame.y, index: Int(RMTextureIndexY.rawValue))
            enc.setFragmentTexture(frame.cbcr, index: Int(RMTextureIndexCbCr.rawValue))
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.popDebugGroup()

            if settings.showLivePoints {
                enc.pushDebugGroup("LivePoints")
                enc.setRenderPipelineState(pipeline.livePoints)
                enc.setDepthStencilState(pipeline.depthWrite)
                enc.setVertexBuffer(slot, offset: 0, index: uniformsIndex)
                enc.setVertexTexture(frame.y, index: Int(RMTextureIndexY.rawValue))
                enc.setVertexTexture(frame.cbcr, index: Int(RMTextureIndexCbCr.rawValue))
                enc.setVertexTexture(frame.depth, index: Int(RMTextureIndexDepth.rawValue))
                enc.setVertexTexture(frame.confidence, index: Int(RMTextureIndexConfidence.rawValue))
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: frame.depthWidth * frame.depthHeight)
                enc.popDebugGroup()
            }

            if settings.showGlobalCloudInMainView {
                let snap = pointBuffer.snapshot()
                if snap.count > 0 {
                    let stride = Decimation.stride(count: snap.count, target: maxCloudPoints)
                    let cu = RMCloudUniforms(
                        viewProjection: frame.viewProjection,
                        pointSize: cloudPointSizePx,
                        alpha: cloudAlpha,
                        stride: UInt32(stride),
                        count: UInt32(snap.count),
                        perspective: 1)
                    slot.contents().advanced(by: MetalRenderer.cloudUniformOffset).storeBytes(of: cu, as: RMCloudUniforms.self)
                    enc.pushDebugGroup("GlobalCloud")
                    enc.setRenderPipelineState(pipeline.cloudPoints)
                    enc.setDepthStencilState(pipeline.depthWrite)
                    enc.setVertexBuffer(snap.buffer, offset: 0, index: Int(RMBufferIndexPoints.rawValue))
                    enc.setVertexBuffer(slot, offset: MetalRenderer.cloudUniformOffset, index: uniformsIndex)
                    enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Decimation.decimatedCount(count: snap.count, stride: stride))
                    enc.popDebugGroup()
                }
            }

            if let peers, !peers.peers.isEmpty {
                drawPeers(enc, viewProjection: frame.viewProjection, slot: slot, peers: peers)
            }
        }

        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
        context.flushTextureCache()

        let d = ContinuousClock.now - start
        clock.recordCPUFrame(ms: Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }

    /// One draw per peer: their points are already tinted with the party colour on the way in, so
    /// only the size and the alpha separate them from this phone's own cloud.
    private func drawPeers(_ enc: MTLRenderCommandEncoder, viewProjection vp: simd_float4x4, slot: MTLBuffer, peers: PeerCloudStore) {
        let uniformsIndex = Int(RMBufferIndexUniforms.rawValue)
        let originToClip = vp * peerOriginToWorld
        enc.pushDebugGroup("PeerClouds")
        enc.setRenderPipelineState(pipeline.cloudPoints)
        enc.setDepthStencilState(pipeline.depthWrite)
        for (slotIndex, peer) in peers.peers.prefix(PeerCloudStore.maxPeers).enumerated() {
            let snap = peer.buffer.snapshot()
            guard snap.count > 0 else { continue }
            let stride = Decimation.stride(count: snap.count, target: maxPeerPoints)
            let uniforms = RMCloudUniforms(
                viewProjection: originToClip,
                pointSize: peerPointSizePx,
                alpha: peerAlpha,
                stride: UInt32(stride),
                count: UInt32(snap.count),
                perspective: 1)
            let offset = MetalRenderer.peerUniformOffset + slotIndex * MetalRenderer.peerUniformStride
            slot.contents().advanced(by: offset).storeBytes(of: uniforms, as: RMCloudUniforms.self)
            enc.setVertexBuffer(snap.buffer, offset: 0, index: Int(RMBufferIndexPoints.rawValue))
            enc.setVertexBuffer(slot, offset: offset, index: uniformsIndex)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Decimation.decimatedCount(count: snap.count, stride: stride))
        }
        enc.popDebugGroup()
    }
}
