//
//  ConsumerIntegrationTests.swift
//  ConsumerIntegrationTests
//
//  Worker F — black-box, consumer-perspective integration tests.
//
//  EVIDENCE BOUNDARY
//  -----------------
//  These tests compile against the PUBLIC API only: a plain
//  `import VolcengineTLSProducer`, deliberately WITHOUT `@testable`. They
//  exercise `Producer.open`, which currently wires the PROVISIONAL
//  `BundledCoreAdapter` (an in-memory placeholder: no network, no
//  persistence, no signing, no compression, no retry). A green run therefore
//  proves only that the public Swift surface behaves as documented ON TOP OF
//  THE BUNDLED ADAPTER. It is NOT evidence of Real Core integration, real
//  network delivery, WAL durability, retry/ACK behavior, or Beta readiness.
//  Real Core evidence is blocked on the C Core release gate
//  (see Producer/CORE_VERSION and Producer/DECISIONS.md).
//
//  Self-contained: this target does not link ProducerTestSupport, so the
//  small collector/polling helpers below are intentionally private.
//

import XCTest
import VolcengineTLSProducer

final class ConsumerIntegrationTests: XCTestCase {

    // MARK: - Fixtures (consumer-visible construction only)

    private static let endpoint = "https://tls-cn-beijing.volces.com"
    private static let region = "cn-beijing"
    private static let projectID = "consumer-it-project"
    private static let topicID = "consumer-it-topic"

    private func makeConfiguration() throws -> ProducerConfiguration {
        try ProducerConfiguration()
    }

    private func makeCredentials() -> Credentials {
        Credentials(accessKeyID: "consumer-it-ak", accessKeySecret: "consumer-it-sk")
    }

    private func makeDestination() -> Destination {
        Destination(endpoint: Self.endpoint,
                    region: Self.region,
                    projectID: Self.projectID,
                    topicID: Self.topicID)
    }

    private func makeEvent(_ tag: String = "v") -> LogEvent {
        LogEvent(contents: [
            "level": .string("info"),
            "message": .string("consumer-integration-\(tag)"),
        ])
    }

    // MARK: - Smoke

    /// Consumer lifecycle smoke test:
    /// `open` → `add(.normal)` → `add(.immediate)` → `close(timeout:)`.
    ///
    /// Asserts that at least one `SendResult` with `status == .success` is
    /// delivered to the `onSendResult` handler registered at `open`.
    ///
    /// Note: destination setup (`updateDestination`) is covered by
    /// `testConsumerUpdateCredentialsAndDestination`; it is omitted here
    /// because the bundled in-memory adapter is destination-agnostic.
    func testConsumerSmoke() async throws {
        let collector = SendResultCollector()

        let producer = try await Producer.open(
            configuration: try makeConfiguration(),
            credentials: makeCredentials()
        ) { result in
            collector.append(result)
        }

        // `.normal` enters the batching window; `.immediate` seals the batch
        // and wakes the sender. Both are synchronous, non-network calls.
        try producer.add(makeEvent("normal"), mode: .normal)
        try producer.add(makeEvent("immediate"), mode: .immediate)

        // The sealed batch's terminal SendResult is delivered asynchronously
        // on the SDK callback queue.
        try await waitUntil(timeout: 10) { !collector.results.isEmpty }

        XCTAssertTrue(
            collector.results.contains { $0.status == .success },
            "expected at least one successful SendResult, got \(collector.results)")

        try await producer.close(timeout: 5)
    }

    // MARK: - Defaults

