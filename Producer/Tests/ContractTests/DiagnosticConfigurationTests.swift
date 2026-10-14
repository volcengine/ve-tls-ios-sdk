import Foundation
import XCTest
@testable import VolcengineTLSProducer

final class DiagnosticConfigurationTests: XCTestCase {

    func testSwiftDefaultsAreDisabledAndTextOffDoesNotEnableEmitter() throws {
        let defaults = try ProducerConfiguration.makeTesting()
        XCTAssertNil(defaults.onDiagnostic)
        XCTAssertNil(defaults.diagnosticHandler)
        XCTAssertEqual(defaults.diagnosticLogLevel, .info)
        XCTAssertFalse(Producer.makeDiagnosticEmitter(defaults).isEnabled)

        let textValues = DiagnosticConfigurationCollector()
        var off = try ProducerConfiguration.makeTesting()
        off.diagnosticLogLevel = .off
        off.diagnosticHandler = { @Sendable level, message in
            textValues.appendText(level: level.rawValue, message: message)
        }
        XCTAssertFalse(Producer.makeDiagnosticEmitter(off).isEnabled)
        XCTAssertTrue(textValues.messages.isEmpty)
    }

    func testObjectiveCDefaultsAndDiagnosticLevelMapToSwiftContract() throws {
        let objc = TLSProducerConfiguration()
        XCTAssertEqual(objc.diagnosticLogLevel, .info)
        XCTAssertNil(objc.onDiagnostic)
        XCTAssertNil(objc.diagnosticHandler)

        let textValues = DiagnosticConfigurationCollector()
        objc.diagnosticLogLevel = .warning
        objc.diagnosticHandler = { @Sendable level, message in
            textValues.appendText(level: level, message: message)
        }

        let swift = try objc.swiftValue()
        XCTAssertEqual(swift.diagnosticLogLevel, .warning)
        XCTAssertNotNil(swift.diagnosticHandler)
        swift.diagnosticHandler?(.error, "contract-test")
        XCTAssertEqual(textValues.messages.count, 1)
        XCTAssertEqual(
            textValues.messages.first?.level,
            ProducerDiagnosticLogLevel.error.rawValue)
        XCTAssertEqual(textValues.messages.first?.message, "contract-test")
    }

    func testOpenSnapshotsDiagnosticHandlersAndLevel() async throws {
        let original = DiagnosticConfigurationCollector()
        let replacement = DiagnosticConfigurationCollector()
        var configuration = try ProducerConfiguration.makeTesting()
        configuration.onDiagnostic = { @Sendable value in original.append(value) }
        configuration.diagnosticLogLevel = .debug
        configuration.diagnosticHandler = { @Sendable level, message in
            original.appendText(level: level.rawValue, message: message)
        }

        let adapter = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: adapter,
            configuration: configuration,
            credentials: .testing)

        // Mutating the caller's value after open must not hot-update the
        // producer's immutable emitter snapshot.
        configuration.onDiagnostic = { @Sendable value in replacement.append(value) }
        configuration.diagnosticLogLevel = .off
        configuration.diagnosticHandler = { @Sendable level, message in
            replacement.appendText(level: level.rawValue, message: message)
        }

        try producer.add(LogEvent(contents: ["message": .string("snapshot")]))
        try await producer.close(timeout: 1)
        try await waitUntil(timeout: 2) {
            original.values.contains { $0.kind == .closed }
        }

