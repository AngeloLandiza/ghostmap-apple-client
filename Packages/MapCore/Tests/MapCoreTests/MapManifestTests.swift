import Foundation
import simd
import XCTest
@testable import MapCore

final class MapManifestTests: XCTestCase {

    /// 2026-09-02T14:05:00Z.
    private static let referenceDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 2
        components.hour = 14
        components.minute = 5
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    private static let utc = TimeZone(secondsFromGMT: 0)!

    private func makeManifest() -> MapManifest {
        MapManifest(
            name: "Kitchen",
            createdAt: MapManifestTests.referenceDate,
            deviceModel: "iPhone17,2",
            iosVersion: "27.0"
        )
    }

    private func jsonObject(_ manifest: MapManifest) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try manifest.encoded())
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - Keys

    func testJSONContainsExactKeys() throws {
        let object = try jsonObject(makeManifest())
        let required: Set<String> = [
            "map_id", "version", "name", "frame", "origin", "point_count", "keyframe_count",
            "created_at", "duration_s", "device_model", "ios_version", "status", "encodings",
            "has_world_map", "voxel_size_m",
        ]
        for key in required {
            XCTAssertNotNil(object[key], "missing key \(key)")
        }
        // The manifest always carries app_version as well; bbox, size_bytes and finalize_s are
        // optional and absent when nil. 15 required + app_version = 16 keys.
        XCTAssertEqual(Set(object.keys), required.union(["app_version"]))
        XCTAssertEqual(object.count, 16)
    }

    func testOptionalKeysAppearOnlyWhenSet() throws {
        var manifest = makeManifest()
        XCTAssertNil(try jsonObject(manifest)["bbox"])
        XCTAssertNil(try jsonObject(manifest)["size_bytes"])
        XCTAssertNil(try jsonObject(manifest)["finalize_s"])

        manifest.bbox = BoundingBox(min: SIMD3<Float>(-1, -2, -3), max: SIMD3<Float>(1, 2, 3))
        manifest.sizeBytes = 4_096
        manifest.finalizeSeconds = 2.5
        let object = try jsonObject(manifest)
        XCTAssertEqual(object.count, 19)   // 16 + bbox + size_bytes + finalize_s
        XCTAssertEqual(object["size_bytes"] as? Int, 4096)
        XCTAssertEqual(object["finalize_s"] as? Double, 2.5)
        let bbox = try XCTUnwrap(object["bbox"] as? [String: Any])
        XCTAssertEqual(Set(bbox.keys), ["min", "max"])
        XCTAssertEqual(bbox["min"] as? [Double], [-1, -2, -3])
        XCTAssertEqual(bbox["max"] as? [Double], [1, 2, 3])
    }

    func testNestedObjectKeys() throws {
        let object = try jsonObject(makeManifest())
        let origin = try XCTUnwrap(object["origin"] as? [String: Any])
        XCTAssertEqual(Set(origin.keys), ["type"])          // marker_id is nil → omitted
        XCTAssertEqual(origin["type"] as? String, "session-start")

        let encodings = try XCTUnwrap(object["encodings"] as? [String: Any])
        XCTAssertEqual(Set(encodings.keys), ["depth", "confidence", "cloud", "keyframe_log"])
        XCTAssertEqual(encodings["depth"] as? String, "u16mm+lzfse")
        XCTAssertEqual(encodings["confidence"] as? String, "u8+lzfse")
        XCTAssertEqual(encodings["cloud"] as? String, "ply-binary-little-endian-xyzrgb")
        XCTAssertEqual(encodings["keyframe_log"] as? String, "smkf-v1")

        var marker = makeManifest()
        marker.origin = OriginDescriptor(type: "marker", markerID: "tag36h11_0")
        let markerOrigin = try XCTUnwrap(try jsonObject(marker)["origin"] as? [String: Any])
        XCTAssertEqual(Set(markerOrigin.keys), ["type", "marker_id"])
        XCTAssertEqual(markerOrigin["marker_id"] as? String, "tag36h11_0")
    }

    // MARK: - Values

    func testEncodedValues() throws {
        let manifest = makeManifest()
        let object = try jsonObject(manifest)
        XCTAssertEqual(object["map_id"] as? String, manifest.mapID.rawValue)
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["name"] as? String, "Kitchen")
        XCTAssertEqual(object["frame"] as? String, "world:session-start")
        XCTAssertEqual(object["point_count"] as? Int, 0)
        XCTAssertEqual(object["keyframe_count"] as? Int, 0)
        XCTAssertEqual(object["created_at"] as? String, "2026-09-02T14:05:00Z")
        XCTAssertEqual(object["duration_s"] as? Double, 0)
        XCTAssertEqual(object["device_model"] as? String, "iPhone17,2")
        XCTAssertEqual(object["ios_version"] as? String, "27.0")
        XCTAssertEqual(object["app_version"] as? String, "1.0")
        XCTAssertEqual(object["status"] as? String, "recording")
        XCTAssertEqual(object["has_world_map"] as? Bool, false)
        // Float 0.02 is 0.019999999552965164 as a Double.
        XCTAssertEqual(try XCTUnwrap(object["voxel_size_m"] as? Double), 0.02, accuracy: 1e-6)
    }

    func testStatusStrings() throws {
        for (status, text) in [(MapStatus.recording, "recording"), (.finalizing, "finalizing"), (.saved, "saved"), (.failed, "failed")] {
            var manifest = makeManifest()
            manifest.status = status
            XCTAssertEqual(try jsonObject(manifest)["status"] as? String, text)
        }
    }

    func testDefaults() {
        let manifest = makeManifest()
        XCTAssertEqual(manifest.version, MapManifest.currentVersion)
        XCTAssertEqual(MapManifest.currentVersion, 1)
        XCTAssertEqual(manifest.frame, "world:session-start")
        XCTAssertEqual(manifest.origin, .sessionStart)
        XCTAssertNil(manifest.bbox)
        XCTAssertEqual(manifest.status, .recording)
        XCTAssertEqual(manifest.encodings, .v1)
        XCTAssertEqual(manifest.appVersion, "1.0")
        XCTAssertFalse(manifest.hasWorldMap)
        XCTAssertEqual(manifest.voxelSizeMeters, 0.02)
        XCTAssertNil(manifest.sizeBytes)
        XCTAssertNil(manifest.finalizeSeconds)
    }

    func testEncodingIsDeterministic() throws {
        let manifest = makeManifest()
        XCTAssertEqual(try manifest.encoded(), try manifest.encoded())
        let text = String(decoding: try manifest.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"frame\" : \"world:session-start\""), "slashes are not escaped, keys sorted, pretty printed")
        XCTAssertFalse(text.contains("\\/"))
    }

    // MARK: - Round trip

    func testRoundTrip() throws {
        var manifest = makeManifest()
        manifest.bbox = BoundingBox(min: SIMD3<Float>(-1.5, 0, -2), max: SIMD3<Float>(3, 2.5, 4))
        manifest.pointCount = 1_234_567
        manifest.keyframeCount = 321
        manifest.durationSeconds = 181.25
        manifest.status = .saved
        manifest.sizeBytes = 55_000_000
        manifest.hasWorldMap = true
        manifest.finalizeSeconds = 3.75
        manifest.origin = OriginDescriptor(type: "marker", markerID: "tag36h11_7")
        let decoded = try MapManifest.decode(try manifest.encoded())
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.createdAt, MapManifestTests.referenceDate)
    }

    func testDecodeFailures() {
        func assertInvalid(_ json: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try MapManifest.decode(Data(json.utf8)), file: file, line: line) { error in
                guard let mapError = error as? MapError, case .invalidManifest = mapError else {
                    return XCTFail("expected MapError.invalidManifest, got \(error)", file: file, line: line)
                }
            }
        }
        assertInvalid("{}")
        assertInvalid("")
        assertInvalid("not json")
        assertInvalid("[]")
        // Every required key present but map_id is not a UUID.
        assertInvalid("""
        {"map_id":"nope","version":1,"name":"x","frame":"f","origin":{"type":"session-start"},
         "point_count":0,"keyframe_count":0,"created_at":"2026-09-02T14:05:00Z","duration_s":0,
         "device_model":"m","ios_version":"v","app_version":"1.0","status":"saved",
         "encodings":{"depth":"a","confidence":"b","cloud":"c","keyframe_log":"d"},
         "has_world_map":false,"voxel_size_m":0.02}
        """)
        // Unknown status.
        assertInvalid("""
        {"map_id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","version":1,"name":"x","frame":"f",
         "origin":{"type":"session-start"},"point_count":0,"keyframe_count":0,
         "created_at":"2026-09-02T14:05:00Z","duration_s":0,"device_model":"m","ios_version":"v",
         "app_version":"1.0","status":"exploded",
         "encodings":{"depth":"a","confidence":"b","cloud":"c","keyframe_log":"d"},
         "has_world_map":false,"voxel_size_m":0.02}
        """)
    }

    func testDecodeMinimalHandWrittenManifest() throws {
        let json = """
        {"map_id":"6ba7b810-9dad-11d1-80b4-00c04fd430c8","version":1,"name":"Hand","frame":"world:session-start",
         "origin":{"type":"session-start"},"point_count":5,"keyframe_count":2,
         "created_at":"2026-09-02T14:05:00Z","duration_s":1.5,"device_model":"m","ios_version":"v",
         "app_version":"1.0","status":"saved",
         "encodings":{"depth":"u16mm+lzfse","confidence":"u8+lzfse","cloud":"c","keyframe_log":"smkf-v1"},
         "has_world_map":true,"voxel_size_m":0.03}
        """
        let manifest = try MapManifest.decode(Data(json.utf8))
        XCTAssertEqual(manifest.mapID.rawValue, "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "ids are uppercased")
        XCTAssertEqual(manifest.name, "Hand")
        XCTAssertEqual(manifest.pointCount, 5)
        XCTAssertEqual(manifest.keyframeCount, 2)
        XCTAssertEqual(manifest.createdAt, MapManifestTests.referenceDate)
        XCTAssertEqual(manifest.durationSeconds, 1.5)
        XCTAssertEqual(manifest.status, .saved)
        XCTAssertTrue(manifest.hasWorldMap)
        XCTAssertEqual(manifest.voxelSizeMeters, 0.03)
        XCTAssertNil(manifest.bbox)
    }

    // MARK: - defaultName

    func testDefaultName() {
        // 2026-09-02T14:05Z rendered in UTC: "MMM d, HH:mm" → "Sep 2, 14:05"
        XCTAssertEqual(MapManifest.defaultName(for: MapManifestTests.referenceDate, timeZone: MapManifestTests.utc),
                       "Room — Sep 2, 14:05")
        // Same instant at UTC+2 → 16:05
        XCTAssertEqual(MapManifest.defaultName(for: MapManifestTests.referenceDate, timeZone: TimeZone(secondsFromGMT: 7200)!),
                       "Room — Sep 2, 16:05")
        // Same instant at UTC−10 → 04:05 (zero-padded hour, no leading zero on the day)
        XCTAssertEqual(MapManifest.defaultName(for: MapManifestTests.referenceDate, timeZone: TimeZone(secondsFromGMT: -36_000)!),
                       "Room — Sep 2, 04:05")
        // 14:05Z + 10 h crosses midnight at UTC+10 → Sep 3, 00:05
        XCTAssertEqual(MapManifest.defaultName(for: MapManifestTests.referenceDate, timeZone: TimeZone(secondsFromGMT: 36_000)!),
                       "Room — Sep 3, 00:05")
    }

    // MARK: - MapID

    func testMapIDValidation() throws {
        XCTAssertNil(MapID(rawValue: "not-a-uuid"))
        XCTAssertNil(MapID(rawValue: ""))
        let id = try XCTUnwrap(MapID(rawValue: "6ba7b810-9dad-11d1-80b4-00c04fd430c8"))
        XCTAssertEqual(id.rawValue, "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")
        XCTAssertEqual(id.description, id.rawValue)
        XCTAssertEqual(id, MapID(rawValue: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"))
        XCTAssertNotNil(UUID(uuidString: MapID().rawValue))
        XCTAssertNotEqual(MapID(), MapID())
    }

    // MARK: - BoundingBox

    func testBoundingBoxUnionAndContains() {
        var box = BoundingBox.empty
        XCTAssertTrue(box.isEmpty)
        XCTAssertEqual(box.extent, .zero)
        XCTAssertEqual(box.center, .zero)
        XCTAssertFalse(box.contains(.zero))

        box.formUnion(SIMD3<Float>(1, 2, 3))
        XCTAssertFalse(box.isEmpty)
        XCTAssertEqual(box.min, SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(box.max, SIMD3<Float>(1, 2, 3))
        box.formUnion(SIMD3<Float>(-1, 0, 5))
        // min = (-1, 0, 3), max = (1, 2, 5), extent = (2, 2, 2), center = (0, 1, 4)
        XCTAssertEqual(box.min, SIMD3<Float>(-1, 0, 3))
        XCTAssertEqual(box.max, SIMD3<Float>(1, 2, 5))
        XCTAssertEqual(box.extent, SIMD3<Float>(2, 2, 2))
        XCTAssertEqual(box.center, SIMD3<Float>(0, 1, 4))
        XCTAssertTrue(box.contains(SIMD3<Float>(0, 1, 4)))
        XCTAssertFalse(box.contains(SIMD3<Float>(0, 1, 5.1)))

        var other = BoundingBox.empty
        other.formUnion(box)
        XCTAssertEqual(other, box)
        other.formUnion(BoundingBox.empty)
        XCTAssertEqual(other, box, "union with an empty box is a no-op")
        XCTAssertEqual(box.union(SIMD3<Float>(10, 10, 10)).max, SIMD3<Float>(10, 10, 10))
    }
}
