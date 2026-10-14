import Foundation
import XCTest
@testable import VolcengineTLSProducer

final class DiagnosticEmitterTests: XCTestCase {
    func testDisabledEmitterIsNoOpAndDoesNotInvokeCallbacks() {
        let structured = LockedValues<ProducerDiagnostic>()
        let text = LockedValues<String>()
        let emitter = DiagnosticEmitter(
            structuredHandler: nil,
            textHandler: { _, message in text.append(message) },
            level: .off)

        XCTAssertFalse(emitter.isEnabled)
        XCTAssertFalse(emitter.offer(ProducerDiagnostic(kind: .opened)))
        emitter.recordAdmission(accepted: true)
        emitter.admissionSummary()
        emitter.finish()
        XCTAssertTrue(structured.values.isEmpty)
        XCTAssertTrue(text.values.isEmpty)
    }

    func testStructuredThenTextShareSequenceAndSnapshotContext() throws {
        let expectation = expectation(description: "both callbacks")
        expectation.expectedFulfillmentCount = 2
        let order = LockedValues<String>()
        let structured = LockedValues<ProducerDiagnostic>()
        let emitter = DiagnosticEmitter(
            structuredHandler: { value in
                order.append("structured")
                structured.append(value)
                expectation.fulfill()
            },
            textHandler: { level, message in
                XCTAssertEqual(level, .info)
                XCTAssertNotNil(Self.jsonObject(message))
                order.append("text")
                expectation.fulfill()
            },
            level: .info,
            producerID: "producer-a",
            topicID: "topic-a",
            endpoint: "https://logs.example.com",
            producerInstanceID: "instance-a",
            sdkVersion: "1.2.3",
            clock: DiagnosticEmitterClock(wallMilliseconds: { 1234 }, monotonicNanoseconds: { 99 }))

        XCTAssertTrue(emitter.offer(ProducerDiagnostic(kind: .opened)))
        wait(for: [expectation], timeout: 2)
        emitter.finish()

        let value = try XCTUnwrap(structured.values.first)
        XCTAssertEqual(value.context?.sequence, 1)
        XCTAssertEqual(value.context?.timeMs, 1234)
        XCTAssertEqual(value.context?.producerID, "producer-a")
        XCTAssertEqual(value.context?.topicID, "topic-a")
        XCTAssertEqual(value.context?.endpointHost, "logs.example.com")
        XCTAssertEqual(order.values, ["structured", "text"])
    }

    func testTextLevelThresholdLeavesStructuredDeliveryIndependent() {
        for (configured, expectedCount) in [
            (ProducerDiagnosticLogLevel.debug, 4),
            (.info, 3),
            (.warning, 2),
            (.error, 1),
        ] {
            let structured = LockedValues<ProducerDiagnostic>()
            let text = LockedValues<ProducerDiagnosticLogLevel>()
            let emitter = DiagnosticEmitter(
                structuredHandler: { structured.append($0) },
                textHandler: { level, _ in text.append(level) },
                level: configured,
                clock: DiagnosticEmitterClock(wallMilliseconds: { 1 }))
            let events = [
                ProducerDiagnostic(kind: .batchSealed),
                ProducerDiagnostic(kind: .opened),
                ProducerDiagnostic(kind: .admissionRejected),
                ProducerDiagnostic(kind: .openFailed, reason: .nonRetryable),
            ]
            for event in events { XCTAssertTrue(emitter.offer(event)) }
            eventually(timeout: 2) { structured.values.count == events.count }
            eventually(timeout: 2) { text.values.count == expectedCount }
            XCTAssertEqual(structured.values.count, events.count)
            XCTAssertEqual(text.values.count, expectedCount)
            emitter.finish()
        }
    }

