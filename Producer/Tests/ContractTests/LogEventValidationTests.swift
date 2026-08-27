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
        XCTAssertEqual(recording.addCalls[0].event.contents["k"], .string("v1"))
        XCTAssertNil(recording.addCalls[0].event.contents["other"])

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