        XCTAssertFalse(original.values.isEmpty)
        XCTAssertFalse(original.messages.isEmpty)
        XCTAssertTrue(replacement.values.isEmpty)
        XCTAssertTrue(replacement.messages.isEmpty)
    }

    func testTwoOpenInstancesKeepDiagnosticEventsAndInstanceIDsSeparate() async throws {
        let firstValues = DiagnosticConfigurationCollector()
        let secondValues = DiagnosticConfigurationCollector()
        var firstConfiguration = try ProducerConfiguration.makeTesting()
        firstConfiguration.destination = Destination(
            endpoint: "https://first.example",
            region: "cn-beijing",
            projectID: "project",
            topicID: "topic-first")
        firstConfiguration.onDiagnostic = { @Sendable value in firstValues.append(value) }
        var secondConfiguration = try ProducerConfiguration.makeTesting()
        secondConfiguration.destination = Destination(
            endpoint: "https://second.example",
            region: "cn-shanghai",
            projectID: "project",
            topicID: "topic-second")
        secondConfiguration.onDiagnostic = { @Sendable value in secondValues.append(value) }

        let first = try await Producer.open(
            adapter: RecordingAdapter(),
            configuration: firstConfiguration,
            credentials: .testing)
        let second = try await Producer.open(
            adapter: RecordingAdapter(),
            configuration: secondConfiguration,
            credentials: .testing)
        try await first.close(timeout: 1)
        try await second.close(timeout: 1)

        try await waitUntil(timeout: 2) {
            firstValues.values.contains { $0.kind == .closed } &&
                secondValues.values.contains { $0.kind == .closed }
        }

        let firstEvents = firstValues.values
        let secondEvents = secondValues.values
        let firstInstanceID = try XCTUnwrap(
            firstEvents.first?.context?.producerInstanceID)
        let secondInstanceID = try XCTUnwrap(
            secondEvents.first?.context?.producerInstanceID)
        XCTAssertNotEqual(firstInstanceID, secondInstanceID)
        XCTAssertTrue(firstEvents.allSatisfy {
            $0.context?.producerInstanceID == firstInstanceID &&
                $0.context?.topicID == "topic-first"
        })
        XCTAssertTrue(secondEvents.allSatisfy {
            $0.context?.producerInstanceID == secondInstanceID &&
                $0.context?.topicID == "topic-second"
        })
    }

    func testOpenValidationFailureEmitsOneOpenFailedWithInstanceContext() async throws {
        let values = DiagnosticConfigurationCollector()
        var configuration = try ProducerConfiguration.makeTesting()
        configuration.destination = Destination(
            endpoint: "http://invalid.example",
            region: "cn-beijing",
            projectID: "project",
            topicID: "topic")
        configuration.onDiagnostic = { @Sendable value in values.append(value) }

        do {
            _ = try await Producer.open(
                configuration: configuration,
                credentials: .testing)
            XCTFail("invalid destination must fail before adapter construction")
        } catch let error as ProducerError {
            guard case .configuration = error else {
                XCTFail("expected configuration error, got \(error)")
                return
            }
        }

        try await waitUntil(timeout: 2) {
            values.values.contains { $0.kind == .openFailed }
        }
        let events = values.values
        XCTAssertEqual(events.filter { $0.kind == .openStarted }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .openFailed }.count, 1)
        XCTAssertNotNil(events.first?.context?.producerInstanceID)
    }

    func testCredentialValidationFailureAlsoEmitsOneOpenFailed() async throws {
        let values = DiagnosticConfigurationCollector()
        var configuration = try ProducerConfiguration.makeTesting()
        configuration.destination = Destination(
            endpoint: "https://valid.example",
            region: "cn-beijing",
            projectID: "project",
            topicID: "topic")
        configuration.onDiagnostic = { @Sendable value in values.append(value) }

        let invalidCredentials = Credentials(
            accessKeyID: "valid-ak",
            accessKeySecret: "")
        do {
            _ = try await Producer.open(
                configuration: configuration,
                credentials: invalidCredentials)
            XCTFail("invalid credentials must fail before adapter construction")
        } catch let error as ProducerError {
            guard case .configuration = error else {
                XCTFail("expected configuration error, got \(error)")
                return
            }
        }

        try await waitUntil(timeout: 2) {
            values.values.contains { $0.kind == .openFailed }
        }
        XCTAssertEqual(values.values.filter { $0.kind == .openStarted }.count, 1)
        XCTAssertEqual(values.values.filter { $0.kind == .openFailed }.count, 1)
    }

    func testMissingDestinationEmitsOneOpenFailed() async throws {
        let values = DiagnosticConfigurationCollector()
        var configuration = try ProducerConfiguration.makeTesting()
        configuration.onDiagnostic = { @Sendable value in values.append(value) }
        XCTAssertNil(configuration.destination)

        do {
            _ = try await Producer.open(
                configuration: configuration,
                credentials: .testing)
            XCTFail("missing destination must fail before adapter construction")
        } catch let error as ProducerError {
            guard case .configuration = error else {
                XCTFail("expected configuration error, got \(error)")
                return
            }
        }

        try await waitUntil(timeout: 2) {
            values.values.contains { $0.kind == .openFailed }
        }
        let events = values.values
        XCTAssertEqual(events.filter { $0.kind == .openStarted }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .openFailed }.count, 1)
        XCTAssertEqual(
            events.first(where: { $0.kind == .openFailed })?.context?.producerErrorName,
            "configuration")
    }

    func testNotReadyAdmissionReportsStateStageOnce() async throws {
        let values = DiagnosticConfigurationCollector()
        var configuration = try ProducerConfiguration.makeTesting()
        configuration.onDiagnostic = { @Sendable value in values.append(value) }
        let producer = Producer(
            adapter: RecordingAdapter(),
            configuration: configuration,
            credentials: .testing,
            onSendResult: nil)

        XCTAssertThrowsError(
            try producer.add(LogEvent(contents: ["message": .string("not-ready")]))) { error in
            XCTAssertEqual(error as? ProducerError, .invalidState)
        }

        try await waitUntil(timeout: 2) {
            values.values.filter { $0.kind == .admissionRejected }.count == 1
        }
        let rejected = values.values.filter { $0.kind == .admissionRejected }
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?.context?.admissionStage, "state")
        XCTAssertEqual(rejected.first?.context?.producerErrorName, "invalidState")
    }

    func testSingleLogTooLargeReportsSizeValidationWithoutDuplicateAdmission() async throws {
        let values = DiagnosticConfigurationCollector()
        var configuration = try ProducerConfiguration.makeTesting()
        configuration.batch.maxRawBytes = 1
        configuration.onDiagnostic = { @Sendable value in values.append(value) }
        let adapter = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: adapter,
            configuration: configuration,
            credentials: .testing)

        XCTAssertThrowsError(
            try producer.add(LogEvent(contents: ["message": .string("too-large")]))) { error in
            XCTAssertEqual(error as? ProducerError, .singleLogTooLarge)
        }
        XCTAssertTrue(adapter.addCalls.isEmpty)
        try await producer.close(timeout: 1)

        try await waitUntil(timeout: 2) {
            values.values.contains { $0.kind == .closed } &&
                values.values.filter { $0.kind == .admissionRejected }.count == 1
        }
        let rejected = values.values.filter { $0.kind == .admissionRejected }
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?.context?.admissionStage, "size_validation")
        XCTAssertEqual(rejected.first?.context?.producerErrorName, "singleLogTooLarge")
        let summary = try XCTUnwrap(
            values.values.first(where: { $0.kind == .admissionSummary }))
        XCTAssertEqual(summary.context?.addAttemptedTotal, 1)
        XCTAssertEqual(summary.context?.addAcceptedTotal, 0)
        XCTAssertEqual(summary.context?.addRejectedByError?["singleLogTooLarge"], 1)
    }

    func testBufferFullReportsCoreAddWithoutDuplicateAdmission() async throws {
        let values = DiagnosticConfigurationCollector()
        var configuration = try ProducerConfiguration.makeTesting()
        configuration.onDiagnostic = { @Sendable value in values.append(value) }
        let adapter = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: adapter,
            configuration: configuration,
            credentials: .testing)
        adapter.addError = ProducerError.bufferFull

        XCTAssertThrowsError(
            try producer.add(LogEvent(contents: ["message": .string("buffer-full")]))) { error in
            XCTAssertEqual(error as? ProducerError, .bufferFull)
        }
        XCTAssertEqual(adapter.addCalls.count, 1)
        try await producer.close(timeout: 1)

        try await waitUntil(timeout: 2) {
            values.values.contains { $0.kind == .closed } &&
                values.values.filter { $0.kind == .admissionRejected }.count == 1
        }
        let rejected = values.values.filter { $0.kind == .admissionRejected }
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?.context?.admissionStage, "core_add")
        XCTAssertEqual(rejected.first?.context?.producerErrorName, "bufferFull")
        let summary = try XCTUnwrap(
            values.values.first(where: { $0.kind == .admissionSummary }))
        XCTAssertEqual(summary.context?.addAttemptedTotal, 1)
        XCTAssertEqual(summary.context?.addAcceptedTotal, 0)
        XCTAssertEqual(summary.context?.addRejectedByError?["bufferFull"], 1)
    }

    func testClosedAdmissionReportsStateStageOnceAndPreservesError() async throws {
        let values = DiagnosticConfigurationCollector()
        var configuration = try ProducerConfiguration.makeTesting()
        configuration.onDiagnostic = { @Sendable value in values.append(value) }
        let producer = try await Producer.open(
            adapter: RecordingAdapter(),
            configuration: configuration,
            credentials: .testing)
        try await producer.close(timeout: 1)

        XCTAssertThrowsError(
            try producer.add(LogEvent(contents: ["message": .string("closed")]))) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }

        try await waitUntil(timeout: 2) {
            values.values.filter { $0.kind == .admissionRejected }.count == 1
        }
        let rejected = values.values.filter { $0.kind == .admissionRejected }
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?.context?.admissionStage, "state")
        XCTAssertEqual(rejected.first?.context?.producerErrorName, "closed")
    }

    func testObjectiveCUnmappableModeReportsFacadeModeOnceAndPreservesError() async throws {
        let values = DiagnosticConfigurationCollector()
        var configuration = try ProducerConfiguration.makeTesting()
        configuration.onDiagnostic = { @Sendable value in values.append(value) }
        let swiftProducer = try await Producer.open(
            adapter: RecordingAdapter(),
            configuration: configuration,
            credentials: .testing)
        let objcProducer = TLSProducer.makeForTesting(
            swiftProducer: swiftProducer,
            callbackQueue: configuration.callbackQueue)

        // The enum has no public invalid initializer. This simulates an
        // Objective-C caller passing a value from a newer/unknown header.
        let unmappableMode = unsafeBitCast(99, to: TLSAddMode.self)
        var error: NSError?
        XCTAssertFalse(objcProducer.addLog(
            TLSLogEvent(contents: ["message": "mode"]),
            mode: unmappableMode,
            error: &error))
        XCTAssertEqual(error?.domain, TLSProducer.errorDomain)
        XCTAssertEqual(error?.code, TLSProducerErrorCode.configuration.rawValue)
        XCTAssertEqual(
            error?.userInfo[TLSProducer.errorCodeKey] as? String,
            "configuration")

        try await swiftProducer.close(timeout: 1)
        try await waitUntil(timeout: 2) {
            values.values.contains { $0.kind == .closed } &&
                values.values.filter { $0.kind == .admissionRejected }.count == 1
        }
        let rejected = values.values.filter { $0.kind == .admissionRejected }
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?.context?.admissionStage, "facade_mode")
        XCTAssertEqual(rejected.first?.context?.producerErrorName, "configuration")
        let summary = try XCTUnwrap(
            values.values.first(where: { $0.kind == .admissionSummary }))
        XCTAssertEqual(summary.context?.addAttemptedTotal, 1)
        XCTAssertEqual(summary.context?.addAcceptedTotal, 0)
        XCTAssertEqual(summary.context?.addRejectedByError?["configuration"], 1)
    }

    func testAdmissionRejectionsKeepValidationAndCoreStages() async throws {
        let values = DiagnosticConfigurationCollector()
        var configuration = try ProducerConfiguration.makeTesting()
        configuration.onDiagnostic = { @Sendable value in values.append(value) }
        let adapter = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: adapter,
            configuration: configuration,
            credentials: .testing)

        XCTAssertThrowsError(
            try producer.add(LogEvent(contents: [:]))) { error in
            XCTAssertEqual(error as? ProducerError, .invalidLog(["contents: must contain at least one field"]))
        }
        adapter.addError = ProducerError.queueFull
        XCTAssertThrowsError(
            try producer.add(LogEvent(contents: ["message": .string("core-reject")]))) { error in
            XCTAssertEqual(error as? ProducerError, .queueFull)
        }
        adapter.addError = nil
        try await producer.close(timeout: 1)

        try await waitUntil(timeout: 2) {
            values.values.filter { $0.kind == .admissionRejected }.count == 2
        }
        let rejected = values.values.filter { $0.kind == .admissionRejected }
        XCTAssertEqual(
            rejected.map { $0.context?.admissionStage },
            ["log_validation", "core_add"])
        XCTAssertEqual(
            rejected.map { $0.context?.producerErrorName },
            ["invalidLog", "queueFull"])
    }
}

private final class DiagnosticConfigurationCollector: @unchecked Sendable {
    struct TextValue: Sendable {
        let level: Int
        let message: String
    }

    private let lock = NSLock()
    private var _values: [ProducerDiagnostic] = []
    private var _messages: [TextValue] = []

    var values: [ProducerDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    var messages: [TextValue] {
        lock.lock()
        defer { lock.unlock() }
        return _messages
    }

    func append(_ value: ProducerDiagnostic) {
        lock.lock()
        _values.append(value)
        lock.unlock()
    }

    func appendText(level: Int, message: String) {
        lock.lock()
        _messages.append(TextValue(level: level, message: message))
        lock.unlock()
    }
}
