import MapCore
import SwiftUI

struct MapDetailView: View {
    let env: AppEnvironment
    let summary: MapSummary
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var renderer: GhostMapRenderer?
    @State private var loadError: String?
    @State private var loadedPoints = 0
    @State private var confirmDelete = false
    @State private var showRename = false
    @State private var name: String
    @State private var topDown = false
    /// The backend id once this map has been uploaded. Seeded from the manifest (a previous
    /// launch's upload) and updated when `env.uploadStatus` reports a fresh success, since
    /// `summary` itself is a snapshot the parent list took before this screen opened.
    @State private var cloudMapId: String?

    init(env: AppEnvironment, summary: MapSummary, onChanged: @escaping () -> Void) {
        self.env = env
        self.summary = summary
        self.onChanged = onChanged
        _name = State(initialValue: summary.manifest.name)
        _cloudMapId = State(initialValue: summary.manifest.cloudMapId)
    }

    private var plyURL: URL { env.store.url(for: .cloud, in: summary.manifest.mapID) }
    private var uploadStatus: MapUploadStatus { env.uploadStatus[summary.manifest.mapID] ?? .idle }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let renderer {
                    MetalView(context: env.context, renderer: renderer, preferredFPS: 60, isOpaque: true, gestureRenderer: renderer)
                        .ignoresSafeArea(edges: .horizontal)
                    VStack {
                        Spacer()
                        HStack {
                            Text("\(Format.count(loadedPoints)) points · drag to orbit · pinch to zoom · two fingers to pan")
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(6).background(.ultraThinMaterial, in: Capsule())
                            Spacer()
                        }.padding(8)
                    }
                } else if let loadError {
                    ContentUnavailableView("Cloud unavailable", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else {
                    ProgressView("Loading point cloud…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            List {
                Section("Map") {
                    row("Points", Format.count(summary.manifest.pointCount))
                    row("Keyframes", "\(summary.manifest.keyframeCount)")
                    row("Duration", Format.duration(summary.manifest.durationSeconds))
                    row("Size on disk", Format.bytes(summary.sizeBytes))
                    row("Created", summary.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    row("Status", summary.manifest.status.rawValue)
                }
                Section("Details") {
                    row("Voxel", String(format: "%.0f cm", summary.manifest.voxelSizeMeters * 100))
                    row("Frame", summary.manifest.frame)
                    if let b = summary.manifest.bbox {
                        row("Extent", String(format: "%.1f × %.1f × %.1f m", b.extent.x, b.extent.y, b.extent.z))
                    }
                    row("World map", summary.manifest.hasWorldMap ? "saved" : "not saved")
                    row("Device", "\(summary.manifest.deviceModel) · iOS \(summary.manifest.iosVersion)")
                    if let f = summary.manifest.finalizeSeconds { row("Finalize", String(format: "%.1f s", f)) }
                    row("ID", summary.manifest.mapID.rawValue)
                }
                Section("Cloud") {
                    cloudSection
                }
            }
            .listStyle(.insetGrouped)
            .frame(maxHeight: 300)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if FileManager.default.fileExists(atPath: plyURL.path) {
                    ShareLink(item: plyURL, preview: SharePreview(name + ".ply")) {
                        Label("Export PLY", systemImage: "square.and.arrow.up")
                    }
                }
                Menu {
                    Button { showRename = true } label: { Label("Rename", systemImage: "pencil") }
                    Button { toggleMode() } label: { Label(topDown ? "Orbit view" : "Top-down view", systemImage: topDown ? "rotate.3d" : "square.grid.3x3") }
                    Button { renderer?.camera.resetView() } label: { Label("Reset view", systemImage: "arrow.counterclockwise") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete map", systemImage: "trash") }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete this map?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteMap() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The keyframe log, point cloud and thumbnail will be removed from this phone.")
        }
        .alert("Rename map", isPresented: $showRename) {
            TextField("Name", text: $name)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) { name = summary.manifest.name }
        }
        .task { await load() }
        .onChange(of: uploadStatus) { _, status in
            if case .succeeded(let id) = status {
                cloudMapId = id
                onChanged()
            }
        }
    }

    // MARK: - Cloud upload

    @ViewBuilder
    private var cloudSection: some View {
        switch uploadStatus {
        case .uploading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text(stageLabel(progress.stage)).font(.subheadline)
                ProgressView(value: progress.fraction)
            }
            .padding(.vertical, 2)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                uploadButton
            }
        case .idle, .succeeded:
            if let cloudMapId {
                row("Cloud ID", String(cloudMapId.prefix(12)))
            }
            uploadButton
        }
    }

    @ViewBuilder
    private var uploadButton: some View {
        Button {
            env.uploadMap(id: summary.manifest.mapID)
        } label: {
            Label(cloudMapId == nil ? "Upload to cloud" : "Re-upload", systemImage: "icloud.and.arrow.up")
        }
        .disabled(!env.account.canMap || uploadStatus.isUploading)
        if !env.account.canMap {
            Text("Sign in as this phone in Settings to upload maps.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func stageLabel(_ stage: MapUploadStage) -> String {
        switch stage {
        case .creatingRecord: return "Registering map…"
        case .uploadingFile(let file): return "Uploading \(file.rawValue)…"
        case .finalizing: return "Finalizing…"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func load() async {
        let url = plyURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = summary.manifest.status == .failed ? "This recording was interrupted. Use Rebuild in the map list to recover the cloud from the keyframe log." : "cloud.ply is missing."
            return
        }
        do {
            let cloud = try await Task.detached(priority: .userInitiated) { try PLYReader.read(url: url) }.value
            let buffer = try SharedPointBuffer(device: env.context.device, capacity: max(cloud.count, 1))
            buffer.append(cloud.points)
            let r = try GhostMapRenderer(context: env.context, pipeline: env.pipeline, pointBuffer: buffer, trajectory: nil, clock: nil)
            r.camera.mode = .orbit
            r.camera.autoOrbit = false
            r.pointAlpha = 1
            r.pointSizePx = 4
            r.maxPoints = 3_000_000
            r.skipWhenMainIsBehind = false
            r.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
            r.camera.frame(bounds: cloud.bounds)
            r.camera.snapToTarget()
            renderer = r
            loadedPoints = cloud.count
        } catch {
            loadError = String(describing: error)
        }
    }

    private func toggleMode() {
        topDown.toggle()
        renderer?.camera.mode = topDown ? .topDown : .orbit
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { name = summary.manifest.name; return }
        try? env.store.rename(id: summary.manifest.mapID, to: trimmed)
        onChanged()
    }

    private func deleteMap() {
        try? env.store.delete(id: summary.manifest.mapID)
        onChanged()
        dismiss()
    }
}
