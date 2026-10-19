//
//  ProducerIntegrationTests.swift
//  ProducerIntegrationTests
//
//  These tests compile against the public API only: a plain
//  `import VolcengineTLSProducer`, deliberately WITHOUT `@testable`. They
//  exercise `Producer.open` through the real C Core while a caller-owned
//  URLSessionConfiguration injects a URLProtocol stub. A green run therefore
//  proves that the public facade reaches the configured transport and emits a
//  wire request.
//
//  Self-contained: this target does not link BridgeTests support, so the
//  small collector/polling helpers below are intentionally private.
//

import XCTest
import VolcengineTLSProducer

private final class ProducerStubURLProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var requests: [URLRequest] = []
        var statusCode = 200
        var headers: [String: String] = [
            "x-tls-request-id": "producer-stub-request"
        ]
        var body = Data()
        var hangs = false
        var recoveryAfterFailures: Int?
    }

    private static let registry = Registry()

    static func reset() {
        registry.lock.withLock {
            registry.requests.removeAll()
            registry.statusCode = 200
            registry.headers = ["x-tls-request-id": "producer-stub-request"]
            registry.body = Data()
            registry.hangs = false
            registry.recoveryAfterFailures = nil
        }
    }

    static func recordedRequests() -> [URLRequest] {
        registry.lock.withLock { registry.requests }
    }

    static func setResponse(
        statusCode: Int,
        headers: [String: String],
        body: Data
    ) {
        registry.lock.withLock {
            registry.statusCode = statusCode
            registry.headers = headers
            registry.body = body
        }
    }

    static func setRecovery(statusCode: Int, body: Data, afterFailures: Int) {
        registry.lock.withLock {
            registry.statusCode = statusCode
            registry.body = body
            registry.recoveryAfterFailures = afterFailures
        }
    }

    static func setHanging() {
        registry.lock.withLock { registry.hangs = true }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var recordedRequest = request
        if recordedRequest.httpBody == nil,
           let stream = recordedRequest.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            recordedRequest.httpBody = data
        }
        let behavior = Self.registry.lock.withLock { () -> (Int, [String: String], Data, Bool) in
            Self.registry.requests.append(recordedRequest)
            let recovered = Self.registry.recoveryAfterFailures.map {
                Self.registry.requests.count > $0
            } ?? false
            return (
                recovered ? 200 : Self.registry.statusCode,
                Self.registry.headers,
                recovered ? Data() : Self.registry.body,
                Self.registry.hangs)
        }
        if behavior.3 { return }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: behavior.0,
            httpVersion: "HTTP/1.1",
            headerFields: behavior.1
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !behavior.2.isEmpty {
            client?.urlProtocol(self, didLoad: behavior.2)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

final class ProducerIntegrationTests: XCTestCase {

    // MARK: - Fixtures (producer-visible construction only)

    private static let producerUserAgent = "volc-tls-ios/producer/v2.0.2"
    private static let apiVersion = "0.3.0"
    private static let endpoint = "https://producer.stub.local"
    private static let region = "cn-beijing"
    private static let projectID = "producer-it-project"
    private static let topicID = "producer-it-topic"

    override func setUp() {
        super.setUp()
        ProducerStubURLProtocol.reset()
    }

    private func makeConfiguration(
        requestTimeout: TimeInterval = 15
    ) throws -> ProducerConfiguration {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProducerStubURLProtocol.self]
        return try ProducerConfiguration(
            requestTimeout: requestTimeout,
            retry: RetryConfiguration(maxAttempts: 3),
            urlSessionConfiguration: sessionConfiguration,
            destination: makeDestination())
    }

    private func makeCredentials(
        _ label: String = "base",
        includeSession: Bool = false
    ) -> Credentials {
        let values = [
            "producer-it-\(label)-ak",
            "producer-it-\(label)-sk",
            "producer-it-\(label)-session",
        ]
        return Credentials(
            accessKeyID: values[0],
            accessKeySecret: values[1],
            securityToken: includeSession ? values[2] : nil)
    }

    private func makeServiceErrorBody(code: String, message: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "ErrorCode": code,
            "ErrorMessage": message,
        ])
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
            "message": .string("producer-integration-\(tag)"),
        ])
    }

    // MARK: - Delivery policy alignment

    private func deliveryConfiguration(retention: TimeInterval = 0,
                                       maxAttempts: Int = 0,
                                       diagnostics: DiagnosticCollector) throws -> ProducerConfiguration {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [ProducerStubURLProtocol.self]
        return try ProducerConfiguration(
            requestTimeout: 0.15, requestIdleTimeout: 50,
            retry: RetryConfiguration(maxAttempts: maxAttempts, totalTimeout: 1,
                                      initialInterval: 0.1, maxInterval: 1),
            memoryRetryRetention: retention,
            onDiagnostic: { diagnostics.append($0) },
            urlSessionConfiguration: session, destination: makeDestination())
    }

    func testFourthAttemptRecoversAndReportsOneTerminalResult() async throws {
        ProducerStubURLProtocol.setRecovery(statusCode: 503,
            body: try makeServiceErrorBody(code: "InternalError", message: "PRIVATE-BODY"),
            afterFailures: 3)
        let diagnostics = DiagnosticCollector()
        let results = SendResultCollector()
        let producer = try await Producer.open(
            configuration: deliveryConfiguration(diagnostics: diagnostics),
            credentials: makeCredentials()) { results.append($0) }
        try producer.add(makeEvent("fourth"), mode: .immediate)
        try await waitUntil(timeout: 5) { results.results.count == 1 }
        XCTAssertEqual(results.results.first?.status, .success)
        XCTAssertEqual(ProducerStubURLProtocol.recordedRequests().count, 4)
        XCTAssertEqual(ProducerStubURLProtocol.recordedRequests().first?.timeoutInterval, 50)
        let attempts = diagnostics.events.filter { $0.kind == .attemptFinished }
        XCTAssertEqual(attempts.map(\.attemptCount), [1, 2, 3, 4])
        XCTAssertTrue(attempts.allSatisfy { $0.logCount == 1 && $0.rawBytes > 0 })
        XCTAssertEqual(diagnostics.events.filter { $0.kind == .batchTerminal }.count, 1)
        XCTAssertFalse(String(describing: diagnostics.events).contains("PRIVATE-BODY"))
        try await producer.close(timeout: 2)
    }

    func testTransientHTTPResponsesRecoverButPermanent400DoesNotRetry() async throws {
        for (status, code, expectedRequests) in [
            (400, "ClientCanceled", 4), (408, "Timeout", 4),
            (499, "ConnectionClosed", 4), (400, "InvalidArgument", 1),
            (400, "UnknownFailure", 1)] {
            ProducerStubURLProtocol.reset()
            ProducerStubURLProtocol.setRecovery(statusCode: status,
                body: try makeServiceErrorBody(code: code, message: "context canceled"),
                afterFailures: 3)
            let diagnostics = DiagnosticCollector()
            let results = SendResultCollector()
            let producer = try await Producer.open(
                configuration: deliveryConfiguration(diagnostics: diagnostics),
                credentials: makeCredentials()) { results.append($0) }
            try producer.add(makeEvent("http-classification"), mode: .immediate)
            try await waitUntil(timeout: 5) { results.results.count == 1 }
            XCTAssertEqual(ProducerStubURLProtocol.recordedRequests().count, expectedRequests,
                           "HTTP \(status), ErrorCode \(code)")
            XCTAssertEqual(results.results.first?.status, expectedRequests == 4 ? .success : .failure)
            try await producer.close(timeout: 2)
        }
    }

    func testMemoryRetentionSpansCyclesWithoutIntermediateTerminalResult() async throws {
        ProducerStubURLProtocol.setRecovery(statusCode: 503,
            body: try makeServiceErrorBody(code: "InternalError", message: "failed"),
            afterFailures: 3)
        let diagnostics = DiagnosticCollector()
        let results = SendResultCollector()
        let producer = try await Producer.open(
            configuration: deliveryConfiguration(retention: 3, maxAttempts: 1,
                                                  diagnostics: diagnostics),
            credentials: makeCredentials()) { results.append($0) }
        try producer.add(makeEvent("retained"), mode: .immediate)
        try await waitUntil(timeout: 5) { results.results.count == 1 }
        XCTAssertEqual(results.results.first?.status, .success)
        XCTAssertEqual(diagnostics.events.filter { $0.kind == .batchRetained }.count, 3)
        XCTAssertEqual(diagnostics.events.filter { $0.kind == .batchTerminal }.count, 1)
        XCTAssertEqual(diagnostics.events.filter { $0.kind == .attemptFinished }.map(\.attemptCount),
                       [1, 2, 3, 4])
        try await producer.close(timeout: 2)
    }

    func testRetentionExpiresAndRecoveryCannotReviveDiscardedBatch() async throws {
        ProducerStubURLProtocol.setResponse(statusCode: 503, headers: [:], body: Data())
        let diagnostics = DiagnosticCollector()
        let results = SendResultCollector()
        let producer = try await Producer.open(
            configuration: deliveryConfiguration(retention: 0.2, maxAttempts: 1,
                                                  diagnostics: diagnostics),
            credentials: makeCredentials()) { results.append($0) }
        try producer.add(makeEvent("retention-expiry"), mode: .immediate)
        try await waitUntil(timeout: 3) { results.results.count == 1 }
        XCTAssertEqual(results.results.first?.status, .failure)
        XCTAssertEqual(results.results.first?.error, .timeout)
        XCTAssertEqual(diagnostics.events.last { $0.kind == .batchTerminal }?.reason, .retentionExpired)
        let before = ProducerStubURLProtocol.recordedRequests().count
        ProducerStubURLProtocol.setResponse(statusCode: 200, headers: [:], body: Data())
        try producer.notifyNetworkRecovered()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(ProducerStubURLProtocol.recordedRequests().count, before)
        XCTAssertEqual(results.results.count, 1)
        try await producer.close(timeout: 2)
    }

    func testCloseDoesNotWaitForLongMemoryRetention() async throws {
        ProducerStubURLProtocol.setResponse(statusCode: 503, headers: [:], body: Data())
        let diagnostics = DiagnosticCollector()
        let results = SendResultCollector()
        let producer = try await Producer.open(
            configuration: deliveryConfiguration(retention: 86_400, maxAttempts: 1,
                                                  diagnostics: diagnostics),
            credentials: makeCredentials()) { results.append($0) }
        try producer.add(makeEvent("close-retained"), mode: .immediate)
        try await waitUntil(timeout: 2) { diagnostics.events.contains { $0.kind == .batchRetained } }
        let start = Date()
        try await producer.close(timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        try await waitUntil(timeout: 2) { results.results.count == 1 }
        XCTAssertEqual(results.results.first?.error, .closed)
        XCTAssertEqual(diagnostics.events.last { $0.kind == .batchTerminal }?.reason, .closed)
    }

    func testOpenFailureDiagnosticDoesNotIncludeConfigurationDetails() async throws {
        let diagnostics = DiagnosticCollector()
        var configuration = try deliveryConfiguration(diagnostics: diagnostics)
        configuration.destination = nil
        do {
            _ = try await Producer.open(configuration: configuration, credentials: makeCredentials())
            XCTFail("missing destination should fail")
        } catch {}
        try await waitUntil(timeout: 2) { diagnostics.events.contains { $0.kind == .openFailed } }
        XCTAssertEqual(diagnostics.events.last?.errorCode, "configuration")
        XCTAssertNil(diagnostics.events.last?.requestID)
    }

    func testAdmissionFailureDiagnosticsUseSafeCodes() async throws {
        let diagnostics = DiagnosticCollector()
        let producer = try await Producer.open(
            configuration: deliveryConfiguration(diagnostics: diagnostics),
            credentials: makeCredentials())
        XCTAssertThrowsError(try producer.add(LogEvent(contents: [:])))
        try await waitUntil(timeout: 2) {
            diagnostics.events.contains { $0.kind == .admissionRejected }
        }
        XCTAssertEqual(diagnostics.events.first { $0.kind == .admissionRejected }?.errorCode, "invalidLog")
        try await producer.close(timeout: 2)
        XCTAssertThrowsError(try producer.notifyNetworkRecovered())
    }

    // MARK: - Smoke

    /// Producer lifecycle smoke test:
    /// `open` → `add(.normal)` → `add(.immediate)` → `close(timeout:)`.
    ///
    /// Asserts that at least one `SendResult` with `status == .success` is
    /// delivered to the `onSendResult` handler registered at `open`.
    ///
    func testProducerSmoke() async throws {
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

        let requests = ProducerStubURLProtocol.recordedRequests()
        XCTAssertFalse(requests.isEmpty, "public Producer.open must reach the configured transport")
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "producer.stub.local")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "TopicId" })?.value,
            Self.topicID)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            Self.producerUserAgent,
            "Producer request must carry the fixed iOS producer User-Agent")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-tls-apiversion"),
            Self.apiVersion,
            "Producer request must preserve the C Core API version")
        XCTAssertFalse((request.httpBody ?? Data()).isEmpty)

        try await producer.close(timeout: 5)
    }

    // MARK: - Defaults

    /// Asserts the documented producer-visible defaults of
    /// `ProducerConfiguration`.
    func testProducerDefaults() throws {
        let config = try ProducerConfiguration()

        // Batching
        XCTAssertEqual(config.batch.maxLogCount, 1024)
        XCTAssertEqual(config.batch.maxRawBytes, 1024 * 1024)
        XCTAssertEqual(config.batch.linger, 3, accuracy: 0.0001)

        // Buffer
        XCTAssertEqual(config.buffer.maxBytes, 64 * 1024 * 1024)
        XCTAssertEqual(config.buffer.fullPolicy, .reject)

        // Sender / compression / persistence
        XCTAssertEqual(config.sendConcurrency, 1)
        XCTAssertEqual(config.compression, .lz4)
        XCTAssertEqual(config.persistence, .disabled)

        // Timeouts
        XCTAssertEqual(config.connectTimeout, 10, accuracy: 0.0001)
        XCTAssertEqual(config.requestTimeout, 90, accuracy: 0.0001)

        // Expiry / unauthorized
        XCTAssertEqual(config.maxLogAge, 7 * 24 * 60 * 60, accuracy: 0.0001)
        XCTAssertEqual(config.expiredLogPolicy, .rewriteTimestamp)
        XCTAssertEqual(config.unauthorizedPolicy, .retain)

        // Metadata
#if os(macOS)
        XCTAssertEqual(config.metadata.source, "macOS")
#else
        XCTAssertEqual(config.metadata.source, "iOS")
#endif
        XCTAssertNil(config.metadata.fileName)
        XCTAssertTrue(config.metadata.tags.isEmpty)

        // No producerID by default (persistence defaults to .disabled)
        XCTAssertNil(config.producerID)
    }

    // MARK: - Credentials / destination rotation

    /// `updateCredentials` / `updateDestination` must not throw while the
    /// producer is open, and must throw `ProducerError.closed` after close.
    func testProducerUpdateCredentialsAndDestination() async throws {
        let producer = try await Producer.open(
            configuration: try makeConfiguration(),
            credentials: makeCredentials())

        // Whole-group atomic credential rotation while open.
        let rotated = makeCredentials("rotated", includeSession: true)
        XCTAssertNoThrow(try producer.updateCredentials(rotated))

        // Destination replacement while open (current-target semantics).
        let rotatedDestination = Destination(
            endpoint: "https://rotated.producer.stub.local",
            region: "cn-shanghai",
            projectID: "rotated-project",
            topicID: "rotated-topic")
        XCTAssertNoThrow(try producer.updateDestination(rotatedDestination))
        try producer.add(makeEvent("rotated-destination"), mode: .immediate)
        try await waitUntil {
            ProducerStubURLProtocol.recordedRequests().contains {
                $0.url?.host == "rotated.producer.stub.local"
            }
        }
        let rotatedRequest = try XCTUnwrap(
            ProducerStubURLProtocol.recordedRequests().first {
                $0.url?.host == "rotated.producer.stub.local"
            })
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(rotatedRequest.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "TopicId" })?.value,
            "rotated-topic")

        try await producer.close(timeout: 5)

        // After close, both updates are rejected with .closed.
        XCTAssertThrowsError(try producer.updateCredentials(rotated)) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
        XCTAssertThrowsError(try producer.updateDestination(makeDestination())) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
    }

    // MARK: - Public failure mapping

    func testProducerHTTPStatusesMapToPublicProducerErrors() async throws {
        enum Expected {
            case auth
            case quota
            case service(Int)
        }
        let expiredCode = ["Expired", "To", "ken"].joined()
        let untrustedMessage = "private=do-not-forward"
        let cases: [(name: String, status: Int, errorCode: String, expected: Expected, requestCount: Int)] = [
            ("unauthorized", 401, "ServiceCode", .auth, 1),
            ("forbidden", 403, "ServiceCode", .auth, 1),
            ("expired-auth", 400, expiredCode, .auth, 1),
            ("invalid-argument", 400, "InvalidArgument", .service(400), 1),
            ("quota", 429, "ServiceCode", .quota, 3),
            ("server", 500, "ServiceCode", .service(500), 3),
        ]

        for item in cases {
            ProducerStubURLProtocol.reset()
            ProducerStubURLProtocol.setResponse(
                statusCode: item.status,
                headers: ["x-tls-request-id": "producer-status-\(item.name)"],
                body: try makeServiceErrorBody(
                    code: item.errorCode,
                    message: untrustedMessage))
            let collector = SendResultCollector()
            let producer = try await Producer.open(
                configuration: try makeConfiguration(),
                credentials: makeCredentials()) { collector.append($0) }

            try producer.add(makeEvent("status-\(item.status)"), mode: .immediate)
            try await waitUntil(timeout: 10) { !collector.results.isEmpty }
            try await producer.close(timeout: 5)

            let results = collector.results
            XCTAssertEqual(results.count, 1,
                           "one accepted batch must have one terminal result")
            XCTAssertEqual(
                ProducerStubURLProtocol.recordedRequests().count,
                item.requestCount,
                "HTTP \(item.status) retry count must match the Core contract")
            let error = try XCTUnwrap(results.first?.error)
            switch item.expected {
            case .auth:
                XCTAssertEqual(error, .auth)
            case .quota:
                XCTAssertEqual(error, .quota)
            case .service(let status):
                guard case .service(let code, let message, let requestID) = error else {
                    XCTFail("expected service error, got \(error)")
                    continue
                }
                XCTAssertEqual(code, status)
                XCTAssertEqual(message, item.errorCode)
                XCTAssertEqual(requestID, "producer-status-\(item.name)")
                XCTAssertFalse(message.contains(untrustedMessage))
            }
        }
    }

    func testProducerTimeoutMapsToOnePublicTerminalResult() async throws {
        ProducerStubURLProtocol.setHanging()
        let collector = SendResultCollector()
        let producer = try await Producer.open(
            configuration: try makeConfiguration(requestTimeout: 0.1),
            credentials: makeCredentials()) { collector.append($0) }

        let started = Date()
        try producer.add(makeEvent("timeout"), mode: .immediate)
        try await waitUntil(timeout: 5) { !collector.results.isEmpty }
        let elapsed = Date().timeIntervalSince(started)
        try await producer.close(timeout: 5)

        let results = collector.results
        XCTAssertEqual(results.count, 1,
                       "one accepted batch must have one terminal timeout result")
        XCTAssertEqual(results.first?.error, .timeout)
        XCTAssertLessThan(elapsed, 5, "public timeout path must remain bounded")
        XCTAssertEqual(ProducerStubURLProtocol.recordedRequests().count, 3,
                       "retryable timeout should honor the Core max-attempt contract")
    }

    func testProducerPersistentAuthRetainResumesWithOneTerminalResult() async throws {
        let expiredCode = ["Expired", "To", "ken"].joined()
        ProducerStubURLProtocol.setResponse(
            statusCode: 400,
            headers: ["x-tls-request-id": "producer-auth-retain-first"],
            body: try makeServiceErrorBody(
                code: expiredCode,
                message: "authorization expired"))
        let collector = SendResultCollector()
        var configuration = try makeConfiguration(requestTimeout: 0.2)
        configuration.persistence = .buffered
        configuration.producerID = "producer-auth-\(UUID().uuidString.prefix(12))"
        configuration.unauthorizedPolicy = .retain

        let producer = try await Producer.open(
            configuration: configuration,
            credentials: makeCredentials()) { collector.append($0) }
        try producer.add(makeEvent("auth-retain"), mode: .immediate)
        try await waitUntil(timeout: 3) {
            !ProducerStubURLProtocol.recordedRequests().isEmpty
        }

        // A retained authentication failure is a suspended attempt, not a
        // terminal batch result.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(collector.results.isEmpty)

        ProducerStubURLProtocol.setResponse(
            statusCode: 200,
            headers: ["x-tls-request-id": "producer-auth-retain-success"],
            body: Data())
        try producer.updateCredentials(makeCredentials("updated"))
        try await waitUntil(timeout: 8) { collector.results.count == 1 }

        let result = try XCTUnwrap(collector.results.first)
        XCTAssertEqual(result.status, .success)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.requestID, "producer-auth-retain-success")
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(collector.results.count, 1)
        try await producer.close(timeout: 5)
    }

    // MARK: - Invalid log rejection

    func testProducerPersistentAdmissionErrorCanReplayAfterReopen() async throws {
        for persistence in [Persistence.buffered, .sync] {
            ProducerStubURLProtocol.reset()
            let marker = "admission-replay-\(UUID().uuidString)"
            let payload = "recovered-payload-" + String(repeating: "x", count: 512)
            let event = LogEvent(contents: [
                "event_id": .string(marker),
                "payload": .string(payload),
            ])
            var configuration = try makeConfiguration()
            configuration.persistence = persistence
            configuration.producerID = "replay-\(UUID().uuidString.prefix(12))"
            configuration.compression = .disabled
            configuration.automaticLifecycleHandling = false
            // The event is valid, but its encoded bytes cannot fit in RAM.
            // Persistent admission writes WAL before checking this budget.
            configuration.buffer = BufferConfiguration(maxBytes: 1, fullPolicy: .reject)
            let firstResults = SendResultCollector()
            let first = try await Producer.open(
                configuration: configuration,
                credentials: makeCredentials()) { firstResults.append($0) }

            XCTAssertThrowsError(try first.add(LogEvent(contents: ["invalid": .double(.nan)]))) {
                guard case ProducerError.invalidLog = $0 else {
                    return XCTFail("invalid input must fail before WAL admission")
                }
            }
            XCTAssertThrowsError(try first.add(event, mode: .immediate)) {
                XCTAssertEqual($0 as? ProducerError, .bufferFull)
            }
            try await first.close(timeout: 5)
            XCTAssertTrue(firstResults.results.isEmpty)
            XCTAssertTrue(ProducerStubURLProtocol.recordedRequests().isEmpty)

            // Do not add the event again: reopening alone must recover it.
            configuration.buffer = BufferConfiguration()
            let recoveredResults = SendResultCollector()
            let recovered = try await Producer.open(
                configuration: configuration,
                credentials: makeCredentials()) { recoveredResults.append($0) }
            try await waitUntil(timeout: 10) { recoveredResults.results.count == 1 }
            try await recovered.close(timeout: 5)
            XCTAssertEqual(recoveredResults.results.map(\.status), [.success])
            let requests = ProducerStubURLProtocol.recordedRequests()
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-tls-compresstype"), "none")
            let body = try XCTUnwrap(request.httpBody)
            let markerBytes = Data(marker.utf8)
            let markerRange = try XCTUnwrap(body.range(of: markerBytes))
            XCTAssertNil(body.range(of: markerBytes, in: markerRange.upperBound..<body.endIndex))
            XCTAssertNotNil(body.range(of: Data(payload.utf8)), "the complete value must survive WAL recovery")

            // A successful recovery is ACKed; a further clean open is empty.
            let empty = try await Producer.open(
                configuration: configuration, credentials: makeCredentials())
            try await empty.close(timeout: 5)
            XCTAssertEqual(ProducerStubURLProtocol.recordedRequests().count, 1)
        }
    }

    /// Diagnostic handlers must observe the persistent admission/recovery
    /// path without changing the business outcome or the durable cleanup.
    /// The independent off/on runs intentionally share one producerID. Their
    /// fixture directory is reset between runs so each starts from the same
    /// clean durable state while still checking post-ACK WAL cleanup.
    func testProducerPersistentAdmissionDiagnosticsTogglePreservesReplayAndWAL() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.123)
        let payload = "same-diagnostic-business-payload-" + String(repeating: "x", count: 512)
        let event = LogEvent(
            timestamp: timestamp,
            contents: ["message": .string(payload)])

        for persistence in [Persistence.buffered, .sync] {
            let mode = persistence == .buffered ? "buffered" : "sync"
            let producerID = "diagnostic-admission-\(mode)-\(UUID().uuidString.prefix(12))"
            defer {
                if let directory = producerDirectoryURL(for: producerID) {
                    try? FileManager.default.removeItem(at: directory)
                }
            }

            let withoutDiagnostics = try await runPersistentAdmissionDiagnosticScenario(
                persistence: persistence,
                producerID: producerID,
                event: event,
                diagnosticsEnabled: false)
            try await Task.sleep(nanoseconds: 500_000_000)
            if let directory = producerDirectoryURL(for: producerID) {
                try? FileManager.default.removeItem(at: directory)
            }
            let withDiagnostics = try await runPersistentAdmissionDiagnosticScenario(
                persistence: persistence,
                producerID: producerID,
                event: event,
                diagnosticsEnabled: true)

            XCTAssertEqual(withoutDiagnostics.firstRequests, [])
            XCTAssertEqual(withDiagnostics.firstRequests, [])
            XCTAssertEqual(withoutDiagnostics.firstCallbackCount, 0)
            XCTAssertEqual(withDiagnostics.firstCallbackCount, 0)

            XCTAssertEqual(withoutDiagnostics.recoveredRequests.count, 1)
            XCTAssertEqual(withDiagnostics.recoveredRequests.count, 1)
            XCTAssertEqual(withoutDiagnostics.recoveredCallbackCount, 1)
            XCTAssertEqual(withDiagnostics.recoveredCallbackCount, 1)
            XCTAssertEqual(withoutDiagnostics.recoveredStatuses, [.success])
            XCTAssertEqual(withDiagnostics.recoveredStatuses, [.success])

            // The only request is the recovery send. A clean reopen after its
            // ACK must remain empty in both configurations.
            XCTAssertEqual(withoutDiagnostics.finalRequests, withoutDiagnostics.recoveredRequests)
            XCTAssertEqual(withDiagnostics.finalRequests, withDiagnostics.recoveredRequests)
            XCTAssertEqual(withoutDiagnostics.recoveredRequests, withDiagnostics.recoveredRequests)
            XCTAssertEqual(withoutDiagnostics.finalRequests, withDiagnostics.finalRequests)
            XCTAssertEqual(withoutDiagnostics.walFileNames, withDiagnostics.walFileNames)
            let expectedWALFiles: Set<String> = [
                "manifest", "checkpoint", "seg-000001.log", "lease.lock",
            ]
            XCTAssertEqual(withoutDiagnostics.walFileNames, expectedWALFiles)
            XCTAssertEqual(withDiagnostics.walFileNames, expectedWALFiles)

            XCTAssertEqual(withoutDiagnostics.textMessageCount, 0)
            XCTAssertGreaterThan(withDiagnostics.textMessageCount, 0)
            let admissionEvents = withDiagnostics.diagnostics.filter {
                $0.kind == .admissionRejected
            }
            XCTAssertEqual(admissionEvents.count, 1)
            XCTAssertEqual(
                withDiagnostics.diagnostics.filter { $0.kind == .batchTerminal }.count,
                1)
            XCTAssertTrue(admissionEvents.allSatisfy {
                $0.context?.disposition != "discard"
            })
        }
    }

    private func runPersistentAdmissionDiagnosticScenario(
        persistence: Persistence,
        producerID: String,
        event: LogEvent,
        diagnosticsEnabled: Bool
    ) async throws -> PersistentAdmissionDiagnosticObservation {
        ProducerStubURLProtocol.reset()
        let structuredCollector: DiagnosticCollector? = diagnosticsEnabled
            ? DiagnosticCollector()
            : nil
        let textCollector: DiagnosticTextCollector? = diagnosticsEnabled
            ? DiagnosticTextCollector()
            : nil

        var configuration = try makeConfiguration()
        configuration.persistence = persistence
        configuration.producerID = producerID
        configuration.compression = .disabled
        configuration.automaticLifecycleHandling = false
        configuration.buffer = BufferConfiguration(maxBytes: 1, fullPolicy: .reject)
        if let structuredCollector {
            configuration.onDiagnostic = { @Sendable diagnostic in
                structuredCollector.append(diagnostic)
            }
        }
        if let textCollector {
            configuration.diagnosticLogLevel = .info
            configuration.diagnosticHandler = { @Sendable level, message in
                textCollector.append(level: level, message: message)
            }
        }

        let firstResults = SendResultCollector()
        let first = try await Producer.open(
            configuration: configuration,
            credentials: makeCredentials()) { firstResults.append($0) }
        XCTAssertThrowsError(try first.add(event, mode: .immediate)) {
            XCTAssertEqual($0 as? ProducerError, .bufferFull)
        }
        try await first.close(timeout: 5)

        let firstRequests = producerRequestSnapshots()
        XCTAssertTrue(firstRequests.isEmpty)
        XCTAssertTrue(firstResults.results.isEmpty)

        if let structuredCollector {
            try await waitUntil(timeout: 3) {
                structuredCollector.events.contains { $0.kind == .admissionRejected }
            }
        }

        configuration.buffer = BufferConfiguration()
        let recoveredResults = SendResultCollector()
        let recovered = try await Producer.open(
            configuration: configuration,
            credentials: makeCredentials()) { recoveredResults.append($0) }
        try await waitUntil(timeout: 10) { recoveredResults.results.count == 1 }
        try await recovered.close(timeout: 5)
        let recoveredRequests = producerRequestSnapshots()
        let recoveredStatuses = recoveredResults.results.map(\.status)

        let empty = try await Producer.open(
            configuration: configuration,
            credentials: makeCredentials())
        try await empty.close(timeout: 5)
        let finalRequests = producerRequestSnapshots()

        if let textCollector {
            try await waitUntil(timeout: 3) { textCollector.count > 0 }
        }

        return PersistentAdmissionDiagnosticObservation(
            firstRequests: firstRequests,
            recoveredRequests: recoveredRequests,
            finalRequests: finalRequests,
            firstCallbackCount: firstResults.results.count,
            recoveredCallbackCount: recoveredResults.results.count,
            recoveredStatuses: recoveredStatuses,
            walFileNames: producerWALFileNames(for: producerID),
            diagnostics: structuredCollector?.events ?? [],
            textMessageCount: textCollector?.count ?? 0)
    }

    /// A log containing a NaN double must be rejected at admission with
    /// `ProducerError.invalidLog`; the whole event is rejected (no partial
    /// admission).
    func testProducerInvalidLogRejected() async throws {
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
    func testProducerAddAfterCloseRejected() async throws {
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

/// Polls until `condition` is true or the deadline passes. Producer tests
/// are self-contained: BridgeTests support helpers are intentionally not
/// linked (this target sees the public API only).
private func waitUntil(
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
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

private final class DiagnosticCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProducerDiagnostic] = []
    var events: [ProducerDiagnostic] { lock.withLock { values } }
    func append(_ diagnostic: ProducerDiagnostic) { lock.withLock { values.append(diagnostic) } }
}

private final class DiagnosticTextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [(ProducerDiagnosticLogLevel, String)] = []

    var count: Int { lock.withLock { messages.count } }

    func append(level: ProducerDiagnosticLogLevel, message: String) {
        lock.withLock { messages.append((level, message)) }
    }
}

