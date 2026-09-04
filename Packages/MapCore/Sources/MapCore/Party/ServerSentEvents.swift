import Foundation

/// One dispatched `text/event-stream` event.
public struct ServerSentEvent: Sendable, Equatable {
    /// The stream's last event id at the time this event was dispatched (`id:` is sticky per the
    /// spec, so it survives events that do not carry one). Ably takes it back as `lastEvent=`.
    public var id: String?
    /// The `event:` field; the spec's default is `message`.
    public var event: String
    /// The `data:` lines joined with newlines.
    public var data: String
    /// The `retry:` field in milliseconds, when the server sent one.
    public var retryMilliseconds: Int?

    public init(id: String? = nil, event: String = "message", data: String, retryMilliseconds: Int? = nil) {
        self.id = id
        self.event = event
        self.data = data
        self.retryMilliseconds = retryMilliseconds
    }
}

/// Incremental parser for the `text/event-stream` wire format (WHATWG HTML §9.2.6), fed one line at
/// a time by whatever is reading the socket.
///
/// It implements exactly the parts a subscriber needs: `event`, `data`, `id` and `retry` fields, one
/// optional space after the colon, comment lines (`:` — which is how Ably sends its keep-alive
/// heartbeat) and the blank line that dispatches an event. Everything else is ignored, per the spec.
public struct ServerSentEventParser: Sendable {
    /// The most recent `id:` seen, which the next reconnect resumes from.
    public private(set) var lastEventID: String?
    /// The most recent `retry:` the server asked for, in milliseconds.
    public private(set) var retryMilliseconds: Int?
    /// True while a comment (heartbeat) was the last thing seen — a live but idle stream.
    public private(set) var commentCount = 0

    private var event: String?
    private var dataLines: [String] = []
    private var hasData = false

    public init() {}

    /// Feeds one line, without its terminator. Returns an event when the line dispatches one
    /// (a blank line after at least one `data:` line).
    public mutating func consume(line: String) -> ServerSentEvent? {
        // A CR left over from CRLF framing is not part of the value.
        var line = line
        if line.hasSuffix("\r") { line.removeLast() }

        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") {
            commentCount += 1
            return nil
        }
        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }
        switch field {
        case "event":
            event = value
        case "data":
            dataLines.append(value)
            hasData = true
        case "id":
            // The spec ignores an id containing a NUL; nothing else is filtered.
            if !value.contains("\0") { lastEventID = value }
        case "retry":
            if let milliseconds = Int(value), milliseconds >= 0 { retryMilliseconds = milliseconds }
        default:
            break   // unknown field: ignored
        }
        return nil
    }

    /// Emits a pending event when the stream ends mid-block. The spec drops such a block; Ably
    /// terminates cleanly, so this only matters for a truncated response and is opt-in.
    public mutating func flush() -> ServerSentEvent? {
        dispatch()
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            event = nil
            dataLines.removeAll(keepingCapacity: true)
            hasData = false
        }
        guard hasData else { return nil }
        return ServerSentEvent(id: lastEventID,
                               event: event?.isEmpty == false ? (event ?? "message") : "message",
                               data: dataLines.joined(separator: "\n"),
                               retryMilliseconds: retryMilliseconds)
    }
}
