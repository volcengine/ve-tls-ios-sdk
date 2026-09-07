//
// ObjectiveCFacadeTests.swift
// Contract tests for the NSObject/Objective-C compatibility surface.
//

import Foundation
import XCTest
@testable import VolcengineTLSProducer

final class ObjectiveCFacadeTests: XCTestCase {

    func testConfigurationDefaultsMatchSwiftModel() throws {
        let objcConfiguration = TLSProducerConfiguration()
        let swiftConfiguration = try objcConfiguration.swiftValue()

        XCTAssertEqual(objcConfiguration.batchMaxLogCount,
                       swiftConfiguration.batch.maxLogCount)
        XCTAssertEqual(objcConfiguration.batchMaxRawBytes,
                       swiftConfiguration.batch.maxRawBytes)
        XCTAssertEqual(objcConfiguration.batchLinger,
                       swiftConfiguration.batch.linger)
        XCTAssertEqual(objcConfiguration.bufferMaxBytes,
                       swiftConfiguration.buffer.maxBytes)
        XCTAssertEqual(objcConfiguration.bufferBlockTimeout,
                       swiftConfiguration.buffer.blockTimeout)
        XCTAssertEqual(objcConfiguration.sendConcurrency,
                       swiftConfiguration.sendConcurrency)
        XCTAssertEqual(objcConfiguration.connectTimeout,
                       swiftConfiguration.connectTimeout)
        XCTAssertEqual(objcConfiguration.requestTimeout,
                       swiftConfiguration.requestTimeout)
        XCTAssertEqual(objcConfiguration.metadataSource,
                       swiftConfiguration.metadata.source)
        XCTAssertEqual(objcConfiguration.metadataFileName,
                       swiftConfiguration.metadata.fileName)
        XCTAssertEqual(objcConfiguration.metadataTags,
                       swiftConfiguration.metadata.tags)
        XCTAssertEqual(objcConfiguration.maxLogAge,
                       swiftConfiguration.maxLogAge)
        XCTAssertEqual(objcConfiguration.automaticLifecycleHandling,
                       swiftConfiguration.automaticLifecycleHandling)
        XCTAssertEqual(objcConfiguration.producerID,
                       swiftConfiguration.producerID)
        XCTAssertEqual(objcConfiguration.destination, nil)
        XCTAssertEqual(objcConfiguration.callbackQueue.label,
                       swiftConfiguration.callbackQueue.label)
        XCTAssertNil(swiftConfiguration.urlSessionConfiguration.urlCache)
        XCTAssertNil(swiftConfiguration.urlSessionConfiguration.httpCookieStorage)
        XCTAssertNil(swiftConfiguration.urlSessionConfiguration.urlCredentialStorage)
        XCTAssertFalse(swiftConfiguration.urlSessionConfiguration.httpShouldSetCookies)
    }

