import AuthenticationServices
import Foundation
import MapCore
import UIKit
import os

enum GoogleSignInError: Error, Sendable, Equatable, LocalizedError {
    /// `GhostmapGoogleClientID` is missing from Info.plist or still a placeholder.
    case notConfigured
    /// The person closed the consent screen.
    case cancelled
    case authorizationURLUnavailable
    case callback(GoogleOAuth.CallbackError)
    /// Google's token endpoint refused the exchange.
    case tokenExchange(status: Int, code: String?, message: String?)
    case transport(String)
    case decoding(String)
    /// There was no window to present the consent screen from.
    case presentationUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google sign-in is not configured in this build (Info.plist key GhostmapGoogleClientID)."
        case .cancelled:
            return "Sign-in was cancelled."
        case .authorizationURLUnavailable:
            return "The Google sign-in URL could not be built."
        case .callback(let error):
            switch error {
            case .stateMismatch: return "The sign-in response did not match this request."
            case .missingCode: return "Google did not return an authorization code."
            case .provider(let code, let description):
                if code == "access_denied" { return "Sign-in was declined." }
                return description ?? "Google refused the sign-in (\(code))."
            }
        case .tokenExchange(let status, let code, let message):
            return message ?? code ?? "Google's token endpoint returned HTTP \(status)."
        case .transport(let message):
            return message
        case .decoding(let detail):
            return "Google sent an unexpected response: \(detail)"
        case .presentationUnavailable:
            return "There is no window to show the Google sign-in screen in."
        }
    }
}

/// Google sign-in for an installed app: OAuth 2.0 authorization code + PKCE (RFC 8252),
/// presented with `ASWebAuthenticationSession` and exchanged at Google's token endpoint without a
/// client secret. The result is the OpenID `id_token` the backend verifies in `POST /v1/auth/google`.
///
/// The client id comes from the Info.plist key `GhostmapGoogleClientID`; the redirect URI is the
/// reversed client id (`com.googleusercontent.apps.<id>:/oauthredirect`), which must also appear in
/// `CFBundleURLTypes`. The URL building, PKCE and callback parsing live in `MapCore` and are unit
/// tested; this type only does the browser session and the HTTP exchange.
@MainActor
final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {

    /// What the caller needs after a successful sign-in.
    struct Outcome: Sendable, Equatable {
        /// The OpenID id token. Send it straight to the backend; do not trust its claims here.
        let idToken: String
        /// Unverified claims, only for showing something while the backend answers.
        let email: String?
        let name: String?
    }

    static let clientIDInfoPlistKey = "GhostmapGoogleClientID"

    private let clientID: String
    private let session: URLSession
    private let log = SessionLogger.osLogger(.cloud)
    /// Held for the lifetime of the flow: `ASWebAuthenticationSession` cancels itself when released.
    private var webAuthSession: ASWebAuthenticationSession?

    /// The configured client id, or `nil` when the key is absent, empty or not a Google client id.
    static func configuredClientID(bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: clientIDInfoPlistKey) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GoogleOAuth.reversedClientScheme(clientID: trimmed) != nil else { return nil }
        return trimmed
    }

    /// Whether this build can sign in at all.
    static var isConfigured: Bool { configuredClientID() != nil }

    /// Fails when the build has no usable client id.
    init?(clientID: String? = GoogleSignIn.configuredClientID(), session: URLSession = GoogleSignIn.makeSession()) {
        guard let clientID else { return nil }
        self.clientID = clientID
        self.session = session
        super.init()
    }

    static func makeSession(timeout: TimeInterval = 30) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration)
    }

    /// Runs the whole flow and returns the id token.
    ///
    /// - Parameter prefersEphemeralSession: `true` shows a private browser with no existing Google
    ///   cookies, so the account chooser always appears.
    func signIn(prefersEphemeralSession: Bool = false) async throws(GoogleSignInError) -> Outcome {
        let pkce = PKCE.generate()
        let request = GoogleOAuth.AuthorizationRequest(
            clientID: clientID,
            state: PKCE.randomURLSafeString(),
            nonce: PKCE.randomURLSafeString(),
            pkce: pkce
        )
        guard let request else { throw .notConfigured }

        let code = try await authorize(request, ephemeral: prefersEphemeralSession)
        let tokens = try await exchange(request, code: code)
        let claims = GoogleOAuth.unverifiedClaims(idToken: tokens.idToken)
        log.notice("google sign-in completed")
        return Outcome(
            idToken: tokens.idToken,
            email: claims?["email"]?.stringValue,
            name: claims?["name"]?.stringValue
        )
    }

    // MARK: - Browser session

    private func authorize(_ request: GoogleOAuth.AuthorizationRequest, ephemeral: Bool) async throws(GoogleSignInError) -> String {
        guard let url = request.url, let scheme = request.callbackScheme else {
            throw .authorizationURLUnavailable
        }
        let callback: URL
        do {
            callback = try await presentWebAuthentication(url: url, callbackScheme: scheme, ephemeral: ephemeral)
        } catch let error as GoogleSignInError {
            throw error
        } catch {
            throw .transport(String(describing: error))
        }
        switch GoogleOAuth.parseCallback(callback, expectedState: request.state) {
        case .success(let code):
            return code
        case .failure(let error):
            if case .provider(let code, _) = error, code == "access_denied" { throw .cancelled }
            throw .callback(error)
        }
    }

    private func presentWebAuthentication(url: URL, callbackScheme: String, ephemeral: Bool) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let authSession = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let error {
                    let code = (error as? ASWebAuthenticationSessionError)?.code
                    continuation.resume(throwing: code == .canceledLogin ? GoogleSignInError.cancelled : GoogleSignInError.transport(error.localizedDescription))
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: GoogleSignInError.callback(.missingCode))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            authSession.presentationContextProvider = self
            authSession.prefersEphemeralWebBrowserSession = ephemeral
            webAuthSession = authSession
            // `start()` returns false without ever calling the completion handler, so resuming here is safe.
            if !authSession.start() {
                continuation.resume(throwing: GoogleSignInError.presentationUnavailable)
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // AppKit/UIKit only asks for the anchor on the main thread.
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
        }
    }

    // MARK: - Token exchange

    private func exchange(_ request: GoogleOAuth.AuthorizationRequest, code: String) async throws(GoogleSignInError) -> GoogleOAuth.TokenResponse {
        guard let endpoint = URL(string: GoogleOAuth.tokenEndpoint) else { throw .authorizationURLUnavailable }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = request.tokenRequestBody(code: code)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            if error.code == .cancelled { throw .cancelled }
            throw .transport(error.localizedDescription)
        } catch {
            throw .transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else { throw .transport("Google sent a non-HTTP response.") }
        let decoder = GhostmapJSON.makeDecoder()
        guard (200...299).contains(http.statusCode) else {
            let failure = try? decoder.decode(GoogleOAuth.ErrorResponse.self, from: data)
            log.error("google token exchange failed: HTTP \(http.statusCode) \(failure?.error ?? "-", privacy: .public)")
            throw .tokenExchange(status: http.statusCode, code: failure?.error, message: failure?.errorDescription)
        }
        do {
            return try decoder.decode(GoogleOAuth.TokenResponse.self, from: data)
        } catch {
            throw .decoding(String(describing: error))
        }
    }
}
