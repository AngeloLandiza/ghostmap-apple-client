import AVFoundation
import MapCore
import SwiftUI

struct CaptureView: View {
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var session: CaptureSession?
    @State private var initError: String?
    @State private var cameraDenied = false
    @State private var showParty = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session {
                MetalView(context: env.context, renderer: session.mainRenderer, preferredFPS: 60, isOpaque: true)
                    .ignoresSafeArea()
                // The Ghost Map sits below the controls in z-order so Start/Stop stays reachable even when expanded.
                GhostMapOverlay(session: session)
                if !session.ghostExpanded { partyButton(session) }
                VStack {
                    Spacer()
                    controls(session)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                }
                if session.isFinalizing {
                    FinalizeOverlay(step: session.finalizeStep, progress: session.finalizeProgress)
                }
            } else if cameraDenied {
                ContentUnavailableView("Camera access needed", systemImage: "camera.fill", description: Text("Allow camera access in Settings → RoomMapper to scan rooms."))
                closeButton
            } else if let initError {
                ContentUnavailableView("Capture unavailable", systemImage: "exclamationmark.triangle", description: Text(initError))
                closeButton
            } else {
                ProgressView().tint(.white)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task { await start() }
        .onDisappear { session?.teardown() }
        .sheet(isPresented: $showParty) {
            PartyView(env: env)
        }
        .onChange(of: env.pendingJoinCode) { _, code in
            if code != nil { showParty = true }
        }
    }

    /// Top-left pill: opens the party screen, and shows the code and head count while in one.
    @ViewBuilder
    private func partyButton(_ session: CaptureSession) -> some View {
        VStack {
            HStack {
                Button { showParty = true } label: {
                    PartyBadge(party: session.party)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(session.isStreamingToParty ? 0.5 : 0.18), lineWidth: 0.5))
                }
                .foregroundStyle(.white)
                .disabled(session.isFinalizing)
                .accessibilityLabel(session.party.isActive ? "Party \(session.party.inviteCode ?? "")" : "Parties")
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)).padding(12).background(.ultraThinMaterial, in: Circle()) }
                Spacer()
            }
            .padding()
            Spacer()
        }
    }

    private func start() async {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        guard granted else {
            cameraDenied = true
            return
        }
        do {
            let s = try CaptureSession(env: env)
            session = s
            s.startPreview()
        } catch {
            initError = String(describing: error)
        }
    }

    @ViewBuilder
    private func controls(_ session: CaptureSession) -> some View {
        HStack(alignment: .center) {
            Button {
                session.teardown()
                dismiss()
            } label: {
                Image(systemName: session.phase == .saved ? "checkmark" : "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(session.isRecording || session.isFinalizing)
            .opacity(session.isRecording || session.isFinalizing ? 0.3 : 1)
            .accessibilityLabel(session.phase == .saved ? "Done" : "Close")

            Spacer()

            RecordButton(session: session)

            Spacer()

            Menu {
                Toggle("High-confidence depth only", isOn: Binding(get: { session.settings.highConfidenceOnly }, set: { session.settings.highConfidenceOnly = $0 }))
                Toggle("Live depth points", isOn: Binding(get: { session.settings.showLivePoints }, set: { session.settings.showLivePoints = $0 }))
                Toggle("Global cloud in main view", isOn: Binding(get: { session.settings.showGlobalCloudInMainView }, set: { session.settings.showGlobalCloudInMainView = $0 }))
                Toggle("Ghost Map auto-orbit", isOn: Binding(get: { session.settings.ghostAutoOrbit }, set: { session.settings.ghostAutoOrbit = $0 }))
                Picker("Quality", selection: Binding(get: { session.settings.quality }, set: { session.settings.quality = $0 })) {
                    ForEach(QualityPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(session.isRecording)
                Picker("Dynamic objects", selection: Binding(get: { session.settings.dynamicSensitivity }, set: { session.settings.dynamicSensitivity = $0 })) {
                    ForEach(DynamicSensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(session.isRecording)
                Toggle("4K color (30 fps)", isOn: Binding(get: { session.settings.highResolutionColor }, set: { session.settings.highResolutionColor = $0 })).disabled(session.isRecording)
                Toggle("Marker origin (\(Int((session.settings.markerPhysicalWidth * 100).rounded())) cm)",
                       isOn: Binding(get: { session.settings.markerOrigin }, set: { session.settings.markerOrigin = $0 }))
                    .disabled(session.isRecording)
                Button { session.resetGhostView() } label: { Label("Reset Ghost Map view", systemImage: "arrow.counterclockwise") }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .foregroundStyle(.white)
    }
}

struct RecordButton: View {
    let session: CaptureSession

    var body: some View {
        Button {
            Task {
                if session.isRecording {
                    await session.stopRecording()
                } else if session.canStart {
                    await session.startRecording()
                }
            }
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                if session.isRecording {
                    RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 32, height: 32)
                } else if session.isFinalizing {
                    ProgressView().tint(.white)
                } else {
                    Circle().fill(.red).frame(width: 60, height: 60)
                }
            }
        }
        .disabled(session.isFinalizing || !(session.isRecording || session.canStart))
        .accessibilityLabel(session.isRecording ? "Stop" : "Start")
        .overlay(alignment: .top) {
            if session.phase == .saved, let id = session.savedMapID {
                Text("Saved · \(Format.count(session.manifest?.pointCount ?? 0)) pts")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.green.opacity(0.85), in: Capsule())
                    .offset(y: -40)
                    .id(id)
            } else if case .failed(let message) = session.phase {
                Text(message)
                    .font(.caption2)
                    .lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.red.opacity(0.85), in: Capsule())
                    .offset(y: -44)
                    .frame(width: 260)
            }
        }
    }
}

struct FinalizeOverlay: View {
    let step: CaptureSession.FinalizeStep?
    let progress: Double

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress).tint(.white).frame(width: 220)
            Text(step?.rawValue ?? "Finalizing…").font(.subheadline.weight(.medium))
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .foregroundStyle(.white)
    }
}