    func testConfigurationMapsEveryFlattenedField() throws {
        let callbackQueue = DispatchQueue(label: "objc.facade.configuration")
        let objcConfiguration = TLSProducerConfiguration()
        objcConfiguration.batchMaxLogCount = 17
        objcConfiguration.batchMaxRawBytes = 123_456
        objcConfiguration.batchLinger = 2
        objcConfiguration.bufferMaxBytes = 987_654
        objcConfiguration.bufferFullPolicy = .block
        objcConfiguration.bufferBlockTimeout = 4
        objcConfiguration.sendConcurrency = 3
        objcConfiguration.compression = .disabled
        objcConfiguration.persistence = .memory
        objcConfiguration.connectTimeout = 6
        objcConfiguration.requestTimeout = 7
        objcConfiguration.metadataSource = "objc-source"
        objcConfiguration.metadataFileName = "objc-file"
        objcConfiguration.metadataTags = ["team": "sdk"]
        objcConfiguration.maxLogAge = 86_400
        objcConfiguration.expiredLogPolicy = .drop
        objcConfiguration.unauthorizedPolicy = .drop
        objcConfiguration.callbackQueue = callbackQueue
        objcConfiguration.urlSessionConfiguration = .default
        objcConfiguration.automaticLifecycleHandling = false
        objcConfiguration.producerID = "objc-producer"
        objcConfiguration.destination = TLSDestination(
            endpoint: "https://tls-cn-beijing.volces.com",
            region: "cn-beijing",
            projectID: "project",
            topicID: "topic")

        let swiftConfiguration = try objcConfiguration.swiftValue()
        XCTAssertEqual(swiftConfiguration.batch,
                       BatchConfiguration(maxLogCount: 17,
                                          maxRawBytes: 123_456,
                                          linger: 2))
        XCTAssertEqual(swiftConfiguration.buffer,
                       BufferConfiguration(maxBytes: 987_654,
                                           fullPolicy: .block,
                                           blockTimeout: 4))
        XCTAssertEqual(swiftConfiguration.sendConcurrency, 3)
        XCTAssertEqual(swiftConfiguration.compression, .disabled)
        XCTAssertEqual(swiftConfiguration.persistence, .memory)
        XCTAssertEqual(swiftConfiguration.connectTimeout, 6)
        XCTAssertEqual(swiftConfiguration.requestTimeout, 7)
        XCTAssertEqual(swiftConfiguration.metadata,
                       ProducerMetadata(source: "objc-source",
                                        fileName: "objc-file",
                                        tags: ["team": "sdk"]))
        XCTAssertEqual(swiftConfiguration.maxLogAge, 86_400)
        XCTAssertEqual(swiftConfiguration.expiredLogPolicy, .drop)
        XCTAssertEqual(swiftConfiguration.unauthorizedPolicy, .drop)
        XCTAssertEqual(swiftConfiguration.callbackQueue.label, callbackQueue.label)
        XCTAssertEqual(swiftConfiguration.automaticLifecycleHandling, false)
        XCTAssertEqual(swiftConfiguration.producerID, "objc-producer")
        XCTAssertEqual(swiftConfiguration.destination, Destination(
            endpoint: "https://tls-cn-beijing.volces.com",
            region: "cn-beijing",
            projectID: "project",
            topicID: "topic"))
        XCTAssertNil(swiftConfiguration.urlSessionConfiguration.urlCache)
    }

