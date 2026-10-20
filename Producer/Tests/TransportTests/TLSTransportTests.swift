// TLSTransportTests.swift
// TransportTests
//
// NSURLSession transport contract tests.
//
// All network is stubbed offline via a per-session NSURLProtocol subclass
// (TLSTestStubURLProtocol), so no real connection is ever made. The stub
// behavior registry is keyed by URL path, keeping tests safe even if test
// methods are parallelized.
//
// URLProtocol stubs exercise deterministic transport behavior without making
// external network requests.
//

import Foundation
import XCTest
import TLSProducerBridge
import VolcengineTLSProducer

private final class TransportResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var response: TLSHTTPResponse?

    func record(_ response: TLSHTTPResponse) {
        lock.lock()
        callCount += 1
        self.response = response
        lock.unlock()
    }

    var snapshot: (callCount: Int, response: TLSHTTPResponse?) {
        lock.lock()
        defer { lock.unlock() }
        return (callCount, response)
    }
}

private final class DiagnosticEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [[String: Any]] = []

    func record(_ fields: [String: Any]) {
        lock.lock()
        storedEvents.append(fields)
        lock.unlock()
    }

    var events: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func events(named event: String) -> [[String: Any]] {
        events.filter { $0["event"] as? String == event }
    }
}

private final class SyntheticTransactionMetrics: URLSessionTaskTransactionMetrics, @unchecked Sendable {
    override init() { super.init() }

    override var domainLookupStartDate: Date? { Date(timeIntervalSince1970: 100) }
    override var domainLookupEndDate: Date? { Date(timeIntervalSince1970: 101) }
    override var connectStartDate: Date? { Date(timeIntervalSince1970: 101) }
    override var connectEndDate: Date? { Date(timeIntervalSince1970: 102) }
    override var secureConnectionStartDate: Date? { Date(timeIntervalSince1970: 102) }
    override var secureConnectionEndDate: Date? { Date(timeIntervalSince1970: 103) }
    override var requestStartDate: Date? { Date(timeIntervalSince1970: 103) }
    override var requestEndDate: Date? { Date(timeIntervalSince1970: 104) }
    override var responseStartDate: Date? { Date(timeIntervalSince1970: 104) }
    override var responseEndDate: Date? { Date(timeIntervalSince1970: 105) }
    override var networkProtocolName: String? { "h2" }
    override var isReusedConnection: Bool { true }
}

private final class SyntheticTaskMetrics: URLSessionTaskMetrics, @unchecked Sendable {
    private let storedTransactions: [URLSessionTaskTransactionMetrics]

    init(transactions: [URLSessionTaskTransactionMetrics]) {
        storedTransactions = transactions
        super.init()
    }

    override var transactionMetrics: [URLSessionTaskTransactionMetrics] {
        storedTransactions
    }
}

// MARK: - Offline stub protocol

/// NSURLProtocol stub serving canned responses per URL path.
final class TLSTestStubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Behavior: Sendable {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
        /// Artificial delay before the response is delivered.
        var delay: TimeInterval
        /// When true, startLoading never calls back: the request stays open
        /// until the session cancels it (timeout/cancel tests).
        var neverRespond: Bool
        /// When set, a redirect response (status `statusCode`) with this
        /// Location header is delivered instead of a normal response.
        var redirectLocation: String?

        static func success(requestID: String? = nil, body: Data = Data()) -> Behavior {
            Behavior(
                statusCode: 200,
                headers: requestID.map { ["x-tls-request-id": $0] } ?? [:],
                body: body,
                delay: 0,
                neverRespond: false,
                redirectLocation: nil)
        }

