// RealCoreAdapterIntegrationTests.swift
// ConsumerIntegrationTests
//
// Integration tests for the RealCoreAdapter (C Core v0.3.1).
// Uses a local HTTP stub to verify end-to-end send behavior.
//

import XCTest
@testable import VolcengineTLSProducer
import TLSProducerBridge

/// Minimal HTTP stub that intercepts requests via URLProtocol.
final class RealCoreStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stubbedResponses: [String: (HTTPURLResponse, Data)] = [:]
    private static var requestLog: [(url: String, body: Data?)] = []

    static func setResponse(statusCode: Int, body: Data = Data(), forPath path: String) {
        lock.lock()
        defer { lock.unlock() }
        let response = HTTPURLResponse(
            url: URL(string: "https://stub.local\(path)")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["x-tls-request-id": "stub-req-001"])!
        stubbedResponses[path] = (response, body)
    }

    static func recordedRequests() -> [(url: String, body: Data?)] {
        lock.lock()
        defer { lock.unlock() }
        return requestLog
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        stubbedResponses.removeAll()
        requestLog.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let path = request.url?.path ?? "/"
        Self.lock.lock()
        let stub = Self.stubbedResponses[path]
        Self.requestLog.append((url: request.url?.absoluteString ?? "", body: request.httpBody))
        Self.lock.unlock()

        if let (response, body) = stub {
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

final class RealCoreAdapterIntegrationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        RealCoreStubURLProtocol.reset()
        // Inject a session configuration that uses our stub protocol.
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [RealCoreStubURLProtocol.self]
        TLSRealCoreAdapter.testSessionConfiguration = sessionConfig
    }

    override func tearDown() async throws {
        TLSRealCoreAdapter.testSessionConfiguration = nil
        try await super.tearDown()
    }

    private func makeConfig(persistent: Bool = false) throws -> ProducerConfiguration {
        var config = try ProducerConfiguration()
        config.destination = Destination(
            endpoint: "https://stub.local",
            region: "cn-beijing",
            projectID: "test-project",
            topicID: "test-topic")
        if persistent {
            config.producerID = "test-producer-\(UUID().uuidString.prefix(8))"
            config.persistence = .buffered
        }
        return config
    }

    private func makeCredentials() -> Credentials {
        Credentials(accessKeyID: "test-ak",
                    accessKeySecret: "test-sk",
                    securityToken: "test-token")
    }

    // MARK: - Lifecycle

    func testRealCoreAdapterCreatesSuccessfully() throws {
        let config = try makeConfig()
        let adapter = try RealCoreAdapter(configuration: config, credentials: makeCredentials())
        XCTAssertNotNil(adapter)
    }

    func testRealCoreAdapterOpenClose() async throws {
        let config = try makeConfig()
        let adapter = try RealCoreAdapter(configuration: config, credentials: makeCredentials())
        try adapter.open(configuration: config, credentials: makeCredentials())
        await adapter.close(timeout: 5)
    }

    // MARK: - Send

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
        await adapter.close(timeout: 5)
    }

    // MARK: - Updates

    func testUpdateCredentialsSucceeds() async throws {
        let config = try makeConfig()
        let adapter = try RealCoreAdapter(configuration: config, credentials: makeCredentials())
        try adapter.open(configuration: config, credentials: makeCredentials())

        let newCreds = Credentials(
            accessKeyID: "new-ak",
            accessKeySecret: "new-sk",
            securityToken: "new-token")
        XCTAssertNoThrow(try adapter.updateCredentials(newCreds))

        await adapter.close(timeout: 5)
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

        await adapter.close(timeout: 5)
    }

    // MARK: - Close semantics

    func testAddAfterCloseThrows() async throws {
        let config = try makeConfig()
        let adapter = try RealCoreAdapter(configuration: config, credentials: makeCredentials())
        try adapter.open(configuration: config, credentials: makeCredentials())
        await adapter.close(timeout: 5)

        let event = LogEvent(contents: ["k": .string("v")])
        XCTAssertThrowsError(try adapter.add(event, mode: .normal)) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
    }

    func testCloseIsIdempotent() async throws {
        let config = try makeConfig()
        let adapter = try RealCoreAdapter(configuration: config, credentials: makeCredentials())
        try adapter.open(configuration: config, credentials: makeCredentials())

        await adapter.close(timeout: 5)
        await adapter.close(timeout: 5) // should not crash
    }
}