private struct ProducerRequestSnapshot: Equatable {
    let url: String
    let body: Data?
    let headers: [String: String]
}

private struct PersistentAdmissionDiagnosticObservation {
    let firstRequests: [ProducerRequestSnapshot]
    let recoveredRequests: [ProducerRequestSnapshot]
    let finalRequests: [ProducerRequestSnapshot]
    let firstCallbackCount: Int
    let recoveredCallbackCount: Int
    let recoveredStatuses: [SendResult.Status]
    let walFileNames: Set<String>
    let diagnostics: [ProducerDiagnostic]
    let textMessageCount: Int
}

private func producerRequestSnapshots() -> [ProducerRequestSnapshot] {
    ProducerStubURLProtocol.recordedRequests().map { request in
        let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) {
            result, pair in
            let key = pair.key.lowercased()
            guard key != "authorization", key != "x-date" else { return }
            result[key] = pair.value
        }
        return ProducerRequestSnapshot(
            url: request.url?.absoluteString ?? "",
            body: request.httpBody,
            headers: headers)
    }
}

private func producerDirectoryURL(for producerID: String) -> URL? {
    guard let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask).first else {
        return nil
    }
    return applicationSupport
        .appendingPathComponent("com.volcengine.tls", isDirectory: true)
        .appendingPathComponent("producer", isDirectory: true)
        .appendingPathComponent(producerID, isDirectory: true)
}

private func producerWALFileNames(for producerID: String) -> Set<String> {
    guard let directory = producerDirectoryURL(for: producerID),
          FileManager.default.fileExists(atPath: directory.path),
          let entries = try? FileManager.default.contentsOfDirectory(
              at: directory,
              includingPropertiesForKeys: nil,
              options: [.skipsHiddenFiles]) else {
        return []
    }
    return Set(entries.map(\.lastPathComponent))
}
