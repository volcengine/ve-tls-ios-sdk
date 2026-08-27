// TLSTransportTests.swift
// TransportTests
//
// Wave 2 Worker D — NSURLSession transport contract tests.
//
// All network is stubbed offline via a per-session NSURLProtocol subclass
// (TLSTestStubURLProtocol), so no real connection is ever made. The stub
// behavior registry is keyed by URL path, keeping tests safe even if test
// methods are parallelized.
//
// Evidence boundary: written against Swift 5.8 / iOS 13 APIs; NOT compiled
// or run on this Linux dev machine (no Apple toolchain). Execution pending
// macOS + Xcode (decision ledger §4).
//

import Foundation
import XCTest
import TLSProducerBridge
import VolcengineTLSProducer

// MARK: - Offline stub protocol

/// NSURLProtocol stub serving canned responses per URL path.
final class TLSTestStubURLProtocol: URLProtocol {

    struct Behavior {
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

    private static let stateLock = NSLock()
    private static var behaviors: [String: Behavior] = [:]

    static func setBehavior(_ behavior: Behavior, forPath path: String) {
        stateLock.lock()
        behaviors[path] = behavior
        stateLock.unlock()
    }

    static func reset() {
        stateLock.lock()
        behaviors.removeAll()
        stateLock.unlock()
    }

