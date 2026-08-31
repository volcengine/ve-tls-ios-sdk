//
//  LogValueEncodingTests.swift
//  ContractTests
//
//  Worker A — encoding matrix, verbatim assertions.
//

import XCTest
@testable import VolcengineTLSProducer

final class LogValueEncodingTests: XCTestCase {

    // MARK: - Scalars

    func testStringEncodedVerbatim() throws {
        XCTAssertEqual(try LogValue.string("hello").encodedString(), "hello")
        XCTAssertEqual(try LogValue.string("").encodedString(), "")
        XCTAssertEqual(try LogValue.string("中文日志").encodedString(), "中文日志")
    }

    func testSignedIntEncodedDecimal() throws {
        XCTAssertEqual(try LogValue.signedInt(42).encodedString(), "42")
        XCTAssertEqual(try LogValue.signedInt(-7).encodedString(), "-7")
        XCTAssertEqual(try LogValue.signedInt(0).encodedString(), "0")
        XCTAssertEqual(
            try LogValue.signedInt(Int64.min).encodedString(),
            "-9223372036854775808")
        XCTAssertEqual(
            try LogValue.signedInt(Int64.max).encodedString(),
            "9223372036854775807")
    }

    func testUnsignedIntEncodedDecimal() throws {
        XCTAssertEqual(try LogValue.unsignedInt(42).encodedString(), "42")
        XCTAssertEqual(try LogValue.unsignedInt(0).encodedString(), "0")
        XCTAssertEqual(
            try LogValue.unsignedInt(UInt64.max).encodedString(),
            "18446744073709551615")
    }

    func testDoubleEncodedLocaleIndependent() throws {
        XCTAssertEqual(try LogValue.double(1.5).encodedString(), "1.5")
        XCTAssertEqual(try LogValue.double(-2.25).encodedString(), "-2.25")
        XCTAssertEqual(try LogValue.double(0.0).encodedString(), "0.0")
        XCTAssertEqual(try LogValue.double(1_000_000.25).encodedString(), "1000000.25")
    }

    func testBoolEncodedLowercase() throws {
        XCTAssertEqual(try LogValue.bool(true).encodedString(), "true")
        XCTAssertEqual(try LogValue.bool(false).encodedString(), "false")
    }

    func testNullEncodedAsString() throws {
        XCTAssertEqual(try LogValue.null.encodedString(), "null")
    }

    // MARK: - Collections (compact JSON)

    func testEmptyArrayEncoded() throws {
        XCTAssertEqual(try LogValue.array([]).encodedString(), "[]")
    }

    func testArrayEncodedCompact() throws {
        let value: LogValue = .array([.signedInt(1), .signedInt(2), .string("x")])
        XCTAssertEqual(try value.encodedString(), "[1,2,\"x\"]")
    }

    func testEmptyDictionaryEncoded() throws {
        XCTAssertEqual(try LogValue.dictionary([:]).encodedString(), "{}")
    }

    func testDictionaryEncodedSortedKeys() throws {
        let value: LogValue = .dictionary([
            "b": .string("2"),
            "a": .signedInt(1),
        ])
        XCTAssertEqual(try value.encodedString(), "{\"a\":1,\"b\":\"2\"}")
    }

    func testNestedCollectionEncoded() throws {
        let value: LogValue = .dictionary([
            "k": .array([.bool(true), .null, .double(1.5)]),
        ])
        XCTAssertEqual(try value.encodedString(), "{\"k\":[true,null,1.5]}")
    }

    func testJSONStringEscaping() throws {
        let value: LogValue = .dictionary([
            "quote\"slash\\": .string("line1\nline2\ttab\u{1}"),
        ])
        let encoded = try value.encodedString()
        XCTAssertEqual(
            encoded,
            "{\"quote\\\"slash\\\\\":\"line1\\nline2\\ttab\\u0001\"}")
    }

    // MARK: - utf8Data

    func testUTF8DataEncodedAsText() throws {
        let data = Data([0x66, 0x6F, 0x6F]) // "foo"
        XCTAssertEqual(try LogValue.utf8Data(data).encodedString(), "foo")
    }

