//
//  ProducerConfigurationDefaultsTests.swift
//  ContractTests
//
//  Worker A — SLS-aligned defaults, asserted item by item.
//

import XCTest
@testable import VolcengineTLSProducer

final class ProducerConfigurationDefaultsTests: XCTestCase {

    func testDefaultsMatchSLS() throws {
        let config = try ProducerConfiguration()

        // Batch (SLS iOS wrapper)
        XCTAssertEqual(config.batch.maxLogCount, 1024)
        XCTAssertEqual(config.batch.maxRawBytes, 1024 * 1024)
        XCTAssertEqual(config.batch.linger, 3, accuracy: 0.0001)

        // Buffer (SLS)
        XCTAssertEqual(config.buffer.maxBytes, 64 * 1024 * 1024)
        XCTAssertEqual(config.buffer.fullPolicy, .reject)

        // Sender
        XCTAssertEqual(config.sendConcurrency, 1)
        XCTAssertEqual(config.compression, .lz4)
        XCTAssertEqual(config.persistence, .disabled)

        // Timeouts (SLS)
        XCTAssertEqual(config.connectTimeout, 10, accuracy: 0.0001)
        XCTAssertEqual(config.requestTimeout, 15, accuracy: 0.0001)

        // Metadata (SLS iOS wrapper)
        XCTAssertEqual(config.metadata.source, "iOS")
        XCTAssertNil(config.metadata.fileName)
        XCTAssertTrue(config.metadata.tags.isEmpty)

        // Expiry (SLS C default / iOS behavior)
        XCTAssertEqual(config.maxLogAge, 7 * 24 * 60 * 60, accuracy: 0.0001)
        XCTAssertEqual(config.expiredLogPolicy, .rewriteTimestamp)
        XCTAssertEqual(config.unauthorizedPolicy, .retain)

        // producerID
        XCTAssertNil(config.producerID)
    }

    func testDefaultCallbackQueueIsSDKOwnedSerialUtilityQueue() throws {
        let config = try ProducerConfiguration()
        XCTAssertNotIdentical(config.callbackQueue, DispatchQueue.main)
        let label = dispatch_queue_get_label(config.callbackQueue)
        XCTAssertEqual(label, "com.volcengine.tls.producer.callback")
        XCTAssertEqual(
            config.callbackQueue.qos.qosClass.rawValue,
            DispatchQoS.QoSClass.utility.rawValue)
    }

    func testDefaultURLSessionConfigurationIsEphemeral() throws {
        let config = try ProducerConfiguration()
        XCTAssertNil(config.urlSessionConfiguration.urlCache)
        XCTAssertNil(config.urlSessionConfiguration.httpCookieStorage)
        XCTAssertNil(config.urlSessionConfiguration.urlCredentialStorage)
        XCTAssertFalse(config.urlSessionConfiguration.httpShouldSetCookies)
    }

    func testDefaultAutomaticLifecycleHandling() throws {
        // XCTest runs in an app process (no NSExtension key) → true.
        XCTAssertTrue(ProducerConfiguration.defaultAutomaticLifecycleHandling())
        let config = try ProducerConfiguration()
        XCTAssertTrue(config.automaticLifecycleHandling)
    }

    func testExplicitAutomaticLifecycleHandlingOverride() throws {
        let config = try ProducerConfiguration(automaticLifecycleHandling: false)
        XCTAssertFalse(config.automaticLifecycleHandling)
    }

    // MARK: - Validation

    func testInvalidBatchMaxLogCount() {
        XCTAssertThrowsError(
            try ProducerConfiguration(batch: BatchConfiguration(maxLogCount: 0))
        ) { error in
            assertConfigurationError(error, containing: "maxLogCount")
        }
    }

    func testInvalidBatchMaxRawBytes() {
        XCTAssertThrowsError(
            try ProducerConfiguration(batch: BatchConfiguration(maxRawBytes: 0))
        ) { error in
            assertConfigurationError(error, containing: "maxRawBytes")
        }
    }

    func testNegativeLingerRejected() {
        XCTAssertThrowsError(
            try ProducerConfiguration(batch: BatchConfiguration(linger: -1))
        ) { error in
            assertConfigurationError(error, containing: "linger")
        }
    }

    func testInvalidBufferMaxBytes() {
        XCTAssertThrowsError(
            try ProducerConfiguration(buffer: BufferConfiguration(maxBytes: 0))
        ) { error in
            assertConfigurationError(error, containing: "maxBytes")
        }
    }

