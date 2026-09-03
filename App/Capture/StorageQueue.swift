import Foundation
import MapCore

/// Serial background owner of the append-only keyframe log.
///
/// Thread-safety invariant (`@unchecked Sendable`): `writer`, `errors` and `lastError` are only
/// accessed on `queue`; every public method enqueues work on it.
final class StorageQueue: @unchecked Sendable {
    struct Status: Sendable, Equatable {
        var records: Int
        var bytes: Int64
        var errors: Int
    }

    private let queue = DispatchQueue(label: "tech.alandiza.roommapper.storage", qos: .utility)
    private var writer: KeyframeLogWriter?
    private var errors = 0
    private var lastError: String?
    private let logger: SessionLogger

    init(logger: SessionLogger) {
        self.logger = logger
    }

    func open(url: URL) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    writer = try KeyframeLogWriter(url: url)
                    c.resume()
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }

    /// Enqueues a record. Failures are counted and logged, never thrown at the caller.
    func append(_ record: KeyframeRecord) {
        queue.async { [self] in
            guard let writer else {
                errors += 1
                return
            }
            do {
                try writer.append(record)
            } catch {
                errors += 1
                lastError = String(describing: error)
                logger.log(.storage, "keyframe append failed seq=\(record.seq): \(error)", level: .error)
            }
        }
    }

    func status() async -> Status {
        await withCheckedContinuation { (c: CheckedContinuation<Status, Never>) in
            queue.async { [self] in
                c.resume(returning: Status(records: writer?.recordCount ?? 0, bytes: writer?.byteCount ?? 0, errors: errors))
            }
        }
    }

    /// Drains pending appends, fsyncs and closes the log.
    func finish() async throws -> Status {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Status, Error>) in
            queue.async { [self] in
                do {
                    try writer?.sync()
                    let s = Status(records: writer?.recordCount ?? 0, bytes: writer?.byteCount ?? 0, errors: errors)
                    try writer?.close()
                    writer = nil
                    c.resume(returning: s)
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }
}
