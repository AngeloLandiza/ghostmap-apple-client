// Decoding/encoding smoke check for the backend DTOs in App/Cloud/GhostmapModels.swift.
//
// The app has no XCTest target (pure logic lives in Packages/MapCore, which is where the coder,
// PKCE, retry and URL tests are). This runs the DTOs against payloads shaped exactly like the ones
// ghostmap-backend returns — Drizzle rows in camelCase, hand-written wrappers in snake_case.
//
//   cd Packages/MapCore && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
//     xcrun swift build --scratch-path /tmp/mapcore-build
//   DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swiftc -swift-version 6 \
//     -I /tmp/mapcore-build/debug/Modules -I /tmp/mapcore-build/debug -L /tmp/mapcore-build/debug -lMapCore \
//     App/Cloud/Keychain.swift App/Cloud/GhostmapModels.swift scripts/api-smoke/main.swift -o /tmp/api-smoke && /tmp/api-smoke

import Foundation
import MapCore

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") } else { print("ok: \(what)") }
}

let decoder = GhostmapJSON.makeDecoder()

// POST /v1/auth/google (device)
let authJSON = """
{"token":"jwt.abc.def","expires_at":"2026-10-04T12:00:00.000Z","role":"device","device_id":"7f9a1e2c-0000-4000-8000-000000000001",
 "user":{"id":"u1","email":"a@b.c","name":"Angelo","picture_url":"https://lh3.googleusercontent.com/x","created_at":"2026-09-01T10:00:00.000Z"}}
"""
let auth = try decoder.decode(AuthResponse.self, from: Data(authJSON.utf8))
check(auth.role == .device, "auth role")
check(auth.deviceId == "7f9a1e2c-0000-4000-8000-000000000001", "auth device id")
check(auth.user?.name == "Angelo", "auth user name")
check(auth.user?.pictureUrl?.hasPrefix("https://") == true, "auth picture url")

