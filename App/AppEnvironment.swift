import Foundation
import MapCore
import Observation

/// App-wide services: Metal, the map store, thermal monitoring and persisted settings.
@Observable
@MainActor
final class AppEnvironment {
    let context: MetalContext
    let pipeline: PointCloudPipeline
    let store: MapStore
    let thermal = ThermalMonitor()
    /// Typed client for the Ghostmap backend. It exists even when signed out — only `/health`
    /// works then — so the Settings screen can test a URL before anyone signs in.
    let api: GhostmapAPI
    /// The signed-in account and this phone's identity.
    let account: AccountStore
    /// The collaborative session this phone is in, if any, plus the peers' live clouds.
    let party: PartySession
    /// Uploads a map folder to the backend (Phase 2 §5). Stateless itself; `uploadStatus` below is
    /// the observable state a view actually reads.
    let uploader: MapUploader
    /// An invite code handed to the app by a `ghostmap://join/<code>` link, waiting for the party
    /// screen to pick it up.
    var pendingJoinCode: String?
    private(set) var interruptedMapIDs: [MapID] = []
    /// Where each map's cloud upload stands, keyed by map id. Read by the map list (for the cloud
    /// badge) and the detail view (for the progress bar and any error); written only from
    /// `uploadMap`. A map with no entry has never been uploaded this launch — check
    /// `manifest.cloudMapId` for "uploaded in an earlier launch".
    private(set) var uploadStatus: [MapID: MapUploadStatus] = [:]

    var settings: CaptureSettings {
        didSet { settings.save() }
    }

    var cloud: CloudSettings {
        didSet { cloud.save() }
    }

    /// Maps live under Documents/Maps so the Files app can show them (UIFileSharingEnabled exposes
    /// only the Documents directory; see DECISIONS.md).
    static func mapsRootURL() throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return docs.appendingPathComponent("Maps", isDirectory: true)
    }

    init() throws {
        context = try MetalContext()
        pipeline = try PointCloudPipeline(context: context, colorFormat: .bgra8Unorm, depthFormat: .depth32Float)
        store = try MapStore(rootURL: try AppEnvironment.mapsRootURL())
        settings = CaptureSettings.load()
        let cloudSettings = CloudSettings.load()
        cloud = cloudSettings
        // A stored URL that no longer parses falls back to production rather than failing launch.
        api = GhostmapAPI(baseURL: try CloudSettings.resolvedURL(cloudSettings.backendURLString))
        let account = AccountStore(api: api)
        self.account = account
        party = PartySession(api: api, account: account, device: context.device)
        uploader = MapUploader(api: api)
        let logger = SessionLogger.osLogger(.app)
        do {
            interruptedMapIDs = try store.markInterruptedRecordings()
            if !interruptedMapIDs.isEmpty {
                logger.notice("marked \(self.interruptedMapIDs.count) interrupted recording(s) as failed")
            }
        } catch {
            logger.error("markInterruptedRecordings failed: \(String(describing: error), privacy: .public)")
        }
        logger.info("maps root: \(self.store.rootURL.path, privacy: .public)")
    }

    /// Accepts a `ghostmap://join/<code>` deep link (or a dashboard share link). Returns false when
    /// the URL is not a join link, so the caller can ignore it.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let code = PartyCode.code(from: url) else { return false }
        pendingJoinCode = code
        SessionLogger.osLogger(.app).notice("join link received for party \(code, privacy: .public)")
        return true
    }

    /// Validates and stores a new backend URL, and points the API client at it.
    /// Throws without changing anything when the text is not a usable http(s) URL.
    @discardableResult
    func setBackendURL(_ raw: String) throws(BackendURL.ValidationError) -> URL {
        let url = try BackendURL.normalized(raw)
        cloud.backendURLString = url.absoluteString
        Task { await api.setBaseURL(url) }
        return url
    }

    // MARK: - Cloud upload (Phase 2 §5)

    /// Starts uploading `id` if it is not already uploading, from the "Upload maps to cloud"
    /// setting after a save and from the Upload button in `MapDetailView`. A map already uploaded
    /// this launch (`cloudMapId` set) is re-uploaded onto the same cloud record rather than
    /// creating a second one.
    @discardableResult
    func uploadMap(id: MapID) -> Task<Void, Never> {
        if uploadStatus[id]?.isUploading == true { return Task {} }
        return Task { [weak self] in await self?.runUpload(id: id) }
    }

    private func runUpload(id: MapID) async {
        guard account.canMap else {
            uploadStatus[id] = .failed("Sign in as this phone in Settings to upload maps.")
            return
        }
        let manifest: MapManifest
        do {
            manifest = try store.loadManifest(id: id)
        } catch {
            uploadStatus[id] = .failed("Map not found on this phone.")
            return
        }
        uploadStatus[id] = .uploading(MapUploadProgress(stage: .creatingRecord, completedFiles: 0, totalFiles: 0))
        let directory = store.directoryURL(for: id)
        let existingCloudMapId = manifest.cloudMapId
        do {
            let cloudMap = try await uploader.upload(
                manifest: manifest,
                directory: directory,
                existingCloudMapId: existingCloudMapId
            ) { [weak self] progress in
                self?.uploadStatus[id] = .uploading(progress)
            }
            var saved = manifest
            saved.cloudMapId = cloudMap.id
            try? store.saveManifest(saved)
            uploadStatus[id] = .succeeded(cloudMapId: cloudMap.id)
            SessionLogger.osLogger(.cloud).notice("map \(id.rawValue, privacy: .public) uploaded as \(cloudMap.id, privacy: .public)")
        } catch {
            uploadStatus[id] = .failed(error.localizedDescription)
            SessionLogger.osLogger(.cloud).error("upload of \(id.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
