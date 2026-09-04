import Foundation
import MapCore
import os

/// Everything that can go wrong talking to Ably directly.
enum AblyError: Error, Sendable, Equatable, LocalizedError {
    /// The backend answered `realtime: null` — Ably is not configured on that deployment.
    case notConfigured
    /// `token_request` was not a shape this client understands.
    case invalidTokenRequest(String)
    /// The channel name could not be put in a URL.
    case invalidChannel(String)
    case transport(code: URLError.Code, message: String)
    /// Ably answered with a non-2xx status; `code` is Ably's numeric error code when it sent one.
    case server(status: Int, code: Int?, message: String?)
    case invalidResponse
    case cancelled

    /// A rejected or expired token: the caller should ask the backend for a new one.
    var requiresNewToken: Bool {
        if case .server(let status, _, _) = self { return status == 401 || status == 403 }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Live updates are not configured on this backend."
        case .invalidTokenRequest(let detail):
            return "The realtime token could not be used: \(detail)"
        case .invalidChannel(let channel):
            return "\"\(channel)\" is not a usable channel name."
        case .transport(_, let message):
            return message
        case .server(let status, let code, let message):
            if let message, !message.isEmpty { return message }
            if let code { return "Ably error \(code) (HTTP \(status))." }
            return "Ably returned HTTP \(status)."
        case .invalidResponse:
            return "Ably sent a response that was not HTTP."
        case .cancelled:
            return "The realtime connection was cancelled."
        }
    }
}

/// An Ably token, ready to authenticate both the SSE stream and REST calls.
struct AblyToken: Sendable, Equatable {
    let token: String
    let expiresAt: Date?

    /// Ably's token auth over REST: the token string, base64-encoded, with the `Bearer` scheme.
    var authorizationValue: String { AblyWire.authorizationValue(token: token) }

    func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(-leeway) <= now
    }
}

/// One message off the channel, with Ably's envelope already unwrapped.
struct AblyMessage: Sendable, Equatable {
    /// The publisher's message name: `keyframes`, `pose`, `participant`, `session`, `merge`.
    let name: String
    let data: JSONValue
    let clientId: String?
    let connectionId: String?
}

/// A presence member as `GET /channels/:channel/presence` reports it.
struct AblyPresenceMember: Sendable, Equatable {
    let clientId: String?
    let action: String?
    let data: JSONValue
}

/// What a subscriber sees.
enum AblyRealtimeEvent: Sendable {
    /// The SSE stream is open and delivering.
    case opened
    case message(AblyMessage)
    /// The stream dropped; the client is backing off and will reconnect on its own.
    case interrupted(String)
    /// A failure the client cannot recover from by retrying (no token, Ably not configured).
    case failed(AblyError)
}

