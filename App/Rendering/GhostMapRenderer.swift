import CoreGraphics
import MapCore
import Metal
import MetalKit
import simd

/// Ghost Map / map-detail renderer: the global cloud (strided), the keyframe trajectory polyline and
/// the current camera frustum, from a top-down orthographic or orbiting camera. Runs at ≤ 30 fps and
/// skips frames when the main renderer is behind. Also renders thumbnails offscreen.
@MainActor
final class GhostMapRenderer: NSObject, MTKViewDelegate {
    static let uniformSlotBytes = 4096
    static let trajectoryUniformOffset = 256
    static let frustumUniformOffset = 512
    /// One 256-byte cloud-uniform block per party peer, then one 128-byte line block each.
    static let peerCloudUniformOffset = 1024
    static let peerCloudUniformStride = 256
    static let peerLineUniformOffset = 3072
    static let peerLineUniformStride = 128
    /// Vertices in one frustum wireframe (4 apex spokes + 4 far-plane edges, as line pairs).
    static let frustumVertexCount = 16

    private let context: MetalContext
    private let pipeline: PointCloudPipeline
    let pointBuffer: SharedPointBuffer
    let trajectory: TrajectoryBuffer?
    private let clock: RenderClock?

    var camera = GhostCamera()
    var pointAlpha: Float = 0.55
    var pointSizePx: Float = 3
    var maxPoints = 250_000
    var trajectoryColor = SIMD4<Float>(1.0, 0.82, 0.25, 0.95)
    var frustumColor = SIMD4<Float>(0.35, 0.9, 1.0, 1.0)
    var cameraTransform: simd_float4x4?
    /// Polled every frame so the frustum follows the live camera at the ghost frame rate.
    var cameraTransformProvider: (@MainActor () -> simd_float4x4?)?
    var frustumDepth: Float = 0.3
    var frustumHalfExtents = SIMD2<Float>(0.18, 0.135)
    var skipWhenMainIsBehind = true
    var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

    // MARK: Party peers

    /// The other phones in the party. Their clouds and frustums are drawn in their party colours.
    var peers: PeerCloudStore?
    /// `world_from_origin`, which lifts peers' origin-frame data into this phone's world frame.
    var peerOriginToWorld = matrix_identity_float4x4
    var peerPointSizePx: Float = 2
    var peerAlpha: Float = 0.7
    var maxPeerPoints = 120_000
    private(set) var fps: Double = 0
    private(set) var skippedFrames = 0

    private let inflight = DispatchSemaphore(value: 2)
    private let uniformRing: [MTLBuffer]
    private var ringIndex = 0
    private let frustumBuffer: MTLBuffer
    private let peerFrustumBuffer: MTLBuffer
    private var lastDraw: ContinuousClock.Instant?

    init(context: MetalContext, pipeline: PointCloudPipeline, pointBuffer: SharedPointBuffer,
         trajectory: TrajectoryBuffer?, clock: RenderClock?) throws {
        self.context = context
        self.pipeline = pipeline
        self.pointBuffer = pointBuffer
        self.trajectory = trajectory
        self.clock = clock
        var ring: [MTLBuffer] = []
        for i in 0..<3 {
            guard let b = context.device.makeBuffer(length: GhostMapRenderer.uniformSlotBytes, options: .storageModeShared) else {
                throw RenderError.bufferAllocationFailed(bytes: GhostMapRenderer.uniformSlotBytes)
            }
            b.label = "GhostUniforms.\(i)"
            ring.append(b)
        }
        uniformRing = ring
        let frustumBytes = GhostMapRenderer.frustumVertexCount * MemoryLayout<RMLineVertex>.stride
        guard let fb = context.device.makeBuffer(length: frustumBytes, options: .storageModeShared) else {
            throw RenderError.bufferAllocationFailed(bytes: frustumBytes)
        }
        fb.label = "Frustum"
        frustumBuffer = fb
        let peerBytes = frustumBytes * PeerCloudStore.maxPeers
        guard let pb = context.device.makeBuffer(length: peerBytes, options: .storageModeShared) else {
            throw RenderError.bufferAllocationFailed(bytes: peerBytes)
        }
        pb.label = "PeerFrustums"
        peerFrustumBuffer = pb
        super.init()
    }

