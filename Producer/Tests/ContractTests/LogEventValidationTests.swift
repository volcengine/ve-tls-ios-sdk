//
//  LogEventValidationTests.swift
//  ContractTests
//
//  Worker A — whole-event rejection, field paths, depth, snapshot semantics.
//

import XCTest
@testable import VolcengineTLSProducer

final class LogEventValidationTests: XCTestCase {

    // MARK: - Whole-event rejection

    func testOneInvalidFieldRejectsWholeEvent() async throws {
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        let event = LogEvent(contents: [
            "good": .string("value"),
            "bad": .double(Double.nan),
        ])

        XCTAssertThrowsError(try producer.add(event)) { error in
            guard case ProducerError.invalidLog(let paths) = error else {
                XCTFail("expected .invalidLog, got \(error)")
                return
            }
            XCTAssertEqual(paths.count, 1)
            XCTAssertTrue(paths[0].hasPrefix("bad:"), "paths: \(paths)")
        }

        // Nothing was admitted: the spy must not have seen ANY field.
        XCTAssertTrue(recording.addCalls.isEmpty)

        try await producer.close(timeout: 1)
    }

    func testMultipleInvalidFieldsAllReported() throws {
        let event = LogEvent(contents: [
            "nan": .double(Double.nan),
            "inf": .double(Double.infinity),
            "badData": .utf8Data(Data([0xFF])),
        ])
        XCTAssertThrowsError(try event.validate()) { error in
            guard case ProducerError.invalidLog(let paths) = error else {
                XCTFail("expected .invalidLog, got \(error)")
                return
            }
            XCTAssertEqual(paths.count, 3)
            let joined = paths.joined(separator: "|")
            XCTAssertTrue(joined.contains("nan:"))
            XCTAssertTrue(joined.contains("inf:"))
            XCTAssertTrue(joined.contains("badData:"))
        }
    }

    func testEmptyKeyRejected() throws {
        let event = LogEvent(contents: ["": .string("x")])
        XCTAssertThrowsError(try event.validate()) { error in
            guard case ProducerError.invalidLog(let paths) = error else {
                XCTFail("expected .invalidLog, got \(error)")
                return
            }
            XCTAssertEqual(paths.count, 1)
            XCTAssertTrue(paths[0].hasPrefix("<empty-key>:"))
        }
    }

    func testDepthViolationReportedWithFieldPath() throws {
        var deep: LogValue = .signedInt(1)
        for _ in 0..<33 {
            deep = .array([deep])
        }
        let event = LogEvent(contents: ["deep": deep])
        XCTAssertThrowsError(try event.validate()) { error in
            guard case ProducerError.invalidLog(let paths) = error else {
                XCTFail("expected .invalidLog, got \(error)")
                return
            }
            XCTAssertEqual(paths.count, 1)
            XCTAssertTrue(paths[0].hasPrefix("deep:"))
        }
    }

    func testEmbeddedNULAndNonFiniteTimestampAreRejected() throws {
        let event = LogEvent(
            timestamp: Date(timeIntervalSince1970: .infinity),
            hashKey: "hash\0suffix",
            contents: [
                "key\0suffix": .string("value"),
                "value": .string("prefix\0suffix"),
            ])
        XCTAssertThrowsError(try event.validate()) { error in
            guard case ProducerError.invalidLog(let paths) = error else {
                XCTFail("expected .invalidLog, got \(error)")
                return
            }
            let joined = paths.joined(separator: "|")
            XCTAssertTrue(joined.contains("timestamp:"))
            XCTAssertTrue(joined.contains("hashKey:"))
            XCTAssertTrue(joined.contains("embedded NUL"))
        }
    }

    func testHashKeyMustBeExactly32LowercaseHexBytes() throws {
        let valid = [
            String(repeating: "0", count: 32),
            "0123456789abcdef0123456789abcdef",
            String(repeating: "f", count: 32),
        ]
        for hashKey in valid {
            XCTAssertNoThrow(
                try LogEvent(hashKey: hashKey, contents: ["k": .string("v")]).validate(),
                "expected valid hashKey: \(hashKey)")
        }

        let invalid = [
            "",
            "0",
            "0123456789abcdef",
            "ABCDEF",
            "0123456789abcdef0123456789abcdef0",
            "g",
            "hash-key",
            "é",
        ]
        for hashKey in invalid {
            XCTAssertThrowsError(
                try LogEvent(hashKey: hashKey, contents: ["k": .string("v")]).validate(),
                "expected invalid hashKey: \(hashKey)") { error in
                guard case ProducerError.invalidLog(let paths) = error else {
                    XCTFail("expected .invalidLog, got \(error)")
                    return
                }
                XCTAssertTrue(paths.contains { $0.hasPrefix("hashKey:") })
            }
        }
    }

    func testSingleLogAboveNinePointFiveMiBRejectedAtRecommendedBatchLimit() async throws {
        let recommendedMaxRawBytes = 19 * 512 * 1024
        let recording = RecordingAdapter()
        let config = try ProducerConfiguration(
            batch: BatchConfiguration(
                maxLogCount: 10_000,
                maxRawBytes: recommendedMaxRawBytes,
                linger: 3))
        let producer = try await Producer.open(
            adapter: recording,
            configuration: config,
            credentials: .testing)

        let oversizedValue = String(repeating: "x", count: recommendedMaxRawBytes)
        let oversized = LogEvent(contents: ["k": .string(oversizedValue)])
        XCTAssertThrowsError(try producer.add(oversized)) { error in
            XCTAssertEqual(error as? ProducerError, .singleLogTooLarge)
        }
        XCTAssertTrue(recording.addCalls.isEmpty)

        try await producer.close(timeout: 1)
    }

