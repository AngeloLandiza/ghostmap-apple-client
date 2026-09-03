import Foundation
import os

enum LogCategory: String, Sendable, CaseIterable {
    case capture
    case cloud
    case storage
    case render
    case thermal
    case app
}

/// Structured text log for one map (`session.log`) mirrored to `os.Logger`.
///
/// Thread-safety invariant (`@unchecked Sendable`): `handle`, `formatter` and `lineCount` are only
/// touched on the serial `queue`.
final class SessionLogger: @unchecked Sendable {
    static let subsystem = "tech.alandiza.roommapper"

    private static let loggers: [LogCategory: Logger] = Dictionary(
        uniqueKeysWithValues: LogCategory.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) })

    private let queue = DispatchQueue(label: "tech.alandiza.roommapper.sessionlog", qos: .utility)
    private var handle: FileHandle?
    private var formatter: ISO8601DateFormatter?
    private var lineCount = 0
    let fileURL: URL?

    /// Creates a logger. With a file URL, lines are appended to that file (created if missing).
    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL else { return }
        queue.async { [self] in
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            do {
                let h = try FileHandle(forWritingTo: fileURL)
                try h.seekToEnd()
                self.handle = h
            } catch {
                SessionLogger.loggers[.storage]?.error("session.log open failed: \(String(describing: error), privacy: .public)")
            }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.formatter = f
        }
    }

    static func osLogger(_ category: LogCategory) -> Logger {
        loggers[category] ?? Logger(subsystem: subsystem, category: category.rawValue)
    }

    func log(_ category: LogCategory, _ message: String, level: OSLogType = .info) {
        SessionLogger.osLogger(category).log(level: level, "\(message, privacy: .public)")
        guard fileURL != nil else { return }
        let now = Date()
        queue.async { [self] in
            guard let handle else { return }
            let stamp = formatter?.string(from: now) ?? "\(now.timeIntervalSince1970)"
            let line = "\(stamp) [\(category.rawValue)] \(message)\n"
            if let data = line.data(using: .utf8) {
                do {
                    try handle.write(contentsOf: data)
                    lineCount += 1
                } catch {
                    SessionLogger.loggers[.storage]?.error("session.log write failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Flushes and closes the file.
    func close() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                try? handle?.synchronize()
                try? handle?.close()
                handle = nil
                c.resume()
            }
        }
    }
}
