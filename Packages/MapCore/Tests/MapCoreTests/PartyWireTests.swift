import XCTest
@testable import MapCore

final class PartyWireTests: XCTestCase {

    func testWireNamesMatchTheBackendEnum() {
        XCTAssertEqual(TrackingState.normal.wireName, "normal")
        XCTAssertEqual(TrackingState.notAvailable.wireName, "not_available")
        XCTAssertEqual(TrackingState.limited(.relocalizing).wireName, "relocalizing")
        for reason in TrackingState.LimitedReason.allCases where reason != .relocalizing {
            XCTAssertEqual(TrackingState.limited(reason).wireName, "limited", "\(reason)")
        }
    }

    func testEveryWireNameIsOneTheBackendAccepts() {
        let accepted: Set<String> = ["normal", "limited", "relocalizing", "not_available"]
        var states: [TrackingState] = [.normal, .notAvailable]
        states.append(contentsOf: TrackingState.LimitedReason.allCases.map { TrackingState.limited($0) })
        for state in states {
            XCTAssertTrue(accepted.contains(state.wireName), "\(state.label) → \(state.wireName)")
        }
    }

    func testParsingBack() {
        XCTAssertEqual(TrackingState(wireName: "normal"), .normal)
        XCTAssertEqual(TrackingState(wireName: "relocalizing"), .limited(.relocalizing))
        XCTAssertEqual(TrackingState(wireName: "limited"), .limited(.unknown))
        XCTAssertEqual(TrackingState(wireName: "not_available"), .notAvailable)
        XCTAssertEqual(TrackingState(wireName: "something new"), .notAvailable)
    }

    func testRelocalizingRoundTrips() {
        XCTAssertEqual(TrackingState(wireName: TrackingState.limited(.relocalizing).wireName), .limited(.relocalizing))
    }
}
