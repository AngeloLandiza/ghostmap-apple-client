import CoreGraphics
import MapCore
import simd

/// Camera model for the Ghost Map and the map detail viewer: a top-down orthographic view or a
/// tilted orbit, auto-framed to the cloud's bounding box with "north" = the session's initial heading.
struct GhostCamera: Sendable {
    enum Mode: Sendable, Equatable {
        case topDown
        case orbit
    }

    var mode: Mode = .topDown
    var autoOrbit = false
    /// Azimuth around the up axis (radians); 0 looks along `north`.
    var azimuth: Float = 0
    /// Elevation above the ground plane (radians) for orbit mode.
    var elevation: Float = RenderMath.radians(35)
    /// User zoom factor (1 = auto-framed). Smaller = closer.
    var zoom: Float = 1
    /// User pan applied to the framing center, in world meters.
    var panOffset = SIMD3<Float>(repeating: 0)
    /// Initial heading projected on the ground plane; drawn "up" in top-down mode.
    var north = SIMD3<Float>(0, 0, -1)

    static let autoOrbitRate: Float = 0.25   // rad/s
    static let fovY: Float = RenderMath.radians(50)
    static let up = SIMD3<Float>(0, 1, 0)

    private(set) var center = SIMD3<Float>(repeating: 0)
    private(set) var radius: Float = 1

    private var targetCenter = SIMD3<Float>(repeating: 0)
    private var targetRadius: Float = 1

    /// Updates the auto-framing targets from the cloud bounds.
    mutating func frame(bounds: BoundingBox) {
        guard !bounds.isEmpty, simd_length(bounds.extent) < 1000 else { return }   // ignore boxes polluted by parked points
        targetCenter = bounds.center
        targetRadius = max(simd_length(bounds.extent) * 0.5, 0.5)
    }

    /// Advances smoothing and the optional auto-orbit by `dt` seconds.
    mutating func advance(dt: Float) {
        let k = 1 - exp(-dt * 3)
        center += (targetCenter - center) * k
        radius += (targetRadius - radius) * k
        if autoOrbit && mode == .orbit {
            azimuth += GhostCamera.autoOrbitRate * dt
            if azimuth > .pi * 2 { azimuth -= .pi * 2 }
        }
    }

    /// Snaps smoothing to the targets (e.g. when a static cloud is loaded).
    mutating func snapToTarget() {
        center = targetCenter
        radius = targetRadius
    }

    /// Sets north from a camera forward vector (projected onto the ground plane).
    mutating func setNorth(fromForward forward: SIMD3<Float>) {
        var h = forward - simd_dot(forward, GhostCamera.up) * GhostCamera.up
        if simd_length_squared(h) < 1e-6 { h = SIMD3<Float>(0, 0, -1) }
        north = simd_normalize(h)
    }

    /// East vector completing the right-handed (east, up, north) basis: with north = −Z, east = +X.
    var east: SIMD3<Float> { simd_normalize(simd_cross(north, GhostCamera.up)) }

    var framedCenter: SIMD3<Float> { center + panOffset }

    func viewMatrix() -> simd_float4x4 {
        let c = framedCenter
        switch mode {
        case .topDown:
            let height = radius * 2 + 2
            return RenderMath.lookAt(eye: c + GhostCamera.up * height, target: c, up: north)
        case .orbit:
            let d = orbitDistance
            let el = elevation
            let dir = east * (sin(azimuth) * cos(el)) + GhostCamera.up * sin(el) - north * (cos(azimuth) * cos(el))
            return RenderMath.lookAt(eye: c + dir * d, target: c, up: GhostCamera.up)
        }
    }

    var orbitDistance: Float {
        radius / sin(GhostCamera.fovY * 0.5) * 1.1 * zoom
    }

    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        switch mode {
        case .topDown:
            let half = radius * 1.1 * zoom
            let hx = aspect >= 1 ? half * aspect : half
            let hy = aspect >= 1 ? half : half / aspect
            let height = radius * 2 + 2
            return RenderMath.orthographic(left: -hx, right: hx, bottom: -hy, top: hy, near: 0.01, far: height * 2 + radius * 2 + 10)
        case .orbit:
            let d = orbitDistance
            return RenderMath.perspective(fovYRadians: GhostCamera.fovY, aspect: aspect, near: 0.02, far: d + radius * 2 + 20)
        }
    }

    func viewProjection(aspect: Float) -> simd_float4x4 {
        projectionMatrix(aspect: aspect) * viewMatrix()
    }

    // MARK: Gestures

    /// One-finger drag: orbit (azimuth/elevation) in orbit mode, pan in top-down mode.
    mutating func applyDrag(delta: CGSize, viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        switch mode {
        case .orbit:
            let dx = Float(delta.width / viewSize.width)
            let dy = Float(delta.height / viewSize.height)
            azimuth -= dx * .pi * 2
            elevation = min(max(elevation + dy * .pi, RenderMath.radians(5)), RenderMath.radians(89))
        case .topDown:
            applyPan(delta: delta, viewSize: viewSize)
        }
    }

    /// Two-finger drag: pan in both modes.
    mutating func applyPan(delta: CGSize, viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let dx = Float(delta.width / viewSize.width)
        let dy = Float(delta.height / viewSize.height)
        let scale = (mode == .topDown ? radius * 1.1 * zoom : orbitDistance * 0.5) * 2
        let view = viewMatrix()
        // Camera right/up in world space are the first two rows of the rotation part.
        let right = SIMD3<Float>(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let up = SIMD3<Float>(view.columns.0.y, view.columns.1.y, view.columns.2.y)
        panOffset -= right * (dx * scale)
        panOffset += up * (dy * scale)
    }

    mutating func applyPinch(scale: CGFloat) {
        guard scale > 0 else { return }
        zoom = min(max(zoom / Float(scale), 0.05), 20)
    }

    mutating func resetView() {
        zoom = 1
        panOffset = .zero
        azimuth = 0
        elevation = RenderMath.radians(35)
    }
}
