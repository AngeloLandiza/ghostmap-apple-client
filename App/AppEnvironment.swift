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
    private(set) var interruptedMapIDs: [MapID] = []

    var settings: CaptureSettings {
        didSet { settings.save() }
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
}