    func testValidEventPassesValidation() throws {
        let event = LogEvent(contents: [
            "s": .string("x"),
            "i": .signedInt(-1),
            "u": .unsignedInt(1),
            "d": .double(2.5),
            "b": .bool(true),
            "n": .null,
            "a": .array([.signedInt(1), .string("y")]),
            "o": .dictionary(["k": .bool(false)]),
            "data": .utf8Data(Data("raw".utf8)),
        ])
        XCTAssertNoThrow(try event.validate())
    }

    func testAdmissionPreparationProducesOneImmutableWireSnapshot() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.123)
        let event = LogEvent(
            timestamp: timestamp,
            hashKey: "0123456789abcdef0123456789abcdef",
            contents: [
                "plain": .string("value"),
                "nested": .dictionary(["b": .string("two"), "a": .signedInt(1)]),
            ])

        let prepared = try event.prepareForAdmission()

        XCTAssertTrue(event.hasCachedAdmissionSnapshot)
        XCTAssertEqual(prepared.timestampMilliseconds, 1_700_000_000_123)
        XCTAssertEqual(prepared.hashKey, event.hashKey)
        XCTAssertEqual(prepared.encodedKeys.count, 2)
        XCTAssertEqual(prepared.encodedValues.count, 2)
        XCTAssertEqual(prepared.encodedLengths.count, 4)
        XCTAssertEqual(prepared.encodedFieldBytes.count, prepared.rawBytes)
        XCTAssertEqual(prepared.encodedContents["plain"], "value")
        XCTAssertEqual(prepared.encodedContents["nested"], "{\"a\":1,\"b\":\"two\"}")
        XCTAssertEqual(
            prepared.rawBytes,
            "plain".utf8.count + "value".utf8.count
                + "nested".utf8.count + "{\"a\":1,\"b\":\"two\"}".utf8.count)
    }

    func testAdmissionPreparationPreservesUnicodeAndEmptyValues() throws {
        let event = LogEvent(contents: [
            "键🔑": .string("值🙂"),
            "empty": .string(""),
        ])

        let prepared = try event.prepareForAdmission()

        XCTAssertEqual(prepared.encodedContents["键🔑"], "值🙂")
        XCTAssertEqual(prepared.encodedContents["empty"], "")
        XCTAssertEqual(prepared.encodedFieldBytes.count, prepared.rawBytes)
        XCTAssertEqual(
            prepared.encodedLengths.sorted(),
            [0, "键🔑".utf8.count, "值🙂".utf8.count, "empty".utf8.count].sorted())
    }

    func testAdmissionPreparationCacheInvalidatesOnMutation() throws {
        var event = LogEvent(
            hashKey: String(repeating: "0", count: 32),
            contents: ["key": .string("before")])
        XCTAssertTrue(event.hasCachedAdmissionSnapshot)

        event.contents["key"] = .string("after")
        XCTAssertFalse(event.hasCachedAdmissionSnapshot)

        let prepared = try event.prepareForAdmission()
        XCTAssertEqual(prepared.hashKey, String(repeating: "0", count: 32))
        XCTAssertEqual(prepared.encodedContents, ["key": "after"])
    }

    func testInvalidAndEmptyEventsDoNotCacheAdmissionSnapshot() {
        XCTAssertFalse(LogEvent(contents: [:]).hasCachedAdmissionSnapshot)
        XCTAssertFalse(LogEvent(contents: ["key": .double(.nan)]).hasCachedAdmissionSnapshot)
    }

    func testInvalidLogStillPrecedesOversizeRejection() async throws {
        let recording = RecordingAdapter()
        let config = try ProducerConfiguration(
            batch: BatchConfiguration(maxLogCount: 1024, maxRawBytes: 16, linger: 3))
        let producer = try await Producer.open(
            adapter: recording,
            configuration: config,
            credentials: .testing)

        let event = LogEvent(contents: [
            "large": .string(String(repeating: "x", count: 100)),
            "invalid": .double(.nan),
        ])
        XCTAssertThrowsError(try producer.add(event)) { error in
            guard case ProducerError.invalidLog(let paths) = error else {
                XCTFail("expected invalidLog before size rejection, got \(error)")
                return
            }
            XCTAssertTrue(paths.contains { $0.hasPrefix("invalid:") })
        }
        XCTAssertTrue(recording.addCalls.isEmpty)

        try await producer.close(timeout: 1)
    }

    // MARK: - Snapshot semantics

    func testAddSnapshotsValue() async throws {
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        var event = LogEvent(contents: ["k": .string("v1")])
        try producer.add(event)

        // Mutating the original must not affect the admitted copy.
        event.contents["k"] = .string("v2")
        event.contents["other"] = .signedInt(2)

        XCTAssertEqual(recording.addCalls.count, 1)
        XCTAssertEqual(recording.addCalls[0].prepared.encodedContents["k"], "v1")
        XCTAssertNil(recording.addCalls[0].prepared.encodedContents["other"])
        XCTAssertEqual(recording.addCalls[0].prepared.rawBytes, 3)

        try await producer.close(timeout: 1)
    }

    func testDefaultTimestampCapturedAtInit() throws {
        let before = Date()
        let event = LogEvent(contents: ["k": .string("v")])
        let after = Date()
        XCTAssertTrue(before <= event.timestamp)
        XCTAssertTrue(event.timestamp <= after)
    }
}