    func testWallClockRegressionPreservesOccurrenceTimeAndDiagnosticDurations() {
        let values = LockedValues<ProducerDiagnostic>()
        let clock = RegressingDiagnosticClock(wallMilliseconds: [200, 100])
        let emitter = DiagnosticEmitter(
            structuredHandler: { values.append($0) },
            level: .off,
            clock: DiagnosticEmitterClock(
                wallMilliseconds: { clock.nextWallMilliseconds() },
                monotonicNanoseconds: { clock.nextMonotonicNanoseconds() }))

        var first = ProducerDiagnosticDetails()
        first.source = "core"
        first.attemptID = "d14-attempt-1"
        first.attemptElapsedMs = 12
        first.queueWaitMs = 4
        var second = ProducerDiagnosticDetails()
        second.source = "core"
        second.attemptID = "d14-attempt-2"
        second.attemptElapsedMs = 0
        second.queueWaitMs = 8

        XCTAssertTrue(emitter.offer(ProducerDiagnostic(kind: .attemptFinished, context: first)))
        XCTAssertTrue(emitter.offer(ProducerDiagnostic(kind: .attemptFinished, context: second)))
        eventually(timeout: 2) { values.values.count == 2 }

        let events = values.values
        XCTAssertEqual(events.compactMap { $0.context?.timeMs }, [200, 100])
        XCTAssertEqual(events.compactMap { $0.context?.sequence }, [1, 2])
        XCTAssertEqual(events[0].context?.attemptElapsedMs, 12)
        XCTAssertEqual(events[0].context?.queueWaitMs, 4)
        XCTAssertEqual(events[1].context?.attemptElapsedMs, 0)
        XCTAssertEqual(events[1].context?.queueWaitMs, 8)
        XCTAssertTrue(events.allSatisfy {
            ($0.context?.attemptElapsedMs ?? -1) >= 0 &&
            ($0.context?.queueWaitMs ?? -1) >= 0
        })
        XCTAssertEqual(clock.monotonicSampleCount, 2)
        emitter.finish()
    }

    func testAdmissionSummaryContainsFacadeAndNativeCounters() throws {
        let expectation = expectation(description: "summary")
        let values = LockedValues<ProducerDiagnostic>()
        let emitter = DiagnosticEmitter(
            structuredHandler: { value in
                values.append(value)
                if value.kind == .admissionSummary { expectation.fulfill() }
            },
            level: .off,
            clock: DiagnosticEmitterClock(wallMilliseconds: { 10 }))
        // A structured handler remains enabled when text is off.
        emitter.recordAdmission(accepted: true)
        emitter.recordAdmission(accepted: false, errorName: "buffer_full")
        emitter.recordAdmission(accepted: false, errorName: "buffer_full")
        var native = ProducerDiagnosticDetails()
        native.coreRequestsTotal = 7
        native.bufferUsedBytes = 128
        emitter.admissionSummary(nativeFields: native)
        wait(for: [expectation], timeout: 2)
        let summary = try XCTUnwrap(values.values.first(where: { $0.kind == .admissionSummary }))
        XCTAssertEqual(summary.context?.addAttemptedTotal, 3)
        XCTAssertEqual(summary.context?.addAcceptedTotal, 1)
        XCTAssertEqual(summary.context?.addRejectedByError?["buffer_full"], 2)
        XCTAssertEqual(summary.context?.coreRequestsTotal, 7)
        XCTAssertEqual(summary.context?.bufferUsedBytes, 128)
        emitter.finish()
    }

    func testFinishDoesNotDisableClosedBoundaryDiagnostics() {
        let values = LockedValues<ProducerDiagnostic>()
        let emitter = DiagnosticEmitter(
            structuredHandler: { values.append($0) },
            level: .off,
            clock: DiagnosticEmitterClock(wallMilliseconds: { 10 }))
        XCTAssertTrue(emitter.offer(ProducerDiagnostic(kind: .closed, reason: .closed)))
        emitter.finish()
        XCTAssertTrue(emitter.offer(ProducerDiagnostic(
            kind: .admissionRejected,
            reason: .nonRetryable,
            errorCode: "producer_closed")))
        eventually(timeout: 2) { values.values.count == 2 }
        XCTAssertEqual(values.values.map(\.kind), [.closed, .admissionRejected])
    }

