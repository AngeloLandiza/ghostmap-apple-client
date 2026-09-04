import Foundation
import MapCore
import os

/// One step of an upload, for the progress bar in `MapDetailView` and the map list.
enum MapUploadStage: Sendable, Equatable {
    case creatingRecord
    case uploadingFile(CloudMapFile)
    case finalizing
}

/// A snapshot of how far one map's upload has gotten.
struct MapUploadProgress: Sendable, Equatable {
    var stage: MapUploadStage
    var completedFiles: Int
    var totalFiles: Int

    var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(completedFiles) / Double(totalFiles)
    }
}

/// One map's upload state, as `AppEnvironment` tracks it for the map list and the detail view.
/// `idle` also covers "never tried" and "tried, then dismissed" — there is nothing to show either
/// way, only the manifest's `cloudMapId` says whether a previous upload actually succeeded.
enum MapUploadStatus: Sendable, Equatable {
    case idle
    case uploading(MapUploadProgress)
    case succeeded(cloudMapId: String)
    case failed(String)

    var isUploading: Bool {
        if case .uploading = self { return true }
        return false
    }
}

/// Reports progress back to the caller. Declared `@MainActor` so a view model can update
/// `@Observable` state directly from inside it — `MapUploader` hops there to call it and does
/// nothing else on that actor.
typealias MapUploadProgressHandler = @MainActor @Sendable (MapUploadProgress) -> Void

/// Everything that can go wrong uploading a map.
enum MapUploaderError: Error, Sendable, Equatable, LocalizedError {
    /// `cloud.ply` is not on disk. The backend requires it before it will finalize a map, so there
    /// is no point starting.
    case cloudMissing
    /// A backend call (create, upload-urls or finalize) failed.
    case api(GhostmapAPIError)
    /// `cloud.ply` itself failed to reach storage; every other file is best-effort.
    case uploadFailed(CloudMapFile)

    var errorDescription: String? {
        switch self {
        case .cloudMissing:
            return "This map has no point cloud yet — finalize it on this phone first."
        case .api(let error):
            return error.localizedDescription
        case .uploadFailed(let file):
            return "Uploading \(file.rawValue) failed. Check your connection and try again."
        }
    }

    /// The token is missing or rejected — the UI should point at Settings, not just "try again".
    var requiresSignIn: Bool {
        if case .api(let error) = self { return error.requiresSignIn }
        return false
    }
}

