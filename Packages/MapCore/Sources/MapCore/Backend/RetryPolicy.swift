import Foundation

/// Exponential backoff with jitter for transient backend failures.
///
/// Pure arithmetic: the caller supplies the random draw so the schedule is testable.
public struct RetryPolicy: Sendable, Equatable {
    /// Total number of attempts, including the first one. `1` disables retrying.
    public var maxAttempts: Int
    /// Delay before the second attempt.
    public var baseDelay: TimeInterval
    /// Upper bound for a single delay.
    public var maxDelay: TimeInterval
    /// Growth factor per attempt.
    public var multiplier: Double
    /// Fraction of the delay that jitter may remove, in `0...1` ("full jitter" at `1`).
    public var jitter: Double

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 8, multiplier: Double = 2, jitter: Double = 0.5) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.multiplier = max(1, multiplier)
        self.jitter = min(max(0, jitter), 1)
    }

    /// Three attempts, 0.5 s → 1 s, half jitter.
    public static let `default` = RetryPolicy()
    /// No retrying (non-idempotent requests).
    public static let none = RetryPolicy(maxAttempts: 1)

    /// Delay before attempt number `attempt` (2 for the first retry). `randomUnit` in `0...1`
    /// selects a point inside the jitter window; pass `0` for the shortest delay.
    public func delay(beforeAttempt attempt: Int, randomUnit: Double) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        let exponent = Double(attempt - 2)
        let raw = baseDelay * pow(multiplier, exponent)
        let capped = min(raw, maxDelay)
        let unit = min(max(0, randomUnit), 1)
        return capped * (1 - jitter * unit)
    }

    public func delay(beforeAttempt attempt: Int) -> TimeInterval {
        delay(beforeAttempt: attempt, randomUnit: Double.random(in: 0...1))
    }

    /// Whether another attempt is allowed after `attempt` failed.
    public func shouldRetry(afterAttempt attempt: Int) -> Bool {
        attempt < maxAttempts
    }

    /// HTTP statuses worth retrying: request timeout, rate limiting and every server error.
    public static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    /// The `Retry-After` header, either as seconds or as an HTTP date. `nil` when absent or unparsable.
    public static func retryAfter(header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let seconds = TimeInterval(trimmed) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
