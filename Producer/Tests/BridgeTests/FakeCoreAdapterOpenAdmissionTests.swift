// FakeCoreAdapterOpenAdmissionTests.swift
// BridgeTests
//
// open success/failure and add admission contracts (normal vs immediate,
// count/byte sealing thresholds).
//

import XCTest
@testable import VolcengineTLSProducer
import ProducerTestSupport

final class FakeCoreAdapterOpenAdmissionTests: XCTestCase {

    private func makeFake(
        maxLogCount: Int = 1024,
        maxRawBytes: Int = 1_048_576,
        linger: TimeInterval = 0
    ) throws -> (FakeCoreAdapter, ProducerConfiguration) {
        let fake = FakeCoreAdapter()
        let config = try TestConfigurations.make(
            maxLogCount: maxLogCount,
            maxRawBytes: maxRawBytes,
            linger: linger)
        return (fake, config)
    }

    func testOpenSucceedsAndSnapshotsConfiguration() throws {
        let (fake, config) = try makeFake()
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        XCTAssertNotNil(fake.currentCredentials)
        XCTAssertEqual(fake.currentCredentials?.accessKeyID, "ak-A")
        // Destination is not part of open; it arrives via updateDestination.
        XCTAssertNil(fake.currentDestination)
        XCTAssertFalse(fake.isClosed)
        XCTAssertTrue(fake.admittedEvents.isEmpty)
        XCTAssertTrue(fake.sealedBatches.isEmpty)
    }

    func testOpenTwiceThrows() throws {
        let (fake, config) = try makeFake()
        try fake.open(configuration: config, credentials: SampleCredentials.setA)
        XCTAssertThrowsError(
            try fake.open(configuration: config, credentials: SampleCredentials.setB)
        ) { error in
            XCTAssertEqual(error as? ProducerError, .invalidState)
        }
    }

    func testStubbedAdmissionErrorDoesNotAffectOpen() throws {
        let (fake, config) = try makeFake()
        fake.stubbedAdmissionError = .closed
        try fake.open(configuration: config, credentials: SampleCredentials.setA)
        XCTAssertFalse(fake.isClosed)

        // The stub only affects add.
        XCTAssertThrowsError(
            try fake.add(SampleEvents.make(), mode: .normal)
        ) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
        XCTAssertTrue(fake.admittedEvents.isEmpty)
    }

    func testAddBeforeOpenThrows() {
        let fake = FakeCoreAdapter()
        XCTAssertThrowsError(try fake.add(SampleEvents.make(), mode: .normal)) {
            error in
            XCTAssertEqual(error as? ProducerError, .invalidState)
        }
    }

    func testNormalAddEnqueuesWithoutSealing() throws {
        let (fake, config) = try makeFake(maxLogCount: 100, linger: 0)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        for i in 0..<3 {
            try fake.add(SampleEvents.make(value: "v-\(i)"), mode: .normal)
        }

        XCTAssertEqual(fake.admittedEvents.count, 3)
        XCTAssertTrue(fake.sealedBatches.isEmpty, "linger=0 must not seal on its own")
    }

    func testImmediateAddSealsBatch() throws {
        let (fake, config) = try makeFake(maxLogCount: 100, linger: 0)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        try fake.add(SampleEvents.make(value: "a"), mode: .normal)
        try fake.add(SampleEvents.make(value: "b"), mode: .normal)
        try fake.add(SampleEvents.make(value: "c"), mode: .immediate)

        XCTAssertEqual(fake.admittedEvents.count, 3)
        XCTAssertEqual(fake.sealedBatches.count, 1)
        let batch = try XCTUnwrap(fake.sealedBatches.first)
        XCTAssertEqual(batch.events.count, 3)
        XCTAssertEqual(batch.sealReason, .immediate)
        XCTAssertEqual(batch.compressedBytes, batch.rawBytes,
                       "Fake does not compress")
        XCTAssertTrue(batch.requestID.hasPrefix("fake-req-"))
    }

    func testMaxLogCountSealsBatch() throws {
        let (fake, config) = try makeFake(maxLogCount: 3, linger: 0)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        for i in 0..<3 {
            try fake.add(SampleEvents.make(value: "v-\(i)"), mode: .normal)
        }

        XCTAssertEqual(fake.sealedBatches.count, 1)
        XCTAssertEqual(fake.sealedBatches.first?.sealReason, .maxCount)
        XCTAssertEqual(fake.sealedBatches.first?.events.count, 3)
    }

    func testMaxRawBytesSealsBatch() throws {
        // ~200 bytes per event; seal once the batch reaches 500 bytes.
        let (fake, config) = try makeFake(maxLogCount: 1000, maxRawBytes: 500, linger: 0)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        for _ in 0..<5 {
            let value = String(repeating: "x", count: 190)
            try fake.add(SampleEvents.make(value: value), mode: .normal)
        }

        XCTAssertGreaterThanOrEqual(fake.sealedBatches.count, 1)
        let first = try XCTUnwrap(fake.sealedBatches.first)
        XCTAssertEqual(first.sealReason, .maxBytes)
        XCTAssertGreaterThanOrEqual(first.rawBytes, 500)
    }

    /// H1 regression: after the linger timer fires once and seals a batch, it
    /// must reschedule so that a later event's batch also seals on linger.
    func testLingerTimerReschedulesAfterEachSeal() async throws {
        let callbackQueue = DispatchQueue(label: "test.linger-resched")
        let fake = FakeCoreAdapter()
        let config = try TestConfigurations.make(
            maxLogCount: 100, maxRawBytes: 10_000_000, linger: 0.5,
            callbackQueue: callbackQueue)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        let sealedTwice = expectation(description: "two batches sealed by linger")
        sealedTwice.expectedFulfillmentCount = 2
        // Serial callback queue → the handler runs one at a time, so a plain
        // reference box is sufficient synchronization.
        final class ReentryBox { var didAddSecond = false }
        let box = ReentryBox()
        fake.onSendResult = { _ in
            sealedTwice.fulfill()
            if !box.didAddSecond {
                box.didAddSecond = true
                // Admit the second event only after the first batch sealed;
                // its batch must seal on a FRESH linger timer.
                try? fake.add(SampleEvents.make(value: "b"), mode: .normal)
            }
        }

        try fake.add(SampleEvents.make(value: "a"), mode: .normal)
        await fulfillment(of: [sealedTwice], timeout: 5)
        XCTAssertEqual(fake.sealedBatches.count, 2)
        XCTAssertEqual(fake.sealedBatches.map(\.sealReason), [.linger, .linger])
    }

    func testSealedBatchDeliversAsyncSuccessResult() async throws {
        let callbackQueue = DispatchQueue(label: "test.delivery")
        let fake = FakeCoreAdapter()
        let config = try TestConfigurations.make(
            maxLogCount: 100, linger: 0, callbackQueue: callbackQueue)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        let delivered = expectation(description: "terminal callback delivered")
        fake.onSendResult = { result in
            switch result.status {
            case .success:
                break
            default:
                XCTFail("expected .success, got \(result.status)")
            }
            XCTAssertNil(result.error)
            XCTAssertEqual(result.compressedBytes, result.rawBytes)
            XCTAssertTrue(result.requestID?.hasPrefix("fake-req-") ?? false)
            delivered.fulfill()
        }

        let event = SampleEvents.make()
        try fake.add(event, mode: .immediate)
        await fulfillment(of: [delivered], timeout: 5)

        let batch = try XCTUnwrap(fake.sealedBatches.first)
        XCTAssertEqual(batch.rawBytes, event.estimatedRawBytes())
        XCTAssertNotNil(batch.deliveredAt)
    }
}
