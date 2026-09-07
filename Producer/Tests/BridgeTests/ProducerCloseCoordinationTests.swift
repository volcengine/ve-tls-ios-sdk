// ProducerCloseCoordinationTests.swift
// BridgeTests
//
// Producer-level close coordination observed through FakeCoreAdapter:
// multiple/concurrent close awaits finalize exactly once, Task cancellation
// must not cause duplicate resume or crash, and add after close is rejected.
//
// Producer construction goes through ProducerTestHarness.makeProducer(...).
//

import XCTest
@testable import VolcengineTLSProducer

final class ProducerCloseCoordinationTests: XCTestCase {

    private func makeProducer(
        fake: FakeCoreAdapter,
        artificialCloseDelay: TimeInterval = 0
    ) async throws -> Producer {
        fake.artificialCloseDelay = artificialCloseDelay
        let config = try TestConfigurations.make(
            maxLogCount: 100, linger: 0)
        return try await ProducerTestHarness.makeProducer(
            configuration: config,
            credentials: SampleCredentials.setA,
            adapter: fake)
    }

    func testMultipleConcurrentCloseCallsFinalizeOnce() async throws {
        let fake = FakeCoreAdapter()
        let producer = try await makeProducer(fake: fake, artificialCloseDelay: 0.1)

        // Concurrent close calls: the Producer must finalize exactly once.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = try? await producer.close(timeout: 5)
                }
            }
            try await group.waitForAll()
        }

        XCTAssertTrue(fake.isClosed)
        XCTAssertEqual(fake.closeCallCount, 1,
                       "Producer must finalize the core exactly once across "
                       + "concurrent close calls")
    }

    func testSequentialCloseCallsFinalizeOnce() async throws {
        let fake = FakeCoreAdapter()
        let producer = try await makeProducer(fake: fake)

        try await producer.close(timeout: 5)
        try await producer.close(timeout: 5)

        XCTAssertTrue(fake.isClosed)
        XCTAssertEqual(fake.closeCallCount, 1)
    }

    func testTaskCancellationDoesNotCrashOrDuplicateFinalization() async throws {
        let fake = FakeCoreAdapter()
        let producer = try await makeProducer(fake: fake, artificialCloseDelay: 0.3)

        // Start close, let it enter the in-flight window, THEN cancel.
        let task = Task { try await producer.close(timeout: 5) }
        try? await Task.sleep(nanoseconds: 100_000_000) // in-flight
        task.cancel()
        _ = try? await task.value

        // The close must still converge exactly once.
        try await producer.close(timeout: 5)
        XCTAssertTrue(fake.isClosed)
        XCTAssertEqual(fake.closeCallCount, 1,
                       "cancelled close must not duplicate finalization")
    }

    func testAddAfterCloseIsRejected() async throws {
        let fake = FakeCoreAdapter()
        let producer = try await makeProducer(fake: fake)

        try await producer.close(timeout: 5)

        XCTAssertThrowsError(
            try producer.add(SampleEvents.make(), mode: .normal)
        ) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
        XCTAssertTrue(fake.admittedEvents.isEmpty)
    }
}
