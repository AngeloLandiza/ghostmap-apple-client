import XCTest
@testable import MapCore

final class PKCETests: XCTestCase {

    // MARK: - Base64URL

    func testBase64URLDropsPaddingAndSubstitutesAlphabet() {
        // 0xFB 0xFF encodes to "+/8=" in standard base64.
        XCTAssertEqual(Base64URL.encode(Data([0xFB, 0xFF])), "-_8")
        XCTAssertEqual(Base64URL.encode(Data()), "")
        XCTAssertEqual(Base64URL.encode(Data([0x00])), "AA")
    }

    func testBase64URLRoundTrip() {
        for count in [0, 1, 2, 3, 16, 32, 33] {
            let data = Data((0..<count).map { UInt8($0 &* 7 &+ 1) })
            let encoded = Base64URL.encode(data)
            XCTAssertFalse(encoded.contains("="))
            XCTAssertFalse(encoded.contains("+"))
            XCTAssertFalse(encoded.contains("/"))
            XCTAssertEqual(Base64URL.decode(encoded), data, "round trip failed for \(count) bytes")
        }
    }

    func testBase64URLRejectsImpossibleLength() {
        XCTAssertNil(Base64URL.decode("A"))
        XCTAssertNil(Base64URL.decode("****"))
    }

    // MARK: - Verifier

    func testGeneratedVerifierIs43CharactersAndUnreserved() {
        let pkce = PKCE.generate()
        XCTAssertEqual(pkce.verifier.count, 43)
        XCTAssertTrue(PKCE.isValidVerifier(pkce.verifier))
    }

    func testGenerateIsDeterministicForAFixedGenerator() {
        let bytes: (Int) -> Data = { count in Data(repeating: 0xA5, count: count) }
        let a = PKCE.generate(randomBytes: bytes)
        let b = PKCE.generate(randomBytes: bytes)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.verifier, Base64URL.encode(Data(repeating: 0xA5, count: 32)))
    }

    func testGenerateClampsSmallByteCountsUp() {
        let pkce = PKCE.generate(byteCount: 1, randomBytes: { Data(repeating: 0x01, count: $0) })
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, PKCE.minVerifierLength)
        XCTAssertTrue(PKCE.isValidVerifier(pkce.verifier))
    }

    func testGenerateNeverExceedsTheMaximumLength() {
        let pkce = PKCE.generate(byteCount: 90, randomBytes: { Data(repeating: 0x02, count: $0) })
        XCTAssertLessThanOrEqual(pkce.verifier.count, PKCE.maxVerifierLength)
        XCTAssertTrue(PKCE.isValidVerifier(pkce.verifier))
    }

    func testTwoGenerationsDiffer() {
        XCTAssertNotEqual(PKCE.generate().verifier, PKCE.generate().verifier)
    }

    func testVerifierValidation() {
        XCTAssertFalse(PKCE.isValidVerifier(String(repeating: "a", count: 42)))
        XCTAssertTrue(PKCE.isValidVerifier(String(repeating: "a", count: 43)))
        XCTAssertTrue(PKCE.isValidVerifier(String(repeating: "a", count: 128)))
        XCTAssertFalse(PKCE.isValidVerifier(String(repeating: "a", count: 129)))
        XCTAssertFalse(PKCE.isValidVerifier(String(repeating: "a", count: 42) + "/"))
        XCTAssertNil(PKCE(verifier: "too-short"))
    }

    // MARK: - Challenge

    /// RFC 7636 appendix B: the verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    /// has the challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM".
    func testRFC7636AppendixBVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let pkce = PKCE(verifier: verifier)
        XCTAssertEqual(pkce?.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(PKCE.challengeMethod, "S256")
    }

    func testChallengeIsUnpaddedBase64URLOf32Bytes() {
        let challenge = PKCE.generate().challenge
        XCTAssertEqual(challenge.count, 43)
        XCTAssertEqual(Base64URL.decode(challenge)?.count, 32)
    }

    func testRandomURLSafeStringIsURLSafe() {
        let state = PKCE.randomURLSafeString()
        XCTAssertFalse(state.isEmpty)
        XCTAssertTrue(state.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
}