/// Uploads one on-device map folder to the Ghostmap backend: `POST /v1/maps` (or `/upload-urls`
/// for a re-upload) → PUT every present file to its signed URL → `POST /v1/maps/:id/finalize`.
///
/// One actor, reused for every map: it owns nothing about *which* map is uploading, so several
/// uploads could in principle run concurrently (the caller serializes per map id in
/// `AppEnvironment`, since a second tap on "Upload" while one is in flight is a no-op, not a
/// second race).
///
/// Small files (`manifest.json`, `thumbnail.png`, `session.log`, `worldmap.arworldmap`) go up as a
/// single `PUT` of the whole file's bytes — a few hundred KB at most. `cloud.ply` and
/// `keyframes.bin` can be tens of megabytes, so the backend mints *resumable* tickets for them
/// (PLAN §5, API.md): an empty-body `POST` opens the session, the `Location` response header names
/// where the bytes actually go, and that `PUT` reads straight off disk with
/// `URLSession.uploadTask(with:fromFile:)` instead of first loading the whole point cloud into a
/// `Data` in this process.
actor MapUploader {
    private let api: GhostmapAPI
    private let session: URLSession
    private let log = SessionLogger.osLogger(.cloud)

    init(api: GhostmapAPI, session: URLSession = MapUploader.makeSession()) {
        self.api = api
        self.session = session
    }

    /// Uploads can carry a multi-minute point cloud on a slow connection, so this session is
    /// happy to wait for connectivity rather than fail fast the way `KeyframeStreamer`'s does.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 10 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    /// Uploads `directory` (a `MapStore` map folder matching `manifest`).
    ///
    /// With `existingCloudMapId` nil this registers a brand-new cloud map (`POST /v1/maps`); with
    /// one set — a map that was uploaded before — it instead asks for fresh tickets on the same
    /// cloud record (`POST /v1/maps/:id/upload-urls`), so re-uploading after an edit or a failed
    /// attempt does not pile up duplicate cloud maps.
    ///
    /// Every file that exists on disk from `CloudMapFile.defaults` (plus the world map when the
    /// manifest says it was saved) is uploaded; `cloud.ply` failing aborts the whole attempt
    /// (`.uploadFailed(.cloud)`) since the backend refuses to finalize without it, but any other
    /// file failing is only logged — finalize still runs, and the map is saved with whatever made
    /// it up, matching how `KeyframeStreamer` degrades rather than losing the whole keyframe.
    func upload(
        manifest: MapManifest,
        directory: URL,
        existingCloudMapId: String? = nil,
        onProgress: MapUploadProgressHandler? = nil
    ) async throws(MapUploaderError) -> CloudMap {
        let files = Self.candidateFiles(for: manifest, directory: directory)
        guard files.contains(.cloud) else { throw .cloudMissing }

        await onProgress?(MapUploadProgress(stage: .creatingRecord, completedFiles: 0, totalFiles: files.count))

        let mapId: String
        let uploads: [SignedUpload]
        do {
            if let existingCloudMapId {
                mapId = existingCloudMapId
                uploads = try await api.mapUploadURLs(mapId: existingCloudMapId, files: files).uploads
            } else {
                let request = CreateMapRequest(
                    name: manifest.name,
                    frame: manifest.frame,
                    origin: CloudOrigin(type: manifest.origin.type, markerId: manifest.origin.markerID),
                    files: files
                )
                let created = try await api.createMap(request)
                mapId = created.map.id
                uploads = created.uploads
            }
        } catch {
            throw .api(error)
        }

        var completed = 0
        var failed: [CloudMapFile] = []
        for file in files {
            await onProgress?(MapUploadProgress(stage: .uploadingFile(file), completedFiles: completed, totalFiles: files.count))
            guard let ticket = uploads.first(where: { $0.path.hasSuffix("/" + file.rawValue) }) else {
                log.error("no upload ticket for \(file.rawValue, privacy: .public)")
                failed.append(file)
                continue
            }
            let fileURL = directory.appendingPathComponent(file.rawValue, isDirectory: false)
            let ok = ticket.resumable == true
                ? await putResumable(fileURL, ticket: ticket)
                : await putDirect(fileURL, ticket: ticket)
            if ok {
                completed += 1
            } else {
                failed.append(file)
                log.error("upload failed for \(file.rawValue, privacy: .public)")
            }
        }
        guard !failed.contains(.cloud) else { throw .uploadFailed(.cloud) }

        await onProgress?(MapUploadProgress(stage: .finalizing, completedFiles: completed, totalFiles: files.count))
        let manifestJSON = Self.manifestJSON(manifest)
        do {
            let finalized = try await api.finalizeMap(mapId: mapId, manifest: manifestJSON)
            log.notice("map \(mapId, privacy: .public) uploaded: \(completed, privacy: .public)/\(files.count, privacy: .public) files")
            return finalized.map
        } catch {
            throw .api(error)
        }
    }

    // MARK: - File selection

    /// `CloudMapFile.defaults`, plus the world map when the manifest says one was saved, filtered
    /// to what is actually on disk — a map made before some file existed (or a partial write) just
    /// uploads less rather than failing outright.
    private static func candidateFiles(for manifest: MapManifest, directory: URL) -> [CloudMapFile] {
        var candidates = CloudMapFile.defaults
        if manifest.hasWorldMap { candidates.append(.worldMap) }
        let fileManager = FileManager.default
        return candidates.filter { fileManager.fileExists(atPath: directory.appendingPathComponent($0.rawValue).path) }
    }

    /// The manifest as the `JSONValue` `POST /v1/maps/:id/finalize` wants, so the saved map row
    /// reflects exactly what is on this phone rather than whatever `manifest.json` happens to
    /// decode to on the backend after the upload above.
    private static func manifestJSON(_ manifest: MapManifest) -> JSONValue? {
        guard let data = try? manifest.encoded() else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: - Transport

    /// One `PUT` of the whole file, for the handful-of-KB files. `GhostmapAPI.performOnce` uses
    /// the same `session.data(for:)` shape for its JSON bodies.
    private func putDirect(_ fileURL: URL, ticket: SignedUpload) async -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else {
            log.error("could not read \(fileURL.lastPathComponent, privacy: .public) to upload")
            return false
        }
        guard let url = URL(string: ticket.url) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = ticket.method.isEmpty ? "PUT" : ticket.method
        for (field, value) in ticket.headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = data
        do {
            let (_, response) = try await session.data(for: request)
            return Self.isSuccess(response)
        } catch {
            log.error("PUT \(fileURL.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// GCS's resumable protocol (API.md): an empty-body `POST` with the ticket's headers opens the
    /// session; the `Location` it answers with is where the bytes actually go. That `PUT` streams
    /// straight from `fileURL` — a completion-handler `uploadTask`, bridged with a continuation, is
    /// what lets it read from disk instead of through an `async` API that would need the file in
    /// memory as `Data` first.
    private func putResumable(_ fileURL: URL, ticket: SignedUpload) async -> Bool {
        guard let openURL = URL(string: ticket.url) else { return false }
        var openRequest = URLRequest(url: openURL)
        openRequest.httpMethod = "POST"
        for (field, value) in ticket.headers { openRequest.setValue(value, forHTTPHeaderField: field) }
        openRequest.setValue("0", forHTTPHeaderField: "Content-Length")

        let opened: (Data, URLResponse)
        do {
            opened = try await session.data(for: openRequest)
        } catch {
            log.error("resumable open for \(fileURL.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return false
        }
        guard Self.isSuccess(opened.1),
              let http = opened.1 as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location"),
              let putURL = URL(string: location) else {
            log.error("resumable open for \(fileURL.lastPathComponent, privacy: .public) returned no Location")
            return false
        }

        var putRequest = URLRequest(url: putURL)
        putRequest.httpMethod = "PUT"
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let task = session.uploadTask(with: putRequest, fromFile: fileURL) { _, response, error in
                if error != nil {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: Self.isSuccess(response))
            }
            task.resume()
        }
    }

    private static func isSuccess(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }
}