    func testUTF8DataEncodedAsUTF8Text() throws {
        let text = "日志内容"
        XCTAssertEqual(
            try LogValue.utf8Data(Data(text.utf8)).encodedString(),
            text)
    }

    func testUTF8DataEmptyEncodedAsEmptyString() throws {
        XCTAssertEqual(try LogValue.utf8Data(Data()).encodedString(), "")
    }

    func testUTF8DataInsideArrayEncodedAsJSONString() throws {
        let value: LogValue = .array([
            .utf8Data(Data("a\"b\\c\n🙂".utf8)),
        ])
        XCTAssertEqual(try value.encodedString(), "[\"a\\\"b\\\\c\\n🙂\"]")
    }

    func testUTF8DataInsideDictionaryEncodedAsJSONString() throws {
        let value: LogValue = .dictionary([
            "bytes": .utf8Data(Data("字节-🙂".utf8)),
        ])
        XCTAssertEqual(try value.encodedString(), "{\"bytes\":\"字节-🙂\"}")
    }

    // MARK: - Rejections

    func testNaNDoubleRejected() {
        XCTAssertThrowsError(try LogValue.double(Double.nan).encodedString()) { error in
            XCTAssertEqual(
                error as? LogValueEncodingError,
                LogValueEncodingError.nonFiniteDouble)
        }
    }

    func testInfinityDoubleRejected() {
        XCTAssertThrowsError(try LogValue.double(Double.infinity).encodedString()) { error in
            XCTAssertEqual(
                error as? LogValueEncodingError,
                LogValueEncodingError.nonFiniteDouble)
        }
        XCTAssertThrowsError(try LogValue.double(-Double.infinity).encodedString()) { error in
            XCTAssertEqual(
                error as? LogValueEncodingError,
                LogValueEncodingError.nonFiniteDouble)
        }
    }

    func testInvalidUTF8DataRejected() {
        XCTAssertThrowsError(try LogValue.utf8Data(Data([0xFF])).encodedString()) { error in
            XCTAssertEqual(
                error as? LogValueEncodingError,
                LogValueEncodingError.invalidUTF8Data)
        }
        XCTAssertThrowsError(try LogValue.utf8Data(Data([0xC3, 0x28])).encodedString()) { error in
            XCTAssertEqual(
                error as? LogValueEncodingError,
                LogValueEncodingError.invalidUTF8Data)
        }
    }

    func testEmbeddedNULDetectionPreservesUnicodeAndBoundarySemantics() throws {
        XCTAssertEqual(
            try LogValue.string("日志内容").encodedString(),
            "日志内容")

        for value in ["\0suffix", "prefix\0", "日志\0内容"] {
            XCTAssertThrowsError(try LogValue.string(value).encodedString()) { error in
                XCTAssertEqual(
                    error as? LogValueEncodingError,
                    LogValueEncodingError.embeddedNUL)
            }
        }

        XCTAssertThrowsError(
            try LogValue.utf8Data(Data("日志\0内容".utf8)).encodedString()) { error in
                XCTAssertEqual(
                    error as? LogValueEncodingError,
                    LogValueEncodingError.embeddedNUL)
            }
    }

    // MARK: - Depth

    private func nestedArray(depth: Int) -> LogValue {
        var value: LogValue = .signedInt(1)
        for _ in 0..<depth {
            value = .array([value])
        }
        return value
    }

    func testDepth32Accepted() throws {
        XCTAssertNoThrow(try nestedArray(depth: 32).encodedString())
    }

    func testDepth33Rejected() {
        XCTAssertThrowsError(try nestedArray(depth: 33).encodedString()) { error in
            XCTAssertEqual(
                error as? LogValueEncodingError,
                LogValueEncodingError.nestingDepthExceeded)
        }
    }

    func testDepth33InDictionaryRejected() {
        let value: LogValue = .dictionary(["deep": nestedArray(depth: 33)])
        XCTAssertThrowsError(try value.encodedString()) { error in
            XCTAssertEqual(
                error as? LogValueEncodingError,
                LogValueEncodingError.nestingDepthExceeded)
        }
    }
}
