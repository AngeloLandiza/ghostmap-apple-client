import XCTest
@testable import MapCore

final class SnakeCaseTests: XCTestCase {

    // MARK: - Key conversion

    func testToCamelCase() {
        XCTAssertEqual(SnakeCase.toCamelCase("point_count"), "pointCount")
        XCTAssertEqual(SnakeCase.toCamelCase("device_id"), "deviceId")
        XCTAssertEqual(SnakeCase.toCamelCase("picture_url"), "pictureUrl")
        XCTAssertEqual(SnakeCase.toCamelCase("id_token"), "idToken")
        XCTAssertEqual(SnakeCase.toCamelCase("duration_s"), "durationS")
        XCTAssertEqual(SnakeCase.toCamelCase("name"), "name")
        XCTAssertEqual(SnakeCase.toCamelCase("bbox"), "bbox")
        XCTAssertEqual(SnakeCase.toCamelCase("parent_map_id"), "parentMapId")
        XCTAssertEqual(SnakeCase.toCamelCase("can_publish"), "canPublish")
        XCTAssertEqual(SnakeCase.toCamelCase("error_description"), "errorDescription")
    }

    func testFromCamelCase() {
        XCTAssertEqual(SnakeCase.fromCamelCase("pointCount"), "point_count")
        XCTAssertEqual(SnakeCase.fromCamelCase("deviceId"), "device_id")
        XCTAssertEqual(SnakeCase.fromCamelCase("pictureUrl"), "picture_url")
        XCTAssertEqual(SnakeCase.fromCamelCase("idToken"), "id_token")
        XCTAssertEqual(SnakeCase.fromCamelCase("durationS"), "duration_s")
        XCTAssertEqual(SnakeCase.fromCamelCase("name"), "name")
        XCTAssertEqual(SnakeCase.fromCamelCase("parentMapId"), "parent_map_id")
        XCTAssertEqual(SnakeCase.fromCamelCase("parseHTTPBody"), "parse_http_body")
    }

    func testAlreadySnakeCaseKeysAreUnchangedByEncoding() {
        // Manifests written by the app are already snake_case; encoding must be idempotent.
        for key in ["map_id", "point_count", "created_at", "has_world_map", "cloud.ply"] {
            XCTAssertEqual(SnakeCase.fromCamelCase(key), key)
        }
    }

    /// The backend returns database rows straight from Drizzle (lower camel) and hand-written
    /// payloads as snake_case. Both must land on the same Swift property name.
    func testDrizzleCamelCaseAndSnakeCaseConverge() {
        let columns: [(snake: String, drizzle: String)] = [
            ("point_count", "pointCount"), ("keyframe_count", "keyframeCount"), ("size_bytes", "sizeBytes"),
            ("duration_s", "durationS"), ("created_at", "createdAt"), ("finalized_at", "finalizedAt"),
            ("parent_map_id", "parentMapId"), ("session_id", "sessionId"), ("device_id", "deviceId"),
            ("owner_user_id", "ownerUserId"), ("invite_code", "inviteCode"), ("max_participants", "maxParticipants"),
            ("leader_device_id", "leaderDeviceId"), ("base_map_id", "baseMapId"), ("merged_map_id", "mergedMapId"),
            ("ended_at", "endedAt"), ("display_name", "displayName"), ("joined_at", "joinedAt"),
            ("left_at", "leftAt"), ("picture_url", "pictureUrl"), ("last_login_at", "lastLoginAt"),
        ]
        for column in columns {
            XCTAssertEqual(SnakeCase.toCamelCase(column.snake), column.drizzle, "snake form of \(column.drizzle)")
            XCTAssertEqual(SnakeCase.toCamelCase(column.drizzle), column.drizzle, "camel form of \(column.drizzle)")
            XCTAssertEqual(SnakeCase.fromCamelCase(column.drizzle), column.snake, "request form of \(column.drizzle)")
        }
    }

    func testRoundTripForEveryAPIPropertyName() {
        let names = [
            "id", "name", "email", "role", "token", "expiresAt", "deviceId", "userId", "pictureUrl",
            "pointCount", "keyframeCount", "durationS", "sizeBytes", "createdAt", "finalizedAt",
            "parentMapId", "sessionId", "inviteCode", "maxParticipants", "ownerUserId", "shareUrl",
            "participantCount", "canJoin", "canPublish", "tokenRequest", "displayName", "leftAt",
            "joinedAt", "trackingState", "worldMappingStatus", "depthRef", "confidenceRef",
            "jpegRef", "meshRef", "pointsInline", "nextCursor", "nextSinceId", "objectsRemoved",
            "baseMapId", "ownerName", "accessToken", "idToken", "expiresIn", "tokenType", "refreshToken",
            "missingEnv", "envIssues", "outputMapId", "inputMapIds",
        ]
        for name in names {
            let snake = SnakeCase.fromCamelCase(name)
            XCTAssertEqual(SnakeCase.toCamelCase(snake), name, "\(name) -> \(snake) did not round trip")
        }
    }

    func testEdgeCases() {
        XCTAssertEqual(SnakeCase.toCamelCase(""), "")
        XCTAssertEqual(SnakeCase.toCamelCase("_"), "_")
        XCTAssertEqual(SnakeCase.toCamelCase("_private_key"), "_privateKey")
        XCTAssertEqual(SnakeCase.fromCamelCase(""), "")
        XCTAssertEqual(SnakeCase.fromCamelCase("URL"), "url")
    }

    // MARK: - Coders