        static let neverRespond = Behavior(
            statusCode: 0,
            headers: [:],
            body: Data(),
            delay: 0,
            neverRespond: true,
            redirectLocation: nil)
    }

    struct Failure: Sendable {
        let domain: String
        let code: Int
    }

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var behaviors: [String: Behavior] = [:]
        var failures: [String: Failure] = [:]
        var capturedTimeouts: [String: TimeInterval] = [:]
    }

    private static let registry = Registry()

    static func setBehavior(_ behavior: Behavior, forPath path: String) {
        registry.lock.lock()
        registry.behaviors[path] = behavior
        registry.lock.unlock()
    }

    static func setFailure(
        domain: String = NSURLErrorDomain,
        code: Int,
        forPath path: String
    ) {
        registry.lock.lock()
        registry.failures[path] = Failure(domain: domain, code: code)
        registry.lock.unlock()
    }

    static func capturedTimeout(forPath path: String) -> TimeInterval? {
        registry.lock.lock()
        let timeout = registry.capturedTimeouts[path]
        registry.lock.unlock()
        return timeout
    }

    static func reset() {
        registry.lock.lock()
        registry.behaviors.removeAll()
        registry.failures.removeAll()
        registry.capturedTimeouts.removeAll()
        registry.lock.unlock()
    }

    private static func behavior(for path: String) -> Behavior? {
        registry.lock.lock()
        let behavior = registry.behaviors[path]
        registry.lock.unlock()
        return behavior
    }

    private static func failure(for path: String) -> Failure? {
        registry.lock.lock()
        let failure = registry.failures[path]
        registry.lock.unlock()
        return failure
    }

    private static func captureTimeout(_ timeout: TimeInterval, forPath path: String) {
        registry.lock.lock()
        registry.capturedTimeouts[path] = timeout
        registry.lock.unlock()
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "https":
            return 443
        case "http":
            return 80
        default:
            return nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    private let cancelLock = NSLock()
    private var _cancelled = false

    private var cancelled: Bool {
        get {
            cancelLock.lock()
            let value = _cancelled
            cancelLock.unlock()
            return value
        }
        set {
            cancelLock.lock()
            _cancelled = newValue
            cancelLock.unlock()
        }
    }

    override func startLoading() {
        guard let path = request.url?.path else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "TLSTestStubURLProtocol",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "stub: request has no path"]))
            return
        }
        Self.captureTimeout(request.timeoutInterval, forPath: path)
        if let failure = Self.failure(for: path) {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: failure.domain,
                code: failure.code,
                userInfo: [NSLocalizedDescriptionKey: "stub failure"]))
            return
        }
        guard let behavior = Self.behavior(for: path) else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "TLSTestStubURLProtocol",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "stub: no behavior registered for path"]))
            return
        }
        if behavior.neverRespond {
            // Hold the request open without any callback until cancelled.
            return
        }
        if let location = behavior.redirectLocation {
            // NSURLSession does not reliably call willPerformHTTPRedirection
            // for responses delivered by a custom NSURLProtocol on the
            // simulator. This fixture may deliver a same-origin final response
            // directly for unrelated response-plumbing coverage; it does not
            // model the production signed-target redirect policy. That policy
            // is exercised only by RealHTTPSRedirectIntegrationTests.
            let originalHost = request.url?.host?.lowercased()
            let originalScheme = request.url?.scheme?.lowercased()
            if let redirectURL = URL(string: location),
               let redirectHost = redirectURL.host?.lowercased(),
               let redirectScheme = redirectURL.scheme?.lowercased(),
               redirectHost == originalHost,
               redirectScheme == originalScheme,
               Self.effectivePort(for: request.url!) == Self.effectivePort(for: redirectURL),
               let redirectBehavior = Self.behavior(for: redirectURL.path) {
                // Same-host redirect: deliver the final response directly.
                let finalResponse = HTTPURLResponse(
                    url: redirectURL,
                    statusCode: redirectBehavior.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: redirectBehavior.headers)!
                client?.urlProtocol(self, didReceive: finalResponse, cacheStoragePolicy: .notAllowed)
                if !redirectBehavior.body.isEmpty {
                    client?.urlProtocol(self, didLoad: redirectBehavior.body)
                }
                client?.urlProtocolDidFinishLoading(self)
            } else {
                // Cross-host/cross-scheme: deliver the 302 as-is.
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: behavior.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": location])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        let deliver: @Sendable () -> Void = { [weak self] in
            guard let self = self, !self.cancelled else { return }
            let response = HTTPURLResponse(
                url: self.request.url!,
                statusCode: behavior.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: behavior.headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !behavior.body.isEmpty {
                self.client?.urlProtocol(self, didLoad: behavior.body)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if behavior.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + behavior.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {
        cancelled = true
    }
}

// MARK: - Tests

final class TLSTransportTests: XCTestCase {

    /// `Behavior` is nested in TLSTestStubURLProtocol; alias it for the test
    /// class so call sites stay readable.
    private typealias Behavior = TLSTestStubURLProtocol.Behavior

    private var transport: TLSTransport!

    override func setUp() async throws {
        try await super.setUp()
        TLSTestStubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TLSTestStubURLProtocol.self]
        // Swift imports the ObjC `initWithConfiguration:error:` (nullable +
        // NSError** last) as a throwing initializer; the error: parameter is
        // consumed by `throws`.
        transport = try TLSTransport(configuration: config)
        XCTAssertNotNil(transport, "transport must be constructed")
    }

    override func tearDown() {
        transport?.invalidate()
        transport = nil
        TLSTestStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Helpers

    private func makeRequest(
        path: String,
        host: String = "tls-test.example",
        connectTimeout: TimeInterval = 5,
        idleTimeout: TimeInterval? = nil,
        requestTimeout: TimeInterval = 10,
        headers: [String: String]? = nil,
        body: Data = Data()
    ) -> TLSHTTPRequest {
        if let idleTimeout {
            return TLSHTTPRequest(
                method: "POST",
                urlString: "https://\(host)\(path)",
                headers: headers,
                body: body,
                connectTimeout: connectTimeout,
                idleTimeout: idleTimeout,
                requestTimeout: requestTimeout)
        }
        return TLSHTTPRequest(
            method: "POST",
            urlString: "https://\(host)\(path)",
            headers: headers,
            body: body,
            connectTimeout: connectTimeout,
            requestTimeout: requestTimeout)
    }

    private func transportQueueForTesting() -> DispatchQueue? {
        transport.value(forKey: "queue") as? DispatchQueue
    }

    /// Reads the real task created by `performRequest:` without adding a
    /// production-only test hook. The lookup is serialized on the same queue
    /// that owns the context dictionaries, so the delegate calls below model
    /// URLSession's actual callback queue.
    private func taskForRequestID(
        _ requestID: String,
        timeout: TimeInterval = 5
    ) -> URLSessionDataTask? {
        guard let queue = transportQueueForTesting() else {
            XCTFail("transport queue must be available")
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var task: URLSessionDataTask?
            queue.sync {
                guard let contexts = transport.value(forKey: "contextsByID") as? [String: Any],
                      let context = contexts[requestID] as? NSObject else {
                    return
                }
                task = context.value(forKey: "task") as? URLSessionDataTask
            }
            if let task {
                return task
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("request task must become visible before delegate simulation")
        return nil
    }

    private func lateMetricsCountForTesting() -> Int? {
        guard let queue = transportQueueForTesting() else {
            XCTFail("transport queue must be available")
            return nil
        }
        var count: Int?
        queue.sync {
            count = (transport.value(forKey: "lateMetricsByTaskID") as? NSDictionary)?.count
        }
        return count
    }

    private func expireLateMetricsRecordForTesting(task: URLSessionDataTask) {
        guard let queue = transportQueueForTesting() else {
            XCTFail("transport queue must be available")
            return
        }
        queue.sync {
            guard let records = transport.value(forKey: "lateMetricsByTaskID") as? NSDictionary,
                  let record = records[NSNumber(value: task.taskIdentifier)] as? NSObject else {
                XCTFail("late metrics record must exist before TTL check")
                return
            }
            record.setValue(ProcessInfo.processInfo.systemUptime - 1, forKey: "expiresAt")
        }
    }

    private func startHeldRequest(
        path: String,
        attemptID: String,
        body: Data = Data()
    ) -> (requestID: String, task: URLSessionDataTask, completion: XCTestExpectation)? {
        TLSTestStubURLProtocol.setBehavior(.neverRespond, forPath: path)
        let completionExpectation = expectation(description: "held request completion \(path)")
        let request = TLSHTTPRequest(
            method: "POST",
            urlString: "https://tls-test.example\(path)",
            headers: nil,
            body: body,
            connectTimeout: 5,
            idleTimeout: 5,
            requestTimeout: 30,
            diagnosticContext: ["attempt_id": attemptID])
        guard let requestID = transport.perform(request, completionHandler: { _ in
            completionExpectation.fulfill()
        }) else {
            XCTFail("held request must return an ID")
            return nil
        }
        guard let task = taskForRequestID(requestID) else {
            return nil
        }
        return (requestID, task, completionExpectation)
    }

    private func cancelHeldRequest(
        path: String,
        attemptID: String,
        body: Data = Data()
    ) -> (requestID: String, task: URLSessionDataTask)? {
        guard let started = startHeldRequest(path: path, attemptID: attemptID, body: body) else {
            return nil
        }
        let requestID = started.requestID
        let task = started.task
        transport.cancelRequest(withID: requestID)
        wait(for: [started.completion], timeout: 5)
        return (requestID, task)
    }

    private func finishHeldRequestViaDelegate(
        _ request: (requestID: String, task: URLSessionDataTask, completion: XCTestExpectation)
    ) {
        guard let queue = transportQueueForTesting() else {
            XCTFail("transport queue must be available")
            return
        }
        queue.sync {
            transport.urlSession(
                URLSession.shared,
                task: request.task,
                didCompleteWithError: NSError(domain: "SyntheticMetrics", code: 1))
        }
        wait(for: [request.completion], timeout: 5)
    }

    @discardableResult
    private func performSync(_ request: TLSHTTPRequest, timeout: TimeInterval = 10) -> TLSHTTPResponse? {
        let exp = expectation(description: "request completion")
        var result: TLSHTTPResponse?
        let id = transport.perform(request) { response in
            result = response
            exp.fulfill()
        }
        XCTAssertNotNil(id, "a started/valid request must return an ID")
        wait(for: [exp], timeout: timeout)
        return result
    }

    /// Documents the Core-layer classification contract
    /// for HTTP statuses. The transport itself stays dumb: it propagates the
    /// status code with error == nil for every HTTP response; auth/quota/
    /// service classification is the Core layer's job.
    private func expectedCoreError(for status: Int) -> ProducerError? {
        switch status {
        case 200..<300:
            return nil
        case 401, 403:
            return .auth
        case 429:
            return .quota
        case 400..<500:
            return .service(code: status, message: "", requestID: nil)
        case 500..<600:
            return .service(code: status, message: "", requestID: nil)
        default:
            return .`internal`("unexpected HTTP status \(status)")
        }
    }

    // MARK: Status matrix

    func testStatusMatrixPropagatesStatusAndLeavesClassificationToCore() {
        let statuses = [200, 400, 401, 403, 413, 429, 500, 502, 503, 504]
        for status in statuses {
            let path = "/status-\(status)"
            let requestID = "req-\(status)"
            let body = Data("body-\(status)".utf8)
            TLSTestStubURLProtocol.setBehavior(
                Behavior(
                    statusCode: status,
                    headers: ["x-tls-request-id": requestID],
                    body: body,
                    delay: 0,
                    neverRespond: false,
                    redirectLocation: nil),
                forPath: path)

            let response = performSync(makeRequest(path: path, body: Data("payload".utf8)))

            XCTAssertNotNil(response, "status \(status) must complete")
            XCTAssertEqual(response?.statusCode, status, "status \(status) propagated")
            // Every HTTP response is a transport-level success; 4xx/5xx
            // classification belongs to Core.
            XCTAssertNil(response?.error, "status \(status) must not be a transport error")
            XCTAssertEqual(response?.requestID, requestID, "status \(status) requestID")
            XCTAssertEqual(response?.body, body, "status \(status) body")

            // Document the Core classification contract.
            switch status {
            case 200..<300:
                XCTAssertNil(expectedCoreError(for: status))
            case 401, 403:
                XCTAssertEqual(expectedCoreError(for: status), .auth)
            case 429:
                XCTAssertEqual(expectedCoreError(for: status), .quota)
            case 400..<500:
                XCTAssertEqual(
                    expectedCoreError(for: status),
                    .service(code: status, message: "", requestID: nil))
            case 500..<600:
                XCTAssertEqual(
                    expectedCoreError(for: status),
                    .service(code: status, message: "", requestID: nil))
            default:
                XCTFail("unexpected status \(status)")
            }
        }
    }

    func testOversizedResponseBodyIsRejectedWithoutReturningPartialBytes() {
        let oversizedBody = Data(repeating: 0x41, count: 64 * 1024 + 1)
        TLSTestStubURLProtocol.setBehavior(
            .success(requestID: "rid-oversized", body: oversizedBody),
            forPath: "/oversized-response")

        let response = performSync(makeRequest(path: "/oversized-response"))

        let error = response?.error as NSError?
        XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
        XCTAssertEqual(error?.code, 2107)
        XCTAssertEqual(error?.userInfo[TLSTransportErrorRetryableKey] as? Bool, false)
        XCTAssertTrue(response?.body.isEmpty ?? false)
        XCTAssertEqual(response?.requestID, "rid-oversized")
    }

    func testResponseBodyAtSafetyLimitIsAccepted() {
        let bodyAtLimit = Data(repeating: 0x42, count: 64 * 1024)
        TLSTestStubURLProtocol.setBehavior(
            .success(requestID: "rid-at-limit", body: bodyAtLimit),
            forPath: "/response-at-limit")

        let response = performSync(makeRequest(path: "/response-at-limit"))

        XCTAssertNil(response?.error)
        XCTAssertEqual(response?.body, bodyAtLimit)
        XCTAssertEqual(response?.requestID, "rid-at-limit")
    }

    // MARK: Redirect

    func testCustomProtocolCanDeliverSimulatedSameOriginFinalResponse() {
        TLSTestStubURLProtocol.setBehavior(
            Behavior(
                statusCode: 302,
                headers: [:],
                body: Data(),
                delay: 0,
                neverRespond: false,
                redirectLocation: "https://tls-test.example/redirect-final"),
            forPath: "/redirect-same")
        TLSTestStubURLProtocol.setBehavior(
            Behavior.success(requestID: "rid-final", body: Data("final".utf8)),
            forPath: "/redirect-final")

        let response = performSync(makeRequest(path: "/redirect-same"))

        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertNil(response?.error)
        XCTAssertEqual(response?.requestID, "rid-final")
        XCTAssertEqual(response?.body, Data("final".utf8))
    }

    func testCustomProtocolTreatsExplicit443AsDefaultPort() {
        TLSTestStubURLProtocol.setBehavior(
            Behavior(
                statusCode: 302,
                headers: [:],
                body: Data(),
                delay: 0,
                neverRespond: false,
                redirectLocation: "https://TLS-TEST.EXAMPLE:443/redirect-final-443"),
            forPath: "/redirect-default-443")
        TLSTestStubURLProtocol.setBehavior(
            Behavior.success(requestID: "rid-final-443", body: Data("final-443".utf8)),
            forPath: "/redirect-final-443")

        let response = performSync(makeRequest(path: "/redirect-default-443"))

        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertNil(response?.error)
        XCTAssertEqual(response?.requestID, "rid-final-443")
        XCTAssertEqual(response?.body, Data("final-443".utf8))
    }

    func testCustomProtocolDoesNotSimulateDifferentPortRedirect() {
        TLSTestStubURLProtocol.setBehavior(
            Behavior(
                statusCode: 302,
                headers: [:],
                body: Data(),
                delay: 0,
                neverRespond: false,
                redirectLocation: "https://tls-test.example:8443/redirect-final-port"),
            forPath: "/redirect-cross-port")
        TLSTestStubURLProtocol.setBehavior(
            Behavior.success(requestID: "rid-should-not-follow"),
            forPath: "/redirect-final-port")

        let response = performSync(makeRequest(path: "/redirect-cross-port"))

        // Custom NSURLProtocol responses do not invoke the URLSession redirect
        // delegate reliably on the simulator. The transport therefore sees
        // the original 302; importantly, the cross-port final response is
        // never delivered.
        XCTAssertEqual(response?.statusCode, 302)
        XCTAssertNil(response?.error)
        XCTAssertNil(response?.requestID)
    }

    func testCustomProtocolCrossHostRedirectDoesNotExerciseDelegate() {
        // NOTE: NSURLSession does not reliably call willPerformHTTPRedirection
        // for custom-NSURLProtocol responses on the simulator, so the stub
        // delivers the 302 as-is. The transport's redirect-delegate
        // rejection logic is intentionally proved by the real HTTPS redirect
        // integration tests instead. This test documents only the stub's
        // observable behavior: the 302 response is returned unchanged.
        TLSTestStubURLProtocol.setBehavior(
            Behavior(
                statusCode: 302,
                headers: ["x-tls-request-id": "rid-redirect"],
                body: Data(),
                delay: 0,
                neverRespond: false,
                redirectLocation: "https://tls-other.example/redirect-final"),
            forPath: "/redirect-cross")

        let response = performSync(makeRequest(path: "/redirect-cross"))

        // The 302 is delivered as a normal response (no redirect error
        // because the delegate was not invoked by the custom protocol).
        XCTAssertEqual(response?.statusCode, 302)
        XCTAssertNil(response?.error)
    }

    func testCustomProtocolCrossSchemeRedirectDoesNotExerciseDelegate() {
        // Same caveat as the cross-host stub test: the stub delivers
        // the 307 as-is; the transport's redirect-delegate rejection is not
        // exercised through the custom protocol on the simulator.
        TLSTestStubURLProtocol.setBehavior(
            Behavior(
                statusCode: 307,
                headers: [:],
                body: Data(),
                delay: 0,
                neverRespond: false,
                redirectLocation: "http://tls-test.example/redirect-final"),
            forPath: "/redirect-http")

        let response = performSync(makeRequest(path: "/redirect-http"))

        XCTAssertEqual(response?.statusCode, 307)
        XCTAssertNil(response?.error)
    }

    // MARK: Timeout

    func testRequestTimeoutFiresHardDeadline() {
        TLSTestStubURLProtocol.setBehavior(.neverRespond, forPath: "/timeout")
        let start = Date()

        let response = performSync(
            makeRequest(path: "/timeout", requestTimeout: 0.5),
            timeout: 10)

        let elapsed = Date().timeIntervalSince(start)
        let error = response?.error as NSError?
        XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
        XCTAssertEqual(error?.code, TLSTransportErrorCode.requestTimeout.rawValue)
        // The hard deadline must fire around 0.5s, well before URLSession's
        // own 60s default.
        XCTAssertGreaterThanOrEqual(elapsed, 0.4)
        XCTAssertLessThan(elapsed, 5.0)
    }

    func testDiagnosticContextIsWhitelistedAndTransportFinishedUsesSDKDeadlineSource() {
        TLSTestStubURLProtocol.setBehavior(.neverRespond, forPath: "/diagnostic-sdk-timeout")
        let eventExpectation = expectation(description: "transport diagnostic")
        let lock = NSLock()
        var finished: [String: Any]?
        transport.diagnosticSink = { fields in
            guard fields["event"] as? String == "transport_finished" else { return }
            lock.lock()
            finished = fields
            lock.unlock()
            eventExpectation.fulfill()
        }
        let request = TLSHTTPRequest(
            method: "POST",
            urlString: "https://tls-test.example/diagnostic-sdk-timeout",
            headers: ["X-Diagnostic-Header": "must-not-be-copied"],
            body: Data("payload".utf8),
            connectTimeout: 5,
            idleTimeout: 5,
            requestTimeout: 0.1,
            diagnosticContext: [
                "batch_start_id": 11,
                "batch_end_id": 17,
                "attempt_id": "attempt-1",
                "counters": ["attempt_count": 2, "cycle_attempt_count": 1],
                "private": "drop-me"
            ])
        XCTAssertEqual(request.diagnosticContext?["batch_start_id"] as? Int, 11)
        XCTAssertEqual(request.diagnosticContext?["batch_end_id"] as? Int, 17)
        XCTAssertEqual(request.diagnosticContext?["attempt_id"] as? String, "attempt-1")
        XCTAssertNil(request.diagnosticContext?["private"])
        let counters = request.diagnosticContext?["counters"] as? [String: NSNumber]
        XCTAssertEqual(counters?["attempt_count"]?.intValue, 2)
        XCTAssertEqual(counters?["cycle_attempt_count"]?.intValue, 1)
        XCTAssertNil(counters?["private"])

        let response = performSync(request, timeout: 5)
        wait(for: [eventExpectation], timeout: 2)

        XCTAssertEqual((response?.error as NSError?)?.code,
                       TLSTransportErrorCode.requestTimeout.rawValue)
        lock.lock()
        let fields = finished
        lock.unlock()
        XCTAssertEqual(fields?["source"] as? String, "transport")
        XCTAssertEqual(fields?["timeout_source"] as? String, "sdk_request_deadline")
        XCTAssertEqual(fields?["transport_code"] as? Int,
                       TLSTransportErrorCode.requestTimeout.rawValue)
        XCTAssertEqual(fields?["batch_start_id"] as? Int, 11)
        XCTAssertEqual(fields?["batch_end_id"] as? Int, 17)
        XCTAssertEqual(fields?["attempt_id"] as? String, "attempt-1")
        XCTAssertNotNil(fields?["duration_ms"] as? Double)
    }

    func testURLSessionTimeoutDiagnosticKeepsUnderlyingNamespace() {
        TLSTestStubURLProtocol.setFailure(code: NSURLErrorTimedOut, forPath: "/diagnostic-urlsession-timeout")
        let eventExpectation = expectation(description: "urlsession timeout diagnostic")
        let lock = NSLock()
        var finished: [String: Any]?
        transport.diagnosticSink = { fields in
            guard fields["event"] as? String == "transport_finished" else { return }
            lock.lock()
            finished = fields
            lock.unlock()
            eventExpectation.fulfill()
        }

        let response = performSync(makeRequest(path: "/diagnostic-urlsession-timeout"))
        wait(for: [eventExpectation], timeout: 2)
        XCTAssertEqual((response?.error as NSError?)?.code,
                       TLSTransportErrorCode.requestTimeout.rawValue)
        lock.lock()
        let fields = finished
        lock.unlock()
        XCTAssertEqual(fields?["timeout_source"] as? String, "urlsession_timeout")
        XCTAssertEqual(fields?["underlying_error_domain"] as? String, NSURLErrorDomain)
        XCTAssertEqual(fields?["underlying_error_code"] as? Int, NSURLErrorTimedOut)
        XCTAssertEqual(fields?["transport_error_domain"] as? String, TLSTransportErrorDomain)
    }

    func testDiagnosticUnderlyingNamespacePreservesCocoaSource() {
        TLSTestStubURLProtocol.setFailure(
            domain: NSCocoaErrorDomain,
            code: 4,
            forPath: "/diagnostic-cocoa-error")
        let recorder = DiagnosticEventRecorder()
        transport.diagnosticSink = { fields in recorder.record(fields) }

        let response = performSync(makeRequest(path: "/diagnostic-cocoa-error"))
        let finished = recorder.events(named: "transport_finished").first

        XCTAssertEqual((response?.error as NSError?)?.domain, TLSTransportErrorDomain)
        XCTAssertEqual((response?.error as NSError?)?.code,
                       TLSTransportErrorCode.transportFailure.rawValue)
        XCTAssertEqual(finished?["underlying_error_domain"] as? String, NSCocoaErrorDomain)
        XCTAssertEqual(finished?["underlying_error_code"] as? Int, 4)
    }

    func testDiagnosticUnknownUnderlyingNamespaceIsNull() {
        TLSTestStubURLProtocol.setFailure(
            domain: "Sensitive.Custom.Domain",
            code: 77,
            forPath: "/diagnostic-unknown-error-domain")
        let recorder = DiagnosticEventRecorder()
        transport.diagnosticSink = { fields in recorder.record(fields) }

        let response = performSync(makeRequest(path: "/diagnostic-unknown-error-domain"))
        let finished = recorder.events(named: "transport_finished").first

        XCTAssertEqual((response?.error as NSError?)?.domain, TLSTransportErrorDomain)
        XCTAssertEqual((response?.error as NSError?)?.code,
                       TLSTransportErrorCode.transportFailure.rawValue)
        XCTAssertTrue(finished?["underlying_error_domain"] is NSNull)
        XCTAssertEqual(finished?["underlying_error_code"] as? Int, 77)
        XCTAssertEqual(finished?["fields_omitted"] as? Bool, true)
    }

    func testIdleTimeoutIsAppliedIndependentlyOfOuterDeadline() {
        TLSTestStubURLProtocol.setBehavior(.success(requestID: "rid-idle"), forPath: "/idle-knobs")

        let request = makeRequest(
            path: "/idle-knobs",
            connectTimeout: 10,
            idleTimeout: 0.125,
            requestTimeout: 2)
        let response = performSync(request)

        XCTAssertNil(response?.error)
        XCTAssertEqual(request.connectTimeout, 10, accuracy: 0.0001)
        XCTAssertEqual(request.idleTimeout, 0.125, accuracy: 0.0001)
        XCTAssertEqual(request.requestTimeout, 2, accuracy: 0.0001)
        guard let capturedTimeout = TLSTestStubURLProtocol.capturedTimeout(forPath: "/idle-knobs") else {
            return XCTFail("stub must capture the request timeout")
        }
        XCTAssertEqual(capturedTimeout, 0.125, accuracy: 0.0001)
    }

    func testLegacyInitializerForwardsConnectTimeoutAsIdleTimeout() {
        let request = TLSHTTPRequest(
            method: "POST",
            urlString: "https://tls-test.example/legacy-timeouts",
            headers: nil,
            body: nil,
            connectTimeout: 0.25,
            requestTimeout: 3)

        XCTAssertEqual(request.connectTimeout, 0.25, accuracy: 0.0001)
        XCTAssertEqual(request.idleTimeout, 0.25, accuracy: 0.0001)
        XCTAssertEqual(request.requestTimeout, 3, accuracy: 0.0001)
    }

    func testInvalidTimeoutValuesAreRejectedWithoutStartingURLSession() {
        let invalidRequests: [TLSHTTPRequest] = [
            makeRequest(path: "/invalid-timeout-nan", connectTimeout: .nan),
            makeRequest(path: "/invalid-timeout-infinity", idleTimeout: .infinity),
            makeRequest(path: "/invalid-timeout-negative", requestTimeout: -1),
            makeRequest(
                path: "/invalid-timeout-range",
                idleTimeout: TimeInterval(Int32.max) / 1_000 + 1)
        ]

        for request in invalidRequests {
            let response = performSync(request)
            let error = response?.error as NSError?
            XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
            XCTAssertEqual(error?.code, TLSTransportErrorCode.invalidURL.rawValue)
            XCTAssertEqual(error?.userInfo[TLSTransportErrorRetryableKey] as? Bool, false)
        }
    }

    func testShortConnectTimeoutDoesNotBreakInstantResponses() {
        // The legacy initializer forwards connectTimeout to idleTimeout; an
        // instant stub response must still win with a tiny idle budget.
        TLSTestStubURLProtocol.setBehavior(.success(requestID: "rid-fast"), forPath: "/connect-ok")

        let response = performSync(
            TLSHTTPRequest(
                method: "POST",
                urlString: "https://tls-test.example/connect-ok",
                headers: nil,
                body: nil,
                connectTimeout: 0.01,
                requestTimeout: 10))

        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertNil(response?.error)
        XCTAssertEqual(response?.requestID, "rid-fast")
    }

    // MARK: Cancel

    func testCancelCompletesExactlyOnceWithCancelledError() {
        TLSTestStubURLProtocol.setBehavior(.neverRespond, forPath: "/cancel")
        let exp = expectation(description: "cancelled completion")
        var callCount = 0
        var received: TLSHTTPResponse?

        let id = transport.perform(
            makeRequest(path: "/cancel", requestTimeout: 30)) { response in
                callCount += 1
                received = response
                exp.fulfill()
            }
        XCTAssertNotNil(id)
        transport.cancelRequest(withID: id!)

        wait(for: [exp], timeout: 5)
        XCTAssertEqual(callCount, 1)
        let error = received?.error as NSError?
        XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
        XCTAssertEqual(error?.code, TLSTransportErrorCode.cancelled.rawValue)
        XCTAssertEqual(error?.userInfo[TLSTransportErrorRetryableKey] as? Bool, false)

        // Give URLSession room to deliver any late cancellation callbacks;
        // the completion must still have fired exactly once.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(callCount, 1, "no second completion")
    }

    func testExplicitCancelDiagnosticRecordsCancelSource() {
        TLSTestStubURLProtocol.setBehavior(.neverRespond, forPath: "/diagnostic-explicit-cancel")
        let eventExpectation = expectation(description: "explicit cancel diagnostic")
        let lock = NSLock()
        var finished: [String: Any]?
        transport.diagnosticSink = { fields in
            guard fields["event"] as? String == "transport_finished" else { return }
            lock.lock()
            finished = fields
            lock.unlock()
            eventExpectation.fulfill()
        }
        let completionExpectation = expectation(description: "cancelled completion")
        let id = transport.perform(makeRequest(path: "/diagnostic-explicit-cancel")) { _ in
            completionExpectation.fulfill()
        }
        XCTAssertNotNil(id)
        transport.cancelRequest(withID: id!)
        wait(for: [completionExpectation, eventExpectation], timeout: 5)
        lock.lock()
        let fields = finished
        lock.unlock()
        XCTAssertEqual(fields?["cancel_source"] as? String, "explicit_cancel")
    }

    func testInvalidateDiagnosticRecordsInvalidateSource() {
        TLSTestStubURLProtocol.setBehavior(.neverRespond, forPath: "/diagnostic-invalidate")
        let eventExpectation = expectation(description: "invalidate diagnostic")
        let lock = NSLock()
        var finished: [String: Any]?
        transport.diagnosticSink = { fields in
            guard fields["event"] as? String == "transport_finished" else { return }
            lock.lock()
            finished = fields
            lock.unlock()
            eventExpectation.fulfill()
        }
        let completionExpectation = expectation(description: "invalidated completion")
        let id = transport.perform(makeRequest(path: "/diagnostic-invalidate")) { _ in
            completionExpectation.fulfill()
        }
        XCTAssertNotNil(id)
        transport.invalidate()
        wait(for: [completionExpectation, eventExpectation], timeout: 5)
        lock.lock()
        let fields = finished
        lock.unlock()
        XCTAssertEqual(fields?["cancel_source"] as? String, "invalidate")
    }

    func testUnknownURLSessionCancellationDiagnosticDoesNotGuessBackground() {
        TLSTestStubURLProtocol.setFailure(code: NSURLErrorCancelled, forPath: "/diagnostic-unknown-cancel")
        let eventExpectation = expectation(description: "unknown cancel diagnostic")
        let lock = NSLock()
        var finished: [String: Any]?
        transport.diagnosticSink = { fields in
            guard fields["event"] as? String == "transport_finished" else { return }
            lock.lock()
            finished = fields
            lock.unlock()
            eventExpectation.fulfill()
        }
        let response = performSync(makeRequest(path: "/diagnostic-unknown-cancel"))
        wait(for: [eventExpectation], timeout: 2)
        XCTAssertEqual((response?.error as NSError?)?.code,
                       TLSTransportErrorCode.cancelled.rawValue)
        lock.lock()
        let fields = finished
        lock.unlock()
        XCTAssertEqual(fields?["cancel_source"] as? String, "unknown")
    }

    func testDiagnosticDelegateAccumulatesPartialUploadAndUsesNullWithoutCallback() {
        let recorder = DiagnosticEventRecorder()
        transport.diagnosticSink = { fields in recorder.record(fields) }

        guard let partial = startHeldRequest(
            path: "/diagnostic-partial-upload",
            attemptID: "attempt-partial",
            body: Data(repeating: 0x41, count: 16)),
              let queue = transportQueueForTesting() else {
            return
        }
        queue.sync {
            transport.urlSession(
                URLSession.shared,
                task: partial.task,
                didSendBodyData: 5,
                totalBytesSent: 5,
                totalBytesExpectedToSend: 16)
            transport.urlSession(
                URLSession.shared,
                task: partial.task,
                didSendBodyData: 3,
                totalBytesSent: 8,
                totalBytesExpectedToSend: 16)
        }
        transport.cancelRequest(withID: partial.requestID)
        wait(for: [partial.completion], timeout: 5)

        let partialFinished = recorder.events(named: "transport_finished").first {
            $0["attempt_id"] as? String == "attempt-partial"
        }
        XCTAssertEqual(partialFinished?["sent_body_bytes"] as? Int, 8)
        XCTAssertEqual(partialFinished?["expected_body_bytes"] as? Int, 16)

        guard cancelHeldRequest(
            path: "/diagnostic-no-upload-callback",
            attemptID: "attempt-no-callback",
            body: Data(repeating: 0x42, count: 16)) != nil else {
            return
        }
        let noCallbackFinished = recorder.events(named: "transport_finished").first {
            $0["attempt_id"] as? String == "attempt-no-callback"
        }
        XCTAssertTrue(noCallbackFinished?["sent_body_bytes"] is NSNull)
        XCTAssertTrue(noCallbackFinished?["expected_body_bytes"] is NSNull)
    }

    func testDiagnosticMetricsExposeConnectionReuseAndMissingMetricsStaySilent() {
        let recorder = DiagnosticEventRecorder()
        transport.diagnosticSink = { fields in recorder.record(fields) }
        let transaction = SyntheticTransactionMetrics()
        let metrics = SyntheticTaskMetrics(transactions: [transaction])

        guard let observed = startHeldRequest(
            path: "/diagnostic-connection-reused",
            attemptID: "attempt-reused"),
              let queue = transportQueueForTesting() else {
            return
        }
        queue.sync {
            transport.urlSession(
                URLSession.shared,
                task: observed.task,
                didFinishCollecting: metrics)
        }
        let metricsEvent = recorder.events(named: "transport_metrics").first {
            $0["attempt_id"] as? String == "attempt-reused"
        }
        XCTAssertEqual(metricsEvent?["metrics_late"] as? Bool, false)
        XCTAssertEqual(metricsEvent?["connection_reused"] as? Bool, true)
        XCTAssertEqual(metricsEvent?["network_protocol"] as? String, "h2")
        XCTAssertEqual(metricsEvent?["dns_ms"] as? Double, 1000)
        XCTAssertEqual(metricsEvent?["response_read_ms"] as? Double, 1000)
        finishHeldRequestViaDelegate(observed)

        guard let missing = startHeldRequest(
            path: "/diagnostic-missing-metrics",
            attemptID: "attempt-missing"),
              let missingQueue = transportQueueForTesting() else {
            return
        }
        let countBeforeMissing = recorder.events(named: "transport_metrics").count
        missingQueue.sync {
            transport.urlSession(
                URLSession.shared,
                task: missing.task,
                didFinishCollecting: SyntheticTaskMetrics(transactions: []))
        }
        XCTAssertEqual(recorder.events(named: "transport_metrics").count, countBeforeMissing)
        transport.cancelRequest(withID: missing.requestID)
        wait(for: [missing.completion], timeout: 5)
    }

    func testLateMetricsReuseAttemptIDAndExpireAtThirtySecondTTL() {
        let recorder = DiagnosticEventRecorder()
        transport.diagnosticSink = { fields in recorder.record(fields) }
        let transaction = SyntheticTransactionMetrics()
        let metrics = SyntheticTaskMetrics(transactions: [transaction])

        guard let late = startHeldRequest(
            path: "/diagnostic-late-metrics",
            attemptID: "attempt-late") else {
            return
        }
        guard let queue = transportQueueForTesting() else {
            return
        }
        finishHeldRequestViaDelegate(late)
        queue.sync {
            transport.urlSession(
                URLSession.shared,
                task: late.task,
                didFinishCollecting: metrics)
        }
        let lateEvent = recorder.events(named: "transport_metrics").first {
            $0["attempt_id"] as? String == "attempt-late"
        }
        XCTAssertEqual(lateEvent?["metrics_late"] as? Bool, true)
        XCTAssertEqual(lateEvent?["connection_reused"] as? Bool, true)

        guard let expired = startHeldRequest(
            path: "/diagnostic-expired-metrics",
            attemptID: "attempt-expired") else {
            return
        }
        finishHeldRequestViaDelegate(expired)
        let countBeforeExpiry = recorder.events(named: "transport_metrics").count
        expireLateMetricsRecordForTesting(task: expired.task)
        queue.sync {
            transport.urlSession(
                URLSession.shared,
                task: expired.task,
                didFinishCollecting: metrics)
        }
        XCTAssertEqual(recorder.events(named: "transport_metrics").count, countBeforeExpiry)
    }

    func testLateMetricsRetentionIsBoundedAt128Records() {
        let recorder = DiagnosticEventRecorder()
        transport.diagnosticSink = { fields in recorder.record(fields) }
        var firstTask: URLSessionDataTask?

        for index in 0..<129 {
            guard let request = startHeldRequest(
                path: "/diagnostic-late-bound-\(index)",
                attemptID: "attempt-bound-\(index)") else {
                return
            }
            if index == 0 {
                firstTask = request.task
            }
            // Feed the existing completion delegate directly instead of
            // cancelling each real task. URLSession may emit an automatic
            // empty metrics callback after cancellation, which would consume
            // the late record before this bounded-cache assertion observes
            // it. The request remains held by the stub until tearDown.
            guard let queue = transportQueueForTesting() else {
                return
            }
            queue.sync {
                transport.urlSession(
                    URLSession.shared,
                    task: request.task,
                    didCompleteWithError: NSError(domain: "SyntheticMetrics", code: 1))
            }
            wait(for: [request.completion], timeout: 5)
            if index == 127 {
                XCTAssertEqual(lateMetricsCountForTesting(), 128)
            }
        }
        XCTAssertEqual(lateMetricsCountForTesting(), 128)

        // The oldest record is evicted when the 129th terminal request is
        // retained. Inspecting the private bounded cache via KVC keeps this
        // test-only boundary check out of production API and avoids a 30s
        // wall-clock wait for the TTL.
        guard let firstTask,
              let queue = transportQueueForTesting() else {
            return
        }
        var firstRecordExists = true
        queue.sync {
            let records = transport.value(forKey: "lateMetricsByTaskID") as? NSDictionary
            firstRecordExists = records?[NSNumber(value: firstTask.taskIdentifier)] != nil
        }
        XCTAssertFalse(firstRecordExists)
        XCTAssertEqual(recorder.events(named: "transport_finished").count, 129)
    }

    func testTimeoutPreservesUnderlyingCodeAndIsRetryable() {
        TLSTestStubURLProtocol.setFailure(code: NSURLErrorTimedOut, forPath: "/timeout-error")

        let response = performSync(makeRequest(path: "/timeout-error"))
        let error = response?.error as NSError?

        XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
        XCTAssertEqual(error?.code, TLSTransportErrorCode.requestTimeout.rawValue)
        XCTAssertEqual(
            error?.userInfo[TLSTransportErrorUnderlyingCodeKey] as? Int,
            NSURLErrorTimedOut)
        XCTAssertEqual(error?.userInfo[TLSTransportErrorRetryableKey] as? Bool, true)
    }

    func testDNSFailurePreservesUnderlyingCodeAndIsRetryable() {
        TLSTestStubURLProtocol.setFailure(code: NSURLErrorCannotFindHost, forPath: "/dns-error")

        let response = performSync(makeRequest(path: "/dns-error"))
        let error = response?.error as NSError?

        XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
        XCTAssertEqual(error?.code, TLSTransportErrorCode.transportFailure.rawValue)
        XCTAssertEqual(
            error?.userInfo[TLSTransportErrorUnderlyingCodeKey] as? Int,
            NSURLErrorCannotFindHost)
        XCTAssertEqual(error?.userInfo[TLSTransportErrorRetryableKey] as? Bool, true)
    }

    func testCertificateFailurePreservesUnderlyingCodeAndIsTerminal() {
        TLSTestStubURLProtocol.setFailure(
            code: NSURLErrorServerCertificateUntrusted,
            forPath: "/certificate-error")

        let response = performSync(makeRequest(path: "/certificate-error"))
        let error = response?.error as NSError?

        XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
        XCTAssertEqual(error?.code, TLSTransportErrorCode.transportFailure.rawValue)
        XCTAssertEqual(
            error?.userInfo[TLSTransportErrorUnderlyingCodeKey] as? Int,
            NSURLErrorServerCertificateUntrusted)
        XCTAssertEqual(error?.userInfo[TLSTransportErrorRetryableKey] as? Bool, false)
    }

    func testLateStubCallbackAfterCancelDoesNotCrashOrDoubleComplete() {
        // The stub delivers after 1s; we cancel at ~0.1s. The delayed stub
        // fire must not crash and must not produce a second completion.
        TLSTestStubURLProtocol.setBehavior(
            Behavior(
                statusCode: 200,
                headers: ["x-tls-request-id": "rid-late"],
                body: Data("late".utf8),
                delay: 1.0,
                neverRespond: false,
                redirectLocation: nil),
            forPath: "/late")
        let exp = expectation(description: "cancelled completion")
        var callCount = 0

        let id = transport.perform(
            makeRequest(path: "/late", requestTimeout: 30)) { _ in
                callCount += 1
                exp.fulfill()
            }
        XCTAssertNotNil(id)
        Thread.sleep(forTimeInterval: 0.1)
        transport.cancelRequest(withID: id!)

        wait(for: [exp], timeout: 5)
        XCTAssertEqual(callCount, 1)

        // Wait past the stub's delayed fire (1s); still exactly once.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(callCount, 1, "late stub callback must not double-complete")
    }

    // MARK: HTTPS-only / URL validation

    func testHTTPURLIsRejected() {
        let request = TLSHTTPRequest(
            method: "POST",
            urlString: "http://tls-test.example/plain",
            headers: nil,
            body: nil,
            connectTimeout: 5,
            requestTimeout: 10)

        let response = performSync(request)

        let error = response?.error as NSError?
        XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
        XCTAssertEqual(error?.code, TLSTransportErrorCode.httpsRequired.rawValue)
        XCTAssertEqual(error?.userInfo[TLSTransportErrorRetryableKey] as? Bool, false)
    }

    func testMalformedURLIsRejected() {
        let request = TLSHTTPRequest(
            method: "POST",
            urlString: "not a url",
            headers: nil,
            body: nil,
            connectTimeout: 5,
            requestTimeout: 10)

        let response = performSync(request)

        let error = response?.error as NSError?
        XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
        XCTAssertEqual(error?.code, TLSTransportErrorCode.invalidURL.rawValue)
        XCTAssertEqual(error?.userInfo[TLSTransportErrorRetryableKey] as? Bool, false)
    }

    // MARK: Redaction

    func testErrorsContainNoCredentialsOrBody() {
        // Timeout path with an Authorization header, a sensitive x-tls-*
        // header and a secret body: none may surface in the error.
        TLSTestStubURLProtocol.setBehavior(.neverRespond, forPath: "/redact-timeout")
        let forbiddenValues = [
            ["private", "header"].joined(separator: "-"),
            ["signature", "value"].joined(separator: "-"),
            ["private", "log", "body"].joined(separator: "-"),
        ]
        let requestBody = Data(forbiddenValues[2].utf8)
        let request = TLSHTTPRequest(
            method: "POST",
            urlString: "https://tls-test.example/redact-timeout?authorization=leak",
            headers: [
                "Authorization": "Bearer \(forbiddenValues[0])",
                "x-tls-signature": forbiddenValues[1]
            ],
            body: requestBody,
            connectTimeout: 5,
            requestTimeout: 0.3)

        let response = performSync(request, timeout: 5)

        let error = response?.error as NSError?
        XCTAssertEqual(error?.code, TLSTransportErrorCode.requestTimeout.rawValue)
        let userInfo = error?.userInfo ?? [:]
        for (key, value) in userInfo {
            let keyString = String(describing: key).lowercased()
            XCTAssertFalse(keyString.contains("authorization"), "userInfo key must not leak: \(key)")
            let valueString = String(describing: value).lowercased()
            XCTAssertFalse(valueString.contains("authorization"), "userInfo value must not leak: \(value)")
            XCTAssertFalse(valueString.contains(forbiddenValues[0]), "userInfo must not contain private header data")
            XCTAssertFalse(valueString.contains(forbiddenValues[1]), "userInfo must not contain the signature")
            XCTAssertFalse(valueString.contains(forbiddenValues[2]), "userInfo must not contain the body")
        }
        let description = error?.localizedDescription ?? ""
        XCTAssertFalse(description.contains(forbiddenValues[0]))
        XCTAssertFalse(description.contains(forbiddenValues[1]))
        XCTAssertFalse(description.contains(forbiddenValues[2]))
        // The request body is never echoed back on a transport failure.
        XCTAssertTrue(response?.body.isEmpty ?? false)

        // The redaction contract self-check must still hold.
        XCTAssertTrue(TLSRedactingLogger.runBuiltInSelfCheck())
        // URL redaction strips query/fragment (and thus leaked credentials).
        XCTAssertEqual(
            TLSRedactingLogger.redactedURLString("https://tls-test.example/redact-timeout?authorization=leak"),
            "https://tls-test.example/redact-timeout")
    }

    // MARK: requestID extraction

    func testRequestIDExtractionIsCaseInsensitive() {
        TLSTestStubURLProtocol.setBehavior(
            Behavior(
                statusCode: 200,
                headers: ["X-Tls-Request-Id": "rid-mixed-case"],
                body: Data(),
                delay: 0,
                neverRespond: false,
                redirectLocation: nil),
            forPath: "/rid-case")

        let response = performSync(makeRequest(path: "/rid-case"))

        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertEqual(response?.requestID, "rid-mixed-case")
    }

    func testOfficialTLSRequestIDHeaderIsExtracted() {
        TLSTestStubURLProtocol.setBehavior(
            Behavior(
                statusCode: 200,
                headers: ["X-Tls-Requestid": "rid-official-header"],
                body: Data(),
                delay: 0,
                neverRespond: false,
                redirectLocation: nil),
            forPath: "/rid-official")

        let response = performSync(makeRequest(path: "/rid-official"))

        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertEqual(response?.requestID, "rid-official-header")
    }

    func testRequestIDIsBoundedAndNormalizedBeforeLeavingTransport() {
        let serverControlled = "rid/with spaces/" + String(repeating: "A", count: 300)
        TLSTestStubURLProtocol.setBehavior(
            .success(requestID: serverControlled),
            forPath: "/rid-normalized")

        let response = performSync(makeRequest(path: "/rid-normalized"))

        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertEqual(response?.requestID?.count, 256)
        XCTAssertTrue(response?.requestID?.hasPrefix("rid_with_spaces_") == true)
        XCTAssertFalse(response?.requestID?.contains("/") == true)
        XCTAssertFalse(response?.requestID?.contains(" ") == true)
    }

    func testDiagnosticRequestIDRejectsTruncationAndIllegalCharacters() {
        let serverControlled = "rid/with spaces/" + String(repeating: "A", count: 300)
        TLSTestStubURLProtocol.setBehavior(
            Behavior(
                statusCode: 200,
                headers: ["x-tls-requestid": serverControlled],
                body: Data(),
                delay: 0,
                neverRespond: false,
                redirectLocation: nil),
            forPath: "/rid-diagnostic-strict")
        let recorder = DiagnosticEventRecorder()
        transport.diagnosticSink = { fields in recorder.record(fields) }

        let response = performSync(makeRequest(path: "/rid-diagnostic-strict"))

        // The existing business response keeps its compatibility
        // normalization, while diagnostics reject the incomplete/rewritten
        // value instead of treating it as a correlation ID.
        XCTAssertEqual(response?.requestID?.count, 256)
        let finished = recorder.events(named: "transport_finished").first
        XCTAssertTrue(finished?["request_id"] is NSNull)
        XCTAssertEqual(finished?["fields_omitted"] as? Bool, true)
    }

    func testMissingRequestIDYieldsNil() {
        TLSTestStubURLProtocol.setBehavior(.success(), forPath: "/rid-none")

        let response = performSync(makeRequest(path: "/rid-none"))

        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertNil(response?.requestID)
    }

    // MARK: Invalidate

    func testInvalidateCancelsInflightRequestsAndRejectsNewOnes() {
        TLSTestStubURLProtocol.setBehavior(.neverRespond, forPath: "/invalidate")
        let exp = expectation(description: "cancelled by invalidate")
        let state = TransportResponseState()

        _ = transport.perform(
            makeRequest(path: "/invalidate", requestTimeout: 30)) { response in
                state.record(response)
                exp.fulfill()
            }
        transport.invalidate()

        wait(for: [exp], timeout: 5)
        XCTAssertEqual(state.snapshot.callCount, 1)

        // New requests after invalidation complete with an error.
        let response = performSync(makeRequest(path: "/invalidate"))
        let error = response?.error as NSError?
        XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
        XCTAssertEqual(error?.code, TLSTransportErrorCode.cancelled.rawValue)

        // Idempotent.
        transport.invalidate()
    }

    func testDroppingTransportCompletesZeroDeadlineInflightRequestExactlyOnce() throws {
        TLSTestStubURLProtocol.setBehavior(.neverRespond, forPath: "/dealloc-zero-deadline")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TLSTestStubURLProtocol.self]
        var localTransport: TLSTransport? = try TLSTransport(configuration: config)
        weak var weakTransport: TLSTransport?
        weakTransport = localTransport
        let exp = expectation(description: "dealloc cancellation completion")
        let state = TransportResponseState()

        _ = localTransport?.perform(
            makeRequest(path: "/dealloc-zero-deadline", requestTimeout: 0)) { response in
                state.record(response)
                exp.fulfill()
            }
        localTransport = nil

        wait(for: [exp], timeout: 5)
        XCTAssertNil(weakTransport)
        var snapshot = state.snapshot
        XCTAssertEqual(snapshot.callCount, 1)
        let error = snapshot.response?.error as NSError?
        XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
        XCTAssertEqual(error?.code, TLSTransportErrorCode.cancelled.rawValue)
        XCTAssertEqual(error?.userInfo[TLSTransportErrorRetryableKey] as? Bool, false)
        Thread.sleep(forTimeInterval: 0.2)
        snapshot = state.snapshot
        XCTAssertEqual(snapshot.callCount, 1)
    }

    // MARK: Threading

    func testCompletionIsInvokedOffMainThread() {
        TLSTestStubURLProtocol.setBehavior(.success(), forPath: "/bg")
        let exp = expectation(description: "completion off main")

        _ = transport.perform(makeRequest(path: "/bg")) { _ in
            XCTAssertFalse(Thread.isMainThread, "completion must not run on the main thread")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testConcurrentRequestsShareTheTransport() {
        // Two in-flight requests on one transport must both complete
        // (shared connection pool, per-request contexts).
        TLSTestStubURLProtocol.setBehavior(.success(requestID: "rid-a"), forPath: "/multi-a")
        TLSTestStubURLProtocol.setBehavior(.success(requestID: "rid-b"), forPath: "/multi-b")
        let expA = expectation(description: "A")
        let expB = expectation(description: "B")

        _ = transport.perform(makeRequest(path: "/multi-a")) { response in
            XCTAssertEqual(response.requestID, "rid-a")
            expA.fulfill()
        }
        _ = transport.perform(makeRequest(path: "/multi-b")) { response in
            XCTAssertEqual(response.requestID, "rid-b")
            expB.fulfill()
        }
        wait(for: [expA, expB], timeout: 5)
    }
}
