import XCTest
@testable import MapCore

final class RetryPolicyTests: XCTestCase {

    func testDefaultSchedule() {
        let policy = RetryPolicy.default
        XCTAssertEqual(policy.maxAttempts, 3)
        // randomUnit 0 = no jitter removed, so the delay is the full exponential value.
        XCTAssertEqual(policy.delay(beforeAttempt: 1, randomUnit: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(beforeAttempt: 2, randomUnit: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(beforeAttempt: 3, randomUnit: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(beforeAttempt: 4, randomUnit: 0), 2.0, accuracy: 1e-9)
    }

    func testJitterOnlyShortensTheDelay() {
        let policy = RetryPolicy.default
        for unit in stride(from: 0.0, through: 1.0, by: 0.25) {
            let delay = policy.delay(beforeAttempt: 3, randomUnit: unit)
            XCTAssertLessThanOrEqual(delay, 1.0)
            XCTAssertGreaterThanOrEqual(delay, 0.5) // jitter is 0.5, so at most half is removed
        }
        XCTAssertEqual(policy.delay(beforeAttempt: 3, randomUnit: 1), 0.5, accuracy: 1e-9)
    }

    func testDelayIsCapped() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: 1, maxDelay: 4, multiplier: 2, jitter: 0)
        XCTAssertEqual(policy.delay(beforeAttempt: 2, randomUnit: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(beforeAttempt: 4, randomUnit: 0), 4, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(beforeAttempt: 9, randomUnit: 0), 4, accuracy: 1e-9)
    }

    func testOutOfRangeRandomUnitIsClamped() {
        let policy = RetryPolicy.default
        XCTAssertEqual(policy.delay(beforeAttempt: 2, randomUnit: -5), policy.delay(beforeAttempt: 2, randomUnit: 0), accuracy: 1e-9)
        XCTAssertEqual(policy.delay(beforeAttempt: 2, randomUnit: 5), policy.delay(beforeAttempt: 2, randomUnit: 1), accuracy: 1e-9)
    }

    func testInitialiserClampsNonsense() {
        let policy = RetryPolicy(maxAttempts: -3, baseDelay: -1, maxDelay: -1, multiplier: 0.1, jitter: 4)
        XCTAssertEqual(policy.maxAttempts, 1)
        XCTAssertEqual(policy.baseDelay, 0)
        XCTAssertEqual(policy.multiplier, 1)
        XCTAssertEqual(policy.jitter, 1)
    }

    func testShouldRetry() {
        XCTAssertTrue(RetryPolicy.default.shouldRetry(afterAttempt: 1))
        XCTAssertTrue(RetryPolicy.default.shouldRetry(afterAttempt: 2))
        XCTAssertFalse(RetryPolicy.default.shouldRetry(afterAttempt: 3))
        XCTAssertFalse(RetryPolicy.none.shouldRetry(afterAttempt: 1))
    }

    func testRetryableStatuses() {
        for status in [500, 502, 503, 504, 429, 408] {
            XCTAssertTrue(RetryPolicy.isRetryable(status: status), "\(status)")
        }
        for status in [200, 201, 301, 400, 401, 403, 404, 409, 410, 422] {
            XCTAssertFalse(RetryPolicy.isRetryable(status: status), "\(status)")
        }
    }

    func testRetryAfterHeader() {
        XCTAssertEqual(RetryPolicy.retryAfter(header: "12"), 12)
        XCTAssertEqual(RetryPolicy.retryAfter(header: " 0 "), 0)
        XCTAssertNil(RetryPolicy.retryAfter(header: nil))
        XCTAssertNil(RetryPolicy.retryAfter(header: ""))
        XCTAssertNil(RetryPolicy.retryAfter(header: "soon"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let delay = RetryPolicy.retryAfter(header: "Sat, 16 Jan 2027 00:00:30 GMT", now: now)
        XCTAssertNotNil(delay)
        XCTAssertGreaterThanOrEqual(delay ?? -1, 0)
    }
}
