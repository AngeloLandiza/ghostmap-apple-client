import XCTest
@testable import MapCore

final class PartyCodeTests: XCTestCase {

    // MARK: - Normalisation

    func testNormalizationUppercasesAndStripsSeparators() {
        XCTAssertEqual(PartyCode.normalized(" abcd-2345 "), "ABCD2345")
        XCTAssertEqual(PartyCode.normalized("abcd 2345"), "ABCD2345")
        XCTAssertEqual(PartyCode.normalized("ab_cd\t23\n45"), "ABCD2345")
    }

    /// Neither `0` nor `1` exists in the base32 alphabet, so folding them can never collide with a
    /// different valid code.
    func testNormalizationFoldsConfusableDigits() {
        XCTAssertEqual(PartyCode.normalized("0BCD2345"), "OBCD2345")
        XCTAssertEqual(PartyCode.normalized("1BCD2345"), "IBCD2345")
        XCTAssertEqual(PartyCode.normalized("01234567"), "OI234567")
    }

    func testNormalizationKeepsDigitsThatAreInTheAlphabet() {
        XCTAssertEqual(PartyCode.normalized("234567AB"), "234567AB")
    }

    // MARK: - Validation

    func testValidatesAWellFormedCode() throws {
        XCTAssertEqual(try PartyCode.validated("abcd-2345"), "ABCD2345")
        XCTAssertTrue(PartyCode.isValid("ZZZZ7777"))
    }

    func testRejectsEmptyWrongLengthAndBadCharacters() {
        XCTAssertThrowsError(try PartyCode.validated("   ")) { XCTAssertEqual($0 as? PartyCode.ValidationError, .empty) }
        XCTAssertThrowsError(try PartyCode.validated("ABCD234")) { XCTAssertEqual($0 as? PartyCode.ValidationError, .wrongLength(7)) }
        XCTAssertThrowsError(try PartyCode.validated("ABCD23456")) { XCTAssertEqual($0 as? PartyCode.ValidationError, .wrongLength(9)) }
        // 8 and 9 are outside RFC 4648 base32 and are not folded.
        XCTAssertThrowsError(try PartyCode.validated("ABCD2348")) { XCTAssertEqual($0 as? PartyCode.ValidationError, .invalidCharacter("8")) }
        XCTAssertThrowsError(try PartyCode.validated("ABCD234!")) { XCTAssertEqual($0 as? PartyCode.ValidationError, .invalidCharacter("!")) }
    }

    func testEveryAlphabetCharacterIsAccepted() {
        for character in PartyCode.alphabet {
            let code = String(repeating: String(character), count: PartyCode.length)
            XCTAssertTrue(PartyCode.isValid(code), "\(character) should be a valid code character")
        }
    }

    // MARK: - Formatting

    func testFormattingSplitsTheCodeInHalf() {
        XCTAssertEqual(PartyCode.formatted("abcd2345"), "ABCD 2345")
        // Not a complete code: shown as typed so the field does not jump around.
        XCTAssertEqual(PartyCode.formatted("abc"), "ABC")
    }

    // MARK: - URLs

    func testAppURLRoundTrips() throws {
        let url = try XCTUnwrap(PartyCode.appURL(code: "abcd-2345"))
        XCTAssertEqual(url.absoluteString, "ghostmap://join/ABCD2345")
        XCTAssertEqual(PartyCode.code(from: url), "ABCD2345")
    }

    func testAppURLRejectsAnInvalidCode() {
        XCTAssertNil(PartyCode.appURL(code: "nope"))
    }

    func testCodeFromDashboardShareLink() throws {
        let url = try XCTUnwrap(URL(string: "https://ghostmap-dashboard.vercel.app/join/ABCD2345"))
        XCTAssertEqual(PartyCode.code(from: url), "ABCD2345")
    }

    func testCodeFromSchemeWithoutHost() throws {
        let url = try XCTUnwrap(URL(string: "ghostmap:ABCD2345"))
        XCTAssertEqual(PartyCode.code(from: url), "ABCD2345")
    }

    func testCodeFromUnrelatedURLIsNil() throws {
        XCTAssertNil(PartyCode.code(from: try XCTUnwrap(URL(string: "https://example.com/ABCD2345"))))
        XCTAssertNil(PartyCode.code(from: try XCTUnwrap(URL(string: "ghostmap://join/NOTACODE1"))))
        XCTAssertNil(PartyCode.code(from: try XCTUnwrap(URL(string: "https://example.com/join/"))))
    }
}
