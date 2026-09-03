import Foundation
import XCTest
@testable import MapCore

final class MapStoreTests: XCTestCase {
    private var root: URL!
    private var store: MapStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MapStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Maps", isDirectory: true)
        store = try MapStore(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: - Fixtures

    private func makeManifest(name: String = "Room",
                              createdAt: TimeInterval = 1_000,
                              status: MapStatus = .recording) -> MapManifest {
        MapManifest(
            name: name,
            createdAt: Date(timeIntervalSince1970: createdAt),
            deviceModel: "iPhone17,2",
            iosVersion: "27.0",
            status: status
        )
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    private func assertMapNotFound(_ id: MapID, _ body: () throws -> Void,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? MapError, .mapNotFound(id), file: file, line: line)
        }
    }

    private func assertIO(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let mapError = error as? MapError, case .io = mapError else {
                return XCTFail("expected MapError.io, got \(error)", file: file, line: line)
            }
        }
    }

    // MARK: - init / URLs

    func testInitCreatesRootWithIntermediateDirectories() throws {
        XCTAssertTrue(isDirectory(root))
        let nested = root.appendingPathComponent("a/b/c", isDirectory: true)
        let other = try MapStore(rootURL: nested)
        XCTAssertEqual(other.rootURL, nested)
        XCTAssertTrue(isDirectory(nested))
        // A second store on an existing directory is fine.
        _ = try MapStore(rootURL: nested)
    }

    func testMapFileNames() {
        XCTAssertEqual(MapFile.manifest.rawValue, "manifest.json")
        XCTAssertEqual(MapFile.keyframeLog.rawValue, "keyframes.bin")
        XCTAssertEqual(MapFile.cloud.rawValue, "cloud.ply")
        XCTAssertEqual(MapFile.thumbnail.rawValue, "thumbnail.png")
        XCTAssertEqual(MapFile.worldMap.rawValue, "worldmap.arworldmap")
        XCTAssertEqual(MapFile.sessionLog.rawValue, "session.log")
        XCTAssertEqual(MapFile.allCases.count, 6)
    }

    func testDirectoryAndFileURLs() {
        let id = MapID()
        let directory = store.directoryURL(for: id)
        XCTAssertEqual(directory.lastPathComponent, id.rawValue)
        XCTAssertEqual(directory.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(store.url(for: .cloud, in: id).path, directory.appendingPathComponent("cloud.ply").path)
        XCTAssertEqual(store.url(for: .manifest, in: id).lastPathComponent, "manifest.json")
        XCTAssertEqual(store.url(for: .keyframeLog, in: id).deletingLastPathComponent().path, directory.path)
    }

    // MARK: - create / load

    func testCreateWritesManifestAndReturnsDirectory() throws {
        let manifest = makeManifest()
        let id = manifest.mapID
        XCTAssertFalse(store.exists(id: id))

        let directory = try store.create(manifest: manifest)
        XCTAssertEqual(directory.path, store.directoryURL(for: id).path)
        XCTAssertTrue(store.exists(id: id))
        XCTAssertTrue(isDirectory(directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: .manifest, in: id).path))
        XCTAssertEqual(try store.loadManifest(id: id), manifest)
        // The file on disk is exactly the manifest's own encoding.
        XCTAssertEqual(try Data(contentsOf: store.url(for: .manifest, in: id)), try manifest.encoded())
    }

    func testCreateTwiceThrowsIO() throws {
        let manifest = makeManifest()
        try store.create(manifest: manifest)
        assertIO { try store.create(manifest: manifest) }
        var renamed = manifest
        renamed.name = "Other"
        assertIO { try store.create(manifest: renamed) }
        XCTAssertEqual(try store.loadManifest(id: manifest.mapID).name, "Room", "the existing manifest is untouched")
    }

    func testLoadManifestMissingThrowsMapNotFound() throws {
        let id = MapID()
        assertMapNotFound(id) { _ = try store.loadManifest(id: id) }
        // Directory without a manifest file is also "not found".
        try FileManager.default.createDirectory(at: store.directoryURL(for: id), withIntermediateDirectories: true)
        assertMapNotFound(id) { _ = try store.loadManifest(id: id) }
    }

    func testLoadManifestGarbageThrowsInvalidManifest() throws {
        let id = MapID()
        try FileManager.default.createDirectory(at: store.directoryURL(for: id), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url(for: .manifest, in: id))
        XCTAssertThrowsError(try store.loadManifest(id: id)) { error in
            guard let mapError = error as? MapError, case .invalidManifest = mapError else {
                return XCTFail("expected MapError.invalidManifest, got \(error)")
            }
        }
    }

    func testSaveManifestOverwritesAtomically() throws {
        var manifest = makeManifest()
        try store.create(manifest: manifest)
        manifest.status = .saved
        manifest.pointCount = 12_345
        manifest.keyframeCount = 67
        try store.saveManifest(manifest)
        XCTAssertEqual(try store.loadManifest(id: manifest.mapID), manifest)
        // No temporary files left next to the manifest.
        let contents = try FileManager.default.contentsOfDirectory(atPath: store.directoryURL(for: manifest.mapID).path)
        XCTAssertEqual(contents, ["manifest.json"])
    }

    func testSaveManifestMissingThrowsMapNotFound() {
        let manifest = makeManifest()
        assertMapNotFound(manifest.mapID) { try store.saveManifest(manifest) }
        XCTAssertFalse(store.exists(id: manifest.mapID))
    }

    // MARK: - list

    func testListEmptyStore() throws {
        XCTAssertEqual(try store.list(), [])
    }

    func testListSortsNewestFirst() throws {
        let m1 = makeManifest(name: "one", createdAt: 1)
        let m2 = makeManifest(name: "two", createdAt: 2)
        let m3 = makeManifest(name: "three", createdAt: 3)
        // Create out of order to prove the sort is by createdAt, not by creation sequence.
        try store.create(manifest: m2)
        try store.create(manifest: m3)
        try store.create(manifest: m1)

        let summaries = try store.list()
        XCTAssertEqual(summaries.map(\.manifest.mapID), [m3.mapID, m2.mapID, m1.mapID])
        XCTAssertEqual(summaries.map(\.manifest.name), ["three", "two", "one"])
        for summary in summaries {
            let id = summary.manifest.mapID
            XCTAssertEqual(summary.directoryURL.path, store.directoryURL(for: id).path)
            // Only manifest.json exists, so the size is that file's size.
            XCTAssertEqual(summary.sizeBytes, try fileSize(store.url(for: .manifest, in: id)))
            XCTAssertEqual(summary.sizeBytes, Int64(try summary.manifest.encoded().count))
            XCTAssertFalse(summary.hasThumbnail)
            XCTAssertFalse(summary.hasCloud)
        }
    }

    func testListBreaksCreatedAtTiesByMapID() throws {
        let a = makeManifest(name: "a", createdAt: 5)
        let b = makeManifest(name: "b", createdAt: 5)
        try store.create(manifest: a)
        try store.create(manifest: b)
        let ids = try store.list().map(\.manifest.mapID.rawValue)
        XCTAssertEqual(ids, [a.mapID.rawValue, b.mapID.rawValue].sorted())
    }

    func testListFlagsThumbnailAndCloud() throws {
        let manifest = makeManifest()
        try store.create(manifest: manifest)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: store.url(for: .thumbnail, in: manifest.mapID))
        var summary = try XCTUnwrap(try store.list().first)
        XCTAssertTrue(summary.hasThumbnail)
        XCTAssertFalse(summary.hasCloud)
        try PLYWriter.write(points: [], to: store.url(for: .cloud, in: manifest.mapID))
        summary = try XCTUnwrap(try store.list().first)
        XCTAssertTrue(summary.hasCloud)
        // 4 thumbnail bytes + PLY header bytes + manifest bytes.
        let expected = 4 + Int64(PLYWriter.header(pointCount: 0).utf8.count) + Int64(try manifest.encoded().count)
        XCTAssertEqual(summary.sizeBytes, expected)
    }

    func testListSkipsUnreadableEntries() throws {
        let good = makeManifest(name: "good")
        try store.create(manifest: good)
        let fileManager = FileManager.default
        // Directory with a garbage manifest.
        let garbage = root.appendingPathComponent(MapID().rawValue, isDirectory: true)
        try fileManager.createDirectory(at: garbage, withIntermediateDirectories: true)
        try Data("{\"map_id\": 1}".utf8).write(to: garbage.appendingPathComponent("manifest.json"))
        // Directory with an empty-object manifest (decodes to nothing).
        let emptyObject = root.appendingPathComponent(MapID().rawValue, isDirectory: true)
        try fileManager.createDirectory(at: emptyObject, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: emptyObject.appendingPathComponent("manifest.json"))
        // Directory without a manifest.
        try fileManager.createDirectory(at: root.appendingPathComponent(MapID().rawValue), withIntermediateDirectories: true)
        // A plain file in the root.
        try Data("x".utf8).write(to: root.appendingPathComponent("stray.txt"))

        let summaries = try store.list()
        XCTAssertEqual(summaries.map(\.manifest), [good])
    }

    func testListThrowsIOWhenRootIsGone() throws {
        try FileManager.default.removeItem(at: root)
        assertIO { _ = try store.list() }
    }

    // MARK: - delete / rename / exists

    func testDeleteRemovesDirectory() throws {
        let m1 = makeManifest(name: "one", createdAt: 1)
        let m2 = makeManifest(name: "two", createdAt: 2)
        try store.create(manifest: m1)
        try store.create(manifest: m2)
        try Data(repeating: 0, count: 10).write(to: store.url(for: .sessionLog, in: m1.mapID))
        XCTAssertEqual(try store.list().count, 2)

        try store.delete(id: m1.mapID)
        XCTAssertFalse(store.exists(id: m1.mapID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directoryURL(for: m1.mapID).path))
        XCTAssertEqual(try store.list().map(\.manifest.mapID), [m2.mapID])
        assertMapNotFound(m1.mapID) { try store.delete(id: m1.mapID) }
        XCTAssertEqual(store.directorySize(id: m1.mapID), 0)
    }

    func testRenameUpdatesManifestName() throws {
        let manifest = makeManifest(name: "Before")
        try store.create(manifest: manifest)
        try store.rename(id: manifest.mapID, to: "After")
        let loaded = try store.loadManifest(id: manifest.mapID)
        XCTAssertEqual(loaded.name, "After")
        var expected = manifest
        expected.name = "After"
        XCTAssertEqual(loaded, expected, "only the name changes")
    }

    func testRenameMissingThrowsMapNotFound() {
        let id = MapID()
        assertMapNotFound(id) { try store.rename(id: id, to: "x") }
    }

    func testExistsRequiresDirectory() throws {
        let id = MapID()
        XCTAssertFalse(store.exists(id: id))
        // A plain file with the map's name is not a map.
        try Data().write(to: store.directoryURL(for: id))
        XCTAssertFalse(store.exists(id: id))
    }

    // MARK: - directorySize

    func testDirectorySizeSumsFiles() throws {
        let manifest = makeManifest()
        try store.create(manifest: manifest)
        let manifestSize = try fileSize(store.url(for: .manifest, in: manifest.mapID))
        XCTAssertEqual(store.directorySize(id: manifest.mapID), manifestSize)

        try Data(repeating: 0xAB, count: 1000).write(to: store.url(for: .keyframeLog, in: manifest.mapID))
        // 1000-byte log + manifest
        XCTAssertEqual(store.directorySize(id: manifest.mapID), 1000 + manifestSize)

        // Files in nested directories count too: + 250.
        let nested = store.directoryURL(for: manifest.mapID).appendingPathComponent("extra", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 250).write(to: nested.appendingPathComponent("blob"))
        XCTAssertEqual(store.directorySize(id: manifest.mapID), 1000 + 250 + manifestSize)

        XCTAssertEqual(store.directorySize(id: MapID()), 0)
    }

    // MARK: - markInterruptedRecordings

    func testMarkInterruptedRecordingsFlipsOnlyRecordingAndFinalizing() throws {
        let recording = makeManifest(name: "recording", createdAt: 4, status: .recording)
        let finalizing = makeManifest(name: "finalizing", createdAt: 3, status: .finalizing)
        let saved = makeManifest(name: "saved", createdAt: 2, status: .saved)
        let failed = makeManifest(name: "failed", createdAt: 1, status: .failed)
        for manifest in [recording, finalizing, saved, failed] {
            try store.create(manifest: manifest)
        }

        let interrupted = try store.markInterruptedRecordings()
        // Newest first: recording (4) before finalizing (3).
        XCTAssertEqual(interrupted, [recording.mapID, finalizing.mapID])

        XCTAssertEqual(try store.loadManifest(id: recording.mapID).status, .failed)
        XCTAssertEqual(try store.loadManifest(id: finalizing.mapID).status, .failed)
        XCTAssertEqual(try store.loadManifest(id: saved.mapID), saved)
        XCTAssertEqual(try store.loadManifest(id: failed.mapID), failed)
        // Everything but the status survives.
        var expected = recording
        expected.status = .failed
        XCTAssertEqual(try store.loadManifest(id: recording.mapID), expected)

        XCTAssertEqual(try store.markInterruptedRecordings(), [], "second pass finds nothing")
    }

    // MARK: - MapSummary

    func testMapSummaryEquality() {
        let manifest = makeManifest()
        let url = URL(fileURLWithPath: "/tmp/x")
        let a = MapSummary(manifest: manifest, directoryURL: url, sizeBytes: 1, hasThumbnail: true, hasCloud: false)
        var b = a
        XCTAssertEqual(a, b)
        b.sizeBytes = 2
        XCTAssertNotEqual(a, b)
    }
}