/// Ably without the Ably SDK: a streaming `URLSession` data task against the SSE adapter for
/// subscribing, and plain REST calls for publishing and reading presence.
///
/// The flow is: the backend's `POST /v1/realtime/token` returns a signed Ably **TokenRequest**
/// (`keyName`, `nonce`, `mac`, …), which this actor exchanges at
/// `POST https://rest.ably.io/keys/<keyName>/requestToken` for a real token, then uses as
/// `accessToken` on `https://realtime.ably.io/sse` and as `Authorization: Bearer <base64 token>`
/// on `https://rest.ably.io/channels/<channel>/messages`.
///
/// The stream reconnects by itself with exponential backoff, resuming from the last event id, and
/// fetches a fresh token whenever Ably rejects the current one or it is close to expiry. Everything
/// degrades to "no live updates": with no network, no token or no Ably at all the actor keeps
/// emitting `interrupted`/`failed` and the app carries on capturing locally.
actor AblyRealtime {
    /// Supplies the backend's `POST /v1/realtime/token` answer. Returns nil when the call failed or
    /// the deployment has no Ably, which the actor reports as ``AblyError/notConfigured``.
    typealias TokenProvider = @Sendable () async -> RealtimeToken?

    static let defaultRESTHost = "rest.ably.io"
    static let defaultSSEHost = "realtime.ably.io"
    /// The SSE protocol version this client speaks.
    static let protocolVersion = "1.2"
    /// Backoff bounds for reconnecting.
    static let minimumBackoff: TimeInterval = 1
    static let maximumBackoff: TimeInterval = 30

    nonisolated let channel: String
    /// The event stream; iterate it once (a second iteration sees only later events).
    nonisolated let events: AsyncStream<AblyRealtimeEvent>

    private nonisolated let continuation: AsyncStream<AblyRealtimeEvent>.Continuation
    private let tokenProvider: TokenProvider
    private let session: URLSession
    private let restHost: String
    private let sseHost: String
    private let log = SessionLogger.osLogger(.cloud)

    private var token: AblyToken?
    private var loop: Task<Void, Never>?
    private var lastEventID: String?
    private(set) var isConnected = false
    private(set) var receivedMessages = 0
    private(set) var publishedMessages = 0
    private(set) var reconnects = 0

    init(channel: String,
         tokenProvider: @escaping TokenProvider,
         session: URLSession = AblyRealtime.makeSession(),
         restHost: String = AblyRealtime.defaultRESTHost,
         sseHost: String = AblyRealtime.defaultSSEHost) {
        self.channel = channel
        self.tokenProvider = tokenProvider
        self.session = session
        self.restHost = restHost
        self.sseHost = sseHost
        let (stream, continuation) = AsyncStream<AblyRealtimeEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        self.events = stream
        self.continuation = continuation
    }

    /// A session tuned for a long-lived stream: the request timeout has to outlast Ably's keep-alive
    /// interval, and the resource timeout has to not apply at all.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = true
        configuration.networkServiceType = .responsiveData
        return URLSession(configuration: configuration)
    }

    // MARK: - Lifecycle

    /// Starts (or restarts) the subscription. Safe to call twice.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    /// Stops the subscription and finishes the event stream.
    func stop() {
        loop?.cancel()
        loop = nil
        isConnected = false
        continuation.finish()
    }

    deinit {
        loop?.cancel()
        continuation.finish()
    }

    // MARK: - Subscribing

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            var delivered = false
            do {
                let token = try await currentToken()
                delivered = try await stream(token: token)
                // A clean end-of-stream is normal (Ably rotates connections); reconnect promptly.
                attempt = delivered ? 0 : attempt + 1
            } catch {
                isConnected = false
                if Task.isCancelled { break }
                if error == .cancelled { break }
                if error.requiresNewToken {
                    log.notice("ably token rejected; refreshing")
                    self.token = nil
                }
                if error == .notConfigured {
                    continuation.yield(.failed(error))
                    // Nothing to retry against until the app asks again.
                    break
                }
                continuation.yield(.interrupted(error.localizedDescription))
                attempt += 1
            }
            guard !Task.isCancelled else { break }
            reconnects += 1
            let delay = Self.backoff(attempt: attempt)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                break
            }
        }
        isConnected = false
    }

    private func noteDelivery() {
        if !isConnected {
            isConnected = true
            continuation.yield(.opened)
        }
    }

    /// Full jitter is not needed here (one client, one channel); a doubling delay capped at 30 s is.
    static func backoff(attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return minimumBackoff }
        let raw = minimumBackoff * pow(2, Double(min(attempt, 8) - 1))
        return min(raw, maximumBackoff)
    }

    /// Runs one SSE connection until it ends. Returns true when at least one event arrived, which is
    /// what tells the caller the connection was healthy and the backoff can reset.
    private func stream(token: AblyToken) async throws(AblyError) -> Bool {
        guard let url = sseURL(token: token) else { throw .invalidChannel(channel) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        var parser = ServerSentEventParser()
        var delivered = false
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AblyError.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                throw AblyError.server(status: http.statusCode, code: nil, message: "the SSE stream was refused")
            }
            log.notice("ably sse open on \(self.channel, privacy: .public)")
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard let event = parser.consume(line: line) else { continue }
                lastEventID = parser.lastEventID
                delivered = true
                noteDelivery()
                handle(event)
            }
        } catch let error as URLError {
            if error.code == .cancelled { throw .cancelled }
            throw .transport(code: error.code, message: error.localizedDescription)
        } catch let error as AblyError {
            throw error
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .transport(code: .unknown, message: String(describing: error))
        }
        return delivered
    }

    private func sseURL(token: AblyToken) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = sseHost
        components.path = "/sse"
        var items = [
            URLQueryItem(name: "channels", value: channel),
            URLQueryItem(name: "v", value: Self.protocolVersion),
            URLQueryItem(name: "accessToken", value: token.token),
        ]
        // Resume where the last connection stopped so a blip does not lose keyframes.
        if let lastEventID { items.append(URLQueryItem(name: "lastEvent", value: lastEventID)) }
        components.queryItems = items
        return components.url
    }

    /// Turns one SSE event into an `AblyRealtimeEvent`. Ably's SSE adapter is *enveloped*: the
    /// `data:` payload is a JSON object carrying `name`, `data`, `clientId` and `connectionId`.
    private func handle(_ event: ServerSentEvent) {
        guard let payload = event.data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: payload),
              let value = JSONValue(any: json) else {
            log.error("ably sse: undecodable \(event.event, privacy: .public) payload")
            return
        }
        switch event.event {
        case "error":
            let failure = AblyWire.error(from: value)
            if AblyError.server(status: failure.statusCode, code: failure.code, message: failure.message).requiresNewToken {
                token = nil
            }
            log.error("ably sse error: \(failure.message, privacy: .public)")
            continuation.yield(.interrupted(failure.message))
        case "message", "presence":
            guard let parsed = AblyWire.message(from: value) else { return }
            receivedMessages += 1
            continuation.yield(.message(AblyMessage(
                name: parsed.name,
                data: parsed.data,
                clientId: parsed.clientID,
                connectionId: parsed.connectionID)))
        default:
            break
        }
    }

    // MARK: - Publishing

    /// `POST https://rest.ably.io/channels/<channel>/messages`. Used for `pose` at ≤ 10 Hz; the
    /// caller does the rate limiting.
    func publish(name: String, data: JSONValue) async throws(AblyError) {
        let token = try await currentToken()
        guard let url = restURL(path: "/channels/\(Self.pathEscaped(channel))/messages") else {
            throw .invalidChannel(channel)
        }
        let body = JSONValue.object(["name": .string(name), "data": data])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token.authorizationValue, forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body.anyValue)
        } catch {
            throw .invalidTokenRequest(String(describing: error))
        }
        do {
            _ = try await perform(request)
            publishedMessages += 1
        } catch {
            if error.requiresNewToken { self.token = nil }
            throw error
        }
    }

    /// `GET https://rest.ably.io/channels/<channel>/presence` — who Ably currently has present.
    ///
    /// Ably's REST API can *read* presence but cannot enter it: entering requires a realtime
    /// (WebSocket) connection, which this dependency-free client does not open. See DECISIONS.md.
    func presenceMembers() async throws(AblyError) -> [AblyPresenceMember] {
        let token = try await currentToken()
        guard let url = restURL(path: "/channels/\(Self.pathEscaped(channel))/presence") else {
            throw .invalidChannel(channel)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token.authorizationValue, forHTTPHeaderField: "Authorization")
        let data = try await perform(request)
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let value = JSONValue(any: json), let rows = value.arrayValue else {
            return []
        }
        return rows.map {
            AblyPresenceMember(clientId: $0["clientId"]?.stringValue,
                               action: $0["action"]?.stringValue,
                               data: AblyWire.unwrap($0["data"]))
        }
    }

    // MARK: - Tokens

    /// The current token, fetching and exchanging a new one when there is none or it is near expiry.
    private func currentToken() async throws(AblyError) -> AblyToken {
        if let token, !token.isExpired() { return token }
        guard let realtime = await tokenProvider(), let request = realtime.tokenRequest, !request.isNull else {
            throw .notConfigured
        }
        let fresh = try await exchange(request)
        token = fresh
        return fresh
    }

    /// Turns whatever `POST /v1/realtime/token` returned into a usable token.
    ///
    /// Three shapes are accepted: a signed **TokenRequest** (what Ably's SDK would exchange, and
    /// what the backend sends today), a **TokenDetails** object that already carries `token`, and a
    /// bare token string — so a backend change on either side does not break the app.
    private func exchange(_ request: JSONValue) async throws(AblyError) -> AblyToken {
        let keyName: String
        switch AblyWire.tokenSource(from: request) {
        case .literal(let token):
            return AblyToken(token: token, expiresAt: nil)
        case .details(let token, let expiresAt):
            return AblyToken(token: token, expiresAt: expiresAt)
        case .unusable(let reason):
            throw .invalidTokenRequest(reason)
        case .request(let name):
            keyName = name
        }
        guard let url = restURL(path: "/keys/\(Self.pathEscaped(keyName))/requestToken") else {
            throw .invalidTokenRequest("keyName \(keyName) is not usable in a URL")
        }
        var http = URLRequest(url: url)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            http.httpBody = try JSONSerialization.data(withJSONObject: request.anyValue)
        } catch {
            throw .invalidTokenRequest(String(describing: error))
        }
        let data = try await perform(http)
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let value = JSONValue(any: json),
              let details = AblyWire.token(fromDetails: value) else {
            throw .invalidTokenRequest("requestToken did not return a token")
        }
        log.notice("ably token issued for \(self.channel, privacy: .public)")
        return AblyToken(token: details.token, expiresAt: details.expiresAt)
    }

    // MARK: - Transport

    private func restURL(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = restHost
        components.path = path
        return components.url
    }

    private func perform(_ request: URLRequest) async throws(AblyError) -> Data {
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
            var code: Int?
            var message: String?
            if let json = try? JSONSerialization.jsonObject(with: data), let value = JSONValue(any: json) {
                code = value["error"]?["code"]?.intValue ?? value["code"]?.intValue
                message = value["error"]?["message"]?.stringValue ?? value["message"]?.stringValue
            }
            throw .server(status: http.statusCode, code: code, message: message)
        }
        return data
    }

    /// Percent-encodes one path segment. Channel names contain `:` and key names contain `.`.
    private static func pathEscaped(_ segment: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }
}
