//
//  AddModeContractTests.swift
//  ContractTests
//
//  Worker A — normal/immediate admission contracts.
//

import XCTest
@testable import VolcengineTLSProducer

final class AddModeContractTests: XCTestCase {

    // MARK: - Mode recording

    func testNormalModeRecordedByAdapter() async throws {
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        try producer.add(LogEvent(contents: ["k": .string("v")]))
        XCTAssertEqual(recording.addCalls.count, 1)
        XCTAssertEqual(recording.addCalls[0].mode, .normal)

        // Default argument is .normal.
        try producer.add(LogEvent(contents: ["k2": .string("v2")]), mode: .normal)
        XCTAssertEqual(recording.addCalls[1].mode, .normal)

        try await producer.close(timeout: 1)
    }

    func testImmediateModeRecordedByAdapter() async throws {
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        try producer.add(LogEvent(contents: ["k": .string("v")]), mode: .immediate)
        XCTAssertEqual(recording.addCalls.count, 1)
        XCTAssertEqual(recording.addCalls[0].mode, .immediate)

        try await producer.close(timeout: 1)
    }

    // MARK: - Immediate is still asynchronous

    func testImmediateAddDoesNotWaitForCallback() async throws {
        let recording = RecordingAdapter()
        let counter = CallbackCounter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing) { _ in
                counter.increment()
            }

        try producer.add(
            LogEvent(contents: ["k": .string("v")]),
            mode: .immediate)

        // add returned synchronously; the adapter has not emitted any result
        // and the user handler must not have run yet.
        XCTAssertEqual(counter.value, 0)

        // Emitting from the adapter delivers on the callback queue.
        recording.emit(SendResult(
            status: .success,
            rawBytes: 1,
            compressedBytes: 1,
            requestID: nil,
            error: nil))
        try await waitUntil { counter.value > 0 }
        XCTAssertEqual(counter.value, 1)

        try await producer.close(timeout: 1)
    }

    // MARK: - BundledCoreAdapter: immediate seals without waiting for linger

    func testBundledAdapterImmediateSealsWithoutLinger() async throws {
        let counter = CallbackCounter()
        let producer = try await Producer.open(
            adapter: BundledCoreAdapter(),
            configuration: .makeTesting(),
            credentials: .testing) { _ in
                counter.increment()
            }

        let start = Date()
        try producer.add(
            LogEvent(contents: ["k": .string("v")]),
            mode: .immediate)

        // The batch must seal well before the 3s linger.
        try await waitUntil(timeout: 1) { counter.value > 0 }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertEqual(counter.value, 1)

        try await producer.close(timeout: 2)
    }

    func testBundledAdapterDeliversSuccessfulResultFields() async throws {
        let collector = ResultCollector()
        let producer = try await Producer.open(
            adapter: BundledCoreAdapter(),
            configuration: .makeTesting(),
            credentials: .testing) { result in
                collector.append(result)
            }

        try producer.add(
            LogEvent(contents: ["k": .string("v")]),
            mode: .immediate)
        try await waitUntil(timeout: 1) { collector.results.count > 0 }

        let result = try XCTUnwrap(collector.results.first)
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.requestID, nil)
        XCTAssertEqual(result.error, nil)
        // No compression in the bundled adapter: compressed mirrors raw.
        XCTAssertEqual(result.rawBytes, result.compressedBytes)
        XCTAssertGreaterThan(result.rawBytes, 0)

        try await producer.close(timeout: 2)
    }

    // MARK: - singleLogTooLarge

    func testSingleLogTooLargeRejected() async throws {
        let recording = RecordingAdapter()
        let config = try ProducerConfiguration(
            batch: BatchConfiguration(maxLogCount: 1024, maxRawBytes: 16, linger: 3))
        let producer = try await Producer.open(
            adapter: recording,
            configuration: config,
            credentials: .testing)

        let big = LogEvent(contents: ["k": .string("0123456789abcdef")])
        XCTAssertThrowsError(try producer.add(big)) { error in
            XCTAssertEqual(error as? ProducerError, .singleLogTooLarge)
        }
        XCTAssertTrue(recording.addCalls.isEmpty)

        try await producer.close(timeout: 1)
    }
}

// MARK: - Thread-safe test doubles

private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); _value += 1; lock.unlock()
    }
}

private final class ResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _results: [SendResult] = []
    var results: [SendResult] {
        lock.lock(); defer { lock.unlock() }
        return _results
    }
    func append(_ result: SendResult) {
        lock.lock(); _results.append(result); lock.unlock()
    }
}
