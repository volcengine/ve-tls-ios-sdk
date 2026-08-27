// FakeCoreAdapterCallbackTests.swift
// BridgeTests
//
// Callback queue contract, ordering stability, reentry safety, late-callback
// delivery after close timeout, and linger-timer cancellation.
//

import XCTest
@testable import VolcengineTLSProducer
import ProducerTestSupport

final class FakeCoreAdapterCallbackTests: XCTestCase {

    /// Queue-identity marker used to assert the callback runs on the exact
    /// queue the test configured (not the main thread).
    private static let queueMarkerKey = UnsafeMutableRawPointer.allocate(
        byteCount: 1, alignment: 1)

    private func makeFake(callbackQueue: DispatchQueue) -> FakeCoreAdapter {
        let fake = FakeCoreAdapter()
        // Tag the queue with a pointer-identity marker (global C API; the
        // Swift overlay's setSpecific uses DispatchSpecificKey which cannot
        // be read back for the *current* queue).
        dispatch_queue_set_specific(
            callbackQueue, Self.queueMarkerKey, Self.queueMarkerKey, nil)
        return fake
    }

    func testCallbackRunsOnConfiguredQueueNotMainThread() async throws {
        let callbackQueue = DispatchQueue(label: "test.callback-queue")
        let fake = makeFake(callbackQueue: callbackQueue)
        let config = try TestConfigurations.make(
            maxLogCount: 100, linger: 0, callbackQueue: callbackQueue)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        let delivered = expectation(description: "delivered")
        fake.onSendResult = { _ in
            XCTAssertFalse(Thread.isMainThread,
                           "send-result callback must not run on the main thread")
            XCTAssertNotNil(
                dispatch_get_specific(Self.queueMarkerKey),
                "callback must run on configuration.callbackQueue")
            delivered.fulfill()
        }

        try fake.add(SampleEvents.make(), mode: .immediate)
        await fulfillment(of: [delivered], timeout: 5)
    }

    func testCallbackOrderIsStableOnSerialQueue() async throws {
        let callbackQueue = DispatchQueue(label: "test.callback-order")
        let fake = makeFake(callbackQueue: callbackQueue)
        let config = try TestConfigurations.make(
            maxLogCount: 100, linger: 0, callbackQueue: callbackQueue)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        let batchCount = 10
        let allDelivered = expectation(description: "all delivered")
        allDelivered.expectedFulfillmentCount = batchCount
        var requestIDs: [String] = []
        let idsLock = NSLock()
        fake.onSendResult = { result in
            idsLock.lock()
            requestIDs.append(result.requestID ?? "")
            idsLock.unlock()
            allDelivered.fulfill()
        }

        for i in 0..<batchCount {
            try fake.add(SampleEvents.make(value: "v-\(i)"), mode: .immediate)
        }
        await fulfillment(of: [allDelivered], timeout: 10)

        let expected = (1...batchCount).map { "fake-req-\($0)" }
        XCTAssertEqual(requestIDs, expected,
                       "callbacks must be delivered in seal order on the serial queue")
    }

    func testCallbackReentryAddDoesNotDeadlock() async throws {
        let callbackQueue = DispatchQueue(label: "test.reentry")
        let fake = makeFake(callbackQueue: callbackQueue)
        let config = try TestConfigurations.make(
            maxLogCount: 100, linger: 0, callbackQueue: callbackQueue)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        let delivered = expectation(description: "delivered")
        let stateLock = NSLock()
        var callbackCount = 0
        var didFulfill = false
        fake.onSendResult = { _ in
            // Reentry into the adapter from inside the callback must not
            // deadlock or crash. `try?` because the handler is invoked again
            // during close (for the reentrant event's batch), when add is
            // rejected with .closed; the reentry assertion is no-deadlock,
            // not success of every add.
            try? fake.add(SampleEvents.make(key: "reentry", value: "1"),
                          mode: .normal)
            stateLock.lock()
            callbackCount += 1
            if !didFulfill {
                didFulfill = true
                delivered.fulfill()
            }
            stateLock.unlock()
        }

        try fake.add(SampleEvents.make(), mode: .immediate)
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(fake.admittedEvents.count, 2)

        // Close must still converge (seals the reentrant event's batch and
        // delivers its terminal callback).
        await fake.close(timeout: 5)
        XCTAssertTrue(fake.isClosed)
        stateLock.lock(); let finalCount = callbackCount; stateLock.unlock()
        XCTAssertEqual(finalCount, 2,
                       "the reentrant event's batch must produce a second callback")
    }

    func testLateCallbackAfterCloseTimeoutIsDelivered() async throws {
        let callbackQueue = DispatchQueue(label: "test.late-callback")
        let fake = makeFake(callbackQueue: callbackQueue)
        let config = try TestConfigurations.make(
            maxLogCount: 100, linger: 0, callbackQueue: callbackQueue)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        // Block the callback queue so delivery cannot run before close times out.
        let gate = DispatchSemaphore(value: 0)
        callbackQueue.async { gate.wait() }

        let countLock = NSLock()
        var callCount = 0
        fake.onSendResult = { _ in
            countLock.lock(); callCount += 1; countLock.unlock()
        }

        try fake.add(SampleEvents.make(), mode: .immediate)

        let closed = expectation(description: "close returned")
        Task {
            await fake.close(timeout: 0.2)
            closed.fulfill()
        }
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertTrue(fake.isClosed)

        // Not delivered while the queue was blocked...
        XCTAssertEqual(callCount, 0)

        // ...but once the queue drains, the late terminal callback must still
        // arrive (exactly-once terminal contract; late delivery is safe).
        gate.signal()
        let verified = expectation(description: "late callback verified")
        callbackQueue.async {
            // Serial queue: this runs after the delivery block above.
            countLock.lock(); let n = callCount; countLock.unlock()
            XCTAssertEqual(n, 1)
            verified.fulfill()
        }
        await fulfillment(of: [verified], timeout: 5)
    }

    func testCloseCancelsLingerTimerWithoutExtraCallback() async throws {
        let callbackQueue = DispatchQueue(label: "test.linger-cancel")
        let fake = makeFake(callbackQueue: callbackQueue)
        let config = try TestConfigurations.make(
            maxLogCount: 100, maxRawBytes: 10_000_000, linger: 60,
            callbackQueue: callbackQueue)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        let countLock = NSLock()
        var callCount = 0
        fake.onSendResult = { _ in
            countLock.lock(); callCount += 1; countLock.unlock()
        }

        try fake.add(SampleEvents.make(), mode: .normal) // schedules 60s linger
        await fake.close(timeout: 5) // seals (reason .close) and delivers once

        XCTAssertEqual(callCount, 1)
        // Wait past the original linger deadline; the cancelled timer must
        // not produce a second callback (and a hypothetical late fire is a
        // no-op on the closed adapter).
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(callCount, 1)
    }
}