    /// Asserts the documented consumer-visible defaults of
    /// `ProducerConfiguration` (SLS iOS wrapper / SLS C aligned values).
    func testConsumerDefaults() throws {
        let config = try ProducerConfiguration()

        // Batching (SLS iOS wrapper)
        XCTAssertEqual(config.batch.maxLogCount, 1024)
        XCTAssertEqual(config.batch.maxRawBytes, 1024 * 1024)
        XCTAssertEqual(config.batch.linger, 3, accuracy: 0.0001)

        // Buffer (SLS)
        XCTAssertEqual(config.buffer.maxBytes, 64 * 1024 * 1024)
        XCTAssertEqual(config.buffer.fullPolicy, .reject)

        // Sender / compression / persistence
        XCTAssertEqual(config.sendConcurrency, 1)
        XCTAssertEqual(config.compression, .lz4)
        XCTAssertEqual(config.persistence, .disabled)

        // Timeouts (SLS)
        XCTAssertEqual(config.connectTimeout, 10, accuracy: 0.0001)
        XCTAssertEqual(config.requestTimeout, 15, accuracy: 0.0001)

        // Expiry / unauthorized (SLS C default / iOS behavior)
        XCTAssertEqual(config.maxLogAge, 7 * 24 * 60 * 60, accuracy: 0.0001)
        XCTAssertEqual(config.expiredLogPolicy, .rewriteTimestamp)
        XCTAssertEqual(config.unauthorizedPolicy, .retain)

        // Metadata (SLS iOS wrapper)
        XCTAssertEqual(config.metadata.source, "iOS")
        XCTAssertNil(config.metadata.fileName)
        XCTAssertTrue(config.metadata.tags.isEmpty)

        // No producerID by default (persistence defaults to .disabled)
        XCTAssertNil(config.producerID)
    }

    // MARK: - Credentials / destination rotation

    /// `updateCredentials` / `updateDestination` must not throw while the
    /// producer is open, and must throw `ProducerError.closed` after close.
    func testConsumerUpdateCredentialsAndDestination() async throws {
        let producer = try await Producer.open(
            configuration: try makeConfiguration(),
            credentials: makeCredentials())

        // Whole-group atomic credential rotation while open.
        let rotated = Credentials(
            accessKeyID: "rotated-ak",
            accessKeySecret: "rotated-sk",
            securityToken: "rotated-sts-token")
        XCTAssertNoThrow(try producer.updateCredentials(rotated))

        // Destination replacement while open (current-target semantics).
        XCTAssertNoThrow(try producer.updateDestination(makeDestination()))

        try await producer.close(timeout: 5)

        // After close, both updates are rejected with .closed.
        XCTAssertThrowsError(try producer.updateCredentials(rotated)) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
        XCTAssertThrowsError(try producer.updateDestination(makeDestination())) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
    }

    // MARK: - Invalid log rejection

    /// A log containing a NaN double must be rejected at admission with
    /// `ProducerError.invalidLog`; the whole event is rejected (no partial
    /// admission).
    func testConsumerInvalidLogRejected() async throws {
        let producer = try await Producer.open(
            configuration: try makeConfiguration(),
            credentials: makeCredentials())

        let invalid = LogEvent(contents: [
            "good": .string("value"),
            "bad": .double(Double.nan),
        ])

        XCTAssertThrowsError(try producer.add(invalid)) { error in
            guard case ProducerError.invalidLog(let paths) = error else {
                XCTFail("expected .invalidLog, got \(error)")
                return
            }
            XCTAssertFalse(paths.isEmpty)
            XCTAssertTrue(
                paths.contains { $0.hasPrefix("bad:") },
                "expected a 'bad:' field path, got \(paths)")
        }

        try await producer.close(timeout: 5)
    }

    // MARK: - Closed producer

    /// `add` on a closed producer must throw `ProducerError.closed`.
    func testConsumerAddAfterCloseRejected() async throws {
        let producer = try await Producer.open(
            configuration: try makeConfiguration(),
            credentials: makeCredentials())

        try await producer.close(timeout: 5)

        XCTAssertThrowsError(try producer.add(makeEvent())) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
    }
}

// MARK: - Self-contained helpers

/// Thread-safe collector for `SendResult` values delivered on the SDK
/// callback queue.
private final class SendResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _results: [SendResult] = []

    var results: [SendResult] {
        lock.lock()
        defer { lock.unlock() }
        return _results
    }

    func append(_ result: SendResult) {
        lock.lock()
        _results.append(result)
        lock.unlock()
    }
}

/// Polls until `condition` is true or the deadline passes. Consumer tests
/// are self-contained: ProducerTestSupport helpers are intentionally not
/// linked (this target sees the public API only).
private func waitUntil(
    timeout: TimeInterval = 10,
    file: StaticString = #file,
    line: UInt = #line,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("condition not met within \(timeout)s", file: file, line: line)
}
