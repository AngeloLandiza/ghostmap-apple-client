import MetalKit
import SwiftUI
import UIKit

/// SwiftUI wrapper around an `MTKView`. When `gestureRenderer` is set, one-finger pan (orbit / pan),
/// two-finger pan and pinch drive that renderer's camera, and a fast downward one-finger swipe calls
/// `onSwipeDown`.
struct MetalView: UIViewRepresentable {
    let context: MetalContext
    let renderer: any MTKViewDelegate
    var preferredFPS = 60
    var isOpaque = true
    var gestureRenderer: GhostMapRenderer? = nil
    var onSwipeDown: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context ctx: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: self.context.device)
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.preferredFramesPerSecond = preferredFPS
        view.isOpaque = isOpaque
        view.backgroundColor = isOpaque ? .black : .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: isOpaque ? 1 : 0)
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.isMultipleTouchEnabled = true
        if !isOpaque {
            view.layer.isOpaque = false
        }
        ctx.coordinator.install(on: view)
        ctx.coordinator.renderer = gestureRenderer
        ctx.coordinator.onSwipeDown = onSwipeDown
        ctx.coordinator.setEnabled(gestureRenderer != nil)
        return view
    }

    func updateUIView(_ view: MTKView, context ctx: Context) {
        if view.preferredFramesPerSecond != preferredFPS { view.preferredFramesPerSecond = preferredFPS }
        ctx.coordinator.renderer = gestureRenderer
        ctx.coordinator.onSwipeDown = onSwipeDown
        ctx.coordinator.setEnabled(gestureRenderer != nil)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var renderer: GhostMapRenderer?
        var onSwipeDown: (() -> Void)?
        private var recognizers: [UIGestureRecognizer] = []
        private var lastPan = CGPoint.zero
        private var lastTwoFingerPan = CGPoint.zero
        private var lastScale: CGFloat = 1

        func install(on view: UIView) {
            let pan1 = UIPanGestureRecognizer(target: self, action: #selector(handlePan1(_:)))
            pan1.minimumNumberOfTouches = 1
            pan1.maximumNumberOfTouches = 1
            let pan2 = UIPanGestureRecognizer(target: self, action: #selector(handlePan2(_:)))
            pan2.minimumNumberOfTouches = 2
            pan2.maximumNumberOfTouches = 2
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            for r in [pan1, pan2, pinch] {
                r.delegate = self
                r.cancelsTouchesInView = false
                view.addGestureRecognizer(r)
            }
            recognizers = [pan1, pan2, pinch]
        }

        func setEnabled(_ enabled: Bool) {
            for r in recognizers where r.isEnabled != enabled { r.isEnabled = enabled }
        }

        @objc private func handlePan1(_ g: UIPanGestureRecognizer) {
            guard let renderer, let v = g.view else { return }
            switch g.state {
            case .began:
                lastPan = .zero
            case .changed:
                let t = g.translation(in: v)
                renderer.camera.applyDrag(delta: CGSize(width: t.x - lastPan.x, height: t.y - lastPan.y), viewSize: v.bounds.size)
                lastPan = t
            case .ended:
                let velocity = g.velocity(in: v)
                let t = g.translation(in: v)
                if velocity.y > 1200, t.y > 120, abs(t.x) < t.y {
                    onSwipeDown?()
                }
                lastPan = .zero
            default:
                lastPan = .zero
            }
        }

        @objc private func handlePan2(_ g: UIPanGestureRecognizer) {
            guard let renderer, let v = g.view else { return }
            switch g.state {
            case .began:
                lastTwoFingerPan = .zero
            case .changed:
                let t = g.translation(in: v)
                renderer.camera.applyPan(delta: CGSize(width: t.x - lastTwoFingerPan.x, height: t.y - lastTwoFingerPan.y), viewSize: v.bounds.size)
                lastTwoFingerPan = t
            default:
                lastTwoFingerPan = .zero
            }
        }

        @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let renderer else { return }
            switch g.state {
            case .began:
                lastScale = 1
            case .changed:
                renderer.camera.applyPinch(scale: g.scale / max(lastScale, 0.001))
                lastScale = g.scale
            default:
                lastScale = 1
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
