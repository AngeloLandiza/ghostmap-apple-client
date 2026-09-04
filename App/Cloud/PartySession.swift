import Foundation
import MapCore
import Metal
import Observation
import os
import simd

/// The party this phone is currently in, remembered across launches so a crash or a backgrounded
/// app can rejoin instead of starting a second party in the same room.
struct PartyMembership: Codable, Sendable, Equatable {
    var sessionID: String
    var code: String?
    var name: String
    var joinedAt: Date

    private static let key = "tech.alandiza.roommapper.party"

    static func load(defaults: UserDefaults = .standard) -> PartyMembership? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PartyMembership.self, from: data)
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: PartyMembership.key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

/// A collaborative session ("party"): several phones mapping one room into one coordinate frame.
///
/// It owns the backend calls (`POST /v1/sessions`, `/join`, `/leave`, `/end`), the Ably subscription
/// that carries peers' keyframes and poses, the peers' GPU clouds, and — while a recording is
/// running — the ``KeyframeStreamer`` that pushes this phone's keyframes out.
///
/// Everything degrades: with no account, no network or no Ably the party screen explains what is
/// missing and capture continues exactly as it does solo. Nothing in the capture pipeline waits on
/// anything here.
@Observable
@MainActor
final class PartySession {

    enum Phase: Sendable, Equatable {
        case idle
        case creating
        case joining
        case active
        case leaving
        case ending
    }

    /// The state of the live channel, shown as a dot on the party screen.
    enum Connection: Sendable, Equatable {
        case offline
        case connecting
        case live
        /// Connected to the backend but not to the realtime channel; peers will not appear.
        case degraded(String)

        var isLive: Bool { self == .live }
    }

    /// How often this phone publishes its camera pose while in a party (the contract's ≤ 10 Hz).
    static let posePublishInterval: TimeInterval = 0.1
    /// Republish even when standing still, so a viewer's frustum does not look frozen.
    static let poseHeartbeat: TimeInterval = 1.0
    /// Movement that makes a new pose worth a message.
    static let poseTranslationEpsilon: Float = 0.01
    static let poseRotationEpsilonDegrees: Float = 1.0

    private(set) var phase: Phase = .idle
    private(set) var connection: Connection = .offline
    private(set) var session: CloudSession?
    private(set) var participants: [SessionParticipant] = []
    private(set) var me: SessionParticipant?
    private(set) var channel: String?
    private(set) var shareURL: String?
    private(set) var lastError: String?
    private(set) var streamStats = KeyframeStreamer.Stats()
    private(set) var publishedPoses = 0
    /// A party this phone was in when it was last running, offered for rejoin.
    private(set) var remembered: PartyMembership?

    /// Every peer's live cloud, read by both renderers.
    let peers: PeerCloudStore

    /// Supplies the pose to publish; set by `CaptureSession` while the capture screen is up.
    @ObservationIgnored var poseProvider: (@MainActor () -> AlignedPose?)?

    private let api: GhostmapAPI
    private let account: AccountStore
    private let log = SessionLogger.osLogger(.cloud)

    @ObservationIgnored private var realtime: AblyRealtime?
    @ObservationIgnored private var realtimeTask: Task<Void, Never>?
    @ObservationIgnored private var poseTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private(set) var streamer: KeyframeStreamer?
    @ObservationIgnored private var lastPublishedPose: Pose?
    @ObservationIgnored private var lastPublishedAt: Date?

    init(api: GhostmapAPI, account: AccountStore, device: MTLDevice) {
        self.api = api
        self.account = account
        self.peers = PeerCloudStore(device: device, ownDeviceID: account.deviceID.uuidString.lowercased())
        self.remembered = PartyMembership.load()
    }

    // MARK: - Derived state