    private static func behavior(for path: String) -> Behavior? {
        stateLock.lock()
        let behavior = behaviors[path]
        stateLock.unlock()
        return behavior
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
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: behavior.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": location])!
            client?.urlProtocol(self, didReceive: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let deliver = { [weak self] in
            guard let self = self, !self.cancelled else { return }
            let response = HTTPURLResponse(
                url: self.request.url!,
                statusCode: behavior.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: behavior.headers)!
            self.client?.urlProtocol(self, didReceive: response)
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

    private var transport: TLSTransport!

    override func setUp() {
        super.setUp()
        TLSTestStubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TLSTestStubURLProtocol.self]
        var initError: NSError?
        transport = TLSTransport(configuration: config, error: &initError)
        XCTAssertNil(initError, "transport construction must succeed")
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
        requestTimeout: TimeInterval = 10,
        headers: [String: String]? = nil,
        body: Data = Data()
    ) -> TLSHTTPRequest {
        TLSHTTPRequest(
            method: "POST",
            URLString: "https://\(host)\(path)",
            headers: headers,
            body: body,
            connectTimeout: connectTimeout,
            requestTimeout: requestTimeout)
    }

    @discardableResult
    private func performSync(_ request: TLSHTTPRequest, timeout: TimeInterval = 10) -> TLSHTTPResponse? {
        let exp = expectation(description: "request completion")
        var result: TLSHTTPResponse?
        let id = transport.performRequest(request) { response in
            result = response
            exp.fulfill()
        }
        XCTAssertNotNil(id, "a started/valid request must return an ID")
        wait(for: [exp], timeout: timeout)
        return result
    }

    /// Documents the Core-layer classification contract (Beta design §11.3)
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
            return .internal("unexpected HTTP status \(status)")
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

            // Document the Core classification contract (design §11.3).
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

    // MARK: Redirect

    func testRedirectSameHostIsFollowed() {
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

    func testRedirectCrossHostIsRejected() {
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

        let error = response?.error as NSError?
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
        XCTAssertEqual(error?.code, TLSTransportErrorCode.redirectRejected.rawValue)
        // The redirect response's safe fields are carried on the error.
        XCTAssertEqual(error?.userInfo[TLSTransportErrorStatusCodeKey] as? Int, 302)
        XCTAssertEqual(error?.userInfo[TLSTransportErrorRequestIDKey] as? String, "rid-redirect")
    }

    func testRedirectCrossSchemeIsRejected() {
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

        let error = response?.error as NSError?
        XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
        XCTAssertEqual(error?.code, TLSTransportErrorCode.redirectRejected.rawValue)
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

    func testShortConnectTimeoutDoesNotBreakInstantResponses() {
        // connectTimeout is best-effort (§8.3); an instant stub response
        // must always win regardless of a tiny connect budget.
        TLSTestStubURLProtocol.setBehavior(.success(requestID: "rid-fast"), forPath: "/connect-ok")

        let response = performSync(
            TLSHTTPRequest(
                method: "POST",
                URLString: "https://tls-test.example/connect-ok",
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

        let id = transport.performRequest(
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

        // Give URLSession room to deliver any late cancellation callbacks;
        // the completion must still have fired exactly once.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(callCount, 1, "no second completion")
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

        let id = transport.performRequest(
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
            URLString: "http://tls-test.example/plain",
            headers: nil,
            body: nil,
            connectTimeout: 5,
            requestTimeout: 10)

        let response = performSync(request)

        let error = response?.error as NSError?
        XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
        XCTAssertEqual(error?.code, TLSTransportErrorCode.httpsRequired.rawValue)
    }

    func testMalformedURLIsRejected() {
        let request = TLSHTTPRequest(
            method: "POST",
            URLString: "not a url",
            headers: nil,
            body: nil,
            connectTimeout: 5,
            requestTimeout: 10)

        let response = performSync(request)

        let error = response?.error as NSError?
        XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
        XCTAssertEqual(error?.code, TLSTransportErrorCode.invalidURL.rawValue)
    }

    // MARK: Redaction

    func testErrorsContainNoCredentialsOrBody() {
        // Timeout path with an Authorization header, a sensitive x-tls-*
        // header and a secret body: none may surface in the error.
        TLSTestStubURLProtocol.setBehavior(.neverRespond, forPath: "/redact-timeout")
        let secretBody = Data("super-secret-log-body".utf8)
        let request = TLSHTTPRequest(
            method: "POST",
            URLString: "https://tls-test.example/redact-timeout?authorization=leak",
            headers: [
                "Authorization": "Bearer secret-token",
                "x-tls-signature": "sig-value"
            ],
            body: secretBody,
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
            XCTAssertFalse(valueString.contains("secret-token"), "userInfo must not contain the token")
            XCTAssertFalse(valueString.contains("sig-value"), "userInfo must not contain the signature")
            XCTAssertFalse(valueString.contains("super-secret-log-body"), "userInfo must not contain the body")
        }
        let description = error?.localizedDescription ?? ""
        XCTAssertFalse(description.contains("secret-token"))
        XCTAssertFalse(description.contains("sig-value"))
        XCTAssertFalse(description.contains("super-secret-log-body"))
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
        var callCount = 0

        _ = transport.performRequest(
            makeRequest(path: "/invalidate", requestTimeout: 30)) { _ in
                callCount += 1
                exp.fulfill()
            }
        transport.invalidate()

        wait(for: [exp], timeout: 5)
        XCTAssertEqual(callCount, 1)

        // New requests after invalidation complete with an error.
        let response = performSync(makeRequest(path: "/invalidate"))
        let error = response?.error as NSError?
        XCTAssertEqual(error?.domain, TLSTransportErrorDomain)
        XCTAssertEqual(error?.code, TLSTransportErrorCode.cancelled.rawValue)

        // Idempotent.
        transport.invalidate()
    }

    // MARK: Threading

    func testCompletionIsInvokedOffMainThread() {
        TLSTestStubURLProtocol.setBehavior(.success(), forPath: "/bg")
        let exp = expectation(description: "completion off main")

        _ = transport.performRequest(makeRequest(path: "/bg")) { _ in
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

        _ = transport.performRequest(makeRequest(path: "/multi-a")) { response in
            XCTAssertEqual(response?.requestID, "rid-a")
            expA.fulfill()
        }
        _ = transport.performRequest(makeRequest(path: "/multi-b")) { response in
            XCTAssertEqual(response?.requestID, "rid-b")
            expB.fulfill()
        }
        wait(for: [expA, expB], timeout: 5)
    }
}
