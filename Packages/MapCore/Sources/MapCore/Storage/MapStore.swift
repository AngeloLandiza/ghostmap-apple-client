import Foundation

/// The files that can live in one map directory (`<rootURL>/<mapID>/`). The raw value is the file
/// name. Only `manifest.json` is mandatory; the others appear as a recording progresses and is
/// finalized.
public enum MapFile: String, CaseIterable, Sendable {
    /// `MapManifest` as JSON; written atomically, present from `MapStore.create` onwards.
    case manifest = "manifest.json"
    /// The append-only keyframe log (`KeyframeLogWriter`).
    case keyframeLog = "keyframes.bin"
    /// The finalized point cloud (`PLYWriter`).
    case cloud = "cloud.ply"
    /// A 512×512 PNG preview rendered at finalize time.
    case thumbnail = "thumbnail.png"
    /// The archived `ARWorldMap`, when ARKit reported a mapped session at finalize time.
    case worldMap = "worldmap.arworldmap"
    /// Human-readable session log lines (`SessionLogger`).
    case sessionLog = "session.log"
}

/// One row of `MapStore.list()`: the manifest plus a few facts about the directory.
public struct MapSummary: Sendable, Equatable {
    /// The decoded `manifest.json`.
    public var manifest: MapManifest
    /// The map directory.
    public var directoryURL: URL
    /// Sum of the sizes of every file in the directory, in bytes.
    public var sizeBytes: Int64
    /// True when `thumbnail.png` exists.
    public var hasThumbnail: Bool
    /// True when `cloud.ply` exists.
    public var hasCloud: Bool

    /// Creates a summary.
    public init(manifest: MapManifest, directoryURL: URL, sizeBytes: Int64, hasThumbnail: Bool, hasCloud: Bool) {
        self.manifest = manifest
        self.directoryURL = directoryURL
        self.sizeBytes = sizeBytes
        self.hasThumbnail = hasThumbnail
        self.hasCloud = hasCloud
    }
}

/// The on-device map library: one directory per map under `rootURL`
/// (`…/Application Support/Maps/<mapID>/` in the app), each holding a `manifest.json` and the files
/// listed in `MapFile`.
///
/// `MapStore` is `Sendable` because its only state is the immutable `rootURL`; every operation
/// goes through `FileManager.default` at call time and the file system is the sole source of
/// truth, so instances may be shared freely between actors and queues. Manifests are always
/// written atomically (`Data.write(options: .atomic)`), so a reader never sees a partial file.
public final class MapStore: Sendable {
    /// The directory that contains every map directory.
    public let rootURL: URL

