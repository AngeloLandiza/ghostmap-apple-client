import MapCore
import SwiftUI

/// Positions the Ghost Map panel: a square of 36 % of the screen width, 16 pt inside the top-trailing
/// safe-area corner, or full screen when expanded. Hit testing is scoped to the panel itself.
struct GhostMapOverlay: View {
    let session: CaptureSession

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width * 0.36
            let expanded = session.ghostExpanded
            ZStack(alignment: .topTrailing) {
                Color.clear.allowsHitTesting(false)
                GhostMapPanel(session: session, expanded: expanded)
                    .frame(width: expanded ? geo.size.width : side, height: expanded ? geo.size.height : side)
                    .padding(expanded ? 0 : 16)
            }
            .animation(.spring(duration: 0.35), value: expanded)
        }
        .ignoresSafeArea(edges: session.ghostExpanded ? .all : [])
        .allowsHitTesting(true)
    }
}

struct GhostMapPanel: View {
    let session: CaptureSession
    let expanded: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            MetalView(context: session.env.context, renderer: session.ghostRenderer, preferredFPS: 30, isOpaque: false,
                      gestureRenderer: expanded ? session.ghostRenderer : nil,
                      onSwipeDown: { session.setGhostExpanded(false) })
            StatusStrip(snapshot: session.status.snapshot, expanded: expanded, mode: session.ghostRenderer.camera.mode)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: expanded ? 0 : 12, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { session.setGhostExpanded(!expanded) }
        .onLongPressGesture(minimumDuration: 0.5) { session.toggleGhostMode() }
        .overlay(alignment: .topLeading) {
            if expanded {
                HStack(spacing: 8) {
                    Button { session.setGhostExpanded(false) } label: {
                        Image(systemName: "chevron.down").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle())
                    }
                    Button { session.toggleGhostMode() } label: {
                        Image(systemName: session.ghostRenderer.camera.mode == .topDown ? "rotate.3d" : "square.grid.3x3")
                            .font(.headline).padding(10).background(.ultraThinMaterial, in: Circle())
                    }
                    Button { session.resetGhostView() } label: {
                        Image(systemName: "arrow.counterclockwise").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle())
                    }
                }
                .foregroundStyle(.white)
                .padding(.top, 54)
                .padding(.leading, 16)
            }
        }
        .accessibilityLabel("Ghost map")
    }
}

/// The status strip along the bottom of the Ghost Map (≥ 4 Hz updates come from the snapshot).
struct StatusStrip: View {
    let snapshot: StatusSnapshot
    let expanded: Bool
    let mode: GhostCamera.Mode

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 3 : 1) {
            HStack(spacing: 4) {
                Circle().fill(trackingColor).frame(width: 6, height: 6)
                Text(snapshot.tracking.label).foregroundStyle(trackingColor)
                Text("·").foregroundStyle(.secondary)
                Text(snapshot.worldMapping)
            }
            Text("\(snapshot.keyframes) kf · \(Format.count(snapshot.points)) pts · \(Format.duration(snapshot.elapsed)) · ~\(Format.bytes(snapshot.estimatedDiskBytes))")
            HStack(spacing: 4) {
                Circle().fill(thermalColor).frame(width: 6, height: 6)
                Text(ThermalMonitor.label(for: snapshot.thermal)).foregroundStyle(thermalColor)
                Text("· \(Int(snapshot.fps.rounded())) fps · cb \(String(format: "%.1f", snapshot.callbackP95Ms)) ms")
            }
            if expanded {
                Text("ghost \(Int(snapshot.ghostFPS.rounded())) fps · process \(String(format: "%.1f", snapshot.processMs)) ms · cb max \(String(format: "%.1f", snapshot.callbackMaxMs)) ms")
                Text("mem \(Int(snapshot.memoryMB)) MB · grid \(gridLabel) · policy \(policyLabel) · \(mode == .topDown ? "top-down" : "orbit") · \(snapshot.videoFormat)")
                Text("log \(Format.bytes(snapshot.logBytes)) · \(snapshot.isRecording ? "REC" : "preview")")
            }
            if let warning = snapshot.warning {
                Text(warning).foregroundStyle(.orange).lineLimit(expanded ? 2 : 1)
            }
        }
        .font(.system(size: expanded ? 13 : 9, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, expanded ? 16 : 6)
        .padding(.vertical, expanded ? 12 : 4)
        .padding(.bottom, expanded ? 30 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(expanded ? 0.5 : 0.35))
    }

    private var trackingColor: Color {
        switch snapshot.tracking {
        case .normal: return .green
        case .limited: return .orange
        case .notAvailable: return .red
        }
    }

    private var thermalColor: Color {
        switch snapshot.thermal {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }

    private var gridLabel: String {
        switch snapshot.gridState {
        case .accepting: return "2cm"
        case .capReached: return "cap"
        case .coarsened: return "3cm"
        case .full: return "full"
        }
    }

    private var policyLabel: String {
        switch snapshot.policyMode {
        case .normal: return "normal"
        case .halved: return "halved"
        case .paused: return "paused"
        }
    }
}