    func testLogEventUsesDateAndPreservesNanosecondRemainder() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.123456)
        let objcEvent = TLSLogEvent(
            timestamp: timestamp,
            hashKey: "0123456789abcdef0123456789abcde0",
            contents: ["message": "hello", "kind": "objc"])

        let swiftEvent = objcEvent.swiftValue()
        XCTAssertEqual(swiftEvent.timestamp, timestamp)
        XCTAssertEqual(swiftEvent.hashKey, "0123456789abcdef0123456789abcde0")
        let prepared = try swiftEvent.prepareForAdmission()
        XCTAssertEqual(prepared.encodedContents,
                       ["message": "hello", "kind": "objc"])
        XCTAssertGreaterThan(prepared.timestampNanosecondsRemainder, 0)
        XCTAssertLessThan(prepared.timestampNanosecondsRemainder, 1_000_000)
    }

    func testLogEventSwiftValueCachesAndReusesUnchangedValue() {
        let event = TLSLogEvent(
            hashKey: String(repeating: "0", count: 32),
            contents: ["message": "before"])

        XCTAssertFalse(event.hasCachedSwiftValue)
        let first = event.swiftValue()
        XCTAssertTrue(event.hasCachedSwiftValue)

        let second = event.swiftValue()
        XCTAssertEqual(second, first)
        XCTAssertTrue(event.hasCachedSwiftValue)
    }

    func testLogEventSwiftValueCacheInvalidatesForEachMutableProperty() {
        let event = TLSLogEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            hashKey: String(repeating: "0", count: 32),
            contents: ["message": "before"])

        _ = event.swiftValue()
        XCTAssertTrue(event.hasCachedSwiftValue)

        event.timestamp = Date(timeIntervalSince1970: 1_700_000_001)
        XCTAssertFalse(event.hasCachedSwiftValue)
        _ = event.swiftValue()
        XCTAssertTrue(event.hasCachedSwiftValue)

        event.hashKey = String(repeating: "1", count: 32)
        XCTAssertFalse(event.hasCachedSwiftValue)
        _ = event.swiftValue()
        XCTAssertTrue(event.hasCachedSwiftValue)

        event.contents = ["message": "after"]
        XCTAssertFalse(event.hasCachedSwiftValue)
        _ = event.swiftValue()
        XCTAssertTrue(event.hasCachedSwiftValue)
    }

    func testLogEventSwiftValueCacheInvalidatesForContentsSubscriptMutation() {
        let event = TLSLogEvent(contents: ["message": "before"])
        _ = event.swiftValue()
        XCTAssertTrue(event.hasCachedSwiftValue)

        event.contents["message"] = "after"

        XCTAssertFalse(event.hasCachedSwiftValue)
        XCTAssertEqual(event.swiftValue().contents["message"], .string("after"))
    }

    func testLogEventSwiftValueSnapshotIsNotMutatedByLaterChanges() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let event = TLSLogEvent(
            timestamp: timestamp,
            hashKey: String(repeating: "0", count: 32),
            contents: ["message": "before"])
        let oldValue = event.swiftValue()

        event.timestamp = timestamp.addingTimeInterval(1)
        event.hashKey = String(repeating: "1", count: 32)
        event.contents["message"] = "after"
        event.contents["new"] = "field"

        XCTAssertEqual(oldValue.timestamp, timestamp)
        XCTAssertEqual(oldValue.hashKey, String(repeating: "0", count: 32))
        XCTAssertEqual(oldValue.contents, ["message": .string("before")])

        let newValue = event.swiftValue()
        XCTAssertEqual(newValue.timestamp, timestamp.addingTimeInterval(1))
        XCTAssertEqual(newValue.hashKey, String(repeating: "1", count: 32))
        XCTAssertEqual(newValue.contents, [
            "message": .string("after"),
            "new": .string("field"),
        ])
    }

    func testLogEventSwiftValueCachePreservesInvalidToValidValidation() {
        let event = TLSLogEvent(
            hashKey: "not-a-valid-hash-key",
            contents: ["message": "body"])
        let invalidValue = event.swiftValue()

        XCTAssertThrowsError(try invalidValue.prepareForAdmission()) { error in
            guard case ProducerError.invalidLog = error else {
                XCTFail("expected invalidLog, got \(error)")
                return
            }
        }

        event.hashKey = String(repeating: "0", count: 32)
        XCTAssertFalse(event.hasCachedSwiftValue)
        let validValue = event.swiftValue()
        XCTAssertNoThrow(try validValue.prepareForAdmission())
    }

    func testLogEventSwiftValueCachePreservesValidToInvalidValidation() {
        let event = TLSLogEvent(
            hashKey: String(repeating: "0", count: 32),
            contents: ["message": "body"])
        let validValue = event.swiftValue()
        XCTAssertNoThrow(try validValue.prepareForAdmission())

        event.hashKey = "not-a-valid-hash-key"
        XCTAssertFalse(event.hasCachedSwiftValue)
        let invalidValue = event.swiftValue()
        XCTAssertThrowsError(try invalidValue.prepareForAdmission()) { error in
            guard case ProducerError.invalidLog = error else {
                XCTFail("expected invalidLog, got \(error)")
                return
            }
        }
    }

    func testLogEventSwiftValueSupportsConcurrentReadOnlyAccess() {
        let event = TLSLogEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.25),
            hashKey: String(repeating: "0", count: 32),
            contents: ["message": "body"])
        let expected = LogEvent(
            timestamp: event.timestamp,
            hashKey: event.hashKey,
            contents: ["message": .string("body")])
        XCTAssertFalse(event.hasCachedSwiftValue)
        let box = LogEventSwiftValueReadBox(event: event)

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            box.read()
        }

        let values = box.snapshot()
        XCTAssertEqual(values.count, 64)
        XCTAssertTrue(values.allSatisfy { $0 == expected })
        XCTAssertTrue(event.hasCachedSwiftValue)
    }

    func testEmptyLogFailsAtSynchronousAddBoundary() async throws {
        let callbackQueue = DispatchQueue(label: "objc.facade.empty-log")
        let swiftConfiguration = try ProducerConfiguration(callbackQueue: callbackQueue)
        let recording = RecordingAdapter()
        let swiftProducer = try await Producer.open(
            adapter: recording,
            configuration: swiftConfiguration,
            credentials: .testing)
        let objcProducer = TLSProducer.makeForTesting(
            swiftProducer: swiftProducer,
            callbackQueue: callbackQueue)

        var error: NSError?
        XCTAssertFalse(objcProducer.addLog(
            TLSLogEvent(),
            mode: .normal,
            error: &error))
        XCTAssertEqual(error?.domain, TLSProducer.errorDomain)
        XCTAssertEqual(error?.code, TLSProducerErrorCode.invalidLog.rawValue)
        XCTAssertEqual(error?.userInfo[TLSProducer.errorCodeKey] as? String,
                       "invalidLog")
        XCTAssertTrue(recording.addCalls.isEmpty)
        try await swiftProducer.close(timeout: 1)
    }

    func testSynchronousAddAndUpdateMapToSwiftProducer() async throws {
        let callbackQueue = DispatchQueue(label: "objc.facade.sync-operations")
        let swiftConfiguration = try ProducerConfiguration(callbackQueue: callbackQueue)
        let recording = RecordingAdapter()
        let swiftProducer = try await Producer.open(
            adapter: recording,
            configuration: swiftConfiguration,
            credentials: .testing)
        let objcProducer = TLSProducer.makeForTesting(
            swiftProducer: swiftProducer,
            callbackQueue: callbackQueue)

        var error: NSError?
        let event = TLSLogEvent(contents: ["message": "hello"])
        XCTAssertTrue(objcProducer.addLog(event, mode: .immediate, error: &error))
        XCTAssertNil(error)
        XCTAssertEqual(recording.addCalls.count, 1)
        XCTAssertEqual(recording.addCalls.first?.mode, .immediate)
        XCTAssertEqual(recording.addCalls.first?.prepared.encodedContents,
                       ["message": "hello"])

        let newCredentials = TLSCredentials(
            accessKeyID: "new-ak",
            accessKeySecret: UUID().uuidString,
            securityToken: UUID().uuidString)
        XCTAssertTrue(objcProducer.updateCredentials(newCredentials, error: &error))
        XCTAssertNil(error)
        XCTAssertEqual(recording.updateCredentialsCalls.last,
                       newCredentials.swiftValue())

        let newDestination = TLSDestination(
            endpoint: "https://tls-cn-shanghai.volces.com",
            region: "cn-shanghai",
            projectID: "new-project",
            topicID: "new-topic")
        XCTAssertTrue(objcProducer.updateDestination(newDestination, error: &error))
        XCTAssertNil(error)
        XCTAssertEqual(recording.updateDestinationCalls.last,
                       newDestination.swiftValue())
        try await swiftProducer.close(timeout: 1)
    }

    func testOpenSnapshotsConfigurationBeforeTaskAndCompletesOnQueue() async {
        let probe = QueueProbe(label: "objc.facade.open-snapshot")
        let configuration = TLSProducerConfiguration()
        configuration.callbackQueue = probe.queue
        configuration.destination = TLSDestination(
            endpoint: "https://tls-cn-beijing.volces.com",
            region: "cn-beijing",
            projectID: "project",
            topicID: "topic")
        configuration.batchMaxLogCount = 0
        let credentials = TLSCredentials(
            accessKeyID: "ak",
            accessKeySecret: UUID().uuidString)
        let completion = expectation(description: "open completion")
        let callbackCount = CounterBox()

        TLSProducer.open(with: configuration, credentials: credentials) { producer, error in
            callbackCount.increment()
            XCTAssertNil(producer)
            XCTAssertEqual(error?.domain, TLSProducer.errorDomain)
            XCTAssertEqual(error?.code, TLSProducerErrorCode.configuration.rawValue)
            XCTAssertTrue(probe.isCurrentQueue)
            completion.fulfill()
        }

        // If the Task read the mutable NSObject later, this change would turn
        // the captured invalid configuration into a valid one.
        configuration.batchMaxLogCount = 1
        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(callbackCount.value, 1)
    }

    func testOpenUsesValidValueSnapshotAfterCallerMutation() async {
        let probe = QueueProbe(label: "objc.facade.valid-open-snapshot")
        let configuration = TLSProducerConfiguration()
        configuration.callbackQueue = probe.queue
        configuration.destination = TLSDestination(
            endpoint: "https://tls-cn-beijing.volces.com",
            region: "cn-beijing",
            projectID: "project",
            topicID: "topic")
        let credentials = TLSCredentials(
            accessKeyID: "ak",
            accessKeySecret: UUID().uuidString,
            securityToken: UUID().uuidString)
        let openCompletion = expectation(description: "valid open completion")
        let closeCompletion = expectation(description: "valid open close completion")
        let openResult = OpenResultBox()

        TLSProducer.open(with: configuration, credentials: credentials) { producer, error in
            openResult.store(producer != nil && error == nil, onQueue: probe.isCurrentQueue)
            XCTAssertNotNil(producer)
            XCTAssertNil(error)
            openCompletion.fulfill()
            producer?.close(withTimeout: 1) { closeError in
                XCTAssertNil(closeError)
                closeCompletion.fulfill()
            }
        }

        // The async Task must observe the already-copied valid values. These
        // mutations would make open fail if it read the NSObject later.
        configuration.batchMaxLogCount = 0
        configuration.destination = nil
        credentials.accessKeyID = ""
        credentials.accessKeySecret = ""
        credentials.securityToken = nil

        await fulfillment(of: [openCompletion, closeCompletion], timeout: 5)
        XCTAssertTrue(openResult.succeeded)
        XCTAssertTrue(openResult.wasOnQueue)
    }

    func testCloseCompletionRunsOnceOnConfiguredQueue() async throws {
        let probe = QueueProbe(label: "objc.facade.close-completion")
        let configuration = try ProducerConfiguration(callbackQueue: probe.queue)
        let recording = RecordingAdapter()
        let swiftProducer = try await Producer.open(
            adapter: recording,
            configuration: configuration,
            credentials: .testing)
        let objcProducer = TLSProducer.makeForTesting(
            swiftProducer: swiftProducer,
            callbackQueue: probe.queue)
        let completion = expectation(description: "close completion")
        let counter = CounterBox()
        let callbackOnQueue = OpenResultBox()

        objcProducer.close(withTimeout: 1) { error in
            counter.increment()
            callbackOnQueue.store(error == nil, onQueue: probe.isCurrentQueue)
            XCTAssertNil(error)
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(counter.value, 1)
        XCTAssertTrue(callbackOnQueue.succeeded)
        XCTAssertTrue(callbackOnQueue.wasOnQueue)
        XCTAssertEqual(recording.closeCallCount, 1)
    }

    func testSendResultMappingAndQueueContract() async throws {
        let probe = QueueProbe(label: "objc.facade.send-result")
        let configuration = try ProducerConfiguration(callbackQueue: probe.queue)
        let recording = RecordingAdapter()
        let resultExpectation = expectation(description: "send result")
        let box = ResultBox()
        let swiftProducer = try await Producer.open(
            adapter: recording,
            configuration: configuration,
            credentials: .testing,
            onSendResult: { result in
                let objcResult = TLSSendResult(swiftValue: result)
                box.store(objcResult, onQueue: probe.isCurrentQueue)
                resultExpectation.fulfill()
            })

        recording.emit(SendResult(
            status: .failure,
            rawBytes: 10,
            compressedBytes: 8,
            requestID: "request-1",
            error: .service(code: 500, message: "response body", requestID: "request-1")))
        await fulfillment(of: [resultExpectation], timeout: 2)
        let objcResult = try XCTUnwrap(box.result)
        XCTAssertTrue(box.wasOnQueue)
        XCTAssertEqual(objcResult.status, .failure)
        XCTAssertEqual(objcResult.rawBytes, 10)
        XCTAssertEqual(objcResult.compressedBytes, 8)
        XCTAssertEqual(objcResult.requestID, "request-1")
        XCTAssertEqual(objcResult.error?.domain, TLSProducer.errorDomain)
        XCTAssertEqual(objcResult.error?.code,
                       TLSProducerErrorCode.service.rawValue)
        XCTAssertFalse(objcResult.error?.localizedDescription.contains("response body") == true)
        try await swiftProducer.close(timeout: 1)
    }

    func testEveryProducerErrorHasStableNSErrorCodeAndSafeDescription() {
        let cases: [(ProducerError, TLSProducerErrorCode)] = [
            (.configuration("AKSECRET"), .configuration),
            (.invalidLog(["LOG-BODY"]), .invalidLog),
            (.invalidState, .invalidState),
            (.queueFull, .queueFull),
            (.bufferFull, .bufferFull),
            (.singleLogTooLarge, .singleLogTooLarge),
            (.persistence("AKSECRET"), .persistence),
            (.transport("AKSECRET"), .transport),
            (.service(code: 500, message: "LOG-BODY", requestID: "request"), .service),
            (.auth, .auth),
            (.quota, .quota),
            (.timeout, .timeout),
            (.cancelled, .cancelled),
            (.closed, .closed),
            (ProducerError.`internal`("AKSECRET"), .internal),
        ]

        for (producerError, expectedCode) in cases {
            let error = TLSProducer.makeNSError(producerError)
            XCTAssertEqual(error.domain, TLSProducer.errorDomain)
            XCTAssertEqual(error.code, expectedCode.rawValue)
            XCTAssertEqual(error.userInfo[TLSProducer.errorCodeKey] as? String,
                           producerError.errorCode)
            XCTAssertFalse(error.localizedDescription.contains("AKSECRET"))
            XCTAssertFalse(error.localizedDescription.contains("LOG-BODY"))
        }
    }

    func testUnknownErrorDoesNotLeakUnderlyingText() {
        struct UnknownError: LocalizedError {
            var errorDescription: String? { "SECRET-UNDERLYING-TEXT" }
        }

        let error = TLSProducer.makeNSError(UnknownError())
        XCTAssertEqual(error.domain, TLSProducer.errorDomain)
        XCTAssertEqual(error.code, TLSProducerErrorCode.unknown.rawValue)
        XCTAssertEqual(error.userInfo[TLSProducer.errorCodeKey] as? String, "unknown")
        XCTAssertEqual(error.localizedDescription, "TLS producer operation failed.")
        XCTAssertFalse(error.localizedDescription.contains("SECRET-UNDERLYING-TEXT"))
    }

    func testObjectDescriptionsRedactCredentialAndLogFields() {
        // Synthetic values exist only for this test; no account is used.
        let identifier = UUID().uuidString
        let secret = UUID().uuidString
        let token = UUID().uuidString
        let credentials = TLSCredentials(
            accessKeyID: identifier,
            accessKeySecret: secret,
            securityToken: token)
        let event = TLSLogEvent(contents: ["body": "LOG-BODY"])
        XCTAssertFalse(String(describing: credentials).contains(identifier))
        XCTAssertFalse(String(describing: credentials).contains(secret))
        XCTAssertFalse(String(describing: credentials).contains(token))
        XCTAssertFalse(String(describing: event).contains("LOG-BODY"))
    }
}

private final class QueueProbe: @unchecked Sendable {
    let queue: DispatchQueue
    private let key = DispatchSpecificKey<UInt8>()

    init(label: String) {
        queue = DispatchQueue(label: label)
        queue.setSpecific(key: key, value: 1)
    }

    var isCurrentQueue: Bool {
        DispatchQueue.getSpecific(key: key) == 1
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var result: TLSSendResult?
    private(set) var wasOnQueue = false

    func store(_ result: TLSSendResult, onQueue: Bool) {
        lock.lock()
        self.result = result
        wasOnQueue = onQueue
        lock.unlock()
    }
}

private final class OpenResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var succeeded = false
    private(set) var wasOnQueue = false

    func store(_ succeeded: Bool, onQueue: Bool) {
        lock.lock()
        self.succeeded = succeeded
        wasOnQueue = onQueue
        lock.unlock()
    }
}

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class LogEventSwiftValueReadBox: @unchecked Sendable {
    let event: TLSLogEvent
    private let lock = NSLock()
    private var values: [LogEvent] = []

    init(event: TLSLogEvent) {
        self.event = event
    }

    func read() {
        let value = event.swiftValue()
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [LogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