    func testBlockingHandlerUsesBoundedCapacityAndEmitsDropSummary() throws {
        let handlerStarted = expectation(description: "handler started")
        let release = DispatchSemaphore(value: 0)
        let expectation = expectation(description: "drop summary")
        let values = LockedValues<ProducerDiagnostic>()
        let emitter = DiagnosticEmitter(
            structuredHandler: { value in
                values.append(value)
                if value.kind == .opened { handlerStarted.fulfill(); _ = release.wait(timeout: .now() + 2) }
                if value.kind == .diagnosticsDropped { expectation.fulfill() }
            },
            level: .off,
            capacity: 1_024,
            clock: DiagnosticEmitterClock(wallMilliseconds: { 10 }))

        XCTAssertTrue(emitter.offer(ProducerDiagnostic(kind: .opened)))
        wait(for: [handlerStarted], timeout: 2)
        var accepted = 0
        for _ in 0..<1_024 {
            if emitter.offer(ProducerDiagnostic(kind: .batchSealed)) { accepted += 1 }
        }
        var dropped = 0
        for _ in 0..<32 {
            if !emitter.offer(ProducerDiagnostic(kind: .batchSealed)) { dropped += 1 }
        }
        XCTAssertEqual(accepted, 1_024)
        XCTAssertEqual(dropped, 32)
        release.signal()
        wait(for: [expectation], timeout: 5)
        eventually(timeout: 2) { values.values.count >= 1_026 }
        let summary = try XCTUnwrap(values.values.first(where: { $0.kind == .diagnosticsDropped }))
        XCTAssertEqual(summary.context?.diagnosticDroppedSinceLastReport, 32)
        emitter.finish()
    }

    func testConcurrentOffersHaveFIFOSequenceAndCaptureOccurrenceTime() {
        let values = LockedValues<ProducerDiagnostic>()
        let expected = 300
        let emitter = DiagnosticEmitter(
            structuredHandler: { values.append($0) },
            level: .off,
            capacity: expected,
            clock: DiagnosticEmitterClock(wallMilliseconds: { 777 }))
        DispatchQueue.concurrentPerform(iterations: expected) { _ in
            _ = emitter.offer(ProducerDiagnostic(kind: .batchSealed))
        }
        eventually(timeout: 5) { values.values.count == expected }
        let events = values.values
        XCTAssertEqual(events.count, expected)
        let sequences = events.compactMap { $0.context?.sequence }
        XCTAssertEqual(sequences, Array(1...Int64(expected)))
        XCTAssertTrue(events.allSatisfy { $0.context?.timeMs == 777 })
        emitter.finish()
    }

    func testInvalidSensitiveStringsAreAbsentAndValidRequestIDIsComplete() throws {
        let expectation = expectation(description: "sanitized callback")
        let values = LockedValues<ProducerDiagnostic>()
        let validRequestID = String(repeating: "a", count: 200)
        var details = ProducerDiagnosticDetails()
        details.producerID = "ak=secret"
        details.endpointHost = "https://user:password@example.com/path?token=secret"
        details.producerErrorName = "server message with password"
        details.requestID = nil
        let emitter = DiagnosticEmitter(
            structuredHandler: { value in
                values.append(value)
                expectation.fulfill()
            },
            textHandler: { _, message in
                XCTAssertFalse(message.contains("secret"))
            },
            level: .debug,
            producerID: "safe-producer",
            topicID: "safe-topic",
            endpoint: "https://safe.example.com",
            clock: DiagnosticEmitterClock(wallMilliseconds: { 9 }))
        XCTAssertTrue(emitter.offer(ProducerDiagnostic(
            kind: .transportFinished,
            requestID: validRequestID,
            errorCode: "Authorization: Bearer secret",
            context: details)))
        wait(for: [expectation], timeout: 2)
        let value = try XCTUnwrap(values.values.first)
        XCTAssertEqual(value.requestID, validRequestID)
        XCTAssertNil(value.errorCode)
        XCTAssertEqual(value.context?.producerID, "safe-producer")
        XCTAssertEqual(value.context?.endpointHost, "safe.example.com")
        XCTAssertNil(value.context?.producerErrorName)
        emitter.finish()
    }