    /// Sizes the drawn frustum from the depth-map intrinsics.
    func setDepthIntrinsics(_ k: Intrinsics) {
        guard k.fx > 0, k.fy > 0 else { return }
        frustumHalfExtents = SIMD2<Float>(frustumDepth * Float(k.width) * 0.5 / k.fx, frustumDepth * Float(k.height) * 0.5 / k.fy)
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(in: view) }
    }

    private func drawFrame(in view: MTKView) {
        if skipWhenMainIsBehind, let clock, clock.isBehind {
            skippedFrames += 1
            return
        }
        let now = ContinuousClock.now
        var dt: Float = 1.0 / 30.0
        if let last = lastDraw {
            let d = now - last
            let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            dt = Float(min(max(seconds, 0.001), 0.25))
            if seconds > 0 { fps = fps == 0 ? 1 / seconds : fps * 0.9 + (1 / seconds) * 0.1 }
        }
        lastDraw = now

        if let provider = cameraTransformProvider { cameraTransform = provider() }
        camera.frame(bounds: pointBuffer.bounds)
        camera.advance(dt: dt)

        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor else { return }
        guard inflight.wait(timeout: .now() + .milliseconds(20)) == .success else {
            skippedFrames += 1
            return
        }
        guard let cb = context.commandQueue.makeCommandBuffer() else {
            inflight.signal()
            return
        }
        cb.label = "GhostFrame"
        let sem = inflight
        cb.addCompletedHandler { _ in sem.signal() }
        rpd.colorAttachments[0].clearColor = clearColor
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else {
            cb.commit()
            return
        }
        let slot = uniformRing[ringIndex]
        ringIndex = (ringIndex + 1) % uniformRing.count
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        encodeScene(enc, viewProjection: camera.viewProjection(aspect: aspect), slot: slot,
                    pointSize: pointSizePx, alpha: pointAlpha, maxPoints: maxPoints, includeCamera: true,
                    perspective: camera.mode == .orbit, includePeers: true)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    private func encodeScene(_ enc: MTLRenderCommandEncoder, viewProjection vp: simd_float4x4, slot: MTLBuffer,
                             pointSize: Float, alpha: Float, maxPoints: Int, includeCamera: Bool, perspective: Bool,
                             includePeers: Bool = false) {
        let uniformsIndex = Int(RMBufferIndexUniforms.rawValue)
        let snap = pointBuffer.snapshot()
        if snap.count > 0 {
            let stride = Decimation.stride(count: snap.count, target: maxPoints)
            let cu = RMCloudUniforms(viewProjection: vp, pointSize: pointSize, alpha: alpha,
                                     stride: UInt32(stride), count: UInt32(snap.count),
                                     perspective: perspective ? 1 : 0)
            slot.contents().storeBytes(of: cu, as: RMCloudUniforms.self)
            enc.pushDebugGroup("GhostCloud")
            enc.setRenderPipelineState(pipeline.cloudPoints)
            enc.setDepthStencilState(pipeline.depthWrite)
            enc.setVertexBuffer(snap.buffer, offset: 0, index: Int(RMBufferIndexPoints.rawValue))
            enc.setVertexBuffer(slot, offset: 0, index: uniformsIndex)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Decimation.decimatedCount(count: snap.count, stride: stride))
            enc.popDebugGroup()
        }

        if let trajectory {
            let ts = trajectory.snapshot()
            if ts.count >= 2 {
                let lu = RMLineUniforms(viewProjection: vp, color: trajectoryColor)
                slot.contents().advanced(by: GhostMapRenderer.trajectoryUniformOffset).storeBytes(of: lu, as: RMLineUniforms.self)
                enc.pushDebugGroup("Trajectory")
                enc.setRenderPipelineState(pipeline.lines)
                enc.setDepthStencilState(pipeline.depthDisabled)
                enc.setVertexBuffer(ts.buffer, offset: 0, index: Int(RMBufferIndexLines.rawValue))
                enc.setVertexBuffer(slot, offset: GhostMapRenderer.trajectoryUniformOffset, index: uniformsIndex)
                enc.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: ts.count)
                enc.popDebugGroup()
            }
        }

        if includeCamera, let t = cameraTransform {
            fillFrustum(transform: t)
            let lu = RMLineUniforms(viewProjection: vp, color: frustumColor)
            slot.contents().advanced(by: GhostMapRenderer.frustumUniformOffset).storeBytes(of: lu, as: RMLineUniforms.self)
            enc.pushDebugGroup("Frustum")
            enc.setRenderPipelineState(pipeline.lines)
            enc.setDepthStencilState(pipeline.depthDisabled)
            enc.setVertexBuffer(frustumBuffer, offset: 0, index: Int(RMBufferIndexLines.rawValue))
            enc.setVertexBuffer(slot, offset: GhostMapRenderer.frustumUniformOffset, index: uniformsIndex)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: GhostMapRenderer.frustumVertexCount)
            enc.popDebugGroup()
        }

        if includePeers, let peers, !peers.peers.isEmpty {
            encodePeers(enc, viewProjection: vp, slot: slot, peers: peers, perspective: perspective)
        }
    }

    /// Peer clouds and, for every peer that has published a pose, a small frustum in their colour.
    /// Everything is drawn through `world_from_origin` because peers speak the party's origin frame.
    private func encodePeers(_ enc: MTLRenderCommandEncoder, viewProjection vp: simd_float4x4, slot: MTLBuffer,
                             peers: PeerCloudStore, perspective: Bool) {
        let uniformsIndex = Int(RMBufferIndexUniforms.rawValue)
        let originToClip = vp * peerOriginToWorld
        let visible = Array(peers.peers.prefix(PeerCloudStore.maxPeers))

        enc.pushDebugGroup("PeerClouds")
        enc.setRenderPipelineState(pipeline.cloudPoints)
        enc.setDepthStencilState(pipeline.depthWrite)
        for (slotIndex, peer) in visible.enumerated() {
            let snap = peer.buffer.snapshot()
            guard snap.count > 0 else { continue }
            let stride = Decimation.stride(count: snap.count, target: maxPeerPoints)
            let uniforms = RMCloudUniforms(viewProjection: originToClip, pointSize: peerPointSizePx, alpha: peerAlpha,
                                           stride: UInt32(stride), count: UInt32(snap.count),
                                           perspective: perspective ? 1 : 0)
            let offset = GhostMapRenderer.peerCloudUniformOffset + slotIndex * GhostMapRenderer.peerCloudUniformStride
            slot.contents().advanced(by: offset).storeBytes(of: uniforms, as: RMCloudUniforms.self)
            enc.setVertexBuffer(snap.buffer, offset: 0, index: Int(RMBufferIndexPoints.rawValue))
            enc.setVertexBuffer(slot, offset: offset, index: uniformsIndex)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Decimation.decimatedCount(count: snap.count, stride: stride))
        }
        enc.popDebugGroup()

        enc.pushDebugGroup("PeerFrustums")
        enc.setRenderPipelineState(pipeline.lines)
        enc.setDepthStencilState(pipeline.depthDisabled)
        let vertexStride = MemoryLayout<RMLineVertex>.stride
        for (slotIndex, peer) in visible.enumerated() {
            guard let pose = peer.latestPose else { continue }
            let vertexOffset = slotIndex * GhostMapRenderer.frustumVertexCount * vertexStride
            writeFrustum(transform: pose, into: peerFrustumBuffer, byteOffset: vertexOffset)
            let (r, g, b) = peer.color.components
            let uniforms = RMLineUniforms(viewProjection: originToClip, color: SIMD4<Float>(r, g, b, peer.isStale ? 0.35 : 0.95))
            let offset = GhostMapRenderer.peerLineUniformOffset + slotIndex * GhostMapRenderer.peerLineUniformStride
            slot.contents().advanced(by: offset).storeBytes(of: uniforms, as: RMLineUniforms.self)
            enc.setVertexBuffer(peerFrustumBuffer, offset: vertexOffset, index: Int(RMBufferIndexLines.rawValue))
            enc.setVertexBuffer(slot, offset: offset, index: uniformsIndex)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: GhostMapRenderer.frustumVertexCount)
        }
        enc.popDebugGroup()
    }

    private func fillFrustum(transform t: simd_float4x4) {
        writeFrustum(transform: t, into: frustumBuffer, byteOffset: 0)
    }

    /// Writes one frustum wireframe (16 vertices, 8 line segments) at `byteOffset` in `buffer`.
    private func writeFrustum(transform t: simd_float4x4, into buffer: MTLBuffer, byteOffset: Int) {
        let hx = frustumHalfExtents.x
        let hy = frustumHalfExtents.y
        let d = frustumDepth
        func world(_ p: SIMD3<Float>) -> RMLineVertex {
            let w = t * SIMD4<Float>(p, 1)
            return RMLineVertex(x: w.x, y: w.y, z: w.z)
        }
        let apex = world(SIMD3<Float>(0, 0, 0))
        let c0 = world(SIMD3<Float>(-hx, -hy, -d))
        let c1 = world(SIMD3<Float>(hx, -hy, -d))
        let c2 = world(SIMD3<Float>(hx, hy, -d))
        let c3 = world(SIMD3<Float>(-hx, hy, -d))
        let lines: [RMLineVertex] = [apex, c0, apex, c1, apex, c2, apex, c3, c0, c1, c1, c2, c2, c3, c3, c0]
        lines.withUnsafeBytes { src in
            if let base = src.baseAddress, byteOffset + src.count <= buffer.length {
                buffer.contents().advanced(by: byteOffset).copyMemory(from: base, byteCount: src.count)
            }
        }
    }

    /// Top-down render of the whole cloud into a `size × size` image (used for thumbnails).
    func renderThumbnail(size: Int = 512) -> CGImage? {
        let device = context.device
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pipeline.colorFormat, width: size, height: size, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pipeline.depthFormat, width: size, height: size, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        guard let color = device.makeTexture(descriptor: colorDesc), let depth = device.makeTexture(descriptor: depthDesc),
              let slot = device.makeBuffer(length: GhostMapRenderer.uniformSlotBytes, options: .storageModeShared) else {
            return nil
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare
        rpd.depthAttachment.clearDepth = 1

        var cam = camera
        cam.mode = .topDown
        cam.zoom = 1
        cam.panOffset = .zero
        cam.frame(bounds: pointBuffer.bounds)
        cam.snapToTarget()

        guard let cb = context.commandQueue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        encodeScene(enc, viewProjection: cam.viewProjection(aspect: 1), slot: slot,
                    pointSize: 3, alpha: 1, maxPoints: 1_000_000, includeCamera: false, perspective: false)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        let bytesPerRow = size * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * size)
        let read = bytes.withUnsafeMutableBytes { dst -> Bool in
            guard let base = dst.baseAddress else { return false }
            color.getBytes(base, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            return true
        }
        guard read else { return nil }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
