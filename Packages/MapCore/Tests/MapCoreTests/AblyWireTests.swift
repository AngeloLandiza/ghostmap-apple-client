import XCTest
@testable import MapCore

final class AblyWireTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        return try XCTUnwrap(JSONValue(any: object))
    }

    // MARK: - Token shapes

    func testASignedTokenRequestNeedsExchanging() throws {
        let value = try json(#"{"keyName":"abcd.efgh","ttl":3600000,"nonce":"n","mac":"m","capability":"{}"}"#)
        XCTAssertEqual(AblyWire.tokenSource(from: value), .request(keyName: "abcd.efgh"))
    }

    func testTokenDetailsAreUsedDirectly() throws {
        let value = try json(#"{"token":"abcd.efgh:xyz","expires":1788000000000,"issued":1787996400000}"#)
        guard case .details(let token, let expiry) = AblyWire.tokenSource(from: value) else {
            return XCTFail("expected token details")
        }
        XCTAssertEqual(token, "abcd.efgh:xyz")
        XCTAssertEqual(expiry?.timeIntervalSince1970 ?? 0, 1_788_000_000, accuracy: 0.001)
    }

    func testABareStringIsALiteralToken() throws {
        XCTAssertEqual(AblyWire.tokenSource(from: .string("abcd.efgh:xyz")), .literal("abcd.efgh:xyz"))
        XCTAssertEqual(AblyWire.tokenSource(from: .string("")), .unusable(reason: "empty token string"))
    }

    func testUnusableTokenShapes() {
        XCTAssertEqual(AblyWire.tokenSource(from: nil), .unusable(reason: "no token request"))
        XCTAssertEqual(AblyWire.tokenSource(from: .null), .unusable(reason: "no token request"))
        XCTAssertEqual(AblyWire.tokenSource(from: .int(3)), .unusable(reason: "expected an object or a token string"))
        XCTAssertEqual(AblyWire.tokenSource(from: .object([:])), .unusable(reason: "no keyName in the token request"))
    }

    func testRequestTokenResponse() throws {
        let value = try json(#"{"token":"t","expires":1788000000000,"capability":"{}"}"#)
        let details = try XCTUnwrap(AblyWire.token(fromDetails: value))
        XCTAssertEqual(details.token, "t")
        XCTAssertNotNil(details.expiresAt)
        XCTAssertNil(AblyWire.token(fromDetails: try json(#"{"error":"nope"}"#)))
    }

    func testMillisecondTimestamps() {
        XCTAssertNil(AblyWire.date(fromMilliseconds: nil))
        XCTAssertNil(AblyWire.date(fromMilliseconds: .int(0)))
        XCTAssertNil(AblyWire.date(fromMilliseconds: .string("soon")))
        XCTAssertEqual(AblyWire.date(fromMilliseconds: .int(1500))?.timeIntervalSince1970, 1.5)
    }

    // MARK: - REST auth

    func testAuthorizationHeaderIsTheBase64Token() {
        XCTAssertEqual(AblyWire.authorizationValue(token: "abc"), "Bearer YWJj")
    }

    // MARK: - Envelopes

    func testEnvelopeWithAnObjectPayload() throws {
        let value = try json(#"{"id":"c:0","name":"pose","clientId":"d1","connectionId":"c","data":{"device_id":"d1","aligned":true}}"#)
        let message = try XCTUnwrap(AblyWire.message(from: value))
        XCTAssertEqual(message.name, "pose")
        XCTAssertEqual(message.clientID, "d1")
        XCTAssertEqual(message.connectionID, "c")
        XCTAssertEqual(message.data["device_id"]?.stringValue, "d1")
        XCTAssertEqual(message.data["aligned"]?.boolValue, true)
    }

    /// Ably sends `data` as a JSON *string* when the publisher used the string form.
    func testEnvelopeWithAStringifiedPayload() throws {
        let value = try json(#"{"name":"session","data":"{\"event\":\"ended\"}"}"#)
        let message = try XCTUnwrap(AblyWire.message(from: value))
        XCTAssertEqual(message.data["event"]?.stringValue, "ended")
    }

    func testPlainTextPayloadIsLeftAlone() throws {
        let value = try json(#"{"name":"note","data":"hello"}"#)
        let message = try XCTUnwrap(AblyWire.message(from: value))
        XCTAssertEqual(message.data.stringValue, "hello")
    }

    func testEnvelopeWithoutANameIsIgnored() throws {
        XCTAssertNil(AblyWire.message(from: try json(#"{"id":"c:0","data":{}}"#)))
        XCTAssertNil(AblyWire.message(from: try json(#"{"name":"","data":{}}"#)))
    }

    func testMissingDataBecomesNull() throws {
        let message = try XCTUnwrap(AblyWire.message(from: try json(#"{"name":"merge"}"#)))
        XCTAssertTrue(message.data.isNull)
    }

    func testErrorEvent() throws {
        let error = AblyWire.error(from: try json(#"{"message":"token expired","code":40142,"statusCode":401}"#))
        XCTAssertEqual(error.message, "token expired")
        XCTAssertEqual(error.code, 40142)
        XCTAssertEqual(error.statusCode, 401)
    }

    func testErrorEventNestedUnderError() throws {
        let error = AblyWire.error(from: try json(#"{"error":{"message":"nope","code":1,"statusCode":403}}"#))
        XCTAssertEqual(error.message, "nope")
        XCTAssertEqual(error.statusCode, 403)
    }

    func testErrorEventWithNothingUseful() throws {
        let error = AblyWire.error(from: try json("{}"))
        XCTAssertFalse(error.message.isEmpty)
        XCTAssertEqual(error.statusCode, 0)
        XCTAssertNil(error.code)
    }
}
