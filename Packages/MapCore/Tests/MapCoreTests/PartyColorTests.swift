import XCTest
@testable import MapCore

final class PartyColorTests: XCTestCase {

    func testParsesTheBackendPaletteSpelling() {
        XCTAssertEqual(PartyColor(hex: "#38bdf8"), PartyColor(r: 0x38, g: 0xbd, b: 0xf8))
        XCTAssertEqual(PartyColor(hex: "38BDF8"), PartyColor(r: 0x38, g: 0xbd, b: 0xf8))
        XCTAssertEqual(PartyColor(hex: " #38bdf8ff "), PartyColor(r: 0x38, g: 0xbd, b: 0xf8))
        XCTAssertEqual(PartyColor(hex: "#abc"), PartyColor(r: 0xaa, g: 0xbb, b: 0xcc))
    }

    func testRejectsMalformedHex() {
        XCTAssertNil(PartyColor(hex: ""))
        XCTAssertNil(PartyColor(hex: "#12345"))
        XCTAssertNil(PartyColor(hex: "#gggggg"))
        XCTAssertNil(PartyColor(hex: "rgb(1,2,3)"))
    }

    func testPaletteMatchesTheBackendAndWrapsByIndex() {
        XCTAssertEqual(PartyColor.palette.count, 8)
        XCTAssertEqual(PartyColor.palette.first?.hexString, "#38bdf8")
        XCTAssertEqual(PartyColor.palette.last?.hexString, "#f87171")
        XCTAssertEqual(PartyColor.palette(index: 8), PartyColor.palette[0])
        XCTAssertEqual(PartyColor.palette(index: -1), PartyColor.palette[7])
    }

    func testResolveFallsBackToTheJoinIndex() {
        XCTAssertEqual(PartyColor.resolve(hex: "#4ade80", index: 0), PartyColor.palette[3])
        XCTAssertEqual(PartyColor.resolve(hex: nil, index: 2), PartyColor.palette[2])
        XCTAssertEqual(PartyColor.resolve(hex: "not a colour", index: 1), PartyColor.palette[1])
    }

    func testHexStringRoundTrips() throws {
        for colour in PartyColor.palette {
            XCTAssertEqual(PartyColor(hex: colour.hexString), colour)
        }
    }

    func testTintBlendsTowardThePartyColour() {
        let blue = PartyColor(r: 0, g: 0, b: 255)
        XCTAssertEqual(blue.tint(r: 255, g: 255, b: 255, mix: 0).r, 255)
        let half = blue.tint(r: 255, g: 255, b: 255, mix: 0.5)
        XCTAssertEqual(half.r, 128)
        XCTAssertEqual(half.b, 255)
        let full = blue.tint(r: 255, g: 255, b: 255, mix: 1)
        XCTAssertEqual(full.r, 0)
        XCTAssertEqual(full.g, 0)
        XCTAssertEqual(full.b, 255)
        // Out-of-range mixes clamp rather than overshoot.
        XCTAssertEqual(blue.tint(r: 255, g: 255, b: 255, mix: 5).r, 0)
        XCTAssertEqual(blue.tint(r: 255, g: 255, b: 255, mix: -5).r, 255)
    }

    func testTintedKeepsPositionAndAlpha() {
        let point = PackedPoint(position: SIMD3<Float>(1, 2, 3), r: 200, g: 100, b: 50, a: 128)
        let tinted = PartyColor.palette[0].tinted(point, mix: 1)
        XCTAssertEqual(tinted.position, point.position)
        XCTAssertEqual(tinted.a, 128)
        XCTAssertEqual(tinted.r, 0x38)
    }

    func testPackedColorMatchesPackedPoint() {
        let colour = PartyColor(r: 1, g: 2, b: 3)
        XCTAssertEqual(colour.packedColor(), PackedPoint.packColor(r: 1, g: 2, b: 3))
    }
}