// GET /v1/auth/me
let me = try decoder.decode(MeResponse.self, from: Data(#"{"role":"user","device_id":null,"user":null}"#.utf8))
check(me.role == .user && me.deviceId == nil && me.user == nil, "me")

// GET /health
let health = try decoder.decode(HealthResponse.self, from: Data(#"{"ok":true,"configured":true,"missing_env":[],"env_issues":[],"service":"ghostmap-backend","version":"0.1.0","region":"iad1","time":"2026-09-04T12:00:00.000Z"}"#.utf8))
check(health.ok && health.region == "iad1" && health.missingEnv?.isEmpty == true, "health")

// POST /v1/maps — drizzle row (camelCase) + snake wrappers
let createMapJSON = """
{"map":{"id":"m1","name":"Kitchen","version":1,"parentMapId":null,"sessionId":null,"deviceId":"d1","ownerUserId":"u1",
 "frame":"world:session-start","origin":{"type":"session-start"},"status":"uploading","manifest":null,
 "pointCount":0,"keyframeCount":0,"bbox":null,"durationS":0,"sizeBytes":0,"files":["cloud.ply"],
 "createdAt":"2026-09-04T12:00:00.000Z","finalizedAt":null},
 "uploads":[{"path":"maps/m1/cloud.ply","url":"https://storage.googleapis.com/x","method":"POST",
 "headers":{"Content-Type":"application/octet-stream","x-goog-resumable":"start"},
 "expires_at":"2026-09-04T13:00:00.000Z","resumable":true}]}
"""
let created = try decoder.decode(CreateMapResponse.self, from: Data(createMapJSON.utf8))
check(created.map.status == .uploading, "map status")
check(created.map.origin?.type == "session-start", "map origin")
check(created.uploads.first?.headers["x-goog-resumable"] == "start", "upload headers verbatim")
check(created.uploads.first?.resumable == true, "resumable")
check(created.map.createdAt != nil, "map createdAt")

// GET /v1/maps/:id
let detail = try decoder.decode(MapDetailResponse.self, from: Data("""
{"map":{"id":"m1","name":"K","status":"saved","pointCount":12345,"durationS":42.5,"sizeBytes":99},
 "downloads":{"cloud.ply":{"url":"https://x","expires_at":"2026-09-04T13:00:00.000Z"},
              "session.log":{"url":"https://y","expires_at":"2026-09-04T13:00:00.000Z"}}}
""".utf8))
check(detail.map.pointCount == 12345 && detail.map.durationS == 42.5, "map counts")
check(detail.downloads?["cloud.ply"] != nil && detail.downloads?["session.log"] != nil, "download keys kept")

// GET /v1/maps list
let list = try decoder.decode(MapListResponse.self, from: Data(#"{"maps":[],"next_cursor":"2026-09-04T12:00:00.000Z"}"#.utf8))
check(list.nextCursor == "2026-09-04T12:00:00.000Z", "next cursor as string")

// POST /v1/sessions
let sessionJSON = """
{"session":{"id":"s1","name":"Living room","status":"active","origin":{"type":"marker","marker_id":"gm-1"},
 "leaderDeviceId":"d1","ownerUserId":"u1","inviteCode":"ABCD2345","maxParticipants":4,"baseMapId":null,
 "mergedMapId":null,"keyframeCount":0,"bytes":0,"createdAt":"2026-09-04T12:00:00.000Z","endedAt":null},
 "participants":[{"id":"p1","session_id":"s1","device_id":"d1","user_id":"u1","kind":"device","color":"#ff8800",
 "display_name":"Angelo","role":"leader","joined_at":"2026-09-04T12:00:00.000Z","left_at":null}],
 "channel":"session:s1","share_url":"https://dash.example/join/ABCD2345"}
"""
let envelope = try decoder.decode(SessionEnvelope.self, from: Data(sessionJSON.utf8))
check(envelope.session.inviteCode == "ABCD2345", "invite code")
check(envelope.session.origin?.markerId == "gm-1", "marker origin")
check(envelope.participants.first?.kind == .device, "participant kind")
check(envelope.participants.first?.role == .leader, "participant role")
check(envelope.participants.first?.isActive == true, "participant active")
check(envelope.shareUrl?.contains("ABCD2345") == true, "share url")

// GET /v1/sessions/by-code/:code
let byCode = try decoder.decode(SessionByCodeResponse.self, from: Data("""
{"session":{"id":"s1","name":"n","status":"active","origin":{"type":"session-start"},"invite_code":"ABCD2345",
 "share_url":"https://x/join/ABCD2345","participant_count":4,"max_participants":4,"owner_name":"Angelo"},
 "can_join":false,"reason":"session_full"}
""".utf8))
check(byCode.canJoin == false && byCode.reason == .sessionFull, "by-code rejection")
check(byCode.session.participantCount == 4, "participant count")

// POST /v1/sessions/join
let join = try decoder.decode(JoinSessionResponse.self, from: Data("""
{"session":{"id":"s1","name":"n","status":"active"},"participants":[],"channel":"session:s1",
 "share_url":null,"me":{"id":"p2","kind":"viewer","color":"#00aaff"},
 "realtime":{"token_request":{"keyName":"abc.def","mac":"m","nonce":"n","ttl":3600},"channel":"session:s1","can_publish":true}}
""".utf8))
check(join.me?.kind == .viewer, "me kind")
check(join.realtime?.canPublish == true, "can publish")
check(join.realtime?.tokenRequest?["keyName"] == JSONValue.string("abc.def"), "ably token request verbatim")

// GET /v1/sessions/:id/keyframes
let kfs = try decoder.decode(KeyframeListResponse.self, from: Data("""
{"keyframes":[{"id":7,"sessionId":"s1","deviceId":"d1","seq":3,"t":12.5,"pose":[1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1],
 "intrinsics":{"fx":1,"fy":1,"cx":1,"cy":1,"w":256,"h":192},"tracking_state":"normal","aligned":false,
 "depth_ref":"sessions/s1/kf/d1/3.depth.lzfse","points_inline":[1,2,3,255,0,0],"bytes":100,
 "created_at":"2026-09-04T12:00:00.000Z"}],"next_since_id":7}
""".utf8))
check(kfs.nextSinceId == 7, "next since id")
check(kfs.keyframes.first?.aligned == false, "aligned false")
check(kfs.keyframes.first?.pointsInline?.count == 6, "points inline")
check(kfs.keyframes.first?.intrinsics?.w == 256, "intrinsics")

// POST /v1/sessions/:id/upload-urls
let tickets = try decoder.decode(KeyframeUploadURLsResponse.self, from: Data("""
{"uploads":[{"seq":3,"kind":"depth","path":"sessions/s1/kf/d1/3.depth.lzfse","url":"https://storage.example/put?sig=1",
 "method":"PUT","headers":{"Content-Type":"application/octet-stream","x-goog-Meta-Seq":"3"},
 "expires_at":"2026-09-04T12:30:00.000Z"},
 {"seq":3,"kind":"confidence","path":"sessions/s1/kf/d1/3.conf.lzfse","url":"https://storage.example/put?sig=2",
 "method":"PUT","headers":{},"expires_at":"2026-09-04T12:30:00.000Z"}]}
""".utf8))
check(tickets.uploads.count == 2, "upload tickets")
check(tickets.uploads.first?.kind == .depth, "upload kind")
// Header names must survive verbatim: they are signed into the GCS URL.
check(tickets.uploads.first?.headers["x-goog-Meta-Seq"] == "3", "upload headers verbatim")

// POST /v1/sessions/:id/leave
let left = try decoder.decode(LeaveSessionResponse.self, from: Data("""
{"left":true,"participants":[{"id":"p1","kind":"device","color":"#38bdf8","left_at":"2026-09-04T12:05:00.000Z"}]}
""".utf8))
check(left.left && left.participants?.first?.isActive == false, "leave marks the row inactive")

// POST /v1/sessions/:id/end
let ended = try decoder.decode(SessionStatusResponse.self, from: Data(#"{"session":{"id":"s1","name":"n","status":"ended"}}"#.utf8))
check(ended.session.status == .ended, "end status")

// Every participant colour the backend hands out parses into the app's PartyColor.
for hex in ["#38bdf8", "#f472b6", "#facc15", "#4ade80", "#a78bfa", "#fb923c", "#22d3ee", "#f87171"] {
    check(PartyColor(hex: hex) != nil, "palette colour \(hex)")
}
check(PartyColor(hex: envelope.participants.first?.color ?? "") != nil, "participant colour parses")

// The party keyframe the streamer builds must survive a round trip through the wire encoding.
let inline = InlinePoints.encode([PackedPoint(position: SIMD3<Float>(1, 2, 3), r: 10, g: 20, b: 30)])
check(InlinePoints.decode(inline).first?.r == 10, "inline point round trip")

// errors
let err = try decoder.decode(APIErrorEnvelope.self, from: Data(#"{"error":{"code":"session_full","message":"this party is full"}}"#.utf8))
check(err.error.code == "session_full", "error envelope")

// Requests encode as snake_case
let encoder = GhostmapJSON.makeEncoder()
let body = String(decoding: try encoder.encode(GoogleSignInRequest(idToken: "tok", device: DeviceIdentity(id: UUID(uuidString: "7F9A1E2C-0000-4000-8000-000000000001") ?? UUID(), name: "Angelo's iPhone"))), as: UTF8.self)
check(body.contains("\"id_token\""), "request id_token key")
check(body.contains("\"platform\":\"ios\""), "request platform")
check(body.lowercased().contains("7f9a1e2c-0000-4000-8000-000000000001"), "device uuid lowercased")

let createBody = String(decoding: try encoder.encode(CreateMapRequest(name: "Kitchen", origin: .marker("gm-1"), sessionId: "s1", files: CloudMapFile.defaults)), as: UTF8.self)
check(createBody.contains("\"session_id\":\"s1\""), "create map session_id")
check(createBody.contains("\"marker_id\":\"gm-1\""), "create map marker_id")
check(createBody.contains("\"cloud.ply\""), "create map files as names")
check(!createBody.contains("parent_map_id"), "nil fields omitted")

let kfBody = String(decoding: try encoder.encode(RegisterKeyframesRequest(keyframes: [
    SessionKeyframe(seq: 1, t: 0.5, pose: Array(repeating: 0, count: 16),
                    intrinsics: KeyframeIntrinsics(fx: 1, fy: 1, cx: 1, cy: 1, w: 256, h: 192),
                    trackingState: "normal", aligned: false, depthRef: "p", pointsInline: [1, 2, 3])])), as: UTF8.self)
check(kfBody.contains("\"tracking_state\":\"normal\""), "keyframe tracking_state")
check(kfBody.contains("\"points_inline\""), "keyframe points_inline")
check(kfBody.contains("\"depth_ref\":\"p\""), "keyframe depth_ref")
check(kfBody.contains("\"aligned\":false"), "keyframe aligned")

print(failures == 0 ? "\nALL SMOKE CHECKS PASSED" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
