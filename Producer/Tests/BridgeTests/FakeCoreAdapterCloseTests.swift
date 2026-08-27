// FakeCoreAdapterCloseTests.swift
// BridgeTests
//
// close idempotency, add-after-close rejection, and bounded flush of the
// pending batch at close.
//

import XCTest
@testable import VolcengineTLSProducer
import ProducerTestSupport

final class FakeCoreAdapterCloseTests: XCTestCase {

    func testCloseIsIdempotent() async throws {
        let fake = FakeCoreAdapter()
        let config = try TestConfigurations.make(
            maxLogCount: 100, linger: 0)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        await fake.close(timeout: 5)
        XCTAssertTrue(fake.isClosed)
        let callsAfterFirstClose = fake.closeCallCount

        // A second close must complete normally and perform no new work.
        await fake.close(timeout: 5)
        XCTAssertTrue(fake.isClosed)
        XCTAssertEqual(fake.closeCallCount, callsAfterFirstClose)
    }

    func testCloseWithoutOpenIsSafe() async {
        let fake = FakeCoreAdapter()
        await fake.close(timeout: 1)
        XCTAssertTrue(fake.isClosed)
    }

    func testAddAfterCloseThrowsClosed() async throws {
        let fake = FakeCoreAdapter()
        let config = try TestConfigurations.make(
            maxLogCount: 100, linger: 0)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)
        await fake.close(timeout: 5)

        XCTAssertThrowsError(
            try fake.add(SampleEvents.make(), mode: .normal)
        ) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
        XCTAssertTrue(fake.admittedEvents.isEmpty)
    }

    func testCloseSealsPendingBatchAndDelivers() async throws {
        let callbackQueue = DispatchQueue(label: "test.close-flush")
        let fake = FakeCoreAdapter()
        let config = try TestConfigurations.make(
            maxLogCount: 100, linger: 60, callbackQueue: callbackQueue)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        let delivered = expectation(description: "delivered")
        fake.onSendResult = { _ in delivered.fulfill() }

        try fake.add(SampleEvents.make(value: "a"), mode: .normal)
        try fake.add(SampleEvents.make(value: "b"), mode: .normal)
        // No seal yet (linger 60s). close performs a bounded flush.
        await fake.close(timeout: 5)

        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(fake.sealedBatches.count, 1)
        XCTAssertEqual(fake.sealedBatches.first?.sealReason, .close)
        XCTAssertEqual(fake.sealedBatches.first?.events.count, 2)
        XCTAssertNotNil(fake.sealedBatches.first?.deliveredAt)
    }

    /// M2: concurrent closes while a delivery is in flight must register as
    /// waiters (not take the idempotent fast path), all return once the
    /// delivery completes, and only one close performs real shutdown.
    func testConcurrentCloseCallsMergeOnWaiters() async throws {
        let callbackQueue = DispatchQueue(label: "test.close-merge")
        let fake = FakeCoreAdapter()
        let config = try TestConfigurations.make(
            maxLogCount: 100, linger: 0, callbackQueue: callbackQueue)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        // Block delivery so close takes the waiter path (pendingDeliveries>0).
        let gate = DispatchSemaphore(value: 0)
        callbackQueue.async { gate.wait() }

        fake.onSendResult = { _ in }
        try fake.add(SampleEvents.make(), mode: .immediate) // seals; delivery queued

        // Five concurrent closes: all must join as waiters and return once
        // the delivery completes, without trapping on double resume.
        let group = DispatchGroup()
        for _ in 0..<5 {
            group.enter()
            Task {
                await fake.close(timeout: 5)
                group.leave()
            }
        }
        // Give the closes time to register as waiters.
        try? await Task.sleep(nanoseconds: 100_000_000)

        gate.signal()
        group.wait()

        XCTAssertTrue(fake.isClosed)
        XCTAssertEqual(fake.closeCallCount, 1,
                       "only the first close performs shutdown; the rest join")
    }

    // MARK: - M3: concurrent failure paths

    func testAddDuringCloseInFlightThrowsClosed() async throws {
        let fake = FakeCoreAdapter()
        fake.artificialCloseDelay = 0.3
        let config = try TestConfigurations.make(
            maxLogCount: 100, linger: 0)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        let closeTask = Task { await fake.close(timeout: 5) }
        // Wait until close has entered its in-flight window.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertThrowsError(
            try fake.add(SampleEvents.make(), mode: .normal)
        ) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
        closeTask.cancel() // don't wait the full artificial delay
        _ = await closeTask.value
        XCTAssertTrue(fake.isClosed)
    }

    func testUpdateCredentialsDuringCloseInFlightThrowsClosed() async throws {
        let fake = FakeCoreAdapter()
        fake.artificialCloseDelay = 0.3
        let config = try TestConfigurations.make(
            maxLogCount: 100, linger: 0)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        let closeTask = Task { await fake.close(timeout: 5) }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertThrowsError(
            try fake.updateCredentials(SampleCredentials.setB)
        ) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
        closeTask.cancel()
        _ = await closeTask.value
        XCTAssertTrue(fake.isClosed)
    }

    func testUpdateDestinationDuringCloseInFlightThrowsClosed() async throws {
        let fake = FakeCoreAdapter()
        fake.artificialCloseDelay = 0.3
        let config = try TestConfigurations.make(
            maxLogCount: 100, linger: 0)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        let closeTask = Task { await fake.close(timeout: 5) }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertThrowsError(
            try fake.updateDestination(SampleDestinations.shanghai)
        ) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
        closeTask.cancel()
        _ = await closeTask.value
        XCTAssertTrue(fake.isClosed)
    }

    func testUpdateBeforeOpenThrowsInvalidState() {
        let fake = FakeCoreAdapter()
        XCTAssertThrowsError(
            try fake.updateCredentials(SampleCredentials.setA)
        ) { error in
            XCTAssertEqual(error as? ProducerError, .invalidState)
        }
        XCTAssertThrowsError(
            try fake.updateDestination(SampleDestinations.beijing)
        ) { error in
            XCTAssertEqual(error as? ProducerError, .invalidState)
        }
    }
}
