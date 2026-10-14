// RealCoreAdapterIntegrationTests.swift
// ProducerIntegrationTests
//
// Integration tests for the RealCoreAdapter (C Core v0.3.1).
// Uses a local HTTP stub to verify end-to-end send behavior.
//

import XCTest
@testable import VolcengineTLSProducer
import TLSProducerBridge

/// Minimal HTTP stub that intercepts requests via URLProtocol.
final class RealCoreStubURLProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        struct ScriptedOutcome: @unchecked Sendable {
            let response: (HTTPURLResponse, Data)?
            let error: NSError?
            let delay: TimeInterval
            let hangs: Bool
        }

        let lock = NSLock()
        var stubbedResponses: [String: (HTTPURLResponse, Data)] = [:]
        var responseDelays: [String: TimeInterval] = [:]
        var hangingPaths: Set<String> = []
        var scriptedOutcomes: [String: [ScriptedOutcome]] = [:]
        var requestLog: [(url: String, body: Data?, headers: [String: String])] = []
        var requestExpectation: XCTestExpectation?
    }

    private static let registry = Registry()

    static func setResponse(statusCode: Int,
                            body: Data = Data(),
                            requestID: String? = "stub-req-001",
                            requestIDHeaderName: String = "x-tls-request-id",
                            delay: TimeInterval = 0,
                            forPath path: String) {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        let response = HTTPURLResponse(
            url: URL(string: "https://stub.local\(path)")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: requestID.map { [requestIDHeaderName: $0] })!
        registry.stubbedResponses[path] = (response, body)
        registry.responseDelays[path] = delay
        registry.hangingPaths.remove(path)
        registry.scriptedOutcomes.removeValue(forKey: path)
    }

    /// Installs a finite response script for one path. Each request consumes
    /// one item; after the script is exhausted the normal single response
    /// registry is used. The script is test-only and never changes request
    /// construction or Core retry policy.
    static func setResponseSequence(
        statusCodes: [Int],
        body: Data = Data(),
        requestIDPrefix: String = "script-req",
        delay: TimeInterval = 0,
        forPath path: String
    ) {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        registry.scriptedOutcomes[path] = statusCodes.enumerated().map { index, status in
            let response = HTTPURLResponse(
                url: URL(string: "https://stub.local\(path)")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["x-tls-request-id": "\(requestIDPrefix)-\(index + 1)"])!
            return Registry.ScriptedOutcome(
                response: (response, body), error: nil, delay: delay, hangs: false)
        }
        registry.hangingPaths.remove(path)
    }

    /// Installs a finite NSError script for one path. This is used only for
    /// deterministic transport-error comparisons; request ordering remains
    /// the URLProtocol request log order.
    static func setNetworkErrorSequence(
        codes: [Int],
        domain: String = NSURLErrorDomain,
        forPath path: String
    ) {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        let fallbackResponse = HTTPURLResponse(
            url: URL(string: "https://stub.local\(path)")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["x-tls-request-id": "network-recovery"])!
        registry.stubbedResponses[path] = (fallbackResponse, Data())
        registry.responseDelays[path] = 0
        registry.scriptedOutcomes[path] = codes.map { code in
            Registry.ScriptedOutcome(
                response: nil,
                error: NSError(domain: domain, code: code),
                delay: 0,
                hangs: false)
        }
        registry.hangingPaths.remove(path)
    }

    static func setHanging(forPath path: String) {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        registry.hangingPaths.insert(path)
        registry.stubbedResponses.removeValue(forKey: path)
        registry.responseDelays.removeValue(forKey: path)
        registry.scriptedOutcomes.removeValue(forKey: path)
    }

    static func recordedRequests() -> [(url: String, body: Data?, headers: [String: String])] {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        return registry.requestLog
    }

    static func expectNextRequest(_ expectation: XCTestExpectation) {
        registry.lock.lock()
        registry.requestExpectation = expectation
        registry.lock.unlock()
    }

    static func reset() {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        registry.stubbedResponses.removeAll()
        registry.responseDelays.removeAll()
        registry.hangingPaths.removeAll()
        registry.scriptedOutcomes.removeAll()
        registry.requestLog.removeAll()
        registry.requestExpectation = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    private static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                return nil
            }
            if count == 0 {
                return result
            }
            result.append(contentsOf: buffer[0..<count])
        }
    }

    override func startLoading() {
        let path = request.url?.path ?? "/"
        Self.registry.lock.lock()
        let scripted: Registry.ScriptedOutcome?
        if var outcomes = Self.registry.scriptedOutcomes[path], !outcomes.isEmpty {
            scripted = outcomes.removeFirst()
            Self.registry.scriptedOutcomes[path] = outcomes
        } else {
            scripted = nil
        }
        let isHanging = Self.registry.hangingPaths.contains(path)
        let stub = Self.registry.stubbedResponses[path]
        let delay = Self.registry.responseDelays[path] ?? 0
        Self.registry.requestLog.append((
            url: request.url?.absoluteString ?? "",
            body: Self.bodyData(for: request),
            headers: request.allHTTPHeaderFields ?? [:]))
        let requestExpectation = Self.registry.requestExpectation
        Self.registry.requestExpectation = nil
        Self.registry.lock.unlock()
        requestExpectation?.fulfill()

        if isHanging || scripted?.hangs == true {
            // Deliberately do not call any URLProtocol client callback. The
            // bridge's hard request deadline must cancel this task and turn
            // it into a bounded transport failure.
            return
        }

        let effectiveDelay = scripted?.delay ?? delay
        if effectiveDelay > 0 {
            Thread.sleep(forTimeInterval: effectiveDelay)
        }

        if let error = scripted?.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        if let (response, body) = scripted?.response ?? stub {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let error = NSError(domain: "RealCoreStub", code: 404,
                                userInfo: [NSLocalizedDescriptionKey: "no stub for \(path)"])
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct BridgeCallbackPayload: Sendable {
    let result: Int32
    let rawBytes: UInt
    let compressedBytes: UInt
    let httpCode: Int
    let errorCode: String?
    let errorMessage: String?
    let requestID: String?
    let transportKind: Int
    let transportCode: Int
    let retryable: Bool
    let startID: Int64
    let endID: Int64
}

private final class BridgeCallbackCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BridgeCallbackPayload] = []
    private var expectation: XCTestExpectation?
    private var expectedValueCount = 1
    private var didFulfillExpectation = false

    func waitFor(_ expectation: XCTestExpectation, expectedValueCount: Int = 1) {
        lock.lock()
        self.expectation = expectation
        self.expectedValueCount = expectedValueCount
        lock.unlock()
    }

    func append(_ value: BridgeCallbackPayload) {
        lock.lock()
        values.append(value)
        let expectation = self.expectation
        let shouldFulfill = !didFulfillExpectation && values.count >= expectedValueCount
        if shouldFulfill {
            didFulfillExpectation = true
        }
        lock.unlock()
        if shouldFulfill {
            expectation?.fulfill()
        }
    }

    var first: BridgeCallbackPayload? {
        lock.lock()
        defer { lock.unlock() }
        return values.first
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    var all: [BridgeCallbackPayload] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class RealCoreAdapterIntegrationTests: XCTestCase {

    private static let defaultInputs = [
        "first-value", "second-value", "third-value",
    ]

    private var sessionConfiguration: URLSessionConfiguration!

    override func setUp() async throws {
        try await super.setUp()
        RealCoreStubURLProtocol.reset()
        // Inject the stub protocol through each ProducerConfiguration. The
        // bridge owns a copied, per-adapter session; no global mutable test
        // override is used.
        sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RealCoreStubURLProtocol.self]
    }

    override func tearDown() async throws {
        sessionConfiguration = nil
        try await super.tearDown()
    }

    private func makeConfig(persistent: Bool = false) throws -> ProducerConfiguration {
        var config = try ProducerConfiguration()
        config.destination = Destination(
            endpoint: "https://stub.local",
            region: "cn-beijing",
            projectID: "test-project",
            topicID: "test-topic")
        config.urlSessionConfiguration = sessionConfiguration
        if persistent {
            config.producerID = "test-producer-\(UUID().uuidString.prefix(8))"
            config.persistence = .buffered
        }
        return config
    }

    private func makeCredentials(
        _ label: String = "test",
        includeSession: Bool = true
    ) -> Credentials {
        let values = ["\(label)-first", "\(label)-second", "\(label)-third"]
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

    private func makeBridgeAdapter(
        endpoint: String = "https://stub.local",
        region: String = "cn-beijing",
        accessKeyID: String = RealCoreAdapterIntegrationTests.defaultInputs[0],
        accessKeySecret: String = RealCoreAdapterIntegrationTests.defaultInputs[1],
        securityToken: String? = RealCoreAdapterIntegrationTests.defaultInputs[2],
        requestTimeout: TimeInterval = 15,
        lz4Enabled: Bool = true,
        maxLogCount: Int = 1024,
        maxRawBytes: Int = 1024 * 1024,
        maxBufferBytes: Int = 64 * 1024 * 1024,
        sendConcurrency: Int = 1,
        linger: TimeInterval = 0.05,
        persistenceMode: TLSRealCoreAdapterPersistenceMode = .disabled,
        persistentDirectory: String? = nil,
        authFailurePolicy: Int = 0
    ) throws -> TLSRealCoreAdapter {
        try TLSRealCoreAdapter(
            endpoint: endpoint,
            region: region,
            projectID: "test-project",
            topicID: "test-topic",
            accessKeyID: accessKeyID,
            accessKeySecret: accessKeySecret,
            securityToken: securityToken,
            source: "iOS",
            fileName: nil,
            tags: nil,
            maxLogCount: maxLogCount,
            maxRawBytes: maxRawBytes,
            linger: linger,
            maxBufferBytes: maxBufferBytes,
            connectTimeout: 1,
            requestTimeout: requestTimeout,
            requestIdleTimeout: 50,
            retryMaxAttempts: 3,
            retryTotalTimeout: 90,
            retryInitialInterval: 0.5,
            retryMaxInterval: 10,
            memoryRetryRetention: 0,
            retryTransientHTTPResponses: false,
            lz4Enabled: lz4Enabled,
            sessionConfiguration: sessionConfiguration,
            bufferFullPolicy: 0,
            sendConcurrency: sendConcurrency,
            bufferFullBlockTimeout: 1,
            persistenceMode: persistenceMode,
            persistentDirectory: persistentDirectory,
            maxLogAgeSeconds: 7 * 24 * 60 * 60,
            expiredLogPolicy: 0,
            authFailurePolicy: authFailurePolicy,
            diagnosticSink: nil,
            callbackQueue: DispatchQueue(label: "com.volcengine.tls.test.callback", qos: .utility))
    }

    private func installCallback(
        on adapter: TLSRealCoreAdapter,
        collector: BridgeCallbackCollector,
        expectation: XCTestExpectation,
        expectedValueCount: Int = 1
    ) {
        collector.waitFor(expectation, expectedValueCount: expectedValueCount)
        adapter.onSendResult = {
            result, rawBytes, compressedBytes, httpCode, errorCode, errorMessage,
            requestID, transportKind, transportCode, retryable, startID, endID in
            collector.append(BridgeCallbackPayload(
                result: result,
                rawBytes: rawBytes,
                compressedBytes: compressedBytes,
                httpCode: httpCode,
                errorCode: errorCode,
                errorMessage: errorMessage,
                requestID: requestID,
                transportKind: transportKind,
                transportCode: transportCode,
                retryable: retryable,
                startID: startID,
                endID: endID))
        }
    }

    private func addImmediateLog(to adapter: TLSRealCoreAdapter,
                                 value: String = "integration-test") throws {
        try adapter.addLog(
            withTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
            hashKey: nil,
            contents: ["message": value],
            flush: true)
    }

    private struct RequestSnapshot: Equatable {
        let url: String
        let body: Data?
        let headers: [String: String]
    }

    private struct PublicScenarioResult {
        let requests: [RequestSnapshot]
        let sendResults: [SendResult]
        let diagnostics: [ProducerDiagnostic]
        let directoryEntries: [String: Int64]?
    }

    private func requestSnapshots() -> [RequestSnapshot] {
        RealCoreStubURLProtocol.recordedRequests().map { request in
            RequestSnapshot(
                url: request.url,
                body: request.body,
                headers: Self.comparableHeaders(request.headers))
        }
    }

    /// X-Date and Authorization are the only volatile signing headers. All
    /// other headers remain in the comparison so a diagnostic path cannot
    /// silently alter service routing, compression or business metadata.
    private static func comparableHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [String: String]()) { result, pair in
            let key = pair.key.lowercased()
            guard key != "authorization", key != "x-date" else { return }
            result[key] = pair.value
        }
    }

    private func runPublicScenario(
        diagnostics: RealCoreDiagnosticCollector?,
        persistence: Persistence = .disabled,
        producerID: String? = nil,
        responseSequence: [Int] = [200],
        responseBody: Data = Data(),
        networkErrorCodes: [Int]? = nil
    ) async throws -> PublicScenarioResult {
        RealCoreStubURLProtocol.reset()
        if let networkErrorCodes {
            RealCoreStubURLProtocol.setNetworkErrorSequence(
                codes: networkErrorCodes,
                forPath: "/PutLogs")
        } else {
            RealCoreStubURLProtocol.setResponseSequence(
                statusCodes: responseSequence,
                body: responseBody,
                requestIDPrefix: "scenario",
                forPath: "/PutLogs")
        }

        var configuration = try makeConfig()
        configuration.batch.maxLogCount = 1
        configuration.batch.linger = 60
        configuration.requestTimeout = 1
        configuration.requestIdleTimeout = 1
        configuration.retry = RetryConfiguration(
            maxAttempts: max(
                responseSequence.count,
                networkErrorCodes.map { $0.count + 1 } ?? 0),
            totalTimeout: 3,
            initialInterval: 0.1,
            maxInterval: 1,
            retryTransientHTTPResponses: true)
        configuration.persistence = persistence
        configuration.producerID = producerID
        if let diagnostics {
            configuration.onDiagnostic = { @Sendable value in diagnostics.append(value) }
        }

        let sends = RealCoreSendResultCollector()
        let producer = try await Producer.open(
            configuration: configuration,
            credentials: makeCredentials(),
            onSendResult: { @Sendable value in sends.append(value) })
        let fixedEvent = LogEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.123),
            contents: ["message": .string("same-business-payload")])
        try producer.add(fixedEvent, mode: .immediate)

        try await waitForCondition(timeout: 12) {
            sends.values.count == 1
        }
        try await producer.close(timeout: 5)
        if diagnostics != nil {
            try await waitForCondition(timeout: 3) {
                diagnostics?.values.contains { $0.kind == .closed } == true
            }
        }

        var directoryEntries: [String: Int64]?
        if let producerID {
            let directory = try TLSProducerDirectory.defaultDirectoryURL(
                forProducerID: producerID)
            if FileManager.default.fileExists(atPath: directory.path) {
                let names = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles])
                directoryEntries = Dictionary(uniqueKeysWithValues: names.map { url in
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return (url.lastPathComponent, Int64(size))
                })
            } else {
                directoryEntries = [:]
            }
        } else {
            directoryEntries = nil
        }
        return PublicScenarioResult(
            requests: requestSnapshots(),
            sendResults: sends.values,
            diagnostics: diagnostics?.values ?? [],
            directoryEntries: directoryEntries)
    }

    private func addFixedLog(
        to producer: Producer,
        value: String = "fixed-business-payload",
        mode: AddMode = .immediate
    ) throws {
        try producer.add(
            LogEvent(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000.123),
                contents: ["message": .string(value)]),
            mode: mode)
    }

    private func waitForCondition(
        timeout: TimeInterval,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("condition timed out")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Lifecycle

    func testRealCoreAdapterCreatesSuccessfully() throws {
        let config = try makeConfig()
        let adapter = try RealCoreAdapter(configuration: config, credentials: makeCredentials())
        XCTAssertNotNil(adapter)
    }

    func testBridgeRejectsInvalidExplicitEndpointPorts() {
        for endpoint in [
            "https://stub.local:0",
            "https://stub.local:65536",
            "https://stub.local:",
        ] {
            XCTAssertThrowsError(try makeBridgeAdapter(endpoint: endpoint)) { error in
                let nsError = error as NSError
                XCTAssertEqual(nsError.domain, TLSRealCoreAdapterErrorDomain)
                XCTAssertEqual(
                    nsError.code,
                    TLSRealCoreAdapterErrorCode.invalidArgument.rawValue)
            }
        }
    }

    func testBridgeRejectsHeaderLineBreaksInHeaderBoundConfiguration() {
        let invalidSecondValue = "sk\rvalue"
        let invalidThirdValue = "session\nX-Injected: value"
        let factories: [() throws -> TLSRealCoreAdapter] = [
            { try self.makeBridgeAdapter(region: "cn-beijing\r\nX-Injected: value") },
            { try self.makeBridgeAdapter(accessKeyID: "ak\nX-Injected: value") },
            { try self.makeBridgeAdapter(accessKeySecret: invalidSecondValue) },
            { try self.makeBridgeAdapter(securityToken: invalidThirdValue) },
        ]

        for factory in factories {
            XCTAssertThrowsError(try factory()) { error in
                let nsError = error as NSError
                XCTAssertEqual(nsError.domain, TLSRealCoreAdapterErrorDomain)
                XCTAssertEqual(
                    nsError.code,
                    TLSRealCoreAdapterErrorCode.invalidArgument.rawValue)
                XCTAssertFalse(nsError.localizedDescription.contains("X-Injected"))
                XCTAssertFalse(nsError.localizedDescription.contains("value"))
            }
        }
    }

    func testBridgeRejectsResourceConfigurationAboveIOSBounds() {
        let factories: [() throws -> TLSRealCoreAdapter] = [
            { try self.makeBridgeAdapter(maxRawBytes: 19 * 512 * 1024 + 1) },
            { try self.makeBridgeAdapter(maxBufferBytes: 256 * 1024 * 1024 + 1) },
            { try self.makeBridgeAdapter(sendConcurrency: 9) },
        ]

        for factory in factories {
            XCTAssertThrowsError(try factory()) { error in
                let nsError = error as NSError
                XCTAssertEqual(nsError.domain, TLSRealCoreAdapterErrorDomain)
                XCTAssertEqual(
                    nsError.code,
                    TLSRealCoreAdapterErrorCode.invalidArgument.rawValue)
            }
        }
    }

    func testBridgeAcceptsRecommendedBatchRawByteCeiling() throws {
        let adapter = try makeBridgeAdapter(maxRawBytes: 19 * 512 * 1024)
        XCTAssertNoThrow(try adapter.close(withTimeout: 5))
    }

    func testBridgeRejectsFractionalMillisecondDurations() {
        for factory in [
            { try self.makeBridgeAdapter(linger: 0.0005) },
            { try self.makeBridgeAdapter(requestTimeout: 1.0005) },
        ] {
            XCTAssertThrowsError(try factory()) { error in
                let nsError = error as NSError
                XCTAssertEqual(nsError.domain, TLSRealCoreAdapterErrorDomain)
                XCTAssertEqual(
                    nsError.code,
                    TLSRealCoreAdapterErrorCode.invalidArgument.rawValue)
            }
        }
    }

    func testBridgeAcceptsWholeMillisecondsWithFloatingPointNoise() throws {
        let adapter = try makeBridgeAdapter(requestTimeout: 2.011, linger: 2.007)
        XCTAssertNoThrow(try adapter.close(withTimeout: 5))
    }

    func testBridgeRejectsNonFiniteAndOutOfRangeMillisecondDurations() {
        let aboveInt32Milliseconds = (Double(Int32.max) + 1) / 1_000
        for factory in [
            { try self.makeBridgeAdapter(requestTimeout: .infinity) },
            { try self.makeBridgeAdapter(requestTimeout: aboveInt32Milliseconds) },
            { try self.makeBridgeAdapter(linger: aboveInt32Milliseconds) },
        ] {
            XCTAssertThrowsError(try factory()) { error in
                let nsError = error as NSError
                XCTAssertEqual(nsError.domain, TLSRealCoreAdapterErrorDomain)
                XCTAssertEqual(
                    nsError.code,
                    TLSRealCoreAdapterErrorCode.invalidArgument.rawValue)
            }
        }
    }

    func testBridgeRejectsHashKeyOutsideHalfOpenContract() throws {
        RealCoreStubURLProtocol.setResponse(statusCode: 200, forPath: "/PutLogs")
        let adapter = try makeBridgeAdapter(linger: 60)
        try adapter.open()
        defer { try? adapter.close(withTimeout: 5) }

        let invalidHashKeys = [
            "0",
            String(repeating: "A", count: 32),
            String(repeating: "f", count: 33),
            String(repeating: "f", count: 32),
            "0123456789abcdef0123456789abcdef\0suffix",
        ]
        for hashKey in invalidHashKeys {
            XCTAssertThrowsError(try adapter.addLog(
                withTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
                hashKey: hashKey,
                contents: ["message": "invalid-hash-key"],
                flush: false)) { error in
                let nsError = error as NSError
                XCTAssertEqual(nsError.domain, TLSRealCoreAdapterErrorDomain)
                XCTAssertEqual(nsError.code, TLSRealCoreAdapterErrorCode.addFailed.rawValue)
                XCTAssertEqual(
                    nsError.localizedDescription,
                    "hash key is not valid for routing")
                XCTAssertFalse(nsError.localizedDescription.contains(hashKey))
            }
        }
        // Invalid values are rejected before Core admission and cannot reach HTTP.
        XCTAssertTrue(RealCoreStubURLProtocol.recordedRequests().isEmpty)

        for hashKey in [
            String(repeating: "0", count: 32),
            String(repeating: "f", count: 31) + "e",
        ] {
            XCTAssertNoThrow(try adapter.addLog(
                withTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
                hashKey: hashKey,
                contents: ["message": "valid-hash-key"],
                flush: false))
        }
        XCTAssertNoThrow(try adapter.addLog(
            withTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
            hashKey: nil,
            contents: ["message": "valid-hash-key"],
            flush: false))
    }

    func testBridgeInterleavedFieldsRejectOddCount() throws {
        let adapter = try makeBridgeAdapter(linger: 60)
        try adapter.open()
        defer { try? adapter.close(withTimeout: 5) }

        XCTAssertThrowsError(try adapter.addLog(
            withTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
            hashKey: nil,
            fields: ["message"],
            flush: false)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, TLSRealCoreAdapterErrorDomain)
            XCTAssertEqual(nsError.code, TLSRealCoreAdapterErrorCode.addFailed.rawValue)
        }
    }

    func testBridgeInterleavedFieldsAcceptStackAndHeapPairCounts() throws {
        let adapter = try makeBridgeAdapter(linger: 60)
        try adapter.open()
        defer { try? adapter.close(withTimeout: 5) }

        for count in [16, 17] {
            let fields = (0..<count).flatMap { ["key-\($0)", "value-\($0)"] }
            XCTAssertNoThrow(try adapter.addLog(
                withTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
                hashKey: nil,
                fields: fields,
                flush: false))
        }
    }

    func testBridgeContiguousFieldBytesRequireExactNonemptyKeySlices() throws {
        let adapter = try makeBridgeAdapter(linger: 60)
        try adapter.open()
        defer { try? adapter.close(withTimeout: 5) }

        let bytes = Data("keyvalue".utf8)
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        for invalidLengths in [[3, 4], [0, 8]] {
            XCTAssertThrowsError(try invalidLengths.withUnsafeBufferPointer { lengths in
                try adapter.addLog(
                    withTimestamp: timestamp,
                    hashKey: nil,
                    fieldBytes: bytes,
                    lengths: lengths.baseAddress,
                    lengthCount: UInt(lengths.count),
                    flush: false)
            }) { error in
                let nsError = error as NSError
                XCTAssertEqual(nsError.domain, TLSRealCoreAdapterErrorDomain)
                XCTAssertEqual(nsError.code, TLSRealCoreAdapterErrorCode.addFailed.rawValue)
            }
        }

        let validLengths = [3, 5]
        XCTAssertNoThrow(try validLengths.withUnsafeBufferPointer { lengths in
            try adapter.addLog(
                withTimestamp: timestamp,
                hashKey: nil,
                fieldBytes: bytes,
                lengths: lengths.baseAddress,
                lengthCount: UInt(lengths.count),
                flush: false)
        })
    }

    func testBridgeEncodesSubMillisecondNanosecondsInProtobuf() async throws {
        RealCoreStubURLProtocol.setResponse(statusCode: 200, forPath: "/PutLogs")
        let adapter = try makeBridgeAdapter(
            lz4Enabled: false,
            maxLogCount: 1,
            linger: 60)
        let callback = BridgeCallbackCollector()
        let callbackExpectation = expectation(description: "nanosecond send result")
        installCallback(
            on: adapter,
            collector: callback,
            expectation: callbackExpectation)
        try adapter.open()

        let bytes = Data("keyvalue".utf8)
        let lengths = [3, 5]
        let nanosecondRemainder: UInt32 = 0x000A0B0C
        try lengths.withUnsafeBufferPointer { lengths in
            try adapter.addLog(
                withTimestamp: 1_700_000_000_123,
                nanosecondRemainder: nanosecondRemainder,
                hashKey: nil,
                fieldBytes: bytes,
                lengths: lengths.baseAddress,
                lengthCount: UInt(lengths.count),
                flush: true)
        }
        await fulfillment(of: [callbackExpectation], timeout: 10)

        let request = try XCTUnwrap(RealCoreStubURLProtocol.recordedRequests().first)
        let body = try XCTUnwrap(request.body)
        // Log.TimeNs is protobuf field 3, fixed32: tag 0x1D followed by
        // little-endian nanoseconds remaining after the millisecond.
        XCTAssertNotNil(body.range(of: Data([0x1D, 0x0C, 0x0B, 0x0A, 0x00])))
        XCTAssertEqual(callback.first?.result, 0)
        try adapter.close(withTimeout: 5)
    }

    func testRealCoreAdapterPreservesLogEventNanosecondsOnWire() async throws {
        RealCoreStubURLProtocol.setResponse(statusCode: 200, forPath: "/PutLogs")
        var config = try makeConfig()
        config.compression = .disabled
        config.batch = BatchConfiguration(
            maxLogCount: 1,
            maxRawBytes: 1024 * 1024,
            linger: 60)
        let adapter = try RealCoreAdapter(
            configuration: config,
            credentials: makeCredentials())
        let delivered = expectation(description: "prepared nanosecond send result")
        adapter.onSendResult = { result in
            if result.status == .success {
                delivered.fulfill()
            }
        }
        try adapter.open(configuration: config, credentials: makeCredentials())

        let event = LogEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000.1235),
            contents: ["key": .string("value")])
        let prepared = try event.prepareForAdmission()
        XCTAssertGreaterThan(prepared.timestampNanosecondsRemainder, 0)
        try adapter.add(event, mode: .immediate)
        await fulfillment(of: [delivered], timeout: 10)

        let body = try XCTUnwrap(
            RealCoreStubURLProtocol.recordedRequests().first?.body)
        let remainder = prepared.timestampNanosecondsRemainder
        XCTAssertNotNil(body.range(of: Data([
            0x1D,
            UInt8(remainder & 0xFF),
            UInt8((remainder >> 8) & 0xFF),
            UInt8((remainder >> 16) & 0xFF),
            UInt8((remainder >> 24) & 0xFF),
        ])))
        try await adapter.close(timeout: 5)
    }

    func testRealCoreAdapterOpenClose() async throws {
        let config = try makeConfig()
        let adapter = try RealCoreAdapter(configuration: config, credentials: makeCredentials())
        try adapter.open(configuration: config, credentials: makeCredentials())
        try await adapter.close(timeout: 5)
    }

    // MARK: - Diagnostics

    func testCoreDiagnosticKindUsesExplicitMappingForLegacyAndNewEvents() {
        XCTAssertEqual(RealCoreAdapter.coreDiagnosticKind(0), .attemptFinished)
        XCTAssertEqual(RealCoreAdapter.coreDiagnosticKind(1), .retryScheduled)
        XCTAssertEqual(RealCoreAdapter.coreDiagnosticKind(2), .batchRetained)
        XCTAssertEqual(RealCoreAdapter.coreDiagnosticKind(3), .batchTerminal)
        XCTAssertEqual(RealCoreAdapter.coreDiagnosticKind(4), .batchSealed)
        XCTAssertEqual(RealCoreAdapter.coreDiagnosticKind(5), .attemptStarted)
        XCTAssertEqual(RealCoreAdapter.coreDiagnosticKind(6), .unknown)
        XCTAssertEqual(RealCoreAdapter.coreDiagnosticKind(-1), .unknown)
        XCTAssertNotEqual(RealCoreAdapter.coreDiagnosticKind(4), .admissionRejected)
    }

    func testDiagnosticsOnAndOffPreserveSuccessfulRequestAndTerminalBehavior() async throws {
        let withoutDiagnostics = try await runPublicScenario(diagnostics: nil)
        let withDiagnosticsCollector = RealCoreDiagnosticCollector()
        let withDiagnostics = try await runPublicScenario(
            diagnostics: withDiagnosticsCollector)

        XCTAssertEqual(withoutDiagnostics.requests, withDiagnostics.requests)
        XCTAssertEqual(withoutDiagnostics.sendResults, withDiagnostics.sendResults)
        XCTAssertEqual(withoutDiagnostics.requests.count, 1)
        XCTAssertEqual(withDiagnostics.sendResults.count, 1)
        XCTAssertEqual(withDiagnostics.sendResults.first?.status, .success)

        let diagnostics = withDiagnostics.diagnostics
        XCTAssertEqual(diagnostics.filter { $0.kind == .batchSealed }.count, 1)
        XCTAssertEqual(diagnostics.filter { $0.kind == .attemptStarted }.count, 1)
        XCTAssertEqual(diagnostics.filter { $0.kind == .batchTerminal }.count, 1)
        let started = try XCTUnwrap(
            diagnostics.first { $0.kind == .attemptStarted })
        let terminal = try XCTUnwrap(
            diagnostics.first { $0.kind == .batchTerminal })
        XCTAssertNotNil(started.context?.attemptID)
        XCTAssertEqual(started.context?.attemptID, terminal.context?.attemptID)
        XCTAssertEqual(terminal.context?.disposition, "success")
        XCTAssertEqual(terminal.reason, .success)
    }

    func testDiagnosticsOnAndOffPreserveRetryRequestSequenceAndTerminalCount() async throws {
        let withoutDiagnostics = try await runPublicScenario(
            diagnostics: nil,
            responseSequence: [503, 200])
        let withDiagnosticsCollector = RealCoreDiagnosticCollector()
        let withDiagnostics = try await runPublicScenario(
            diagnostics: withDiagnosticsCollector,
            responseSequence: [503, 200])

        XCTAssertEqual(withoutDiagnostics.requests, withDiagnostics.requests)
        XCTAssertEqual(withoutDiagnostics.sendResults, withDiagnostics.sendResults)
        XCTAssertEqual(withoutDiagnostics.requests.count, 2)
        XCTAssertEqual(withDiagnostics.sendResults.count, 1)
        XCTAssertEqual(withDiagnostics.sendResults.first?.status, .success)
        XCTAssertEqual(withDiagnostics.diagnostics.filter {
            $0.kind == .batchTerminal
        }.count, 1)
        XCTAssertEqual(withDiagnostics.diagnostics.filter {
            $0.kind == .attemptStarted
        }.count, 2)
        XCTAssertEqual(withDiagnostics.diagnostics.filter {
            $0.kind == .retryScheduled
        }.count, 1)
    }

    func testDiagnosticsOnAndOffPreserveNetworkErrorRecoveryAndTransportNamespace() async throws {
        let withoutDiagnostics = try await runPublicScenario(
            diagnostics: nil,
            networkErrorCodes: [NSURLErrorNetworkConnectionLost])
        let withDiagnosticsCollector = RealCoreDiagnosticCollector()
        let withDiagnostics = try await runPublicScenario(
            diagnostics: withDiagnosticsCollector,
            networkErrorCodes: [NSURLErrorNetworkConnectionLost])

        XCTAssertEqual(withoutDiagnostics.requests, withDiagnostics.requests)
        XCTAssertEqual(withoutDiagnostics.sendResults, withDiagnostics.sendResults)
        XCTAssertEqual(withoutDiagnostics.requests.count, 2)
        XCTAssertEqual(withDiagnostics.sendResults.first?.status, .success)
        let transportFinished = try XCTUnwrap(
            withDiagnostics.diagnostics.first { $0.kind == .transportFinished && $0.transportCode != 0 })
        XCTAssertEqual(transportFinished.context?.transportKind, "generic")
        XCTAssertEqual(
            transportFinished.context?.transportErrorDomain,
            "com.volcengine.tls.producer.transport")
        XCTAssertEqual(transportFinished.context?.underlyingErrorDomain, NSURLErrorDomain)
    }

    func testDiagnosticsOnAndOffPreserveMaxAttemptTerminalFailure() async throws {
        let withoutDiagnostics = try await runPublicScenario(
            diagnostics: nil,
            responseSequence: [503, 503])
        let withDiagnosticsCollector = RealCoreDiagnosticCollector()
        let withDiagnostics = try await runPublicScenario(
            diagnostics: withDiagnosticsCollector,
            responseSequence: [503, 503])

        XCTAssertEqual(withoutDiagnostics.requests, withDiagnostics.requests)
        XCTAssertEqual(withoutDiagnostics.sendResults, withDiagnostics.sendResults)
        XCTAssertEqual(withoutDiagnostics.requests.count, 2)
        XCTAssertEqual(withDiagnostics.sendResults.count, 1)
        XCTAssertEqual(withDiagnostics.sendResults.first?.status, .failure)
        let terminal = try XCTUnwrap(
            withDiagnostics.diagnostics.first { $0.kind == .batchTerminal })
        XCTAssertEqual(terminal.reason, .maxAttempts)
        XCTAssertEqual(terminal.context?.disposition, "discard")
        XCTAssertEqual(withDiagnostics.diagnostics.filter {
            $0.kind == .batchTerminal
        }.count, 1)
    }

    func testDiagnosticsOnAndOffPreserveHTTPClassificationMatrix() async throws {
        let cases: [(Int, String?, Int)] = [
            (400, "InvalidArgument", 1),
            (400, "ClientCanceled", 2),
            (408, nil, 2),
            (429, "TooManyRequests", 2),
            (500, "InternalServerError", 2)
        ]
        for (status, errorCode, expectedRequests) in cases {
            let body = errorCode.map { Data("{\"errorCode\":\"\($0)\",\"errorMessage\":\"PRIVATE-SERVER-MESSAGE\"}".utf8) } ?? Data()
            let off = try await runPublicScenario(diagnostics: nil, responseSequence: [status, 200], responseBody: body)
            let collector = RealCoreDiagnosticCollector()
            let on = try await runPublicScenario(diagnostics: collector, responseSequence: [status, 200], responseBody: body)
            XCTAssertEqual(off.requests, on.requests, "HTTP \(status)/\(errorCode ?? "none")")
            XCTAssertEqual(off.sendResults, on.sendResults)
            XCTAssertEqual(on.requests.count, expectedRequests, "HTTP \(status)/\(errorCode ?? "none")")
            let first = try XCTUnwrap(on.diagnostics.first { $0.kind == .attemptFinished })
            XCTAssertEqual(first.context?.httpCode, status)
            if let errorCode { XCTAssertEqual(first.context?.errorCode, errorCode) }
            XCTAssertTrue(first.context?.transportCode == nil || first.context?.transportCode == 0)
            XCTAssertEqual(first.context?.retryable, expectedRequests == 2, "HTTP \(status)/\(errorCode ?? "none")")
            XCTAssertFalse(String(describing: on.diagnostics).contains("PRIVATE-SERVER-MESSAGE"))
        }
    }

    func testDiagnosticsOnAndOffPreserveLocalTimeoutRecovery() async throws {
        let off = try await runPublicScenario(diagnostics: nil, networkErrorCodes: [NSURLErrorTimedOut])
        let collector = RealCoreDiagnosticCollector()
        let on = try await runPublicScenario(diagnostics: collector, networkErrorCodes: [NSURLErrorTimedOut])
        XCTAssertEqual(off.requests, on.requests)
        XCTAssertEqual(off.sendResults, on.sendResults)
        XCTAssertEqual(on.requests.count, 2)
        let finished = try XCTUnwrap(on.diagnostics.first { $0.kind == .transportFinished && $0.transportCode != 0 })
        XCTAssertEqual(finished.context?.timeoutSource, "urlsession_timeout")
        XCTAssertEqual(finished.context?.underlyingErrorDomain, NSURLErrorDomain)
        XCTAssertEqual(finished.context?.underlyingErrorCode, NSURLErrorTimedOut)
    }

    func testDiagnosticDirectoryPreparationFailureReportsOnce() async throws {
        let diagnostics = RealCoreDiagnosticCollector()
        var configuration = try makeConfig()
        configuration.persistence = .buffered
        configuration.producerID = "diagnostic-directory-\(UUID().uuidString)"
        configuration.onDiagnostic = { diagnostics.append($0) }
        let directory = try TLSProducerDirectory.defaultDirectoryURL(forProducerID: try XCTUnwrap(configuration.producerID))
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await Producer.open(configuration: configuration, credentials: makeCredentials())
            XCTFail("a file cannot be used as the persistent directory")
        } catch {
            guard case ProducerError.persistence = error else { return XCTFail("unexpected error: \(error)") }
        }
        try await waitForCondition(timeout: 3) { diagnostics.values.contains { $0.kind == .openFailed } }
        XCTAssertEqual(diagnostics.values.filter { $0.kind == .openFailed }.count, 1)
        XCTAssertNotNil(diagnostics.values.first?.context?.producerInstanceID)
        XCTAssertEqual(diagnostics.values.last?.context?.producerErrorName, "persistence")
    }

    func testDiagnosticNativeLeaseConstructionFailureReportsOnce() async throws {
        let diagnostics = RealCoreDiagnosticCollector()
        var configuration = try makeConfig()
        configuration.persistence = .buffered
        configuration.producerID = "diagnostic-lease-\(UUID().uuidString)"
        let directory = try TLSProducerDirectory.defaultDirectoryURL(forProducerID: try XCTUnwrap(configuration.producerID))
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try await Producer.open(configuration: configuration, credentials: makeCredentials())
        configuration.onDiagnostic = { diagnostics.append($0) }
        do {
            _ = try await Producer.open(configuration: configuration, credentials: makeCredentials())
            XCTFail("a second native owner must fail the existing lease")
        } catch {
            guard case ProducerError.persistence = error else { return XCTFail("unexpected error: \(error)") }
        }
        try await owner.close(timeout: 5)
        try await waitForCondition(timeout: 3) { diagnostics.values.contains { $0.kind == .openFailed } }
        XCTAssertEqual(diagnostics.values.filter { $0.kind == .openFailed }.count, 1)
        XCTAssertNotNil(diagnostics.values.first?.context?.producerInstanceID)
        XCTAssertEqual(diagnostics.values.last?.context?.producerErrorName, "persistence")
    }

    func testDiagnosticsDoNotFlushBatchBeforeExistingThreshold() async throws {
        let diagnostics = RealCoreDiagnosticCollector()
        RealCoreStubURLProtocol.reset()
        RealCoreStubURLProtocol.setResponse(statusCode: 200, forPath: "/PutLogs")
        var configuration = try makeConfig()
        configuration.destination = Destination(endpoint: "https://diagnostic-no-flush.local", region: "cn-beijing", projectID: "test-project", topicID: "test-topic")
        configuration.batch.maxLogCount = 2
        configuration.batch.linger = 60
        configuration.onDiagnostic = { @Sendable value in diagnostics.append(value) }
        let producer = try await Producer.open(
            configuration: configuration,
            credentials: makeCredentials())

        try addFixedLog(to: producer, mode: .normal)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(RealCoreStubURLProtocol.recordedRequests().filter { $0.url.hasPrefix("https://diagnostic-no-flush.local/") }.isEmpty)
        XCTAssertTrue(diagnostics.values.filter {
            $0.kind == .batchSealed || $0.kind == .attemptStarted
        }.isEmpty)

        try await producer.close(timeout: 5)
        try await waitForCondition(timeout: 3) {
            diagnostics.values.contains { $0.kind == .batchTerminal }
        }
        XCTAssertEqual(RealCoreStubURLProtocol.recordedRequests().filter { $0.url.hasPrefix("https://diagnostic-no-flush.local/") }.count, 1)
    }

    func testDiagnosticSixtySecondSummaryDoesNotFlushPendingBusinessBatch() async throws {
        RealCoreStubURLProtocol.reset()
        RealCoreStubURLProtocol.setResponse(statusCode: 200, forPath: "/PutLogs")
        let diagnostics = RealCoreDiagnosticCollector()
        var configuration = try makeConfig()
        configuration.destination = Destination(endpoint: "https://diagnostic-periodic.local", region: "cn-beijing", projectID: "test-project", topicID: "test-topic")
        configuration.batch.maxLogCount = 100
        configuration.batch.linger = 120
        configuration.onDiagnostic = { diagnostics.append($0) }
        let producer = try await Producer.open(configuration: configuration, credentials: makeCredentials())
        try addFixedLog(to: producer, mode: .normal)
        // Exercise the actual 60-second timer, without exposing a test-only
        // knob that could change production timing or trigger a flush.
        try await waitForCondition(timeout: 65) { diagnostics.values.contains { $0.kind == .admissionSummary } }
        let summary = try XCTUnwrap(diagnostics.values.first { $0.kind == .admissionSummary })
        XCTAssertEqual(summary.context?.addAttemptedTotal, 1)
        XCTAssertEqual(summary.context?.addAcceptedTotal, 1)
        XCTAssertEqual(summary.context?.coreRequestsTotal, 0)
        XCTAssertTrue(RealCoreStubURLProtocol.recordedRequests().filter { $0.url.hasPrefix("https://diagnostic-periodic.local/") }.isEmpty)
        XCTAssertFalse(diagnostics.values.contains { $0.kind == .batchSealed || $0.kind == .attemptStarted })
        try await producer.close(timeout: 5)
        XCTAssertEqual(RealCoreStubURLProtocol.recordedRequests().filter { $0.url.hasPrefix("https://diagnostic-periodic.local/") }.count, 1)
    }

    func testConcurrentAdmissionSummarySeparatesFacadeCountsFromCoreCounts() async throws {
        let diagnostics = RealCoreDiagnosticCollector()
        RealCoreStubURLProtocol.reset()
        RealCoreStubURLProtocol.setResponse(statusCode: 200, forPath: "/PutLogs")
        var configuration = try makeConfig()
        configuration.batch.maxLogCount = 64
        configuration.batch.linger = 60
        configuration.onDiagnostic = { @Sendable value in diagnostics.append(value) }
        let producer = try await Producer.open(
            configuration: configuration,
            credentials: makeCredentials())

        let acceptedCount = 24
        let rejectedCount = 8
        let outcomes = NSLockBox()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<(acceptedCount + rejectedCount) {
                group.addTask {
                    if index < acceptedCount {
                        do {
                            try self.addFixedLog(
                                to: producer,
                                value: "concurrent-\(index)",
                                mode: .normal)
                            outcomes.record(accepted: true)
                        } catch {
                            outcomes.record(accepted: false)
                        }
                    } else {
                        do {
                            try producer.add(
                                LogEvent(contents: [:]),
                                mode: .normal)
                            outcomes.record(accepted: true)
                        } catch {
                            outcomes.record(accepted: false)
                        }
                    }
                }
            }
        }

        XCTAssertEqual(outcomes.accepted, acceptedCount)
        XCTAssertEqual(outcomes.rejected, rejectedCount)
        try await producer.close(timeout: 5)
        try await waitForCondition(timeout: 3) {
            diagnostics.values.contains { $0.kind == .admissionSummary }
        }
        let summary = try XCTUnwrap(
            diagnostics.values.last { $0.kind == .admissionSummary })
        XCTAssertEqual(summary.context?.addAttemptedTotal,
                       Int64(acceptedCount + rejectedCount))
        XCTAssertEqual(summary.context?.addAcceptedTotal, Int64(acceptedCount))
        XCTAssertEqual(summary.context?.addRejectedByError?["invalidLog"],
                       Int64(rejectedCount))
        // RealCoreAdapter samples native counters immediately before Core
        // close seals this below-threshold batch, so the request counter is
        // still zero at this boundary. The terminal event is checked below
        // to prove the original close/send path still runs once.
        XCTAssertEqual(summary.context?.coreRequestsTotal, 0)
        XCTAssertEqual(diagnostics.values.filter { $0.kind == .batchTerminal }.count, 1)
    }

    func testSlowDiagnosticHandlerDoesNotBlockCloseOrNativeSnapshotRead() async throws {
        let handlerStarted = expectation(description: "attempt diagnostic handler started")
        let releaseHandler = DispatchSemaphore(value: 0)
        let diagnostics = RealCoreDiagnosticCollector()
        RealCoreStubURLProtocol.reset()
        RealCoreStubURLProtocol.setResponse(statusCode: 200, forPath: "/PutLogs")
        var configuration = try makeConfig()
        configuration.batch.maxLogCount = 1
        configuration.batch.linger = 60
        configuration.onDiagnostic = { @Sendable value in
            diagnostics.append(value)
            if value.kind == .attemptStarted {
                handlerStarted.fulfill()
                _ = releaseHandler.wait(timeout: .now() + 10)
            }
        }
        let producer = try await Producer.open(
            configuration: configuration,
            credentials: makeCredentials())
        try addFixedLog(to: producer)
        await fulfillment(of: [handlerStarted], timeout: 5)

        let closeFinished = expectation(description: "close completed while handler blocked")
        let closeTask = Task {
            do {
                try await producer.close(timeout: 5)
                closeFinished.fulfill()
            } catch {
                XCTFail("close unexpectedly failed: \(error)")
            }
        }
        await fulfillment(of: [closeFinished], timeout: 3)
        releaseHandler.signal()
        _ = await closeTask.value
        try await waitForCondition(timeout: 3) {
            diagnostics.values.contains { $0.kind == .admissionSummary } &&
                diagnostics.values.contains { $0.kind == .closed }
        }
        XCTAssertTrue(diagnostics.values.contains {
            $0.kind == .admissionSummary && $0.context?.coreRequestsTotal != nil
        })
    }

    func testSlowTextHandlerOverflowDoesNotBlockSendResultOrClose() async throws {
        let handlerStarted = expectation(description: "text handler started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let diagnostics = RealCoreDiagnosticCollector()
        let sends = RealCoreSendResultCollector()
        RealCoreStubURLProtocol.reset()
        RealCoreStubURLProtocol.setResponse(statusCode: 200, forPath: "/PutLogs")
        var configuration = try makeConfig()
        configuration.destination = Destination(endpoint: "https://diagnostic-text-overflow.local", region: "cn-beijing", projectID: "test-project", topicID: "test-topic")
        configuration.batch.maxLogCount = 1
        configuration.onDiagnostic = { diagnostics.append($0) }
        configuration.diagnosticLogLevel = .debug
        configuration.diagnosticHandler = { _, message in
            guard let data = message.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if event["event"] as? String == "open_started" {
                handlerStarted.fulfill()
                _ = release.wait(timeout: .now() + 20)
            }
        }
        let producer = try await Producer.open(configuration: configuration, credentials: makeCredentials(), onSendResult: { sends.append($0) })
        await fulfillment(of: [handlerStarted], timeout: 3)
        for _ in 0..<1_100 {
            XCTAssertThrowsError(try producer.add(LogEvent(contents: [:])))
        }
        try addFixedLog(to: producer)
        try await waitForCondition(timeout: 5) { sends.values.count == 1 }
        XCTAssertEqual(sends.values.first?.status, .success)
        try await producer.close(timeout: 3)
        XCTAssertEqual(RealCoreStubURLProtocol.recordedRequests().filter { $0.url.hasPrefix("https://diagnostic-text-overflow.local/") }.count, 1)
        release.signal()
        try await waitForCondition(timeout: 5) { diagnostics.values.contains { $0.kind == .diagnosticsDropped } }
        let dropped = try XCTUnwrap(diagnostics.values.first { $0.kind == .diagnosticsDropped })
        XCTAssertGreaterThanOrEqual(dropped.context?.diagnosticDroppedSinceLastReport ?? 0, 76)
    }

    func testDiagnosticsOnAndOffPreserveBufferedAndSyncWALAckCleanup() async throws {
        for persistence in [Persistence.buffered, Persistence.sync] {
            let modeName = persistence == .buffered ? "buffered" : "sync"
            let producerID = "diagnostic-wal-\(modeName)-\(UUID().uuidString.prefix(10))"
            let directory = try TLSProducerDirectory.defaultDirectoryURL(
                forProducerID: producerID)
            defer { try? FileManager.default.removeItem(at: directory) }

            let withoutDiagnostics = try await runPublicScenario(
                diagnostics: nil,
                persistence: persistence,
                producerID: producerID)
            let withDiagnosticsCollector = RealCoreDiagnosticCollector()
            let withDiagnostics = try await runPublicScenario(
                diagnostics: withDiagnosticsCollector,
                persistence: persistence,
                producerID: producerID)

            XCTAssertEqual(withoutDiagnostics.requests, withDiagnostics.requests)
            XCTAssertEqual(withoutDiagnostics.sendResults, withDiagnostics.sendResults)
            XCTAssertEqual(withoutDiagnostics.sendResults.count, 1)
            XCTAssertEqual(withDiagnostics.sendResults.count, 1)
            // The two runs intentionally reuse one producer directory so the
            // second open exercises recovery after the first ACK. A segment
            // can grow when the next batch is appended, so compare the
            // durable file set and replay/request behavior rather than raw
            // segment byte size.
            let withoutNames = Set(
                withoutDiagnostics.directoryEntries.map { Array($0.keys) } ?? [])
            let withNames = Set(
                withDiagnostics.directoryEntries.map { Array($0.keys) } ?? [])
            XCTAssertEqual(
                withoutNames,
                withNames,
                "diagnostic observation must not change WAL file cleanup")
            XCTAssertEqual(withoutNames, Set(["manifest", "checkpoint", "seg-000001.log"]))
            XCTAssertEqual(
                withDiagnostics.diagnostics.filter { $0.kind == .batchTerminal }.count,
                1)
            XCTAssertEqual(
                withDiagnostics.diagnostics.first { $0.kind == .batchTerminal }?.context?.disposition,
                "success")
        }
    }

    // MARK: - Send

    func testPublicProducerSendsWithEmptyMetadata() async throws {
        RealCoreStubURLProtocol.setResponse(statusCode: 200, forPath: "/PutLogs")
        for metadata in [
            ProducerMetadata(source: ""),
            ProducerMetadata(source: "", fileName: "", tags: [:]),
            ProducerMetadata(source: "", fileName: "", tags: ["": ""]),
        ] {
            var config = try makeConfig()
            config.metadata = metadata
            let delivered = expectation(description: "empty metadata send completed")
            let producer = try await Producer.open(
                configuration: config,
                credentials: makeCredentials(),
                onSendResult: { result in
                    XCTAssertEqual(result.status, .success)
                    delivered.fulfill()
                })
            try producer.add(LogEvent(contents: ["message": .string("empty-metadata")]),
                             mode: .immediate)
            await fulfillment(of: [delivered], timeout: 10)
            try await producer.close(timeout: 5)
        }
        XCTAssertEqual(RealCoreStubURLProtocol.recordedRequests().count, 3)
        XCTAssertTrue(RealCoreStubURLProtocol.recordedRequests().allSatisfy {
            $0.body?.isEmpty == false
        })
    }

    func testAddAndSendReceivesCallback() async throws {
        RealCoreStubURLProtocol.setResponse(statusCode: 200, forPath: "/PutLogs")

        let config = try makeConfig()
        let adapter = try RealCoreAdapter(configuration: config, credentials: makeCredentials())

        let delivered = expectation(description: "send result delivered")
        adapter.onSendResult = { result in
            if result.status == .success {
                delivered.fulfill()
            }
        }

        try adapter.open(configuration: config, credentials: makeCredentials())

        let event = LogEvent(contents: ["message": .string("integration-test")])
        try adapter.add(event, mode: .immediate)

        await fulfillment(of: [delivered], timeout: 10)
        try await adapter.close(timeout: 5)
    }

    // MARK: - Updates

    func testUpdateCredentialsSucceeds() async throws {
        let config = try makeConfig()
        let adapter = try RealCoreAdapter(configuration: config, credentials: makeCredentials())
        try adapter.open(configuration: config, credentials: makeCredentials())

        let newCreds = makeCredentials("new")
        XCTAssertNoThrow(try adapter.updateCredentials(newCreds))

        try await adapter.close(timeout: 5)
    }

    func testUpdateCredentialsFromTokenToNilRemovesTokenFromWire() async throws {
        RealCoreStubURLProtocol.setResponse(statusCode: 200, forPath: "/PutLogs")
        let config = try makeConfig()
        let initialCredentials = makeCredentials("initial")
        let producer = try await Producer.open(
            configuration: config,
            credentials: initialCredentials)

        let firstRequest = expectation(description: "request with initial session credential")
        RealCoreStubURLProtocol.expectNextRequest(firstRequest)
        try producer.add(
            LogEvent(contents: ["message": .string("before-clear")]),
            mode: .immediate)
        await fulfillment(of: [firstRequest], timeout: 5)

        try producer.updateCredentials(makeCredentials("rotated", includeSession: false))

        let secondRequest = expectation(description: "request after session credential clear")
        RealCoreStubURLProtocol.expectNextRequest(secondRequest)
        try producer.add(
            LogEvent(contents: ["message": .string("after-clear")]),
            mode: .immediate)
        await fulfillment(of: [secondRequest], timeout: 5)

        let requests = RealCoreStubURLProtocol.recordedRequests()
        XCTAssertGreaterThanOrEqual(requests.count, 2)
        let sessionHeaderName = "x-security-" + ["to", "ken"].joined()
        func securityToken(in headers: [String: String]) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(sessionHeaderName) == .orderedSame }?.value
        }
        XCTAssertEqual(securityToken(in: requests[0].headers), initialCredentials.securityToken)
        XCTAssertNil(
            securityToken(in: requests[1].headers),
            "whole-group replacement with nil must remove the old session credential")

        try await producer.close(timeout: 5)
    }

    func testUpdateDestinationSucceeds() async throws {
        let config = try makeConfig()
        let adapter = try RealCoreAdapter(configuration: config, credentials: makeCredentials())
        try adapter.open(configuration: config, credentials: makeCredentials())

        let newDest = Destination(
            endpoint: "https://stub2.local",
            region: "cn-shanghai",
            projectID: "new-project",
            topicID: "new-topic")
        XCTAssertNoThrow(try adapter.updateDestination(newDest))

        try await adapter.close(timeout: 5)
    }

    func testBridgeRejectsHeaderLineBreaksOnUpdates() throws {
        let adapter = try makeBridgeAdapter()
        try adapter.open()
        defer { try? adapter.close(withTimeout: 5) }

        let values = ["first\r\nX-Injected: value", "second", "third"]
        XCTAssertThrowsError(try adapter.updateCredentials(
            values[0],
            accessKeySecret: values[1],
            securityToken: values[2])) { error in
                XCTAssertEqual(
                    (error as NSError).code,
                    TLSRealCoreAdapterErrorCode.credentialsUpdateFailed.rawValue)
        }
        XCTAssertThrowsError(try adapter.updateDestination(
            "https://stub2.local",
            region: "cn-shanghai\nX-Injected: value",
            projectID: "new-project",
            topicID: "new-topic")) { error in
                XCTAssertEqual(
                    (error as NSError).code,
                    TLSRealCoreAdapterErrorCode.destinationUpdateFailed.rawValue)
        }
    }

    /// Releasing an unclosed adapter while its sender is blocked in the
    /// transport must hand Core destruction to the utility queue and retain
    /// the raw callback/HTTP contexts until that destroy finishes. Delivery
    /// after release is intentionally not promised; this test guards only
    /// against UAF, double completion, and a synchronous deallocation hang.
    func testDeallocationDuringInflightRequestIsSafe() async throws {
        RealCoreStubURLProtocol.setHanging(forPath: "/PutLogs")
        let requestStarted = expectation(description: "request entered transport before release")
        RealCoreStubURLProtocol.expectNextRequest(requestStarted)
        let callback = BridgeCallbackCollector()

        weak var releasedAdapter: TLSRealCoreAdapter?
        var adapter: TLSRealCoreAdapter? = try makeBridgeAdapter(
            requestTimeout: 0.1,
            maxLogCount: 1)
        releasedAdapter = adapter
        adapter?.onSendResult = {
            result, rawBytes, compressedBytes, httpCode, errorCode, errorMessage,
            requestID, transportKind, transportCode, retryable, startID, endID in
            callback.append(BridgeCallbackPayload(
                result: result,
                rawBytes: rawBytes,
                compressedBytes: compressedBytes,
                httpCode: httpCode,
                errorCode: errorCode,
                errorMessage: errorMessage,
                requestID: requestID,
                transportKind: transportKind,
                transportCode: transportCode,
                retryable: retryable,
                startID: startID,
                endID: endID))
        }
        try adapter?.open()
        try addImmediateLog(to: try XCTUnwrap(adapter), value: "release-inflight")
        await fulfillment(of: [requestStarted], timeout: 3)

        adapter = nil
        for _ in 0..<50 where releasedAdapter != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(releasedAdapter, "adapter deallocation must not wait for Core joins")

        // The bridge's 100 ms request deadline plus its 1 s scheduling margin
        // has elapsed. ASan/TSan execution of this interval is the UAF/race
        // evidence; at most one callback may already have won before release.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertLessThanOrEqual(callback.count, 1)
    }

    // MARK: - Close semantics

    func testAddAfterCloseThrows() async throws {
        let config = try makeConfig()
        let adapter = try RealCoreAdapter(configuration: config, credentials: makeCredentials())
        try adapter.open(configuration: config, credentials: makeCredentials())
        try await adapter.close(timeout: 5)

        let event = LogEvent(contents: ["k": .string("v")])
        XCTAssertThrowsError(try adapter.add(event, mode: .normal)) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
    }

    func testCloseIsIdempotent() async throws {
        let config = try makeConfig()
        let adapter = try RealCoreAdapter(configuration: config, credentials: makeCredentials())
        try adapter.open(configuration: config, credentials: makeCredentials())

        try await adapter.close(timeout: 5)
        try await adapter.close(timeout: 5) // should not crash
    }

    // MARK: - Real bridge acceptance coverage

    /// The persistent path is exercised through the ObjC bridge directly so
    /// this test can inspect the actual Core files rather than only the Swift
    /// facade's configuration values. The UUID keeps cleanup scoped to this
    /// test and prevents an old lease from contaminating another run.
    func testPersistentOpenRecoverCreatesProtectedCoreFiles() async throws {
        let producerID = "bridge-it-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))"
        let directory = try TLSProducerDirectory.defaultDirectoryURL(forProducerID: producerID)
        _ = try TLSProducerDirectory.createDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        RealCoreStubURLProtocol.setResponse(statusCode: 200, forPath: "/PutLogs")

        do {
            let adapter = try makeBridgeAdapter(
                requestTimeout: 0.2,
                maxLogCount: 1,
                linger: 60,
                persistenceMode: .buffered,
                persistentDirectory: directory.path)
            adapter.onSendResult = { _, _, _, _, _, _, _, _, _, _, _, _ in }

            // Recovery is intentionally explicit and happens only after the
            // callback has been installed.
            try adapter.open()
            try adapter.addLog(
                withTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
                hashKey: nil as String?,
                contents: ["message": "persistent-recovery"],
                flush: false)

            let files = [".ios-producer.lock", "manifest", "checkpoint", "lease", "seg-000001.log"]
                .map { directory.appendingPathComponent($0) }
            for file in files {
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: file.path),
                    "persistent Core file must exist: \(file.lastPathComponent)")
                let resourceValues = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
                XCTAssertEqual(
                    resourceValues.isExcludedFromBackup,
                    true,
                    "Core-created file must be excluded from backup: \(file.lastPathComponent)")
#if os(iOS)
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                let protection = attributes[.protectionKey] as? FileProtectionType
#if targetEnvironment(simulator)
                if let protection {
                    XCTAssertEqual(
                        protection,
                        .completeUntilFirstUserAuthentication,
                        "Core-created file has an unexpected protection class: \(file.lastPathComponent)")
                }
#else
                XCTAssertEqual(
                    protection,
                    .completeUntilFirstUserAuthentication,
                    "Core-created file must expose CompleteUntilFirstUserAuthentication on a physical device: \(file.lastPathComponent)")
#endif
#endif
            }

            try adapter.close(withTimeout: 5)
        }

        // Re-open the same directory to exercise the explicit recover pass
        // against the manifest/checkpoint/segment written by the first Core.
        do {
            let recovered = try makeBridgeAdapter(
                requestTimeout: 0.2,
                maxLogCount: 1,
                persistenceMode: .buffered,
                persistentDirectory: directory.path)
            try recovered.open()
            XCTAssertFalse(recovered.isClosed)
            try recovered.close(withTimeout: 5)
        }
    }

    /// The bridge lock is the live-process exclusion. A second adapter for
    /// the same persistent directory must fail before it can unlink the first
    /// adapter's Core lease, and the first adapter must remain usable.
    func testPersistentDirectoryRejectsSecondLiveAdapter() throws {
        let producerID = "bridge-live-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))"
        let directory = try TLSProducerDirectory.defaultDirectoryURL(forProducerID: producerID)
        _ = try TLSProducerDirectory.createDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try makeBridgeAdapter(
            maxLogCount: 4,
            persistenceMode: .buffered,
            persistentDirectory: directory.path)
        defer { try? first.close(withTimeout: 5) }
        try first.open()

        XCTAssertThrowsError(try makeBridgeAdapter(
            maxLogCount: 4,
            persistenceMode: .buffered,
            persistentDirectory: directory.path)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, TLSRealCoreAdapterErrorDomain)
            XCTAssertEqual(nsError.code, TLSRealCoreAdapterErrorCode.createFailed.rawValue)
            XCTAssertEqual(
                (nsError.userInfo[TLSRealCoreAdapterErrorResultKey] as? NSNumber)?.intValue,
                3,
                "live-directory rejection must be a persistence error")
        }

        XCTAssertNoThrow(try first.addLog(
            withTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
            hashKey: nil,
            contents: ["message": "first-adapter-remains-usable"],
            flush: false))
    }

    /// The C Core writes a valid, recent lease. Reinstalling that lease after
    /// a clean close simulates a process killed before the Core's cleanup ran;
    /// the bridge must remove it under the process lock and reopen immediately
    /// instead of waiting for the Core's 60-second heartbeat timeout.
    func testPersistentDirectoryReopensImmediatelyWithStaleCoreLease() async throws {
        let producerID = "bridge-stale-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))"
        let directory = try TLSProducerDirectory.defaultDirectoryURL(forProducerID: producerID)
        _ = try TLSProducerDirectory.createDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try makeBridgeAdapter(
            persistenceMode: .buffered,
            persistentDirectory: directory.path)
        try first.open()
        let leaseURL = directory.appendingPathComponent("lease")
        let leaseSnapshot = try Data(contentsOf: leaseURL)
        try first.close(withTimeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaseURL.path))

        try leaseSnapshot.write(to: leaseURL, options: .atomic)

        let reopened = try makeBridgeAdapter(
            persistenceMode: .buffered,
            persistentDirectory: directory.path)
        try reopened.open()
        XCTAssertFalse(reopened.isClosed)
        try reopened.close(withTimeout: 5)
    }

    /// O_NOFOLLOW must reject a lock-file symlink before any Core file is
    /// touched. The target remains intact because the bridge never follows or
    /// unlinks it.
    func testPersistentDirectoryRejectsSymlinkLockFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tls-bridge-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [FileAttributeKey.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("lock-target")
        try Data("do-not-touch".utf8).write(to: target)
        let lock = directory.appendingPathComponent(".ios-producer.lock")
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)

        XCTAssertThrowsError(try makeBridgeAdapter(
            persistenceMode: .buffered,
            persistentDirectory: directory.path)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, TLSRealCoreAdapterErrorDomain)
            XCTAssertEqual(nsError.code, TLSRealCoreAdapterErrorCode.createFailed.rawValue)
            XCTAssertEqual(
                (nsError.userInfo[TLSRealCoreAdapterErrorResultKey] as? NSNumber)?.intValue,
                3,
                "symlink lock rejection must be a persistence error")
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("do-not-touch".utf8))
    }

    /// Core-owned files use the POSIX platform adapter. A pre-existing final
    /// component symlink must fail with O_NOFOLLOW before manifest creation or
    /// recovery can truncate/read its target.
    func testPersistentCoreFileSymlinkDoesNotTouchTarget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tls-core-file-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [FileAttributeKey.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("manifest-target")
        let sentinel = Data("do-not-read-or-truncate".utf8)
        try sentinel.write(to: target)
        let manifest = directory.appendingPathComponent("manifest")
        try FileManager.default.createSymbolicLink(
            at: manifest,
            withDestinationURL: target)

        do {
            let adapter = try makeBridgeAdapter(
                persistenceMode: .buffered,
                persistentDirectory: directory.path)
            defer { try? adapter.close(withTimeout: 1) }
            XCTAssertThrowsError(try adapter.open())
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, TLSRealCoreAdapterErrorDomain)
        }
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
    }

    /// URLProtocol intentionally never calls a client completion. The bridge
    /// must cancel the request at its hard deadline and emit one structured
    /// timeout result instead of returning a status-0 success or hanging the
    /// Core sender thread indefinitely.
    func testHTTPTimeoutWithoutURLProtocolCallbackIsBounded() async throws {
        RealCoreStubURLProtocol.setHanging(forPath: "/PutLogs")
        let adapter = try makeBridgeAdapter(requestTimeout: 0.1, maxLogCount: 1)
        let callback = BridgeCallbackCollector()
        let callbackExpectation = expectation(description: "timeout result")
        installCallback(on: adapter, collector: callback, expectation: callbackExpectation)
        try adapter.open()

        let started = Date()
        try addImmediateLog(to: adapter, value: "timeout")
        await fulfillment(of: [callbackExpectation], timeout: 8)
        let elapsed = Date().timeIntervalSince(started)

        let result = try XCTUnwrap(callback.first)
        XCTAssertNotEqual(result.result, 0)
        XCTAssertLessThan(elapsed, 6, "HTTP bridge timeout must be bounded")
        XCTAssertLessThanOrEqual(result.httpCode, 0)
        XCTAssertEqual(result.transportCode, TLSTransportErrorCode.requestTimeout.rawValue)
        XCTAssertEqual(result.errorMessage, "HTTP request timed out")
        XCTAssertEqual(callback.count, 1, "one accepted batch must have one terminal callback")

        try adapter.close(withTimeout: 5)
    }

    func testOversizedHTTPResponseIsNonRetryableAndEmitsOneTerminalResult() async throws {
        RealCoreStubURLProtocol.setResponse(
            statusCode: 200,
            body: Data(repeating: 0x41, count: 64 * 1024 + 1),
            requestID: "request-oversized",
            forPath: "/PutLogs")
        let adapter = try makeBridgeAdapter(requestTimeout: 1, maxLogCount: 1)
        let callback = BridgeCallbackCollector()
        let callbackExpectation = expectation(description: "oversized response result")
        installCallback(on: adapter, collector: callback, expectation: callbackExpectation)
        try adapter.open()

        try addImmediateLog(to: adapter, value: "oversized-response")
        await fulfillment(of: [callbackExpectation], timeout: 5)

        let result = try XCTUnwrap(callback.first)
        XCTAssertNotEqual(result.result, 0)
        XCTAssertEqual(result.transportCode, TLSTransportErrorCode.responseTooLarge.rawValue)
        XCTAssertFalse(result.retryable)
        XCTAssertEqual(result.errorMessage, "HTTP transport failed")
        XCTAssertEqual(callback.count, 1)
        XCTAssertEqual(RealCoreStubURLProtocol.recordedRequests().count, 1)

        try adapter.close(withTimeout: 5)
    }

    func testOfficialTLSRequestIDHeaderReachesCoreCallback() async throws {
        RealCoreStubURLProtocol.setResponse(
            statusCode: 200,
            requestID: "request-official-header",
            requestIDHeaderName: "X-Tls-Requestid",
            forPath: "/PutLogs")
        let adapter = try makeBridgeAdapter(requestTimeout: 1, maxLogCount: 1)
        let callback = BridgeCallbackCollector()
        let callbackExpectation = expectation(description: "official request ID callback")
        installCallback(on: adapter, collector: callback, expectation: callbackExpectation)
        try adapter.open()

        try addImmediateLog(to: adapter, value: "official-request-id")
        await fulfillment(of: [callbackExpectation], timeout: 5)

        let result = try XCTUnwrap(callback.first)
        XCTAssertEqual(result.result, 0)
        XCTAssertEqual(result.requestID, "request-official-header")
        XCTAssertEqual(callback.count, 1)
        try adapter.close(withTimeout: 5)
    }

    /// A zero-budget close while a request is in flight must throw and leave
    /// the Core retryable. Once the request reaches its own bounded timeout,
    /// a later close is allowed to complete and only then reports isClosed.
    func testCloseTimeoutRemainsRetryable() async throws {
        RealCoreStubURLProtocol.setHanging(forPath: "/PutLogs")
        let requestStarted = expectation(description: "request entered transport")
        RealCoreStubURLProtocol.expectNextRequest(requestStarted)
        let adapter = try makeBridgeAdapter(requestTimeout: 0.5, maxLogCount: 1)
        let callback = BridgeCallbackCollector()
        let callbackExpectation = expectation(description: "close retry send result")
        installCallback(on: adapter, collector: callback, expectation: callbackExpectation)
        try adapter.open()
        try addImmediateLog(to: adapter, value: "close-retry")

        // Prove the batch is actually in flight before asserting that a
        // zero-budget close must time out. Closing immediately after add is a
        // race: the Core may not have dequeued the batch yet and can then
        // legitimately report an already-drained success.
        await fulfillment(of: [requestStarted], timeout: 3)

        XCTAssertThrowsError(try adapter.close(withTimeout: 0)) { error in
            XCTAssertEqual((error as NSError).domain, TLSRealCoreAdapterErrorDomain)
            XCTAssertEqual((error as NSError).code, TLSRealCoreAdapterErrorCode.closeFailed.rawValue)
        }
        XCTAssertFalse(adapter.isClosed)

        // Let a subsequent retry finish quickly; the already-running hanging
        // request remains bounded by its own 500 ms deadline.
        RealCoreStubURLProtocol.setResponse(statusCode: 200, forPath: "/PutLogs")
        await fulfillment(of: [callbackExpectation], timeout: 8)
        try adapter.close(withTimeout: 10)
        XCTAssertTrue(adapter.isClosed)
    }

    /// Service statuses must survive the NSURLSession → C Core → ObjC bridge
    /// without forwarding the untrusted response body. Retryable statuses are
    /// retried by the C Core, but still produce one terminal callback.
    func testHTTPStatusesPreserveStructuredCallbackFields() async throws {
        let cases: [(status: Int, retryable: Bool)] = [
            (401, false), (403, false), (429, true), (500, true), (503, true)
        ]

        let untrustedMessage = "private=do-not-forward"
        for item in cases {
            let body = try makeServiceErrorBody(
                code: "ServiceCode",
                message: untrustedMessage)
            RealCoreStubURLProtocol.setResponse(
                statusCode: item.status,
                body: body,
                requestID: "request-\(item.status)",
                forPath: "/PutLogs")
            let adapter = try makeBridgeAdapter(requestTimeout: 0.2, maxLogCount: 1)
            let callback = BridgeCallbackCollector()
            let callbackExpectation = expectation(description: "HTTP \(item.status) result")
            installCallback(on: adapter, collector: callback, expectation: callbackExpectation)
            try adapter.open()
            try addImmediateLog(to: adapter, value: "status-\(item.status)")
            await fulfillment(of: [callbackExpectation], timeout: 12)

            let result = try XCTUnwrap(callback.first)
            XCTAssertNotEqual(result.result, 0)
            XCTAssertEqual(result.httpCode, item.status)
            XCTAssertEqual(result.errorCode, "ServiceCode")
            XCTAssertEqual(result.requestID, "request-\(item.status)")
            XCTAssertEqual(result.retryable, item.retryable)
            XCTAssertTrue(result.errorMessage?.contains(untrustedMessage) == false)
            XCTAssertEqual(callback.count, 1)
            try adapter.close(withTimeout: 5)
        }
    }

    /// Persistent `.retain` treats an authentication failure as a suspended
    /// delivery attempt, not a terminal batch result. Updating the complete
    /// credential group resumes that same batch, which must then produce its
    /// one and only terminal callback.
    func testPersistentAuthRetainEmitsOnlySuccessAfterCredentialUpdate() async throws {
        let producerID = "bridge-auth-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))"
        let directory = try TLSProducerDirectory.defaultDirectoryURL(forProducerID: producerID)
        _ = try TLSProducerDirectory.createDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let expiredCode = ["Expired", "To", "ken"].joined()
        RealCoreStubURLProtocol.setResponse(
            statusCode: 400,
            body: try makeServiceErrorBody(
                code: expiredCode,
                message: "authorization expired"),
            requestID: "auth-retain-first",
            forPath: "/PutLogs")
        let firstRequest = expectation(description: "persistent auth request reached transport")
        RealCoreStubURLProtocol.expectNextRequest(firstRequest)

        let prematureFailure = expectation(
            description: "auth retain must not emit a terminal failure")
        prematureFailure.isInverted = true
        let eventualSuccess = expectation(
            description: "credential update resumes retained batch once")
        let callback = BridgeCallbackCollector()
        let adapter = try makeBridgeAdapter(
            requestTimeout: 0.2,
            maxLogCount: 1,
            persistenceMode: .buffered,
            persistentDirectory: directory.path)
        adapter.onSendResult = {
            result, rawBytes, compressedBytes, httpCode, errorCode, errorMessage,
            requestID, transportKind, transportCode, retryable, startID, endID in
            callback.append(BridgeCallbackPayload(
                result: result,
                rawBytes: rawBytes,
                compressedBytes: compressedBytes,
                httpCode: httpCode,
                errorCode: errorCode,
                errorMessage: errorMessage,
                requestID: requestID,
                transportKind: transportKind,
                transportCode: transportCode,
                retryable: retryable,
                startID: startID,
                endID: endID))
            if result == 0 {
                eventualSuccess.fulfill()
            } else {
                prematureFailure.fulfill()
            }
        }

        try adapter.open()
        try addImmediateLog(to: adapter, value: "auth-retain")
        await fulfillment(of: [firstRequest], timeout: 3)
        await fulfillment(of: [prematureFailure], timeout: 0.5)

        RealCoreStubURLProtocol.setResponse(
            statusCode: 200,
            requestID: "auth-retain-success",
            forPath: "/PutLogs")
        let updatedCredentials = makeCredentials("updated")
        try adapter.updateCredentials(
            updatedCredentials.accessKeyID,
            accessKeySecret: updatedCredentials.accessKeySecret,
            securityToken: updatedCredentials.securityToken)

        await fulfillment(of: [eventualSuccess], timeout: 8)
        XCTAssertEqual(callback.count, 1)
        XCTAssertEqual(callback.first?.result, 0)
        XCTAssertEqual(callback.first?.requestID, "auth-retain-success")
        try adapter.close(withTimeout: 5)
    }

    /// TLS returns `HTTP 400 + ExpiredToken` for an expired STS. Under the
    /// persistent `.drop` policy that credential failure is terminal exactly
    /// once; it must not be retained indefinitely or mislabeled as a generic
    /// service failure by the public bridge.
    func testPersistentExpiredTokenDropEmitsOneTerminalFailure() async throws {
        let producerID = "bridge-auth-drop-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"
        let directory = try TLSProducerDirectory.defaultDirectoryURL(forProducerID: producerID)
        _ = try TLSProducerDirectory.createDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let expiredCode = ["Expired", "To", "ken"].joined()
        RealCoreStubURLProtocol.setResponse(
            statusCode: 400,
            body: try makeServiceErrorBody(
                code: expiredCode,
                message: "authorization expired"),
            requestID: "auth-drop-expired",
            forPath: "/PutLogs")
        let callback = BridgeCallbackCollector()
        let callbackExpectation = expectation(description: "expired STS drop result")
        let adapter = try makeBridgeAdapter(
            requestTimeout: 0.2,
            maxLogCount: 1,
            persistenceMode: .buffered,
            persistentDirectory: directory.path,
            authFailurePolicy: 1)
        installCallback(on: adapter, collector: callback, expectation: callbackExpectation)

        try adapter.open()
        try addImmediateLog(to: adapter, value: "auth-drop-expired")
        await fulfillment(of: [callbackExpectation], timeout: 8)

        let result = try XCTUnwrap(callback.first)
        XCTAssertNotEqual(result.result, 0)
        XCTAssertEqual(result.httpCode, 400)
        XCTAssertEqual(result.errorCode, expiredCode)
        XCTAssertEqual(callback.count, 1)
        try adapter.close(withTimeout: 5)
    }

    /// Exhausting one bounded retry cycle must not strand a durable batch
    /// until the process restarts. Retry-cycle failures are non-terminal for
    /// persistent delivery; the same live producer must retry later and emit
    /// exactly one success when the transport recovers.
    func testPersistentRetryExhaustionResumesWithoutRestart() async throws {
        let producerID = "bridge-retry-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))"
        let directory = try TLSProducerDirectory.defaultDirectoryURL(forProducerID: producerID)
        _ = try TLSProducerDirectory.createDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        RealCoreStubURLProtocol.setResponse(
            statusCode: 503,
            requestID: "retry-cycle-exhausted",
            forPath: "/PutLogs")
        let resumedSuccess = expectation(
            description: "persistent batch resumes in the same process")
        let prematureFailure = expectation(
            description: "retry-cycle exhaustion is not a terminal failure")
        prematureFailure.isInverted = true
        let callback = BridgeCallbackCollector()

        let adapter = try makeBridgeAdapter(
            requestTimeout: 0.2,
            maxLogCount: 1,
            persistenceMode: .buffered,
            persistentDirectory: directory.path)
        adapter.onSendResult = {
            result, rawBytes, compressedBytes, httpCode, errorCode, errorMessage,
            requestID, transportKind, transportCode, retryable, startID, endID in
            callback.append(BridgeCallbackPayload(
                result: result,
                rawBytes: rawBytes,
                compressedBytes: compressedBytes,
                httpCode: httpCode,
                errorCode: errorCode,
                errorMessage: errorMessage,
                requestID: requestID,
                transportKind: transportKind,
                transportCode: transportCode,
                retryable: retryable,
                startID: startID,
                endID: endID))
            if result == 0 {
                resumedSuccess.fulfill()
            } else {
                prematureFailure.fulfill()
            }
        }
        try adapter.open()
        try addImmediateLog(to: adapter, value: "retry-exhaustion")

        let requestDeadline = Date().addingTimeInterval(12)
        while RealCoreStubURLProtocol.recordedRequests().count < 3,
              Date() < requestDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(
            RealCoreStubURLProtocol.recordedRequests().count,
            3,
            "the first bounded retry cycle must complete")
        await fulfillment(of: [prematureFailure], timeout: 0.2)

        let resumedRequest = expectation(
            description: "old WAL batch is attempted again")
        RealCoreStubURLProtocol.expectNextRequest(resumedRequest)
        RealCoreStubURLProtocol.setResponse(
            statusCode: 200,
            requestID: "retry-cycle-resumed",
            forPath: "/PutLogs")

        await fulfillment(of: [resumedRequest, resumedSuccess], timeout: 5)
        XCTAssertEqual(callback.count, 1)
        XCTAssertEqual(callback.first?.result, 0)
        XCTAssertEqual(callback.first?.requestID, "retry-cycle-resumed")
        try adapter.close(withTimeout: 5)
    }

    /// A durable retry delayed for a later network window must not turn
    /// `close` into a remote-delivery wait. Closing releases only the live
    /// task; the WAL remains available to the next producer recovery.
    func testPersistentRetryDelayDoesNotBlockLocalClose() async throws {
        let producerID = "bridge-close-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))"
        let directory = try TLSProducerDirectory.defaultDirectoryURL(forProducerID: producerID)
        _ = try TLSProducerDirectory.createDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        RealCoreStubURLProtocol.setResponse(
            statusCode: 503,
            requestID: "retry-before-close",
            forPath: "/PutLogs")
        let callback = BridgeCallbackCollector()
        let adapter = try makeBridgeAdapter(
            requestTimeout: 0.2,
            maxLogCount: 1,
            persistenceMode: .buffered,
            persistentDirectory: directory.path)
        adapter.onSendResult = {
            result, rawBytes, compressedBytes, httpCode, errorCode, errorMessage,
            requestID, transportKind, transportCode, retryable, startID, endID in
            callback.append(BridgeCallbackPayload(
                result: result,
                rawBytes: rawBytes,
                compressedBytes: compressedBytes,
                httpCode: httpCode,
                errorCode: errorCode,
                errorMessage: errorMessage,
                requestID: requestID,
                transportKind: transportKind,
                transportCode: transportCode,
                retryable: retryable,
                startID: startID,
                endID: endID))
        }
        try adapter.open()
        try addImmediateLog(to: adapter, value: "retry-close")

        let requestDeadline = Date().addingTimeInterval(12)
        while RealCoreStubURLProtocol.recordedRequests().count < 3,
              Date() < requestDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(
            RealCoreStubURLProtocol.recordedRequests().count,
            3,
            "the first bounded retry cycle must complete")

        let closeStarted = Date()
        try adapter.close(withTimeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(closeStarted), 2)
        XCTAssertEqual(
            callback.count,
            0,
            "persisted-for-recovery is not a terminal delivery result")

        RealCoreStubURLProtocol.setResponse(
            statusCode: 200,
            requestID: "retry-after-close-recovery",
            forPath: "/PutLogs")
        let recoveredSuccess = expectation(
            description: "next producer recovers the delayed WAL batch")
        let recoveredCallback = BridgeCallbackCollector()
        let recovered = try makeBridgeAdapter(
            requestTimeout: 0.2,
            maxLogCount: 1,
            persistenceMode: .buffered,
            persistentDirectory: directory.path)
        installCallback(
            on: recovered,
            collector: recoveredCallback,
            expectation: recoveredSuccess)
        try recovered.open()
        await fulfillment(of: [recoveredSuccess], timeout: 5)
        XCTAssertEqual(recoveredCallback.count, 1)
        XCTAssertEqual(recoveredCallback.first?.result, 0)
        XCTAssertEqual(
            recoveredCallback.first?.requestID,
            "retry-after-close-recovery")
        try recovered.close(withTimeout: 5)
    }

    /// `dealloc` uses Core destroy rather than the public close path. Once a
    /// persistent task is in a long cross-cycle delay, destroy must honor the
    /// Core `stop` flag, release that live task, and eventually release the
    /// bridge directory lock without waiting for the retry timer.
    func testPersistentDelayedRetryDeallocationReleasesDirectory() async throws {
        let producerID = "bridge-destroy-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))"
        let directory = try TLSProducerDirectory.defaultDirectoryURL(forProducerID: producerID)
        _ = try TLSProducerDirectory.createDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        RealCoreStubURLProtocol.setResponse(
            statusCode: 503,
            requestID: "retry-before-destroy",
            forPath: "/PutLogs")
        weak var releasedAdapter: TLSRealCoreAdapter?
        var adapter: TLSRealCoreAdapter? = try makeBridgeAdapter(
            requestTimeout: 0.2,
            maxLogCount: 1,
            persistenceMode: .buffered,
            persistentDirectory: directory.path)
        releasedAdapter = adapter
        try adapter?.open()
        try addImmediateLog(
            to: try XCTUnwrap(adapter),
            value: "retry-destroy")

        // Five exhausted request cycles put the task on a cross-cycle delay
        // whose minimum jittered duration is over 2.6 seconds. This makes the
        // old `closing`-only destroy bug deterministic while keeping the
        // regression bounded.
        let requestDeadline = Date().addingTimeInterval(25)
        while RealCoreStubURLProtocol.recordedRequests().count < 15,
              Date() < requestDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(
            RealCoreStubURLProtocol.recordedRequests().count,
            15,
            "five bounded retry cycles must complete")
        try await Task.sleep(nanoseconds: 100_000_000)

        adapter = nil
        for _ in 0..<50 where releasedAdapter != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(releasedAdapter, "adapter deallocation must remain non-blocking")

        RealCoreStubURLProtocol.setResponse(
            statusCode: 200,
            requestID: "retry-after-destroy-recovery",
            forPath: "/PutLogs")
        let reopenDeadline = Date().addingTimeInterval(2)
        var reopened: TLSRealCoreAdapter?
        var lastOpenError: Error?
        while reopened == nil, Date() < reopenDeadline {
            do {
                reopened = try makeBridgeAdapter(
                    requestTimeout: 0.2,
                    maxLogCount: 1,
                    persistenceMode: .buffered,
                    persistentDirectory: directory.path)
            } catch {
                lastOpenError = error
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        guard let reopened else {
            XCTFail("async Core destroy did not release the directory lock: \(String(describing: lastOpenError))")
            return
        }
        try reopened.open()
        try reopened.close(withTimeout: 5)
    }

    /// A highly repetitive payload must take the LZ4 branch and report a
    /// smaller compressed byte count while preserving the raw count.
    func testLZ4CallbackReportsCompressedBytes() async throws {
        RealCoreStubURLProtocol.setResponse(statusCode: 200, forPath: "/PutLogs")
        let adapter = try makeBridgeAdapter(
            lz4Enabled: true,
            maxLogCount: 1,
            maxRawBytes: 4 * 1024 * 1024)
        let callback = BridgeCallbackCollector()
        let callbackExpectation = expectation(description: "LZ4 send result")
        installCallback(on: adapter, collector: callback, expectation: callbackExpectation)
        try adapter.open()

        let compressibleValue = String(repeating: "compressible-payload-", count: 100_000)
        try adapter.addLog(
            withTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
            hashKey: nil as String?,
            contents: ["message": compressibleValue],
            flush: true)
        await fulfillment(of: [callbackExpectation], timeout: 12)

        let result = try XCTUnwrap(callback.first)
        XCTAssertEqual(result.result, 0)
        XCTAssertGreaterThan(result.rawBytes, 0)
        XCTAssertGreaterThan(result.compressedBytes, 0)
        XCTAssertLessThan(result.compressedBytes, result.rawBytes)
        try adapter.close(withTimeout: 5)
    }

    /// The public 9.5 MiB raw-batch ceiling must also be the effective HTTP
    /// body ceiling when compression is disabled. The C Core defaults its
    /// compressed-body guard to 5 MiB; the iOS bridge must override that
    /// default or a valid public configuration is dropped before transport.
    func testUncompressedBatchAboveFiveMiBReachesHTTP() async throws {
        RealCoreStubURLProtocol.setResponse(statusCode: 200, forPath: "/PutLogs")
        let adapter = try makeBridgeAdapter(
            lz4Enabled: false,
            maxLogCount: 6,
            maxRawBytes: 19 * 512 * 1024,
            maxBufferBytes: 64 * 1024 * 1024,
            linger: 60)
        let callback = BridgeCallbackCollector()
        let callbackExpectation = expectation(description: "large uncompressed send result")
        installCallback(on: adapter, collector: callback, expectation: callbackExpectation)
        try adapter.open()

        let payload = String(repeating: "x", count: 900_000)
        for index in 0..<6 {
            try adapter.addLog(
                withTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
                hashKey: nil as String?,
                contents: [
                    "message": payload,
                    "sequence": String(index),
                ],
                flush: index == 5)
        }
        await fulfillment(of: [callbackExpectation], timeout: 12)

        let result = try XCTUnwrap(callback.first)
        XCTAssertEqual(result.result, 0, "valid >5 MiB public batch must not be dropped locally")
        XCTAssertNil(result.errorCode)
        XCTAssertGreaterThan(result.rawBytes, UInt(5 * 1024 * 1024))
        XCTAssertGreaterThan(result.compressedBytes, UInt(5 * 1024 * 1024))
        let requests = RealCoreStubURLProtocol.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        try adapter.close(withTimeout: 5)
    }

    func testLocalCorePayloadLimitFailureIsNotMisclassifiedAsTransport() {
        let mapped = RealCoreAdapter.mapSendFailure(
            result: 2,
            httpCode: -1,
            errorCode: "PayloadTooLarge",
            errorMessage: "HTTP transport failed",
            requestID: nil,
            transportKind: 2,
            transportCode: 0,
            retryable: false)

        XCTAssertEqual(mapped, .internal("C Core rejected a validated batch size"))
    }

    func testExpiredTokenHTTP400MapsToAuthWithoutGeneralizingAllBadRequests() {
        let expiredCode = ["Expired", "To", "ken"].joined()
        let expired = RealCoreAdapter.mapSendFailure(
            result: 2,
            httpCode: 400,
            errorCode: expiredCode,
            errorMessage: "authorization expired",
            requestID: "expired-request",
            transportKind: 0,
            transportCode: 0,
            retryable: false)
        XCTAssertEqual(expired, .auth)

        let invalidArgument = RealCoreAdapter.mapSendFailure(
            result: 2,
            httpCode: 400,
            errorCode: "InvalidArgument",
            errorMessage: "invalid request",
            requestID: "invalid-request",
            transportKind: 0,
            transportCode: 0,
            retryable: false)
        XCTAssertEqual(
            invalidArgument,
            .service(code: 400, message: "InvalidArgument", requestID: "invalid-request"))
    }

    /// Hash routing legitimately creates one ordered Core task per distinct
    /// key. The public byte buffer still has ample room here, so an internal
    /// auto-tuned task-slot count must not turn accepted logs into queueFull.
    func testHighCardinalityHashBatchesDoNotHitHiddenAutoQueueLimit() async throws {
        RealCoreStubURLProtocol.setResponse(
            statusCode: 200,
            delay: 0.02,
            forPath: "/PutLogs")
        let adapter = try makeBridgeAdapter(
            endpoint: "https://hash-cardinality.stub.local",
            maxLogCount: 1,
            maxRawBytes: 2 * 1024 * 1024,
            maxBufferBytes: 64 * 1024 * 1024,
            sendConcurrency: 4,
            linger: 60)
        let callback = BridgeCallbackCollector()
        let callbackExpectation = expectation(description: "all keyed batches complete")
        installCallback(
            on: adapter,
            collector: callback,
            expectation: callbackExpectation,
            expectedValueCount: 256)
        try adapter.open()

        for index in 0..<256 {
            try adapter.addLog(
                withTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
                hashKey: String(format: "%032llx", UInt64(index)),
                contents: ["sequence": String(index)],
                flush: true)
        }
        await fulfillment(of: [callbackExpectation], timeout: 20)

        let results = callback.all
        XCTAssertEqual(results.count, 256)
        XCTAssertEqual(
            results.filter { $0.result != 0 }.count,
            0,
            "accepted keyed batches must not fail at the hidden task-slot boundary")
        let requests = RealCoreStubURLProtocol.recordedRequests().filter {
            URL(string: $0.url)?.host == "hash-cardinality.stub.local"
        }
        XCTAssertEqual(requests.count, 256)
        try adapter.close(withTimeout: 5)
    }
}

private final class RealCoreDiagnosticCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [ProducerDiagnostic] = []

    var values: [ProducerDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    func append(_ value: ProducerDiagnostic) {
        lock.lock()
        _values.append(value)
        lock.unlock()
    }
}

private final class RealCoreSendResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [SendResult] = []

    var values: [SendResult] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    func append(_ value: SendResult) {
        lock.lock()
        _values.append(value)
        lock.unlock()
    }
}

private final class NSLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _accepted = 0
    private var _rejected = 0

    var accepted: Int {
        lock.lock()
        defer { lock.unlock() }
        return _accepted
    }

    var rejected: Int {
        lock.lock()
        defer { lock.unlock() }
        return _rejected
    }

    func record(accepted: Bool) {
        lock.lock()
        if accepted {
            _accepted += 1
        } else {
            _rejected += 1
        }
        lock.unlock()
    }
}
