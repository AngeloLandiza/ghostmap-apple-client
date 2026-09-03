import Foundation
import MapCore
import UIKit

/// Rebuilds `cloud.ply` and the thumbnail from `keyframes.bin` for a map whose recording was
/// interrupted (status `failed`). The log carries no color, so points are confidence-tinted gray.
enum MapRebuildService {
    @MainActor
    static func rebuild(id: MapID, env: AppEnvironment) async throws {
        let store = env.store
        var manifest = try store.loadManifest(id: id)
        let logURL = store.url(for: .keyframeLog, in: id)
        let plyURL = store.url(for: .cloud, in: id)
        guard FileManager.default.fileExists(atPath: logURL.path) else { throw MapError.io("no keyframe log to rebuild from") }
        manifest.status = .finalizing
        try store.saveManifest(manifest)
        let logger = SessionLogger(fileURL: store.url(for: .sessionLog, in: id))
        logger.log(.storage, "rebuild started")
        let started = Date()

        let result = try await Task.detached(priority: .userInitiated) { () throws -> CloudRebuilder.Result in
            let r = try CloudRebuilder.rebuild(logURL: logURL)
            try PLYWriter.write(points: r.cloud.points, to: plyURL, comments: ["RoomMapper rebuilt from keyframes.bin", "frame world:session-start"])
            return r
        }.value

        let buffer = try SharedPointBuffer(device: env.context.device, capacity: max(result.cloud.count, 1))
        buffer.append(result.cloud.points)
        let renderer = try GhostMapRenderer(context: env.context, pipeline: env.pipeline, pointBuffer: buffer, trajectory: nil, clock: nil)
        if let image = renderer.renderThumbnail(size: 512), let png = UIImage(cgImage: image).pngData() {
            try png.write(to: store.url(for: .thumbnail, in: id), options: .atomic)
        }

        manifest.pointCount = result.cloud.count
        manifest.keyframeCount = result.keyframeCount
        manifest.bbox = result.cloud.bounds.isEmpty ? nil : result.cloud.bounds
        manifest.status = .saved
        manifest.finalizeSeconds = Date().timeIntervalSince(started)
        manifest.sizeBytes = store.directorySize(id: id) + 2048
        try store.saveManifest(manifest)
        logger.log(.storage, "rebuild done: keyframes=\(result.keyframeCount) points=\(result.cloud.count) truncatedAt=\(result.scan.truncatedAtOffset.map(String.init) ?? "none") corruptedAt=\(result.scan.corruptedAtOffset.map(String.init) ?? "none") in \(String(format: "%.2f", manifest.finalizeSeconds ?? 0)) s")
        await logger.close()
    }
}
