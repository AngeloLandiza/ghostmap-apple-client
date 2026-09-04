import Foundation
import MapCore
import os

/// One keyframe on its way to a party, already reduced to what the wire needs.
///
/// The pose is `origin_from_camera` when the phone has seen the marker (`aligned == true`) and the
/// raw ARKit world pose otherwise, exactly as `POST /v1/sessions/:id/keyframes` defines it. Depth
/// and confidence are the *unencoded* arrays: LZFSE runs on the streamer's actor so the capture
/// path never pays for it.
struct StreamedKeyframe: Sendable {
    var seq: Int
    var timestamp: Double
    /// 16 floats, column-major.
    var pose: [Double]
    var aligned: Bool
    var intrinsics: KeyframeIntrinsics
    /// `normal | limited | relocalizing | not_available`.
    var trackingState: String
    var worldMappingStatus: String
    var depthMillimeters: [UInt16]
    var confidence: [UInt8]
    /// Flat `x y z r g b`, ≤ 2 000 points, in the same frame as `pose`.
    var pointsInline: [Double]
}

/// Streams keyframes to the party while recording: signed URLs in one batch, the LZFSE depth and
/// confidence payloads straight to GCS, then one `POST /v1/sessions/:id/keyframes` that also fans
/// the keyframe out over Ably.
///
/// The queue is bounded at ``maxPending``: when the network cannot keep up the **oldest** keyframes
/// are dropped (the newest ones are the ones a live viewer wants) and counted, so the status strip
/// can show the loss instead of the app growing without limit. Nothing here throws at the capture
/// path — a party that cannot upload just stops contributing, and the local map is unaffected.
actor KeyframeStreamer {

    /// How many keyframes may wait for the network before the oldest are dropped.
    static let maxPending = 10
    /// How many keyframes go into one round of upload URLs / registration (the backend allows 50).
    static let batchSize = 5

    struct Stats: Sendable, Equatable {
        /// Keyframes waiting to be uploaded.
        var pending = 0
        /// Keyframes registered with the backend.
        var streamed = 0
        /// Keyframes thrown away because the queue was full.
        var dropped = 0
        /// Keyframes registered without their depth payload because the upload failed.
        var partial = 0
        /// Rounds that failed outright; the keyframes in them are lost.
        var failed = 0
        var bytesUploaded = 0
        var lastError: String?
    }

    private let api: GhostmapAPI
    private let sessionID: String
    private let session: URLSession
    private let logger: SessionLogger
    private let log = SessionLogger.osLogger(.cloud)

    private var queue: [StreamedKeyframe] = []
    private var stats = Stats()
    private var pump: Task<Void, Never>?
    private var isStopped = false

    init(api: GhostmapAPI, sessionID: String, logger: SessionLogger, session: URLSession = KeyframeStreamer.makeSession()) {
        self.api = api
        self.sessionID = sessionID
        self.logger = logger
        self.session = session
    }

    /// Uploads are single PUTs of ~50 KB; a short timeout keeps a stalled connection from holding
    /// the queue while newer keyframes pile up behind it.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    // MARK: - Intake

    /// Queues one keyframe, dropping the oldest when the queue is full, and wakes the pump.
    func enqueue(_ keyframe: StreamedKeyframe) {
        guard !isStopped else { return }
        queue.append(keyframe)
        while queue.count > Self.maxPending {
            queue.removeFirst()
            stats.dropped += 1
        }
        stats.pending = queue.count
        startPump()
    }

    func currentStats() -> Stats { stats }

    /// Stops accepting keyframes and waits for what is already queued (bounded by `timeout`).
    func finish(timeout: TimeInterval = 6) async -> Stats {
        isStopped = true
        let deadline = Date().addingTimeInterval(timeout)
        // The queue empties as soon as a batch is *taken*, so the pump has to be idle too before
        // the last round can be called finished.
        while pump != nil || !queue.isEmpty {
            guard Date() < deadline else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        pump?.cancel()
        pump = nil
        if !queue.isEmpty {
            stats.dropped += queue.count
            queue.removeAll()
            stats.pending = 0
        }
        logger.log(.cloud, "party stream finished: streamed=\(stats.streamed) dropped=\(stats.dropped) partial=\(stats.partial) failed=\(stats.failed) bytes=\(stats.bytesUploaded)")
        return stats
    }

    /// Drops everything immediately (leaving a party, or the party ending).
    func cancel() {
        isStopped = true
        pump?.cancel()
        pump = nil
        stats.dropped += queue.count
        queue.removeAll()
        stats.pending = 0
    }

    // MARK: - Pump

    private func startPump() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            await self?.drain()
            await self?.pumpFinished()
        }
    }

    private func pumpFinished() {
        pump = nil
        // A keyframe may have arrived while the last round was finishing.
        if !queue.isEmpty, !isStopped { startPump() }
    }

    private func drain() async {
        while !Task.isCancelled, !queue.isEmpty {
            let batch = Array(queue.prefix(Self.batchSize))
            queue.removeFirst(batch.count)
            stats.pending = queue.count
            await send(batch)
        }
    }

    /// One round: upload URLs → PUT the payloads → register. Every step degrades instead of throwing:
    /// with no upload URLs the keyframes are still registered so peers get their inline points.
    private func send(_ batch: [StreamedKeyframe]) async {
        var uploads: [KeyframeUpload] = []
        do {
            let items = batch.map { KeyframeUploadItem(seq: $0.seq, kinds: [.depth, .confidence]) }
            uploads = try await api.keyframeUploadURLs(sessionId: sessionID, items: items).uploads
        } catch {
            note(error, step: "upload-urls")
        }

        var refs: [Int: (depth: String?, confidence: String?, bytes: Int)] = [:]
        for keyframe in batch {
            guard !Task.isCancelled else { return }
            var depthRef: String?
            var confidenceRef: String?
            var bytes = 0
            if let ticket = uploads.first(where: { $0.seq == keyframe.seq && $0.kind == .depth }) {
                if let count = await put(payload: { try DepthCodec.encodeDepth(keyframe.depthMillimeters) }, to: ticket) {
                    depthRef = ticket.path
                    bytes += count
                }
            }
            if let ticket = uploads.first(where: { $0.seq == keyframe.seq && $0.kind == .confidence }) {
                if let count = await put(payload: { try DepthCodec.encodeConfidence(keyframe.confidence) }, to: ticket) {
                    confidenceRef = ticket.path
                    bytes += count
                }
            }
            refs[keyframe.seq] = (depthRef, confidenceRef, bytes)
        }

        let wire = batch.map { keyframe -> SessionKeyframe in
            let ref = refs[keyframe.seq]
            return SessionKeyframe(
                seq: keyframe.seq,
                t: keyframe.timestamp,
                pose: keyframe.pose,
                intrinsics: keyframe.intrinsics,
                trackingState: keyframe.trackingState,
                worldMappingStatus: keyframe.worldMappingStatus,
                aligned: keyframe.aligned,
                depthRef: ref?.depth,
                confidenceRef: ref?.confidence,
                pointsInline: keyframe.pointsInline.isEmpty ? nil : keyframe.pointsInline,
                bytes: ref?.bytes ?? 0)
        }
        do {
            let registered = try await api.registerKeyframes(sessionId: sessionID, keyframes: wire)
            stats.streamed += registered.registered.isEmpty ? wire.count : registered.registered.count
            stats.bytesUploaded += refs.values.reduce(0) { $0 + $1.bytes }
            stats.partial += wire.filter { $0.depthRef == nil }.count
        } catch {
            stats.failed += wire.count
            note(error, step: "keyframes")
        }
    }

    /// PUTs one payload to its signed URL. Returns the byte count on success, nil on any failure —
    /// the keyframe is still registered, just without that reference.
    private func put(payload: () throws -> Data, to upload: KeyframeUpload) async -> Int? {
        let data: Data
        do {
            data = try payload()
        } catch {
            log.error("keyframe payload encoding failed seq=\(upload.seq, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let url = URL(string: upload.url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = upload.method.isEmpty ? "PUT" : upload.method
        for (field, value) in upload.headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = data
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard (200...299).contains(http.statusCode) else {
                stats.lastError = "upload \(upload.kind.rawValue) returned HTTP \(http.statusCode)"
                return nil
            }
            return data.count
        } catch {
            stats.lastError = (error as? URLError)?.localizedDescription ?? String(describing: error)
            return nil
        }
    }

    private func note(_ error: GhostmapAPIError, step: String) {
        stats.lastError = error.localizedDescription
        logger.log(.cloud, "party \(step) failed: \(error.localizedDescription)", level: .error)
    }
}
