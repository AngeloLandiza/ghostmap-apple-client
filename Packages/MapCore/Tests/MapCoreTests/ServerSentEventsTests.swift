import XCTest
@testable import MapCore

final class ServerSentEventsTests: XCTestCase {

    /// Feeds a whole stream body and returns every dispatched event.
    private func parse(_ body: String) -> (events: [ServerSentEvent], parser: ServerSentEventParser) {
        var parser = ServerSentEventParser()
        var events: [ServerSentEvent] = []
        for line in body.components(separatedBy: "\n") {
            if let event = parser.consume(line: line) { events.append(event) }
        }
        return (events, parser)
    }

    func testDispatchesOnTheBlankLine() {
        let (events, _) = parse("event: message\ndata: {\"a\":1}\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "message")
        XCTAssertEqual(events[0].data, "{\"a\":1}")
    }

    func testDefaultsTheEventNameToMessage() {
        let (events, _) = parse("data: hello\n\n")
        XCTAssertEqual(events.first?.event, "message")
    }

    func testJoinsMultipleDataLinesWithNewlines() {
        let (events, _) = parse("data: one\ndata: two\n\n")
        XCTAssertEqual(events.first?.data, "one\ntwo")
    }

    func testOnlyOneLeadingSpaceIsStripped() {
        let (events, _) = parse("data:  padded\n\n")
        XCTAssertEqual(events.first?.data, " padded")
    }

    func testFieldWithoutAColonHasAnEmptyValue() {
        let (events, _) = parse("data\n\n")
        XCTAssertEqual(events.first?.data, "")
    }

    func testCommentsAreHeartbeatsAndDispatchNothing() {
        let (events, parser) = parse(":keepalive\n\n:another\n\n")
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(parser.commentCount, 2)
    }

    func testIdIsStickyAcrossEvents() {
        let (events, parser) = parse("id: 42\ndata: a\n\ndata: b\n\n")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].id, "42")
        XCTAssertEqual(events[1].id, "42")
        XCTAssertEqual(parser.lastEventID, "42")
    }

    func testRetryIsRememberedAndReported() {
        let (events, parser) = parse("retry: 2500\ndata: a\n\n")
        XCTAssertEqual(parser.retryMilliseconds, 2500)
        XCTAssertEqual(events.first?.retryMilliseconds, 2500)
        let (_, ignored) = parse("retry: soon\ndata: a\n\n")
        XCTAssertNil(ignored.retryMilliseconds)
    }

    func testCRLFFramingIsHandled() {
        let (events, _) = parse("event: message\r\ndata: x\r\n\r\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "x")
        XCTAssertEqual(events[0].event, "message")
    }

    func testUnknownFieldsAreIgnored() {
        let (events, _) = parse("weird: value\ndata: x\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "x")
    }

    func testBlankLineWithoutDataDispatchesNothing() {
        let (events, _) = parse("event: ping\n\n")
        XCTAssertTrue(events.isEmpty)
    }

    func testFlushEmitsATruncatedBlock() {
        var parser = ServerSentEventParser()
        XCTAssertNil(parser.consume(line: "data: half"))
        let event = parser.flush()
        XCTAssertEqual(event?.data, "half")
        XCTAssertNil(parser.flush())
    }

    /// The shape Ably actually sends: an enveloped message with `name` and `data` inside the JSON.
    func testAblyStyleEnvelope() {
        let body = """
        id: abc:0
        event: message
        data: {"id":"abc:0","name":"pose","data":{"device_id":"d1"}}

        """
        let (events, _) = parse(body)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].id, "abc:0")
        XCTAssertTrue(events[0].data.contains("\"name\":\"pose\""))
    }
}
