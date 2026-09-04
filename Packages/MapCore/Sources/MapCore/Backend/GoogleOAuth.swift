import Foundation

/// Pure pieces of Google's OAuth 2.0 authorization-code flow for installed apps
/// (RFC 8252 + RFC 7636): scheme derivation, authorization URL, callback parsing and the
/// token-request body. The networking and the browser session live in the app layer.
public enum GoogleOAuth: Sendable {

    public static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    public static let defaultScopes = ["openid", "email", "profile"]

    private static let clientIDSuffix = ".apps.googleusercontent.com"

    /// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`.
    /// Returns `nil` when the id is empty, still a placeholder, or not a Google client id.
    public static func reversedClientScheme(clientID: String) -> String? {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(clientIDSuffix) else { return nil }
        let prefix = String(trimmed.dropLast(clientIDSuffix.count))
        guard !prefix.isEmpty else { return nil }
        guard prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) else { return nil }
        return "com.googleusercontent.apps." + prefix
    }

    /// The redirect URI Google requires for iOS clients: `<reversed client id>:/oauthredirect`.
    public static func redirectURI(clientID: String) -> String? {
        guard let scheme = reversedClientScheme(clientID: clientID) else { return nil }
        return scheme + ":/oauthredirect"
    }

    /// Everything needed to open the consent screen and, later, to redeem the code.
    public struct AuthorizationRequest: Sendable, Equatable {
        public let clientID: String
        public let redirectURI: String
        public let scopes: [String]
        public let state: String
        public let nonce: String
        public let pkce: PKCE

        public init?(clientID: String, scopes: [String] = GoogleOAuth.defaultScopes, state: String, nonce: String, pkce: PKCE) {
            guard let redirect = GoogleOAuth.redirectURI(clientID: clientID) else { return nil }
            self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.redirectURI = redirect
            self.scopes = scopes
            self.state = state
            self.nonce = nonce
            self.pkce = pkce
        }

        /// The scheme `ASWebAuthenticationSession` listens for.
        public var callbackScheme: String? { GoogleOAuth.reversedClientScheme(clientID: clientID) }

        /// The authorization endpoint with all query parameters, sorted for determinism.
        public var url: URL? {
            guard var components = URLComponents(string: GoogleOAuth.authorizationEndpoint) else { return nil }
            let parameters: [String: String] = [
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "response_type": "code",
                "scope": scopes.joined(separator: " "),
                "state": state,
                "nonce": nonce,
                "code_challenge": pkce.challenge,
                "code_challenge_method": PKCE.challengeMethod,
                "prompt": "select_account",
            ]
            components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            return components.url
        }

        /// `application/x-www-form-urlencoded` body for `POST https://oauth2.googleapis.com/token`.
        /// iOS clients have no client secret.
        public func tokenRequestBody(code: String) -> Data {
            let parameters: [String: String] = [
                "client_id": clientID,
                "code": code,
                "code_verifier": pkce.verifier,
                "grant_type": "authorization_code",
                "redirect_uri": redirectURI,
            ]
            return Data(GoogleOAuth.formURLEncoded(parameters).utf8)
        }
    }

    public enum CallbackError: Error, Sendable, Equatable {
        case stateMismatch
        case missingCode
        /// `error` / `error_description` from the authorization server. `access_denied` means the
        /// person declined.
        case provider(code: String, description: String?)
    }

    /// Extracts the authorization code from the redirect, checking `state` first.
    public static func parseCallback(_ url: URL, expectedState: String) -> Result<String, CallbackError> {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var values: [String: String] = [:]
        for item in items where item.value != nil {
            values[item.name] = item.value
        }
        if let error = values["error"] {
            return .failure(.provider(code: error, description: values["error_description"]))
        }
        guard values["state"] == expectedState else { return .failure(.stateMismatch) }
        guard let code = values["code"], !code.isEmpty else { return .failure(.missingCode) }
        return .success(code)
    }

    /// Percent-encodes and joins parameters, sorted by key.
    public static func formURLEncoded(_ parameters: [String: String]) -> String {
        parameters.sorted { $0.key < $1.key }
            .map { "\(percentEncoded($0.key))=\(percentEncoded($0.value))" }
            .joined(separator: "&")
    }

    /// `application/x-www-form-urlencoded` escaping: unreserved characters pass through, spaces
    /// become `+`, everything else is `%XX`.
    public static func percentEncoded(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for byte in Array(value.utf8) {
            let c = Character(UnicodeScalar(byte))
            if (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                || c == "-" || c == "." || c == "_" || c == "~" {
                out.append(c)
            } else if c == " " {
                out.append("+")
            } else {
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }

    /// Google's token endpoint response.
    public struct TokenResponse: Sendable, Equatable, Decodable {
        public let idToken: String
        public let accessToken: String?
        public let expiresIn: Int?
        public let tokenType: String?
        public let scope: String?
        public let refreshToken: String?

        public init(idToken: String, accessToken: String? = nil, expiresIn: Int? = nil, tokenType: String? = nil, scope: String? = nil, refreshToken: String? = nil) {
            self.idToken = idToken
            self.accessToken = accessToken
            self.expiresIn = expiresIn
            self.tokenType = tokenType
            self.scope = scope
            self.refreshToken = refreshToken
        }
    }

    /// An OAuth error document (`{ "error": "invalid_grant", "error_description": "…" }`).
    public struct ErrorResponse: Sendable, Equatable, Decodable {
        public let error: String
        public let errorDescription: String?
    }

    /// The `email`, `name`, `picture` and `exp` claims of an unverified id token.
    ///
    /// The signature is **not** checked — the backend does that. This is only used to show
    /// something in the UI before `/v1/auth/me` answers.
    public static func unverifiedClaims(idToken: String) -> [String: JSONValue]? {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = Base64URL.decode(String(parts[1])) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: payload), let value = JSONValue(any: object) else { return nil }
        return value.objectValue
    }
}
