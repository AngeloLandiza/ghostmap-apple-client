import Foundation
import XCTest
@testable import MapCore

final class TrackingStateTests: XCTestCase {

    /// Every distinct tracking state, used by the round-trip and label tests.
    private let allStates: [TrackingState] = [.normal]
        + TrackingState.LimitedReason.allCases.map { TrackingState.limited($0) }
        + [.notAvailable]

    // MARK: - Wire encoding

    func testNormalRawEncoding() {
        // Wire spec: normal = state 0; reason is 0 whenever not limited.
        XCTAssertEqual(TrackingState.normal.rawState, 0)
        XCTAssertEqual(TrackingState.normal.rawReason, 0)
        XCTAssertEqual(TrackingState(rawState: 0, rawReason: 0), .normal)
    }

    func testNotAvailableRawEncoding() {
        // Wire spec: not available = state 2, reason 0.
        XCTAssertEqual(TrackingState.notAvailable.rawState, 2)
        XCTAssertEqual(TrackingState.notAvailable.rawReason, 0)
        XCTAssertEqual(TrackingState(rawState: 2, rawReason: 0), .notAvailable)
    }

    func testLimitedReasonRawValuesAreStable() {
        // These numbers are persisted in keyframes.bin; they must never change.
        XCTAssertEqual(TrackingState.LimitedReason.initializing.rawValue, 0)
        XCTAssertEqual(TrackingState.LimitedReason.excessiveMotion.rawValue, 1)
        XCTAssertEqual(TrackingState.LimitedReason.insufficientFeatures.rawValue, 2)
        XCTAssertEqual(TrackingState.LimitedReason.relocalizing.rawValue, 3)
        XCTAssertEqual(TrackingState.LimitedReason.unknown.rawValue, 4)
        // 5 reasons: 0...4.
        XCTAssertEqual(TrackingState.LimitedReason.allCases.count, 5)
    }

    func testLimitedRawEncodingForEveryReason() {
        for reason in TrackingState.LimitedReason.allCases {
            let state = TrackingState.limited(reason)
            // limited = state 1; reason byte is the LimitedReason raw value.
            XCTAssertEqual(state.rawState, 1, "\(reason)")
            XCTAssertEqual(state.rawReason, reason.rawValue, "\(reason)")
        }
    }

    func testRawRoundTripForEveryCase() {
        // 1 normal + 5 limited + 1 notAvailable = 7 states.
        XCTAssertEqual(allStates.count, 7)
        for state in allStates {
            let decoded = TrackingState(rawState: state.rawState, rawReason: state.rawReason)
            XCTAssertEqual(decoded, state, "\(state)")
        }
    }

    func testUnknownRawReasonDecodesToUnknown() {
        // Reason bytes outside 0...4 have no LimitedReason case; the decoder falls back to .unknown.
        XCTAssertEqual(TrackingState(rawState: 1, rawReason: 5), .limited(.unknown))
        XCTAssertEqual(TrackingState(rawState: 1, rawReason: 200), .limited(.unknown))
        XCTAssertEqual(TrackingState(rawState: 1, rawReason: 255), .limited(.unknown))
    }

    func testUnknownRawStateDecodesToNotAvailable() {
        // Any state byte other than 0 or 1 decodes as not available.
        XCTAssertEqual(TrackingState(rawState: 7, rawReason: 0), .notAvailable)
        XCTAssertEqual(TrackingState(rawState: 3, rawReason: 2), .notAvailable)
        XCTAssertEqual(TrackingState(rawState: 255, rawReason: 255), .notAvailable)
    }

    func testReasonByteIsIgnoredWhenNotLimited() {
        // The reason byte only matters for state 1.
        XCTAssertEqual(TrackingState(rawState: 0, rawReason: 3), .normal)
        XCTAssertEqual(TrackingState(rawState: 2, rawReason: 3), .notAvailable)
    }

    // MARK: - isNormal

    func testIsNormalOnlyForNormal() {
        XCTAssertTrue(TrackingState.normal.isNormal)
        XCTAssertFalse(TrackingState.notAvailable.isNormal)
        for reason in TrackingState.LimitedReason.allCases {
            XCTAssertFalse(TrackingState.limited(reason).isNormal, "\(reason)")
        }
    }

    // MARK: - Labels

    func testLimitedReasonLabels() {
        XCTAssertEqual(TrackingState.LimitedReason.initializing.label, "initializing")
        XCTAssertEqual(TrackingState.LimitedReason.excessiveMotion.label, "excessive motion")
        XCTAssertEqual(TrackingState.LimitedReason.insufficientFeatures.label, "insufficient features")
        XCTAssertEqual(TrackingState.LimitedReason.relocalizing.label, "relocalizing")
        XCTAssertEqual(TrackingState.LimitedReason.unknown.label, "unknown")
    }

    func testStateLabels() {
        XCTAssertEqual(TrackingState.normal.label, "normal")
        XCTAssertEqual(TrackingState.notAvailable.label, "not available")
        // Limited labels are "limited: " + reason label.
        XCTAssertEqual(TrackingState.limited(.initializing).label, "limited: initializing")
        XCTAssertEqual(TrackingState.limited(.excessiveMotion).label, "limited: excessive motion")
        XCTAssertEqual(TrackingState.limited(.insufficientFeatures).label, "limited: insufficient features")
        XCTAssertEqual(TrackingState.limited(.relocalizing).label, "limited: relocalizing")
        XCTAssertEqual(TrackingState.limited(.unknown).label, "limited: unknown")
    }

    func testLabelsAreDistinct() {
        // 7 states must produce 7 different strings.
        XCTAssertEqual(Set(allStates.map(\.label)).count, 7)
    }

    // MARK: - Equatable / Hashable / Codable

    func testEquality() {
        XCTAssertEqual(TrackingState.limited(.relocalizing), .limited(.relocalizing))
        XCTAssertNotEqual(TrackingState.limited(.relocalizing), .limited(.initializing))
        XCTAssertNotEqual(TrackingState.normal, .notAvailable)
        XCTAssertNotEqual(TrackingState.normal, .limited(.unknown))
    }

    func testHashableDistinguishesEveryCase() {
        // 7 distinct states hash to 7 set members.
        XCTAssertEqual(Set(allStates).count, 7)
    }

    func testCodableRoundTripForEveryCase() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for state in allStates {
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(TrackingState.self, from: data)
            XCTAssertEqual(decoded, state, "\(state)")
        }
    }
}
