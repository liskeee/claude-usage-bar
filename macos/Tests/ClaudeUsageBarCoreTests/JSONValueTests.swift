import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct JSONValueTests {
    @Test func roundTrip_keepsIntegersDoublesBooleansAndNonASCII() throws {
        let source = #"{"ms":1790271138070,"half":2.50,"flag":true,"one":1,"zero":0,"path":"/Users/łukasz/zażółć","list":[1,2.5,"x",null,false]}"#
        let value = try JSONValue.parse(Data(source.utf8))

        #expect(value["ms"] == .int(1790271138070))
        #expect(value["half"] == .double(2.5))
        #expect(value["flag"] == .bool(true))
        #expect(value["one"] == .int(1))
        #expect(value["zero"] == .int(0))
        #expect(value["path"]?.string == "/Users/łukasz/zażółć")
        #expect(try JSONValue.parse(try value.serialized()) == value)
        let text = String(decoding: try value.serialized(), as: UTF8.self)
        #expect(text.contains("1790271138070"))
        #expect(!text.contains("1790271138070.0"))
        #expect(text.contains("/Users/łukasz/zażółć")) // no \/ and no \u escapes
    }

    @Test func loneSurrogate_isRejected() {
        #expect(throws: (any Error).self) { try JSONValue.parse(Data(#"{"x":"a\ud83db"}"#.utf8)) }
    }

    @Test func serialized_sortsKeys_andCompactHasNoNewlines() throws {
        let value = try JSONValue.parse(Data(#"{"b":1,"a":{"d":2,"c":3}}"#.utf8))
        let pretty = String(decoding: try value.serialized(), as: UTF8.self)
        let compact = String(decoding: try value.serialized(pretty: false), as: UTF8.self)

        #expect(pretty.range(of: "\"a\"")!.lowerBound < pretty.range(of: "\"b\"")!.lowerBound)
        #expect(compact == #"{"a":{"c":3,"d":2},"b":1}"#)
    }

    @Test func numberAndAccessors() throws {
        let value = try JSONValue.parse(Data(#"{"i":3,"d":0.5,"s":"x","n":null}"#.utf8))
        #expect(value["i"]?.number == 3)
        #expect(value["d"]?.number == 0.5)
        #expect(value["s"]?.number == nil)
        #expect(value["n"] == .null)
        #expect(value["missing"] == nil)
        #expect(JSONValue.string("x")["anything"] == nil)
    }

    @Test func hex_decodesBytes() {
        #expect(Data(hex: "00ff10") == Data([0x00, 0xff, 0x10]))
        #expect(Data(hex: "zz") == nil)
    }
}