    private struct Upload: Codable, Equatable {
        let path: String
        let url: String
        let method: String
        let headers: [String: String]
        let resumable: Bool
    }

    private struct Payload: Codable, Equatable {
        let deviceId: String
        let pointCount: Int
        let uploads: [Upload]
        let manifest: JSONValue?
        let tokenRequest: JSONValue?
    }

    func testDecodesSnakeCaseKeys() throws {
        let json = """
        {
          "device_id": "abc",
          "point_count": 42,
          "uploads": [
            { "path": "cloud.ply", "url": "https://x/y", "method": "PUT",
              "headers": { "Content-Type": "application/octet-stream", "x-goog-resumable": "start" },
              "resumable": true }
          ],
          "manifest": { "map_id": "M1", "point_count": 7 },
          "token_request": { "keyName": "abc.def", "mac": "zzz", "nonce": "1" }
        }
        """
        let decoded = try GhostmapJSON.makeDecoder().decode(Payload.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.deviceId, "abc")
        XCTAssertEqual(decoded.pointCount, 42)
        XCTAssertEqual(decoded.uploads.first?.headers["Content-Type"], "application/octet-stream")
        XCTAssertEqual(decoded.uploads.first?.headers["x-goog-resumable"], "start")
        XCTAssertEqual(decoded.uploads.first?.resumable, true)
    }

    /// The same model decodes a Drizzle row, whose keys are already lower camel.
    func testDecodesDrizzleCamelCaseKeys() throws {
        let json = #"{ "deviceId": "abc", "pointCount": 42, "uploads": [] }"#
        let decoded = try GhostmapJSON.makeDecoder().decode(Payload.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.deviceId, "abc")
        XCTAssertEqual(decoded.pointCount, 42)
    }

    func testOpaqueSubtreesKeepTheirKeys() throws {
        let json = """
        { "device_id": "abc", "point_count": 1, "uploads": [],
          "manifest": { "map_id": "M1" },
          "token_request": { "keyName": "abc.def", "capability": "{\\"a\\":1}" } }
        """
        let decoded = try GhostmapJSON.makeDecoder().decode(Payload.self, from: Data(json.utf8))
        // The Ably token request must reach the SDK with camelCase keys intact.
        XCTAssertEqual(decoded.tokenRequest?["keyName"], JSONValue.string("abc.def"))
        XCTAssertNil(decoded.tokenRequest?["key_name"])
        // The manifest keeps its own snake_case keys rather than being camelised.
        XCTAssertEqual(decoded.manifest?["map_id"], JSONValue.string("M1"))
        XCTAssertNil(decoded.manifest?["mapId"])
    }

    func testEncodesCamelCaseAsSnakeCase() throws {
        let payload = Payload(
            deviceId: "abc",
            pointCount: 3,
            uploads: [Upload(path: "p", url: "u", method: "PUT", headers: ["Content-Type": "text/plain"], resumable: false)],
            manifest: .object(["map_id": .string("M1")]),
            tokenRequest: .object(["keyName": .string("k")])
        )
        let data = try GhostmapJSON.makeEncoder().encode(payload)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"device_id\""))
        XCTAssertTrue(text.contains("\"point_count\""))
        XCTAssertTrue(text.contains("\"Content-Type\""), "header names must not be rewritten: \(text)")
        XCTAssertTrue(text.contains("\"map_id\""))
        XCTAssertTrue(text.contains("\"keyName\""), "the token request must round trip verbatim: \(text)")
    }

    func testEncodeDecodeRoundTrip() throws {
        let payload = Payload(
            deviceId: "d1",
            pointCount: 9,
            uploads: [Upload(path: "keyframes.bin", url: "https://x", method: "POST", headers: ["x-goog-resumable": "start"], resumable: true)],
            manifest: .object(["map_id": .string("M2"), "point_count": .int(4)]),
            tokenRequest: .object(["keyName": .string("k"), "ttl": .int(3600)])
        )
        let data = try GhostmapJSON.makeEncoder().encode(payload)
        let back = try GhostmapJSON.makeDecoder().decode(Payload.self, from: data)
        XCTAssertEqual(back, payload)
    }

    // MARK: - Timestamps

    private struct Stamped: Codable, Equatable {
        let expiresAt: Date
    }

    func testDecodesTimestampsWithAndWithoutFractionalSeconds() throws {
        let decoder = GhostmapJSON.makeDecoder()
        let a = try decoder.decode(Stamped.self, from: Data(#"{"expires_at":"2026-09-04T12:00:00.123Z"}"#.utf8))
        let b = try decoder.decode(Stamped.self, from: Data(#"{"expires_at":"2026-09-04T12:00:00Z"}"#.utf8))
        XCTAssertEqual(a.expiresAt.timeIntervalSince1970, b.expiresAt.timeIntervalSince1970 + 0.123, accuracy: 0.001)
    }

    func testTimestampRoundTrip() throws {
        let value = Stamped(expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try GhostmapJSON.makeEncoder().encode(value)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("expires_at"))
        let back = try GhostmapJSON.makeDecoder().decode(Stamped.self, from: data)
        XCTAssertEqual(back.expiresAt.timeIntervalSince1970, value.expiresAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRejectsAnUnparsableTimestamp() {
        XCTAssertNil(ISO8601Timestamp.date(from: "yesterday"))
        XCTAssertNil(ISO8601Timestamp.date(from: ""))
        XCTAssertThrowsError(try GhostmapJSON.makeDecoder().decode(Stamped.self, from: Data(#"{"expires_at":"nope"}"#.utf8)))
    }
}