    func testTransportRequestIDCorrelationRejectsNormalizedCoreValueAndKeepsValidID() {
        let values = LockedValues<ProducerDiagnostic>()
        let clock = MutableDiagnosticClock()
        let emitter = DiagnosticEmitter(
            structuredHandler: { values.append($0) },
            level: .off,
            clock: DiagnosticEmitterClock(
                wallMilliseconds: { 10 },
                monotonicNanoseconds: { clock.monotonicNanoseconds }))

        var invalidTransport = ProducerDiagnosticDetails()
        invalidTransport.source = "transport"
        invalidTransport.attemptID = "attempt-invalid"
        invalidTransport.requestID = "rid/rewritten"
        invalidTransport.fieldsOmitted = true
        XCTAssertTrue(emitter.offer(ProducerDiagnostic(
            kind: .transportFinished,
            requestID: "bad_id",
            context: invalidTransport)))

        var invalidCore = ProducerDiagnosticDetails()
        invalidCore.source = "core"
        invalidCore.attemptID = "attempt-invalid"
        XCTAssertTrue(emitter.offer(ProducerDiagnostic(
            kind: .attemptFinished,
            requestID: "bad_id",
            context: invalidCore)))

        var validTransport = ProducerDiagnosticDetails()
        validTransport.source = "transport"
        validTransport.attemptID = "attempt-valid"
        validTransport.requestID = "rid.complete-123"
        XCTAssertTrue(emitter.offer(ProducerDiagnostic(
            kind: .transportFinished,
            requestID: "bad_id",
            context: validTransport)))

        var validCore = ProducerDiagnosticDetails()
        validCore.source = "core"
        validCore.attemptID = "attempt-valid"
        XCTAssertTrue(emitter.offer(ProducerDiagnostic(
            kind: .attemptFinished,
            requestID: "bad_id",
            context: validCore)))

        var otherCore = ProducerDiagnosticDetails()
        otherCore.source = "core"
        otherCore.attemptID = "attempt-other"
        XCTAssertTrue(emitter.offer(ProducerDiagnostic(
            kind: .attemptFinished,
            requestID: "bad_id",
            context: otherCore)))

        eventually(timeout: 2) { values.values.count == 5 }
        let events = values.values
        let invalidPair = events.filter { $0.context?.attemptID == "attempt-invalid" }
        XCTAssertEqual(invalidPair.count, 2)
        XCTAssertTrue(invalidPair.allSatisfy { $0.requestID == nil })
        XCTAssertTrue(invalidPair.allSatisfy { $0.context?.requestID == nil })
        XCTAssertTrue(invalidPair.allSatisfy { $0.context?.fieldsOmitted == true })

        let validPair = events.filter { $0.context?.attemptID == "attempt-valid" }
        XCTAssertEqual(validPair.count, 2)
        XCTAssertTrue(validPair.allSatisfy { $0.requestID == "rid.complete-123" })
        XCTAssertTrue(validPair.allSatisfy { $0.context?.requestID == "rid.complete-123" })

        let other = events.first { $0.context?.attemptID == "attempt-other" }
        XCTAssertNil(other?.requestID)
        XCTAssertTrue(other?.context?.fieldsOmitted == true)
        emitter.finish()
    }