    var isActive: Bool { session?.status == .active && phase == .active }
    var isBusy: Bool { phase == .creating || phase == .joining || phase == .leaving || phase == .ending }
    var inviteCode: String? { session?.inviteCode }
    var participantCount: Int { activeParticipants.count }
    var maxParticipants: Int { session?.maxParticipants ?? 4 }
    var activeParticipants: [SessionParticipant] { participants.filter(\.isActive) }
    var isFull: Bool { participantCount >= maxParticipants }
    /// This phone may stream keyframes: a device token, in an active party, not joined as a viewer.
    /// A missing participant row falls back to the token's role rather than blocking the stream.
    var canStream: Bool { isActive && account.canMap && me?.kind != .viewer }
    /// This account may end the party (the backend also allows the leader device and admins).
    var canEnd: Bool {
        guard let session else { return false }
        if let owner = session.ownerUserId, let user = account.user?.id { return owner == user }
        if let leader = session.leaderDeviceId { return leader == ownDeviceID }
        return false
    }
    var ownDeviceID: String { account.deviceID.uuidString.lowercased() }
    /// The colour this phone was given, for the local frustum and the strip.
    var myColor: PartyColor? {
        guard let me else { return nil }
        let index = participants.firstIndex { $0.id == me.id } ?? 0
        return PartyColor.resolve(hex: me.color, index: index)
    }
    /// The link a QR code should carry: the dashboard's share URL when the backend sent one,
    /// otherwise the app's own `ghostmap://join/<code>` deep link.
    var joinLink: URL? {
        if let shareURL, let url = URL(string: shareURL) { return url }
        guard let code = inviteCode else { return nil }
        return PartyCode.appURL(code: code)
    }

    func colour(for participant: SessionParticipant) -> PartyColor {
        let index = participants.firstIndex { $0.id == participant.id } ?? 0
        return PartyColor.resolve(hex: participant.color, index: index)
    }

    func clearError() { lastError = nil }

    // MARK: - Creating and joining

