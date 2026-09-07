//
//  ProducerLifecycleTests.swift
//  ContractTests
//
//  Producer lifecycle tests.
//

import XCTest
@testable import VolcengineTLSProducer

final class ProducerLifecycleTests: XCTestCase {

    // MARK: - open

    func testOpenSuccess() async throws {
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)
        XCTAssertEqual(recording.openCallCount, 1)

        try producer.add(LogEvent(contents: ["k": .string("v")]))
        XCTAssertEqual(recording.addCalls.count, 1)

        try await producer.close(timeout: 1)
    }

    func testOpenFailurePropagates() async throws {
        let recording = RecordingAdapter()
        recording.openError = ProducerError.transport("simulated open failure")

        do {
            _ = try await Producer.open(
                adapter: recording,
                configuration: .makeTesting(),
                credentials: .testing)
            XCTFail("expected open to throw")
        } catch {
            XCTAssertEqual(
                error as? ProducerError,
                .transport("simulated open failure"))
        }
        XCTAssertEqual(recording.openCallCount, 1)
    }

    func testAddDuringOpeningThrowsInvalidState() async throws {
        let recording = RecordingAdapter()
        let gate = DispatchSemaphore(value: 0)
        recording.openGate = gate

        let producer = Producer(
            adapter: recording,
            configuration: try .makeTesting(),
            credentials: .testing,
            onSendResult: nil)

        let openTask = Task { try await producer.performOpen() }
        try await waitUntil { recording.openCallCount == 1 }

        // Producer is mid-open: add must fail with .invalidState.
        XCTAssertThrowsError(
            try producer.add(LogEvent(contents: ["k": .string("v")]))
        ) { error in
            XCTAssertEqual(error as? ProducerError, .invalidState)
        }
        XCTAssertTrue(recording.addCalls.isEmpty)

        gate.signal()
        try await openTask.value

        // After open completes, add works.
        try producer.add(LogEvent(contents: ["k": .string("v")]))
        XCTAssertEqual(recording.addCalls.count, 1)

        try await producer.close(timeout: 1)
    }

    func testAddAfterFailedOpenThrowsInvalidState() async throws {
        let recording = RecordingAdapter()
        recording.openError = ProducerError.`internal`("simulated")

        let producer = Producer(
            adapter: recording,
            configuration: try .makeTesting(),
            credentials: .testing,
            onSendResult: nil)

        do {
            try await producer.performOpen()
            XCTFail("expected open to throw")
        } catch {
            XCTAssertEqual(error as? ProducerError, .`internal`("simulated"))
        }

        XCTAssertThrowsError(
            try producer.add(LogEvent(contents: ["k": .string("v")]))
        ) { error in
            XCTAssertEqual(error as? ProducerError, .invalidState)
        }
    }

    // MARK: - close

    func testCloseIsIdempotent() async throws {
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        try await producer.close(timeout: 1)
        try await producer.close(timeout: 1)
        XCTAssertEqual(recording.closeCallCount, 1)
    }

    func testConcurrentCloseCallsCompleteOnce() async throws {
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        async let first: Void = producer.close(timeout: 1)
        async let second: Void = producer.close(timeout: 1)
        try await first
        try await second
        XCTAssertEqual(recording.closeCallCount, 1)
    }

    func testCloseJoinsInFlightShutdown() async throws {
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        // Start a close, then race a second close while the first is in
        // flight (RecordingAdapter.close yields once).
        let first = Task { try await producer.close(timeout: 1) }
        let second = Task { try await producer.close(timeout: 1) }
        try await first.value
        try await second.value
        XCTAssertEqual(recording.closeCallCount, 1)
    }

    func testAddAfterCloseThrowsClosed() async throws {
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        try await producer.close(timeout: 1)

        XCTAssertThrowsError(
            try producer.add(LogEvent(contents: ["k": .string("v")]))
        ) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
        XCTAssertEqual(recording.addCalls.count, 0)
    }

    func testUpdateAfterCloseThrowsClosed() async throws {
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        try await producer.close(timeout: 1)

        XCTAssertThrowsError(try producer.updateCredentials(.testing)) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
        XCTAssertThrowsError(try producer.updateDestination(.testing)) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
        XCTAssertTrue(recording.updateCredentialsCalls.isEmpty)
        XCTAssertTrue(recording.updateDestinationCalls.isEmpty)
    }

    func testCloseBeforeOpenThrowsInvalidState() async {
        let producer = Producer(
            adapter: RecordingAdapter(),
            configuration: try! .makeTesting(),
            credentials: .testing,
            onSendResult: nil)
        do {
            try await producer.close(timeout: 1)
            XCTFail("expected close to throw")
        } catch {
            XCTAssertEqual(error as? ProducerError, .invalidState)
        }
    }

    // MARK: - updateCredentials / updateDestination

    func testUpdateCredentialsDelegatedAtomically() async throws {
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        let values = ["first-value", "second-value", "third-value"]
        let newCredentials = Credentials(
            accessKeyID: values[0],
            accessKeySecret: values[1],
            securityToken: values[2])
        try producer.updateCredentials(newCredentials)
        XCTAssertEqual(recording.updateCredentialsCalls.count, 1)
        XCTAssertEqual(recording.updateCredentialsCalls.first, newCredentials)

        try await producer.close(timeout: 1)
    }

    func testUpdateDestinationDelegated() async throws {
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        try producer.updateDestination(.testing)
        XCTAssertEqual(recording.updateDestinationCalls.count, 1)

        try await producer.close(timeout: 1)
    }

    // MARK: - onSendResult delivery

    func testSendResultDeliveredToHandler() async throws {
        let recording = RecordingAdapter()
        let collector = ResultCollector()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing) { result in
                collector.append(result)
            }

        let expected = SendResult(
            status: .failure,
            rawBytes: 100,
            compressedBytes: 50,
            requestID: "req-1",
            error: .auth)
        recording.emit(expected)

        try await waitUntil { collector.results.count > 0 }
        XCTAssertEqual(collector.results.first, expected)

        try await producer.close(timeout: 1)
    }

    func testSendResultDeliveredOnCallbackQueue() async throws {
        let recording = RecordingAdapter()
        let config = try ProducerConfiguration()
        let callbackKey = DispatchSpecificKey<UInt8>()
        config.callbackQueue.setSpecific(key: callbackKey, value: 1)
        let labelChecker = CallbackQueueLabelCollector(key: callbackKey)
        let producer = try await Producer.open(
            adapter: recording,
            configuration: config,
            credentials: .testing) { _ in
                labelChecker.record()
            }

        recording.emit(SendResult(
            status: .success, rawBytes: 1, compressedBytes: 1,
            requestID: nil, error: nil))
        try await waitUntil { labelChecker.recordedCount > 0 }
        XCTAssertTrue(labelChecker.allMatch)

        try await producer.close(timeout: 1)
    }
}

// MARK: - Thread-safe test doubles

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

private final class CallbackQueueLabelCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let key: DispatchSpecificKey<UInt8>
    private var _recordedCount = 0
    private var _allMatch = true

    init(key: DispatchSpecificKey<UInt8>) {
        self.key = key
    }

    var recordedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _recordedCount
    }

    var allMatch: Bool {
        lock.lock(); defer { lock.unlock() }
        return _allMatch
    }

    func record() {
        // Swift 6 has no DispatchQueue.current; verify the callback runs on
        // the tagged queue via the current-queue specific.
        let onCallbackQueue = DispatchQueue.getSpecific(key: key) != nil
        lock.lock()
        _recordedCount += 1
        if !onCallbackQueue {
            _allMatch = false
        }
        lock.unlock()
    }
}
