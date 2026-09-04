import XCTest
@testable import MapCore

final class JSONValueTests: XCTestCase {

    func testDecodesEveryKind() throws {
        let json = #"{"n":null,"b":true,"i":7,"d":1.5,"s":"x","a":[1,"two",false],"o":{"k":1}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value["n"], JSONValue.null)
        XCTAssertEqual(value["b"], JSONValue.bool(true))
        XCTAssertEqual(value["i"], JSONValue.int(7))
        XCTAssertEqual(value["d"], JSONValue.double(1.5))
        XCTAssertEqual(value["s"], JSONValue.string("x"))
        XCTAssertEqual(value["a"]?.arrayValue?.count, 3)
        XCTAssertEqual(value["o"]?["k"], JSONValue.int(1))
    }

    func testIntegersStayIntegers() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("[1,2,3]".utf8))
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "[1,2,3]")
    }

    func testRoundTrip() throws {
        let original = JSONValue.object([
            "map_id": .string("M1"),
            "points": .array([.int(1), .double(2.5), .null, .bool(false)]),
            "nested": .object(["a": .string("b")]),
        ])
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(back, original)
    }

    func testAccessors() {
        XCTAssertEqual(JSONValue.string("a").stringValue, "a")
        XCTAssertNil(JSONValue.int(1).stringValue)
        XCTAssertEqual(JSONValue.int(3).doubleValue, 3)
        XCTAssertEqual(JSONValue.double(3.0).intValue, 3)
        XCTAssertEqual(JSONValue.bool(false).boolValue, false)
        XCTAssertTrue(JSONValue.null.isNull)
        XCTAssertNil(JSONValue.string("a")["k"])
    }

    func testBridgesFromFoundationObjects() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"a":1,"b":true,"c":[1.5,"s"],"d":null}"#.utf8))
        let value = try XCTUnwrap(JSONValue(any: object))
        XCTAssertEqual(value["a"], JSONValue.int(1))
        XCTAssertEqual(value["b"], JSONValue.bool(true))
        XCTAssertEqual(value["c"]?.arrayValue?.first, JSONValue.double(1.5))
        XCTAssertEqual(value["d"], JSONValue.null)
        XCTAssertNil(JSONValue(any: Date()))
    }

    func testBridgesBackToFoundationObjects() throws {
        let value = JSONValue.object(["a": .int(1), "b": .array([.string("x")])])
        let data = try JSONSerialization.data(withJSONObject: value.anyValue, options: [.sortedKeys])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"a":1,"b":["x"]}"#)
    }
}