    /// `POST /v1/sessions`. The origin is the printed marker when marker mode is on, so every phone
    /// that sees the same sheet shares one frame; otherwise the creator's session start.
    @discardableResult
    func create(name: String, markerOrigin: Bool, maxParticipants: Int = 4) async -> Bool {
        guard phase == .idle else { return false }
        guard account.isSignedIn else {
            lastError = "Sign in on the Settings screen before starting a party."
            return false
        }
        phase = .creating
        lastError = nil
        defer { if phase == .creating { phase = .idle } }
        let origin: CloudOrigin = markerOrigin ? .marker(MarkerReference.name) : .sessionStart
        let request = CreateSessionRequest(name: name, origin: origin, maxParticipants: maxParticipants)
        do {
            let envelope = try await api.createSession(request)
            apply(session: envelope.session, participants: envelope.participants, channel: envelope.channel, shareURL: envelope.shareUrl)
            // The creator is already a participant; `me` comes from the participant list.
            me = envelope.participants.first { $0.deviceId?.lowercased() == ownDeviceID }
                ?? envelope.participants.first { $0.userId != nil && $0.userId == account.user?.id }
            phase = .active
            log.notice("party created: \(envelope.session.inviteCode ?? "-", privacy: .public) origin=\(origin.type, privacy: .public)")
            await startRealtime()
            return true
        } catch {
            lastError = message(for: error)
            log.error("party create failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// `GET /v1/sessions/by-code/:code` — the landing summary shown before joining.
    func preview(code raw: String) async -> SessionByCodeResponse? {
        let code: String
        do {
            code = try PartyCode.validated(raw)
        } catch {
            lastError = error.description
            return nil
        }
        lastError = nil
        do {
            return try await api.session(code: code)
        } catch {
            lastError = message(for: error)
            return nil
        }
    }

    /// `POST /v1/sessions/join`. Rejoining an existing party is allowed and keeps the colour.
    @discardableResult
    func join(code raw: String) async -> Bool {
        guard phase == .idle || phase == .active else { return false }
        guard account.isSignedIn else {
            lastError = "Sign in on the Settings screen before joining a party."
            return false
        }
        let code: String
        do {
            code = try PartyCode.validated(raw)
        } catch {
            lastError = error.description
            return false
        }
        phase = .joining
        lastError = nil
        defer { if phase == .joining { phase = .idle } }
        do {
            let response = try await api.joinSession(code: code, kind: account.canMap ? .device : .viewer)
            adopt(response)
            phase = .active
            log.notice("joined party \(code, privacy: .public) as \(response.me?.kind.rawValue ?? "-", privacy: .public)")
            await startRealtime()
            return true
        } catch {
            lastError = message(for: error)
            log.error("party join failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Rejoins the party this phone was in before (`POST /v1/sessions/:id/join`).
    @discardableResult
    func rejoin() async -> Bool {
        guard let remembered else { return false }
        if let code = remembered.code { return await join(code: code) }
        guard phase == .idle, account.isSignedIn else { return false }
        phase = .joining
        lastError = nil
        defer { if phase == .joining { phase = .idle } }
        do {
            let response = try await api.joinSession(id: remembered.sessionID, kind: account.canMap ? .device : .viewer)
            adopt(response)
            phase = .active
            await startRealtime()
            return true
        } catch {
            lastError = message(for: error)
            return false
        }
    }

    /// Forgets a party that can no longer be rejoined.
    func forgetRemembered() {
        remembered = nil
        PartyMembership.clear()
    }

    private func adopt(_ response: JoinSessionResponse) {
        apply(session: response.session, participants: response.participants, channel: response.channel, shareURL: response.shareUrl)
        me = response.me
    }

    private func apply(session: CloudSession, participants: [SessionParticipant], channel: String?, shareURL: String?) {
        // Switching parties: the previous party's clouds are in a different origin frame.
        if let current = self.session, current.id != session.id { peers.removeAll() }
        self.session = session
        self.participants = participants
        self.channel = channel ?? "session:\(session.id)"
        self.shareURL = shareURL
        peers.ownDeviceID = ownDeviceID
        peers.apply(participants: participants)
        let membership = PartyMembership(sessionID: session.id, code: session.inviteCode, name: session.name, joinedAt: Date())
        membership.save()
        remembered = membership
    }

    /// `GET /v1/sessions/:id` — refreshes the participant list and the status.
    func refresh() async {
        guard let id = session?.id else { return }
        do {
            let envelope = try await api.session(id: id)
            session = envelope.session
            participants = envelope.participants
            peers.apply(participants: envelope.participants)
            if let mine = envelope.participants.first(where: { $0.deviceId?.lowercased() == ownDeviceID }) { me = mine }
            if envelope.session.status != .active { await handleEnded(reason: envelope.session.status.rawValue) }
        } catch {
            lastError = message(for: error)
        }
    }

    // MARK: - Leaving and ending

    /// `POST /v1/sessions/:id/leave`. The party keeps running for everyone else.
    func leave() async {
        guard let id = session?.id else { return }
        phase = .leaving
        await stopRealtime()
        await streamer?.cancel()
        streamer = nil
        do {
            let response = try await api.leaveSession(id: id)
            participants = response.participants ?? participants
        } catch {
            lastError = message(for: error)
        }
        reset()
        forgetRemembered()
    }

    /// `POST /v1/sessions/:id/end` — owner, leader device or admin only.
    func end() async {
        guard let id = session?.id else { return }
        phase = .ending
        do {
            let response = try await api.endSession(id: id)
            session = response.session
        } catch {
            lastError = message(for: error)
            phase = .active
            return
        }
        await stopRealtime()
        await streamer?.cancel()
        streamer = nil
        reset()
        forgetRemembered()
    }

    private func handleEnded(reason: String) async {
        guard session != nil else { return }
        log.notice("party ended (\(reason, privacy: .public))")
        lastError = "This party has ended."
        await stopRealtime()
        await streamer?.cancel()
        streamer = nil
        reset()
        forgetRemembered()
    }

    private func reset() {
        session = nil
        participants = []
        me = nil
        channel = nil
        shareURL = nil
        phase = .idle
        connection = .offline
        publishedPoses = 0
        streamStats = KeyframeStreamer.Stats()
        peers.removeAll()
    }

    // MARK: - Streaming this phone's keyframes

    /// Starts a keyframe stream for a recording. Returns nil when this phone may not map into the
    /// party (no device token, viewer role, no active party), which is not an error — capture just
    /// stays local.
    @discardableResult
    func beginStreaming(logger: SessionLogger) -> KeyframeStreamer? {
        guard canStream, let id = session?.id else { return nil }
        let streamer = KeyframeStreamer(api: api, sessionID: id, logger: logger)
        self.streamer = streamer
        startStatsLoop()
        logger.log(.cloud, "party stream started for session \(id)")
        return streamer
    }

    /// Drains the queue and stops reporting. Safe to call when no stream is running.
    func endStreaming() async {
        guard let streamer else { return }
        self.streamer = nil
        statsTask?.cancel()
        statsTask = nil
        streamStats = await streamer.finish()
    }

    private func startStatsLoop() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let streamer = self.streamer else { return }
                self.streamStats = await streamer.currentStats()
            }
        }
    }

    // MARK: - Realtime

    private func startRealtime() async {
        await stopRealtime()
        guard let channel else { return }
        connection = .connecting
        let api = self.api
        let sessionID = session?.id
        let realtime = AblyRealtime(channel: channel, tokenProvider: { [weak self] in
            guard let sessionID else { return nil }
            do {
                return try await api.realtimeToken(sessionId: sessionID)
            } catch {
                // The closure is untyped, so this is `any Error`; only the text is needed.
                await self?.noteTokenFailure(error.localizedDescription)
                return nil
            }
        })
        self.realtime = realtime
        realtimeTask = Task { [weak self] in
            for await event in realtime.events {
                guard let self else { return }
                self.handle(event)
            }
        }
        await realtime.start()
        startPoseLoop()
    }

    private func noteTokenFailure(_ message: String) {
        connection = .degraded(message)
    }

    private func stopRealtime() async {
        poseTask?.cancel()
        poseTask = nil
        realtimeTask?.cancel()
        realtimeTask = nil
        if let realtime { await realtime.stop() }
        realtime = nil
        connection = .offline
    }

    private func handle(_ event: AblyRealtimeEvent) {
        switch event {
        case .opened:
            connection = .live
            lastError = nil
        case .interrupted(let reason):
            connection = .degraded(reason)
        case .failed(let error):
            connection = .degraded(error.localizedDescription)
        case .message(let message):
            handle(message)
        }
    }

    private func handle(_ message: AblyMessage) {
        switch message.name {
        case "keyframes":
            ingestKeyframes(message.data)
        case "pose":
            ingestPose(message.data)
        case "participant":
            ingestParticipant(message.data)
        case "session":
            if message.data["event"]?.stringValue == "ended" {
                Task { await self.handleEnded(reason: "ended") }
            }
        case "merge":
            let event = message.data["event"]?.stringValue ?? "updated"
            log.notice("party merge \(event, privacy: .public)")
        default:
            break
        }
    }

    /// A peer's keyframes: their inline points, tinted with their colour, plus the newest pose.
    ///
    /// The decoding cost is bounded by the contract — at most 2 000 points per keyframe and 50
    /// keyframes per message, and in practice ``KeyframeStreamer/batchSize`` — so it stays inside a
    /// frame on the main actor rather than needing a hop and losing message ordering.
    private func ingestKeyframes(_ data: JSONValue) {
        guard let deviceID = data["device_id"]?.stringValue, deviceID.lowercased() != ownDeviceID else { return }
        guard let frames = data["keyframes"]?.arrayValue, !frames.isEmpty else { return }
        let colour = data["color"]?.stringValue.flatMap(PartyColor.init(hex:))
        guard let peer = peers.peer(deviceID: deviceID,
                                    displayName: nil,
                                    color: colour,
                                    userID: data["user_id"]?.stringValue) else { return }
        var points: [PackedPoint] = []
        for frame in frames {
            if let inline = frame["points_inline"]?.arrayValue, !inline.isEmpty {
                points.append(contentsOf: InlinePoints.decode(inline.map { $0.doubleValue ?? 0 }, tint: peer.color))
            }
            if let pose = Self.pose(from: frame["pose"]) {
                peer.note(pose: pose.matrix, aligned: frame["aligned"]?.boolValue ?? true)
            }
        }
        peer.noteKeyframes(frames.count)
        peer.ingest(points: points)
    }

    private func ingestPose(_ data: JSONValue) {
        guard let deviceID = data["device_id"]?.stringValue, deviceID.lowercased() != ownDeviceID else { return }
        guard let pose = Self.pose(from: data["pose"]) else { return }
        guard let peer = peers.peer(deviceID: deviceID, displayName: nil, color: nil) else { return }
        peer.note(pose: pose.matrix, aligned: data["aligned"]?.boolValue ?? true)
    }

    private func ingestParticipant(_ data: JSONValue) {
        guard let object = data["participant"]?.objectValue else { return }
        let event = data["event"]?.stringValue ?? "joined"
        guard let id = object["id"]?.stringValue else { return }
        let deviceID = object["device_id"]?.stringValue ?? object["deviceId"]?.stringValue
        if event == "left" {
            participants.removeAll { $0.id == id }
            if let deviceID { peers.remove(deviceID: deviceID) }
        }
        // The authoritative list comes from the API; the message only tells us it changed.
        Task { await self.refresh() }
    }

    /// 16 column-major floats off the wire, as a pose. Rejects anything else.
    static func pose(from value: JSONValue?) -> Pose? {
        guard let values = value?.arrayValue, values.count == 16 else { return nil }
        var floats: [Float] = []
        floats.reserveCapacity(16)
        for entry in values {
            guard let number = entry.doubleValue, number.isFinite else { return nil }
            floats.append(Float(number))
        }
        return Pose(columnMajorArray: floats)
    }

    // MARK: - Publishing this phone's pose

    private func startPoseLoop() {
        poseTask?.cancel()
        poseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(PartySession.posePublishInterval))
                guard let self else { return }
                await self.publishPoseIfNeeded()
            }
        }
    }

