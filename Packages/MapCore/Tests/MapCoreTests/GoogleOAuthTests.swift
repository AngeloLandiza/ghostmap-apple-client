import XCTest
@testable import MapCore

final class GoogleOAuthTests: XCTestCase {

    private let clientID = "123456789012-abcdefghijklmnop.apps.googleusercontent.com"

    private func request() throws -> GoogleOAuth.AuthorizationRequest {
        let pkce = try XCTUnwrap(PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
        return try XCTUnwrap(GoogleOAuth.AuthorizationRequest(clientID: clientID, state: "STATE1", nonce: "NONCE1", pkce: pkce))
    }

    // MARK: - Reversed client id

    func testReversedClientScheme() {
        XCTAssertEqual(GoogleOAuth.reversedClientScheme(clientID: clientID), "com.googleusercontent.apps.123456789012-abcdefghijklmnop")
        XCTAssertEqual(GoogleOAuth.redirectURI(clientID: clientID), "com.googleusercontent.apps.123456789012-abcdefghijklmnop:/oauthredirect")
    }

    func testReversedClientSchemeRejectsPlaceholders() {
        XCTAssertNil(GoogleOAuth.reversedClientScheme(clientID: ""))
        XCTAssertNil(GoogleOAuth.reversedClientScheme(clientID: "   "))
        XCTAssertNil(GoogleOAuth.reversedClientScheme(clientID: "not-a-client-id"))
        XCTAssertNil(GoogleOAuth.reversedClientScheme(clientID: ".apps.googleusercontent.com"))
        XCTAssertNil(GoogleOAuth.reversedClientScheme(clientID: "abc def.apps.googleusercontent.com"))
        XCTAssertNil(GoogleOAuth.redirectURI(clientID: "nope"))
    }

    func testAuthorizationRequestRequiresAUsableClientID() {
        let pkce = PKCE.generate()
        XCTAssertNil(GoogleOAuth.AuthorizationRequest(clientID: "", state: "s", nonce: "n", pkce: pkce))
    }

    // MARK: - Authorization URL

    func testAuthorizationURL() throws {
        let url = try XCTUnwrap(request().url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "accounts.google.com")
        XCTAssertEqual(components.path, "/o/oauth2/v2/auth")
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] { values[item.name] = item.value }
        XCTAssertEqual(values["client_id"], clientID)
        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(values["scope"], "openid email profile")
        XCTAssertEqual(values["state"], "STATE1")
        XCTAssertEqual(values["nonce"], "NONCE1")
        XCTAssertEqual(values["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["redirect_uri"], "com.googleusercontent.apps.123456789012-abcdefghijklmnop:/oauthredirect")
        // The verifier must never leave the device before the token exchange.
        XCTAssertFalse(url.absoluteString.contains("dBjftJeZ4CVP"))
    }

    func testCallbackSchemeMatchesTheRedirectURI() throws {
        let r = try request()
        let scheme = try XCTUnwrap(r.callbackScheme)
        XCTAssertTrue(r.redirectURI.hasPrefix(scheme + ":"))
    }

    // MARK: - Callback parsing

    func testParseCallbackReturnsTheCode() throws {
        let url = try XCTUnwrap(URL(string: "com.googleusercontent.apps.123:/oauthredirect?state=STATE1&code=4/abc-DEF"))
        XCTAssertEqual(try GoogleOAuth.parseCallback(url, expectedState: "STATE1").get(), "4/abc-DEF")
    }

    func testParseCallbackRejectsAForeignState() throws {
        let url = try XCTUnwrap(URL(string: "com.googleusercontent.apps.123:/oauthredirect?state=OTHER&code=abc"))
        guard case .failure(let error) = GoogleOAuth.parseCallback(url, expectedState: "STATE1") else {
            return XCTFail("expected a state mismatch")
        }
        XCTAssertEqual(error, .stateMismatch)
    }

    func testParseCallbackSurfacesProviderErrors() throws {
        let url = try XCTUnwrap(URL(string: "com.googleusercontent.apps.123:/oauthredirect?error=access_denied&error_description=The%20user%20said%20no&state=STATE1"))
        guard case .failure(let error) = GoogleOAuth.parseCallback(url, expectedState: "STATE1") else {
            return XCTFail("expected a provider error")
        }
        XCTAssertEqual(error, .provider(code: "access_denied", description: "The user said no"))
    }

    func testParseCallbackWithoutACode() throws {
        let url = try XCTUnwrap(URL(string: "com.googleusercontent.apps.123:/oauthredirect?state=STATE1"))
        guard case .failure(let error) = GoogleOAuth.parseCallback(url, expectedState: "STATE1") else {
            return XCTFail("expected a missing code")
        }
        XCTAssertEqual(error, .missingCode)
    }

    // MARK: - Token request

    func testTokenRequestBody() throws {
        let body = try request().tokenRequestBody(code: "4/abc DEF+x")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertEqual(text, [
            "client_id=123456789012-abcdefghijklmnop.apps.googleusercontent.com",
            "code=4%2Fabc+DEF%2Bx",
            "code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
            "grant_type=authorization_code",
            "redirect_uri=com.googleusercontent.apps.123456789012-abcdefghijklmnop%3A%2Foauthredirect",
        ].joined(separator: "&"))
        XCTAssertFalse(text.contains("client_secret"))
    }

    func testPercentEncoding() {
        XCTAssertEqual(GoogleOAuth.percentEncoded("a b"), "a+b")
        XCTAssertEqual(GoogleOAuth.percentEncoded("a/b"), "a%2Fb")
        XCTAssertEqual(GoogleOAuth.percentEncoded("-._~"), "-._~")
        XCTAssertEqual(GoogleOAuth.percentEncoded("é"), "%C3%A9")
    }

    // MARK: - Responses

    func testDecodesTokenResponse() throws {
        let json = #"{"access_token":"ya29.x","expires_in":3599,"id_token":"a.b.c","scope":"openid email","token_type":"Bearer"}"#
        let response = try GhostmapJSON.makeDecoder().decode(GoogleOAuth.TokenResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.idToken, "a.b.c")
        XCTAssertEqual(response.accessToken, "ya29.x")
        XCTAssertEqual(response.expiresIn, 3599)
        XCTAssertEqual(response.tokenType, "Bearer")
    }

    func testDecodesErrorResponse() throws {
        let json = #"{"error":"invalid_grant","error_description":"Bad Request"}"#
        let response = try GhostmapJSON.makeDecoder().decode(GoogleOAuth.ErrorResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.error, "invalid_grant")
        XCTAssertEqual(response.errorDescription, "Bad Request")
    }

    func testUnverifiedClaims() {
        let payload = Base64URL.encode(Data(#"{"email":"a@b.c","name":"A B","exp":1800000000}"#.utf8))
        let claims = GoogleOAuth.unverifiedClaims(idToken: "header.\(payload).signature")
        XCTAssertEqual(claims?["email"], JSONValue.string("a@b.c"))
        XCTAssertEqual(claims?["name"], JSONValue.string("A B"))
        XCTAssertEqual(claims?["exp"], JSONValue.int(1_800_000_000))
        XCTAssertNil(GoogleOAuth.unverifiedClaims(idToken: "not-a-jwt"))
        XCTAssertNil(GoogleOAuth.unverifiedClaims(idToken: "a.!!!.c"))
    }
}
