import Foundation
import MapCore
import os

/// Everything that can go wrong talking to the backend.
enum GhostmapAPIError: Error, Sendable, Equatable, LocalizedError {
    /// The backend URL in settings could not be turned into a request URL.
    case invalidURL(path: String)
    /// No bearer token in the keychain (or it was cleared) for a call that needs one.
    case notAuthenticated
    /// URLSession failed before a response arrived.
    case transport(code: URLError.Code, message: String)
    /// The server answered with a non-2xx status. `code` is the backend's error code
    /// (`session_full`, `unauthorized`, …) when the body carried one.
    case server(status: Int, code: String?, message: String?, retryAfter: TimeInterval?)
    /// The body was not the JSON the client expected.
    case decoding(String)
    case encoding(String)
    /// The response was not an HTTP response at all.
    case invalidResponse
    case cancelled

    /// The backend's machine-readable error code, if the server sent one.
    var code: String? {
        if case .server(_, let code, _, _) = self { return code }
        return nil
    }

    var httpStatus: Int? {
        if case .server(let status, _, _, _) = self { return status }
        return nil
    }

    /// The token is missing, expired or rejected — the UI should offer signing in again.
    var requiresSignIn: Bool {
        switch self {
        case .notAuthenticated: return true
        case .server(let status, _, _, _): return status == 401
        default: return false
        }
    }

    /// Worth trying again after a delay.
    var isRetryable: Bool {
        switch self {
        case .transport(let code, _):
            return code == .timedOut || code == .networkConnectionLost || code == .cannotConnectToHost
                || code == .dnsLookupFailed || code == .notConnectedToInternet
        case .server(let status, _, _, _):
            return RetryPolicy.isRetryable(status: status)
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL(let path):
            return "The backend URL is not usable for \(path)."
        case .notAuthenticated:
            return "Sign in to use the Ghostmap backend."
        case .transport(_, let message):
            return message
        case .server(let status, let code, let message, _):
            if let message, !message.isEmpty { return message }
            if let code { return "\(code) (HTTP \(status))" }
            return "The server returned HTTP \(status)."
        case .decoding(let detail):
            return "The server sent something unexpected: \(detail)"
        case .encoding(let detail):
            return "The request could not be encoded: \(detail)"
        case .invalidResponse:
            return "The server sent a response that was not HTTP."
        case .cancelled:
            return "The request was cancelled."
        }
    }
}

/// Where the bearer token comes from. Injectable so tests (and previews) do not touch the keychain.
protocol GhostmapTokenSource: Sendable {
    func bearerToken() -> String?
}

/// The real one: the credentials `AccountStore` wrote into the keychain.
struct KeychainTokenSource: GhostmapTokenSource {
    func bearerToken() -> String? { StoredCredentials.load()?.token }
}

/// A fixed token, for tests.
struct StaticTokenSource: GhostmapTokenSource {
    let token: String?
    func bearerToken() -> String? { token }
}

