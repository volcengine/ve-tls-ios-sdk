// FakeCoreAdapterUpdateTests.swift
// BridgeTests
//
// updateCredentials whole-group atomicity (no AK/SK/token mixing in
// in-flight batches) and updateDestination current-target semantics.
//

import XCTest
@testable import VolcengineTLSProducer

final class FakeCoreAdapterUpdateTests: XCTestCase {

    func testSealedBatchKeepsCredentialsSnapshot() async throws {
        let callbackQueue = DispatchQueue(label: "test.creds-snapshot")
        let fake = FakeCoreAdapter()
        let config = try TestConfigurations.make(
            maxLogCount: 1, linger: 0, callbackQueue: callbackQueue)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        let delivered = expectation(description: "delivered")
        fake.onSendResult = { _ in delivered.fulfill() }

        // maxLogCount=1 seals immediately with the setA snapshot.
        try fake.add(SampleEvents.make(), mode: .normal)
        // Whole-group replacement while the batch is in flight.
        try fake.updateCredentials(SampleCredentials.setB)

        await fulfillment(of: [delivered], timeout: 5)

        let batch = try XCTUnwrap(fake.sealedBatches.first)
        XCTAssertEqual(batch.credentials, SampleCredentials.setA)
        XCTAssertEqual(fake.currentCredentials, SampleCredentials.setB)
    }

    func testConcurrentCredentialUpdatesNeverMixGroups() throws {
        let fake = FakeCoreAdapter()
        let config = try TestConfigurations.make(
            maxLogCount: 1, linger: 0,
            callbackQueue: DispatchQueue(label: "test.creds-concurrent"))
        try fake.open(configuration: config, credentials: SampleCredentials.setA)

        let iterations = 40
        let group = DispatchGroup()
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                let credentials = SampleCredentials.allSets[i % SampleCredentials.allSets.count]
                try? fake.updateCredentials(credentials)
                try? fake.add(SampleEvents.make(value: "i-\(i)"), mode: .normal)
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(fake.sealedBatches.count, iterations)
        for batch in fake.sealedBatches {
            XCTAssertTrue(
                SampleCredentials.isCoherentWholeGroup(batch.credentials),
                "batch \(batch.id) mixes values across credential groups: "
                    + "\(batch.credentials.accessKeyID)/"
                    + "\(batch.credentials.accessKeySecret)/"
                    + "\(batch.credentials.securityToken ?? "<nil>")")
        }
    }

    func testUpdateDestinationRetargetsUndeliveredBatch() async throws {
        let callbackQueue = DispatchQueue(label: "test.dest-retarget")
        let fake = FakeCoreAdapter()
        let config = try TestConfigurations.make(
            maxLogCount: 1, linger: 0, callbackQueue: callbackQueue)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)
        // Initial destination is set via updateDestination (not part of open).
        try fake.updateDestination(SampleDestinations.beijing)

        // Block delivery so the batch stays "in flight" during the retarget.
        let gate = DispatchSemaphore(value: 0)
        callbackQueue.async { gate.wait() }

        let delivered = expectation(description: "delivered")
        fake.onSendResult = { _ in delivered.fulfill() }

        try fake.add(SampleEvents.make(), mode: .immediate)
        // Current-target: the not-yet-delivered batch is atomically retargeted.
        try fake.updateDestination(SampleDestinations.shanghai)

        let batch = try XCTUnwrap(fake.sealedBatches.first)
        XCTAssertEqual(batch.destination?.topicID, "topic-b")
        XCTAssertEqual(fake.currentDestination?.topicID, "topic-b")

        gate.signal()
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertNotNil(fake.sealedBatches.first?.deliveredAt)
        XCTAssertEqual(fake.sealedBatches.first?.destination?.topicID, "topic-b",
                       "retarget must survive delivery")
    }

    func testUpdateDestinationDoesNotRewriteDeliveredBatch() async throws {
        let callbackQueue = DispatchQueue(label: "test.dest-delivered")
        let fake = FakeCoreAdapter()
        let config = try TestConfigurations.make(
            maxLogCount: 1, linger: 0, callbackQueue: callbackQueue)
        try fake.open(configuration: config, credentials: SampleCredentials.setA)
        try fake.updateDestination(SampleDestinations.beijing)

        let delivered = expectation(description: "delivered")
        fake.onSendResult = { _ in delivered.fulfill() }

        try fake.add(SampleEvents.make(), mode: .immediate)
        await fulfillment(of: [delivered], timeout: 5)

        try fake.updateDestination(SampleDestinations.shanghai)
        XCTAssertEqual(fake.sealedBatches.first?.destination?.topicID, "topic-a",
                       "delivered batches keep their historical destination")
        XCTAssertEqual(fake.currentDestination?.topicID, "topic-b")
    }

    func testUpdateAfterCloseThrows() async throws {
        let fake = FakeCoreAdapter()
        let config = try TestConfigurations.make()
        try fake.open(configuration: config, credentials: SampleCredentials.setA)
        try await fake.close(timeout: 5)

        XCTAssertThrowsError(
            try fake.updateCredentials(SampleCredentials.setB)
        ) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
        XCTAssertThrowsError(
            try fake.updateDestination(SampleDestinations.shanghai)
        ) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
    }
}
