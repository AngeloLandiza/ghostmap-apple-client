import MapCore
import SwiftUI

struct MapListView: View {
    let env: AppEnvironment
    @State private var maps: [MapSummary] = []
    @State private var showCapture = false
    @State private var renaming: MapSummary?
    @State private var newName = ""
    @State private var rebuilding: Set<MapID> = []
    @State private var errorMessage: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if maps.isEmpty && loaded {
                    ContentUnavailableView("No maps yet", systemImage: "cube.transparent", description: Text("Tap Scan to map a room. Every map stays on this phone."))
                } else {
                    List {
                        ForEach(maps, id: \.manifest.mapID) { summary in
                            NavigationLink(value: summary.manifest.mapID) {
                                MapRow(summary: summary, isRebuilding: rebuilding.contains(summary.manifest.mapID), hasLog: hasLog(summary), onRebuild: { rebuild(summary) })
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { delete(summary.manifest.mapID) } label: { Label("Delete", systemImage: "trash") }
                                Button { beginRename(summary) } label: { Label("Rename", systemImage: "pencil") }.tint(.blue)
                            }
                            .contextMenu {
                                Button { beginRename(summary) } label: { Label("Rename", systemImage: "pencil") }
                                Button(role: .destructive) { delete(summary.manifest.mapID) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Maps")
            .navigationDestination(for: MapID.self) { id in
                if let summary = maps.first(where: { $0.manifest.mapID == id }) {
                    MapDetailView(env: env, summary: summary, onChanged: reload)
                } else {
                    ContentUnavailableView("Map not found", systemImage: "questionmark.folder")
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showCapture = true } label: { Label("Scan", systemImage: "camera.viewfinder") }
                }
            }
            .fullScreenCover(isPresented: $showCapture, onDismiss: reload) {
                CaptureView(env: env)
            }
            .alert("Rename map", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { reload() }
            .refreshable { reload() }
        }
    }

    private func hasLog(_ summary: MapSummary) -> Bool {
        FileManager.default.fileExists(atPath: env.store.url(for: .keyframeLog, in: summary.manifest.mapID).path)
    }

    private func reload() {
        let store = env.store
        Task {
            let list = await Task.detached { (try? store.list()) ?? [] }.value
            maps = list
            loaded = true
        }
    }

    private func delete(_ id: MapID) {
        do {
            try env.store.delete(id: id)
        } catch {
            errorMessage = "Delete failed: \(error)"
        }
        reload()
    }

    private func beginRename(_ summary: MapSummary) {
        newName = summary.manifest.name
        renaming = summary
    }

    private func commitRename() {
        guard let renaming else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            do {
                try env.store.rename(id: renaming.manifest.mapID, to: trimmed)
            } catch {
                errorMessage = "Rename failed: \(error)"
            }
        }
        self.renaming = nil
        reload()
    }

    private func rebuild(_ summary: MapSummary) {
        let id = summary.manifest.mapID
        guard !rebuilding.contains(id) else { return }
        rebuilding.insert(id)
        Task {
            do {
                try await MapRebuildService.rebuild(id: id, env: env)
            } catch {
                errorMessage = "Rebuild failed: \(error)"
            }
            rebuilding.remove(id)
            reload()
        }
    }
}

struct MapRow: View {
    let summary: MapSummary
    var isRebuilding = false
    var hasLog = false
    var onRebuild: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.manifest.name).font(.headline).lineLimit(1)
                Text("\(Format.count(summary.manifest.pointCount)) pts · \(summary.manifest.keyframeCount) kf · \(Format.duration(summary.manifest.durationSeconds)) · \(Format.bytes(summary.sizeBytes))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    StatusBadge(status: summary.manifest.status)
                    if summary.manifest.status == .failed && hasLog {
                        Button(action: onRebuild) {
                            if isRebuilding { ProgressView().controlSize(.mini) } else { Text("Rebuild").font(.caption2.weight(.semibold)) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(isRebuilding)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if summary.hasThumbnail, let image = UIImage(contentsOfFile: summary.directoryURL.appendingPathComponent(MapFile.thumbnail.rawValue).path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.gray.opacity(0.25)
                Image(systemName: "cube.transparent").foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusBadge: View {
    let status: MapStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .saved: return .green
        case .recording, .finalizing: return .orange
        case .failed: return .red
        }
    }
}