/// Typed client for the Ghostmap backend (`docs/API.md`).
///
/// One actor owns the `URLSession`, the JSON coders and the current base URL, so the base URL can
/// change (Settings) while requests are in flight without data races. Bodies and responses are
/// `snake_case`-mapped by `MapCore.GhostmapJSON`; the bearer token is read from the keychain per
/// request, so signing out takes effect immediately.
///
/// Retrying: only requests marked *idempotent* are repeated, and only for 5xx/408/429 or a
/// transient transport failure, with exponential backoff (`MapCore.RetryPolicy`). `POST`s that
/// create something — a map, a party, keyframe rows — are never repeated automatically.
actor GhostmapAPI {
    private(set) var baseURL: URL
    private let session: URLSession
    private let tokenSource: any GhostmapTokenSource
    private let retryPolicy: RetryPolicy
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let log = SessionLogger.osLogger(.cloud)

    init(
        baseURL: URL,
        session: URLSession = GhostmapAPI.makeSession(),
        tokenSource: any GhostmapTokenSource = KeychainTokenSource(),
        retryPolicy: RetryPolicy = .default
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenSource = tokenSource
        self.retryPolicy = retryPolicy
        self.decoder = GhostmapJSON.makeDecoder()
        self.encoder = GhostmapJSON.makeEncoder()
    }

    /// An ephemeral-free default session: no cookies, no caching of API responses.
    static func makeSession(timeout: TimeInterval = 30) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = 5 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Points the client at a different deployment. In-flight requests keep the old URL.
    func setBaseURL(_ url: URL) {
        guard url != baseURL else { return }
        baseURL = url
        log.notice("backend base URL set to \(BackendURL.displayString(url), privacy: .public)")
    }

    /// Whether a token is currently available (does not validate it).
    func hasToken() -> Bool { tokenSource.bearerToken() != nil }

    // MARK: - Health and authentication

    /// `GET /health` — public, used by Settings' "Test connection".
    func health() async throws(GhostmapAPIError) -> HealthResponse {
        try await get("/health", authenticated: false)
    }

    /// `POST /v1/auth/google` — exchanges a Google id token for a backend token.
    /// Passing a `device` yields a 30-day `device` token that may map; omitting it yields a
    /// 7-day `user` token that may only view.
    func signInWithGoogle(idToken: String, device: DeviceIdentity?) async throws(GhostmapAPIError) -> AuthResponse {
        try await post("/v1/auth/google", body: GoogleSignInRequest(idToken: idToken, device: device), authenticated: false)
    }

    /// `GET /v1/auth/me` — who the stored token belongs to.
    func me() async throws(GhostmapAPIError) -> MeResponse {
        try await get("/v1/auth/me")
    }

    // MARK: - Maps

    /// `GET /v1/maps`
    func maps(limit: Int? = nil, cursor: String? = nil, status: CloudMapStatus? = nil, sessionId: String? = nil) async throws(GhostmapAPIError) -> MapListResponse {
        var query: [String: String] = [:]
        if let limit { query["limit"] = String(limit) }
        if let cursor { query["cursor"] = cursor }
        if let status { query["status"] = status.rawValue }
        if let sessionId { query["session_id"] = sessionId }
        return try await get("/v1/maps", query: query)
    }

    /// `POST /v1/maps` — registers a map and returns one upload ticket per file.
    func createMap(_ request: CreateMapRequest) async throws(GhostmapAPIError) -> CreateMapResponse {
        try await post("/v1/maps", body: request)
    }

    /// `POST /v1/maps/:id/upload-urls` — fresh tickets for files that expired or failed.
    func mapUploadURLs(mapId: String, files: [CloudMapFile]) async throws(GhostmapAPIError) -> UploadURLsResponse {
        struct Body: Codable, Sendable { let files: [CloudMapFile] }
        return try await post("/v1/maps/\(mapId)/upload-urls", body: Body(files: files), idempotent: true)
    }

    /// `POST /v1/maps/:id/finalize` — marks the map `saved`. The manifest is read from GCS when
    /// `manifest` is nil.
    func finalizeMap(mapId: String, manifest: JSONValue? = nil) async throws(GhostmapAPIError) -> MapEnvelope {
        struct Body: Codable, Sendable { let manifest: JSONValue? }
        return try await post("/v1/maps/\(mapId)/finalize", body: Body(manifest: manifest), idempotent: true)
    }

    /// `GET /v1/maps/:id` — the record plus signed download URLs.
    func map(id: String) async throws(GhostmapAPIError) -> MapDetailResponse {
        try await get("/v1/maps/\(id)")
    }

    /// `PATCH /v1/maps/:id`
    func renameMap(id: String, name: String) async throws(GhostmapAPIError) -> MapEnvelope {
        struct Body: Codable, Sendable { let name: String }
        return try await send(.patch, "/v1/maps/\(id)", body: Body(name: name), idempotent: true)
    }

    /// `DELETE /v1/maps/:id`
    func deleteMap(id: String) async throws(GhostmapAPIError) -> DeleteMapResponse {
        try await send(.delete, "/v1/maps/\(id)", idempotent: true)
    }

    // MARK: - Parties (sessions)

    /// `POST /v1/sessions` — the caller becomes the owner, and a device caller the leader.
    func createSession(_ request: CreateSessionRequest) async throws(GhostmapAPIError) -> SessionEnvelope {
        try await post("/v1/sessions", body: request)
    }

    /// `GET /v1/sessions`
    func sessions(status: SessionStatus? = nil, limit: Int? = nil) async throws(GhostmapAPIError) -> SessionListResponse {
        var query: [String: String] = [:]
        if let status { query["status"] = status.rawValue }
        if let limit { query["limit"] = String(limit) }
        return try await get("/v1/sessions", query: query)
    }

    /// `GET /v1/sessions/:id`
    func session(id: String) async throws(GhostmapAPIError) -> SessionEnvelope {
        try await get("/v1/sessions/\(id)")
    }

    /// `GET /v1/sessions/by-code/:code` — the landing-page summary, including whether this
    /// account may still join.
    func session(code: String) async throws(GhostmapAPIError) -> SessionByCodeResponse {
        try await get("/v1/sessions/by-code/\(Self.pathEscaped(code))")
    }

    /// `POST /v1/sessions/join` — join by invite code. Rejoining is allowed and keeps the colour.
    func joinSession(code: String, kind: ParticipantKind? = nil, displayName: String? = nil) async throws(GhostmapAPIError) -> JoinSessionResponse {
        try await post("/v1/sessions/join", body: JoinSessionRequest(code: code, kind: kind, displayName: displayName), idempotent: true)
    }

    /// `POST /v1/sessions/:id/join`
    func joinSession(id: String, kind: ParticipantKind? = nil, displayName: String? = nil) async throws(GhostmapAPIError) -> JoinSessionResponse {
        try await post("/v1/sessions/\(id)/join", body: JoinSessionRequest(code: nil, kind: kind, displayName: displayName), idempotent: true)
    }

    /// `POST /v1/sessions/:id/leave`
    func leaveSession(id: String) async throws(GhostmapAPIError) -> LeaveSessionResponse {
        try await post("/v1/sessions/\(id)/leave", idempotent: true)
    }

    /// `POST /v1/sessions/:id/end` — owner, leader device or admin only.
    func endSession(id: String) async throws(GhostmapAPIError) -> SessionStatusResponse {
        try await post("/v1/sessions/\(id)/end", idempotent: true)
    }

    /// `POST /v1/sessions/:id/upload-urls` — up to 100 keyframe payload tickets at a time.
    func keyframeUploadURLs(sessionId: String, items: [KeyframeUploadItem]) async throws(GhostmapAPIError) -> KeyframeUploadURLsResponse {
        try await post("/v1/sessions/\(sessionId)/upload-urls", body: KeyframeUploadURLsRequest(items: items), idempotent: true)
    }

    /// `POST /v1/sessions/:id/keyframes` — up to 50 keyframes; also fans them out over Ably.
    /// Never retried automatically: a repeat would register the keyframes twice.
    func registerKeyframes(sessionId: String, keyframes: [SessionKeyframe]) async throws(GhostmapAPIError) -> RegisterKeyframesResponse {
        try await post("/v1/sessions/\(sessionId)/keyframes", body: RegisterKeyframesRequest(keyframes: keyframes))
    }

    /// `GET /v1/sessions/:id/keyframes` — catch-up for a viewer joining mid-party.
    func keyframes(sessionId: String, deviceId: String? = nil, sinceId: Int? = nil, limit: Int? = nil, includeURLs: Bool = false) async throws(GhostmapAPIError) -> KeyframeListResponse {
        var query: [String: String] = [:]
        if let deviceId { query["device_id"] = deviceId }
        if let sinceId { query["since_id"] = String(sinceId) }
        if let limit { query["limit"] = String(limit) }
        if includeURLs { query["urls"] = "1" }
        return try await get("/v1/sessions/\(sessionId)/keyframes", query: query)
    }

    // MARK: - Realtime

    /// `POST /v1/realtime/token` — an Ably token request for the party channel.
    func realtimeToken(sessionId: String? = nil) async throws(GhostmapAPIError) -> RealtimeToken {
        struct Body: Codable, Sendable { let sessionId: String? }
        return try await post("/v1/realtime/token", body: Body(sessionId: sessionId), idempotent: true)
    }

    // MARK: - Transport

    private enum HTTPMethod: String, Sendable {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    private func get<Response: Decodable & Sendable>(
        _ path: String,
        query: [String: String] = [:],
        authenticated: Bool = true
    ) async throws(GhostmapAPIError) -> Response {
        try await send(.get, path, query: query, bodyData: nil, authenticated: authenticated, idempotent: true)
    }

    private func post<Response: Decodable & Sendable>(
        _ path: String,
        authenticated: Bool = true,
        idempotent: Bool = false
    ) async throws(GhostmapAPIError) -> Response {
        try await send(.post, path, bodyData: Data("{}".utf8), authenticated: authenticated, idempotent: idempotent)
    }

    private func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body,
        authenticated: Bool = true,
        idempotent: Bool = false
    ) async throws(GhostmapAPIError) -> Response {
        try await send(.post, path, body: body, authenticated: authenticated, idempotent: idempotent)
    }

    private func send<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ method: HTTPMethod,
        _ path: String,
        body: Body,
        query: [String: String] = [:],
        authenticated: Bool = true,
        idempotent: Bool = false
    ) async throws(GhostmapAPIError) -> Response {
        let data: Data
        do {
            data = try encoder.encode(body)
        } catch {
            throw .encoding(String(describing: error))
        }
        return try await send(method, path, query: query, bodyData: data, authenticated: authenticated, idempotent: idempotent)
    }

    private func send<Response: Decodable & Sendable>(
        _ method: HTTPMethod,
        _ path: String,
        query: [String: String] = [:],
        bodyData: Data? = nil,
        authenticated: Bool = true,
        idempotent: Bool = false
    ) async throws(GhostmapAPIError) -> Response {
        guard let url = BackendURL.endpoint(base: baseURL, path: path, query: query) else {
            throw .invalidURL(path: path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard let token = tokenSource.bearerToken() else { throw .notAuthenticated }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data = try await perform(request, path: path, idempotent: idempotent)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            log.error("\(method.rawValue, privacy: .public) \(path, privacy: .public) decode failed: \(String(describing: error), privacy: .public)")
            throw .decoding(String(describing: error))
        }
    }

    /// Sends the request, retrying idempotent calls that fail transiently.
    private func perform(_ request: URLRequest, path: String, idempotent: Bool) async throws(GhostmapAPIError) -> Data {
        var attempt = 1
        while true {
            do {
                return try await performOnce(request, path: path)
            } catch {
                // Typed throws: `error` is a GhostmapAPIError.
                let mayRetry = idempotent && error.isRetryable && retryPolicy.shouldRetry(afterAttempt: attempt)
                guard mayRetry else { throw error }
                var delay = retryPolicy.delay(beforeAttempt: attempt + 1)
                if case .server(_, _, _, let retryAfter) = error, let retryAfter {
                    delay = min(max(delay, retryAfter), retryPolicy.maxDelay)
                }
                let rounded = String(format: "%.2f", delay)
                log.notice("retrying \(path, privacy: .public) in \(rounded, privacy: .public)s (attempt \(attempt + 1, privacy: .public))")
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    throw GhostmapAPIError.cancelled
                }
                attempt += 1
            }
        }
    }

    /// One HTTP round trip. Non-2xx statuses become `.server`, with the backend's error code when
    /// the body carried one.
    private func performOnce(_ request: URLRequest, path: String) async throws(GhostmapAPIError) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw .cancelled }
            throw .transport(code: error.code, message: error.localizedDescription)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .transport(code: .unknown, message: String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else { throw .invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data)
            let retryAfter = RetryPolicy.retryAfter(header: http.value(forHTTPHeaderField: "Retry-After"))
            let message = envelope?.error.message ?? Self.shortBody(data)
            log.error("\(path, privacy: .public) → HTTP \(http.statusCode) \(envelope?.error.code ?? "-", privacy: .public)")
            throw .server(status: http.statusCode, code: envelope?.error.code, message: message, retryAfter: retryAfter)
        }
        return data
    }

    /// Percent-encodes one path segment (invite codes come from user input and QR codes).
    private static func pathEscaped(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? segment
    }

    /// At most 200 characters of a non-JSON error body, for the log and the UI.
    private static func shortBody(_ data: Data) -> String? {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= 200 ? trimmed : String(trimmed.prefix(200)) + "…"
    }
}
