import XCTest
@testable import MapCore

final class BackendURLTests: XCTestCase {

    // MARK: - Normalisation

    func testAddsHTTPSAndStripsTrailingSlash() throws {
        XCTAssertEqual(try BackendURL.normalized("ghostmap-backend.vercel.app").absoluteString, "https://ghostmap-backend.vercel.app")
        XCTAssertEqual(try BackendURL.normalized("https://ghostmap-backend.vercel.app/").absoluteString, "https://ghostmap-backend.vercel.app")
        XCTAssertEqual(try BackendURL.normalized("  https://GhostMap-Backend.Vercel.App//  ").absoluteString, "https://ghostmap-backend.vercel.app")
    }

    func testKeepsAPathPrefix() throws {
        XCTAssertEqual(try BackendURL.normalized("example.com/api/").absoluteString, "https://example.com/api")
        XCTAssertEqual(try BackendURL.normalized("http://localhost:3000").absoluteString, "http://localhost:3000")
    }

    func testProductionDefaultIsValid() throws {
        XCTAssertEqual(try BackendURL.normalized(BackendURL.productionString).absoluteString, BackendURL.productionString)
    }

    func testRejectsBadInput() {
        assertRejects("", .empty)
        assertRejects("   ", .empty)
        assertRejects("ftp://example.com", .unsupportedScheme("ftp"))
        assertRejects("ghostmap://join/ABC", .unsupportedScheme("ghostmap"))
        assertRejects("https://", .missingHost)
        assertRejects("https://example.com?x=1", .containsQueryOrFragment)
        assertRejects("https://example.com#frag", .containsQueryOrFragment)
        XCTAssertFalse(BackendURL.isValid("not a url at all"))
        XCTAssertTrue(BackendURL.isValid("example.com"))
    }

    private func assertRejects(_ raw: String, _ expected: BackendURL.ValidationError, file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try BackendURL.normalized(raw)
            XCTFail("\(raw) should not be accepted", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, "\(raw)", file: file, line: line)
        }
    }

    // MARK: - Endpoints

    func testEndpointJoinsPathsAndSortsQuery() throws {
        let base = try BackendURL.normalized("https://api.example.com")
        XCTAssertEqual(BackendURL.endpoint(base: base, path: "/v1/auth/google")?.absoluteString, "https://api.example.com/v1/auth/google")
        XCTAssertEqual(BackendURL.endpoint(base: base, path: "v1/maps")?.absoluteString, "https://api.example.com/v1/maps")
        XCTAssertEqual(
            BackendURL.endpoint(base: base, path: "/v1/maps", query: ["status": "saved", "limit": "20"])?.absoluteString,
            "https://api.example.com/v1/maps?limit=20&status=saved"
        )
    }

    func testEndpointKeepsAPathPrefix() throws {
        let base = try BackendURL.normalized("https://api.example.com/ghostmap")
        XCTAssertEqual(BackendURL.endpoint(base: base, path: "/health")?.absoluteString, "https://api.example.com/ghostmap/health")
    }

    func testEndpointEncodesQueryValues() throws {
        let base = try BackendURL.normalized("https://api.example.com")
        let url = try XCTUnwrap(BackendURL.endpoint(base: base, path: "/v1/maps", query: ["cursor": "2026-09-04T12:00:00Z"]))
        XCTAssertTrue(url.absoluteString.contains("cursor=2026-09-04T12:00:00Z"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first?.value, "2026-09-04T12:00:00Z")
    }

    func testDisplayString() throws {
        XCTAssertEqual(BackendURL.displayString(try BackendURL.normalized("https://ghostmap-backend.vercel.app")), "ghostmap-backend.vercel.app")
        XCTAssertEqual(BackendURL.displayString(try BackendURL.normalized("http://localhost:3000/api")), "localhost:3000/api")
    }
}