    func testInvalidSendConcurrency() {
        XCTAssertThrowsError(try ProducerConfiguration(sendConcurrency: 0)) { error in
            assertConfigurationError(error, containing: "sendConcurrency")
        }
    }

    func testInvalidTimeouts() {
        XCTAssertThrowsError(try ProducerConfiguration(connectTimeout: 0)) { error in
            assertConfigurationError(error, containing: "connectTimeout")
        }
        XCTAssertThrowsError(try ProducerConfiguration(requestTimeout: -1)) { error in
            assertConfigurationError(error, containing: "requestTimeout")
        }
    }

    func testEmptySourceRejected() {
        XCTAssertThrowsError(
            try ProducerConfiguration(metadata: ProducerMetadata(source: ""))
        ) { error in
            assertConfigurationError(error, containing: "source")
        }
    }

    func testInvalidMaxLogAge() {
        XCTAssertThrowsError(try ProducerConfiguration(maxLogAge: 0)) { error in
            assertConfigurationError(error, containing: "maxLogAge")
        }
    }

    // MARK: - producerID

    func testValidProducerIDAccepted() throws {
        XCTAssertNoThrow(
            try ProducerConfiguration(producerID: "abc-DEF_1.2.3"))
        XCTAssertNoThrow(
            try ProducerConfiguration(producerID: String(repeating: "a", count: 64)))
    }

    func testEmptyProducerIDRejected() {
        XCTAssertThrowsError(try ProducerConfiguration(producerID: "")) { error in
            assertConfigurationError(error, containing: "producerID")
        }
    }

    func testProducerIDInvalidCharactersRejected() {
        for bad in ["bad id", "bad/id", "bad:id", "bad#id", "中国"] {
            XCTAssertThrowsError(try ProducerConfiguration(producerID: bad)) { error in
                assertConfigurationError(error, containing: "producerID")
            }
        }
    }

    func testProducerIDTooLongRejected() {
        XCTAssertThrowsError(
            try ProducerConfiguration(producerID: String(repeating: "a", count: 65))
        ) { error in
            assertConfigurationError(error, containing: "producerID")
        }
    }

    func testPersistenceRequiresProducerID() {
        for mode in [Persistence.memory, .buffered, .sync] {
            XCTAssertThrowsError(try ProducerConfiguration(persistence: mode)) { error in
                assertConfigurationError(error, containing: "producerID")
            }
        }
    }

    func testPersistenceWithProducerIDAccepted() throws {
        for mode in [Persistence.memory, .buffered, .sync] {
            XCTAssertNoThrow(
                try ProducerConfiguration(persistence: mode, producerID: "p1"))
        }
    }

    // MARK: - URLSession normalization

    func testCallerURLSessionConfigurationIsSanitized() throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.urlCache = URLCache(memoryCapacity: 1024, diskCapacity: 1024, diskPath: nil)
        sessionConfig.httpCookieStorage = HTTPCookieStorage.shared
        sessionConfig.urlCredentialStorage = URLCredentialStorage.shared
        sessionConfig.httpShouldSetCookies = true

        let config = try ProducerConfiguration(urlSessionConfiguration: sessionConfig)
        XCTAssertNil(config.urlSessionConfiguration.urlCache)
        XCTAssertNil(config.urlSessionConfiguration.httpCookieStorage)
        XCTAssertNil(config.urlSessionConfiguration.urlCredentialStorage)
        XCTAssertFalse(config.urlSessionConfiguration.httpShouldSetCookies)
    }

    func testCallerURLSessionConfigurationIsNotMutated() throws {
        // Beta design §8.2: the caller's configuration instance is copied
        // before sanitization; the original must remain untouched.
        let sessionConfig = URLSessionConfiguration.ephemeral
        let cache = URLCache(memoryCapacity: 1024, diskCapacity: 1024, diskPath: nil)
        sessionConfig.urlCache = cache
        sessionConfig.httpShouldSetCookies = true

        _ = try ProducerConfiguration(urlSessionConfiguration: sessionConfig)

        XCTAssertIdentical(sessionConfig.urlCache, cache)
        XCTAssertTrue(sessionConfig.httpShouldSetCookies)
    }

    // MARK: - Helpers

    private func assertConfigurationError(
        _ error: Error,
        containing fragment: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard case ProducerError.configuration(let reason) = error else {
            XCTFail("expected .configuration, got \(error)", file: file, line: line)
            return
        }
        XCTAssertTrue(
            reason.contains(fragment),
            "reason '\(reason)' should contain '\(fragment)'",
            file: file,
            line: line)
    }
}
