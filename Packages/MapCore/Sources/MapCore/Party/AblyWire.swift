import Foundation

/// The parts of Ably's wire protocol the app has to understand without the Ably SDK: the SSE
/// message envelope, the three shapes a token endpoint can hand back, and the REST auth header.
///
/// Pure string and JSON work, so it is unit tested rather than exercised against the live service.
public enum AblyWire: Sendable {

    /// What `POST /v1/realtime/token` (or Ably itself) returned.
    public enum TokenSource: Sendable, Equatable {
        /// A bare token string, usable as is.
        case literal(String)
        /// Ably `TokenDetails`: a token plus its expiry.
        case details(token: String, expiresAt: Date?)
        /// A signed Ably `TokenRequest`, which must be exchanged at
        /// `POST /keys/<keyName>/requestToken` for a real token.
        case request(keyName: String)
        /// Nothing usable.
        case unusable(reason: String)
    }

    /// Classifies whatever the backend put in `token_request`.
    public static func tokenSource(from value: JSONValue?) -> TokenSource {
        guard let value, !value.isNull else { return .unusable(reason: "no token request") }
        if let literal = value.stringValue {
            return literal.isEmpty ? .unusable(reason: "empty token string") : .literal(literal)
        }
        guard let object = value.objectValue else {
            return .unusable(reason: "expected an object or a token string")
        }
        if let token = object["token"]?.stringValue, !token.isEmpty {
            return .details(token: token, expiresAt: date(fromMilliseconds: object["expires"]))
        }
        guard let keyName = object["keyName"]?.stringValue ?? object["key_name"]?.stringValue, !keyName.isEmpty else {
            return .unusable(reason: "no keyName in the token request")
        }
        return .request(keyName: keyName)
    }

    /// The token out of an Ably `requestToken` response.
    public static func token(fromDetails value: JSONValue) -> (token: String, expiresAt: Date?)? {
        guard let token = value["token"]?.stringValue, !token.isEmpty else { return nil }
        return (token, date(fromMilliseconds: value["expires"]))
    }

    /// Ably reports timestamps as milliseconds since the epoch.
    public static func date(fromMilliseconds value: JSONValue?) -> Date? {
        guard let milliseconds = value?.doubleValue, milliseconds.isFinite, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// Ably REST token auth: the token string, base64-encoded, behind the `Bearer` scheme.
    public static func authorizationValue(token: String) -> String {
        "Bearer " + Data(token.utf8).base64EncodedString()
    }

    /// One enveloped SSE message.
    public struct Message: Sendable, Equatable {
        public var name: String
        public var data: JSONValue
        public var clientID: String?
        public var connectionID: String?

        public init(name: String, data: JSONValue, clientID: String? = nil, connectionID: String? = nil) {
            self.name = name
            self.data = data
            self.clientID = clientID
            self.connectionID = connectionID
        }
    }

    /// Reads Ably's enveloped SSE payload: `{ id, name, data, clientId, connectionId, … }`.
    /// Returns nil when there is no `name`, which is what an envelope without a publisher message
    /// (a channel-state event, say) looks like.
    public static func message(from envelope: JSONValue) -> Message? {
        guard let name = envelope["name"]?.stringValue, !name.isEmpty else { return nil }
        return Message(name: name,
                       data: unwrap(envelope["data"]),
                       clientID: envelope["clientId"]?.stringValue ?? envelope["client_id"]?.stringValue,
                       connectionID: envelope["connectionId"]?.stringValue ?? envelope["connection_id"]?.stringValue)
    }

    /// An Ably `error` SSE event: `{ message, code, statusCode }`.
    public static func error(from envelope: JSONValue) -> (message: String, code: Int?, statusCode: Int) {
        let message = envelope["message"]?.stringValue
            ?? envelope["error"]?["message"]?.stringValue
            ?? "the realtime channel reported an error"
        let code = envelope["code"]?.intValue ?? envelope["error"]?["code"]?.intValue
        let status = envelope["statusCode"]?.intValue ?? envelope["error"]?["statusCode"]?.intValue ?? 0
        return (message, code, status)
    }

    /// Ably delivers `data` as an object when it was published as one and as a JSON *string* when
    /// the publisher sent text, so both are accepted and a string that is not JSON is left alone.
    public static func unwrap(_ value: JSONValue?) -> JSONValue {
        guard let value else { return .null }
        guard let text = value.stringValue else { return value }
        guard let bytes = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]),
              let parsed = JSONValue(any: json) else {
            return value
        }
        return parsed
    }
}