    func testRequestIDAssociationIsBoundedAt128AndExpiresAfterThirtySeconds() {
        let values = LockedValues<ProducerDiagnostic>()
        let clock = MutableDiagnosticClock()
        let emitter = DiagnosticEmitter(
            structuredHandler: { values.append($0) },
            level: .off,
            clock: DiagnosticEmitterClock(
                wallMilliseconds: { 10 },
                monotonicNanoseconds: { clock.monotonicNanoseconds }))

        for index in 0..<129 {
            var transport = ProducerDiagnosticDetails()
            transport.source = "transport"
            transport.attemptID = "cache-" + String(index)
            transport.requestID = "rid-" + String(index)
            XCTAssertTrue(emitter.offer(ProducerDiagnostic(
                kind: .transportFinished,
                requestID: "bad_id",
                context: transport)))
        }

        var evictedCore = ProducerDiagnosticDetails()
        evictedCore.source = "core"
        evictedCore.attemptID = "cache-0"
        XCTAssertTrue(emitter.offer(ProducerDiagnostic(
            kind: .attemptFinished,
            requestID: "bad_id",
            context: evictedCore)))

        var retainedCore = ProducerDiagnosticDetails()
        retainedCore.source = "core"
        retainedCore.attemptID = "cache-128"
        XCTAssertTrue(emitter.offer(ProducerDiagnostic(
            kind: .attemptFinished,
            requestID: "bad_id",
            context: retainedCore)))

        var expiringTransport = ProducerDiagnosticDetails()
        expiringTransport.source = "transport"
        expiringTransport.attemptID = "cache-expiring"
        expiringTransport.requestID = "rid-expiring"
        XCTAssertTrue(emitter.offer(ProducerDiagnostic(
            kind: .transportFinished,
            requestID: "bad_id",
            context: expiringTransport)))
        clock.setMonotonic(30_000_000_001)
        var expiredCore = ProducerDiagnosticDetails()
        expiredCore.source = "core"
        expiredCore.attemptID = "cache-expiring"
        XCTAssertTrue(emitter.offer(ProducerDiagnostic(
            kind: .attemptFinished,
            requestID: "bad_id",
            context: expiredCore)))

        eventually(timeout: 3) { values.values.count == 133 }
        let events = values.values
        XCTAssertEqual(
            events.first {
                $0.kind == .attemptFinished && $0.context?.attemptID == "cache-0"
            }?.requestID,
            nil)
        XCTAssertTrue(events.first {
            $0.kind == .attemptFinished && $0.context?.attemptID == "cache-0"
        }?.context?.fieldsOmitted == true)
        XCTAssertEqual(
            events.first {
                $0.kind == .attemptFinished && $0.context?.attemptID == "cache-128"
            }?.requestID,
            "rid-128")
        XCTAssertEqual(
            events.first {
                $0.kind == .attemptFinished && $0.context?.attemptID == "cache-expiring"
            }?.requestID,
            nil)
        XCTAssertTrue(events.first {
            $0.kind == .attemptFinished && $0.context?.attemptID == "cache-expiring"
        }?.context?.fieldsOmitted == true)
        emitter.finish()
    }

    private static func jsonObject(_ message: String) -> [String: Any]? {
        guard let data = message.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func eventually(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(condition())
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock(); storage.append(value); lock.unlock()
    }
}

private final class MutableDiagnosticClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var monotonicNanoseconds: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func setMonotonic(_ value: UInt64) {
        lock.lock(); self.value = value; lock.unlock()
    }
}

private final class RegressingDiagnosticClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wallValues: [Int64]
    private var wallIndex = 0
    private var monotonicValue: UInt64 = 0
    private(set) var monotonicSampleCount = 0

    init(wallMilliseconds: [Int64]) {
        self.wallValues = wallMilliseconds
    }

    func nextWallMilliseconds() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let value = wallValues[min(wallIndex, wallValues.count - 1)]
        wallIndex += 1
        return value
    }

    func nextMonotonicNanoseconds() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        monotonicValue += 1_000_000
        monotonicSampleCount += 1
        return monotonicValue
    }
}