    /// Creates the store, creating `rootURL` (and any missing parents) if needed.
    /// Throws `MapError.io` when the directory cannot be created.
    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            throw MapError.io("creating map root \(rootURL.path): \(error.localizedDescription)")
        }
    }

    /// `rootURL/<id.rawValue>/`.
    public func directoryURL(for id: MapID) -> URL {
        rootURL.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    /// `directoryURL(for: id)/<file.rawValue>`.
    public func url(for file: MapFile, in id: MapID) -> URL {
        directoryURL(for: id).appendingPathComponent(file.rawValue, isDirectory: false)
    }

    /// Creates the directory for `manifest.mapID` and writes the manifest into it. Returns the map
    /// directory. Callers create maps in `.recording` and move them through `.finalizing` to
    /// `.saved` with `saveManifest`. Throws `MapError.io` when the directory already exists or
    /// cannot be created or written.
    @discardableResult
    public func create(manifest: MapManifest) throws -> URL {
        let directory = directoryURL(for: manifest.mapID)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw MapError.io("map \(manifest.mapID) already exists at \(directory.path)")
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MapError.io("creating map directory \(directory.path): \(error.localizedDescription)")
        }
        try write(manifest, to: url(for: .manifest, in: manifest.mapID))
        return directory
    }

    /// Replaces `manifest.json` of `manifest.mapID` atomically. Throws `MapError.mapNotFound` when
    /// the map directory does not exist and `MapError.io` on a write failure.
    public func saveManifest(_ manifest: MapManifest) throws {
        guard exists(id: manifest.mapID) else {
            throw MapError.mapNotFound(manifest.mapID)
        }
        try write(manifest, to: url(for: .manifest, in: manifest.mapID))
    }

    /// Reads and decodes `manifest.json`. Throws `MapError.mapNotFound` when the directory or the
    /// file is missing, `MapError.io` when the file cannot be read and `MapError.invalidManifest`
    /// when it is not a valid manifest.
    public func loadManifest(id: MapID) throws -> MapManifest {
        let manifestURL = url(for: .manifest, in: id)
        guard exists(id: id), FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw MapError.mapNotFound(id)
        }
        return try readManifest(at: manifestURL)
    }

    /// Every subdirectory of `rootURL` whose `manifest.json` decodes, newest `createdAt` first
    /// (ties broken by map id). Directories without a readable manifest and plain files are
    /// skipped, never reported. Throws `MapError.io` only when `rootURL` itself cannot be listed.
    public func list() throws -> [MapSummary] {
        let fileManager = FileManager.default
        return try readableManifests().map { directory, manifest in
            MapSummary(
                manifest: manifest,
                directoryURL: directory,
                sizeBytes: MapStore.size(ofDirectory: directory),
                hasThumbnail: fileManager.fileExists(atPath: directory.appendingPathComponent(MapFile.thumbnail.rawValue).path),
                hasCloud: fileManager.fileExists(atPath: directory.appendingPathComponent(MapFile.cloud.rawValue).path)
            )
        }
    }

    /// Removes the map directory and everything in it. Throws `MapError.mapNotFound` when the
    /// directory does not exist and `MapError.io` when it cannot be removed.
    public func delete(id: MapID) throws {
        let directory = directoryURL(for: id)
        guard exists(id: id) else {
            throw MapError.mapNotFound(id)
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw MapError.io("deleting map \(id): \(error.localizedDescription)")
        }
    }

    /// Loads the manifest, sets `name` and saves it. Throws like `loadManifest` and `saveManifest`.
    public func rename(id: MapID, to name: String) throws {
        var manifest = try loadManifest(id: id)
        manifest.name = name
        try saveManifest(manifest)
    }

    /// Sum of the sizes of every regular file under the map directory (recursively), in bytes;
    /// `0` when the directory does not exist.
    public func directorySize(id: MapID) -> Int64 {
        MapStore.size(ofDirectory: directoryURL(for: id))
    }

    /// Marks every map still in `.recording` or `.finalizing` as `.failed` (a recording that did
    /// not finish because the app was killed) and returns their ids, newest first. Maps in any
    /// other status are untouched. Throws `MapError.io` when `rootURL` cannot be listed or a
    /// manifest cannot be rewritten.
    public func markInterruptedRecordings() throws -> [MapID] {
        var interrupted: [MapID] = []
        for (directory, manifest) in try readableManifests() {
            guard manifest.status == .recording || manifest.status == .finalizing else { continue }
            var failed = manifest
            failed.status = .failed
            try write(failed, to: directory.appendingPathComponent(MapFile.manifest.rawValue))
            interrupted.append(manifest.mapID)
        }
        return interrupted
    }

    /// True when the map directory exists.
    public func exists(id: MapID) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directoryURL(for: id).path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: - Internals

    /// Every immediate subdirectory of `rootURL` whose name is a map id and whose `manifest.json`
    /// decodes with that same `map_id`, sorted newest first (then by map id for a stable order). Entry URLs are built from `rootURL` (not from
    /// the file system's resolved paths) so they compare equal to `directoryURL(for:)`.
    func readableManifests() throws -> [(directory: URL, manifest: MapManifest)] {
        let fileManager = FileManager.default
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: rootURL.path)
        } catch {
            throw MapError.io("listing \(rootURL.path): \(error.localizedDescription)")
        }

        var found: [(directory: URL, manifest: MapManifest)] = []
        for name in names where !name.hasPrefix(".") {
            let entry = rootURL.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            let manifestURL = entry.appendingPathComponent(MapFile.manifest.rawValue)
            guard let manifest = try? readManifest(at: manifestURL) else { continue }
            // FORMAT.md §2: `map_id` equals the directory name. A directory that breaks the
            // invariant (a copy made through file sharing, a restored duplicate) would be listed
            // under an id that resolves to a different directory, so every id-keyed operation —
            // `delete` above all — would target the original map. Treat it as unreadable.
            guard name == manifest.mapID.rawValue else { continue }
            found.append((entry, manifest))
        }
        found.sort { lhs, rhs in
            if lhs.manifest.createdAt != rhs.manifest.createdAt {
                return lhs.manifest.createdAt > rhs.manifest.createdAt
            }
            return lhs.manifest.mapID.rawValue < rhs.manifest.mapID.rawValue
        }
        return found
    }

    /// Encodes and writes a manifest atomically.
    func write(_ manifest: MapManifest, to manifestURL: URL) throws {
        let data: Data
        do {
            data = try manifest.encoded()
        } catch {
            throw MapError.invalidManifest("encoding manifest \(manifest.mapID): \(error)")
        }
        do {
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            throw MapError.io("writing \(manifestURL.path): \(error.localizedDescription)")
        }
    }

    /// Reads and decodes a manifest file that is expected to exist.
    func readManifest(at manifestURL: URL) throws -> MapManifest {
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw MapError.io("reading \(manifestURL.path): \(error.localizedDescription)")
        }
        return try MapManifest.decode(data)
    }

    /// Recursive sum of regular-file sizes under `directory`; `0` when it does not exist.
    static func size(ofDirectory directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: nil
        ) else {
            return 0
        }
        var total: Int64 = 0
        while let element = enumerator.nextObject() {
            guard let fileURL = element as? URL,
                  let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize else {
                continue
            }
            total += Int64(size)
        }
        return total
    }
}