    /// Publishes `pose` when the camera has actually moved, and at least once a second so a viewer's
    /// frustum does not look frozen. Together with the 100 ms tick this stays inside the contract's
    /// 10 Hz ceiling while costing far fewer Ably messages when the phone is still.
    private func publishPoseIfNeeded() async {
        // Only a mapper's pose means anything to the others; a viewer has nothing to show.
        guard canStream, let realtime, let provider = poseProvider, let aligned = provider() else { return }
        let now = Date()
        if let last = lastPublishedPose, let at = lastPublishedAt, now.timeIntervalSince(at) < Self.poseHeartbeat {
            let moved = last.translationDistance(to: aligned.pose) > Self.poseTranslationEpsilon
                || last.rotationAngleDegrees(to: aligned.pose) > Self.poseRotationEpsilonDegrees
            guard moved else { return }
        }
        lastPublishedPose = aligned.pose
        lastPublishedAt = now
        let payload = JSONValue.object([
            "device_id": .string(ownDeviceID),
            "t": .double(Date().timeIntervalSince1970),
            "pose": .array(aligned.pose.columnMajorArray.map { .double(Double($0)) }),
            "aligned": .bool(aligned.aligned),
        ])
        do {
            try await realtime.publish(name: "pose", data: payload)
            publishedPoses += 1
            if case .degraded = connection { connection = .live }
        } catch {
            if error == .cancelled { return }
            connection = .degraded(error.localizedDescription)
        }
    }

    // MARK: - Errors

    /// Turns the backend's error codes into something a person can act on.
    private func message(for error: GhostmapAPIError) -> String {
        switch error.code {
        case "session_full": return JoinRejection.sessionFull.message
        case "session_ended": return JoinRejection.sessionEnded.message
        case "not_found": return "No party has that code."
        case "forbidden": return "This account is not allowed in that party."
        default: break
        }
        if error.requiresSignIn { return "Sign in again on the Settings screen." }
        return error.localizedDescription
    }
}
