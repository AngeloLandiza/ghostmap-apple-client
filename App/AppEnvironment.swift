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
    private(set) var interruptedMapIDs: [MapID] = []

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
        account = AccountStore(api: api)
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

    /// Validates and stores a new backend URL, and points the API client at it.
    /// Throws without changing anything when the text is not a usable http(s) URL.
    @discardableResult
    func setBackendURL(_ raw: String) throws(BackendURL.ValidationError) -> URL {
        let url = try BackendURL.normalized(raw)
        cloud.backendURLString = url.absoluteString
        Task { await api.setBaseURL(url) }
        return url
    }
}
