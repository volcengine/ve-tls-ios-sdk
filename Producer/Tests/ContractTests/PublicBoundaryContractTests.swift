//
//  PublicBoundaryContractTests.swift
//  ContractTests
//
//  Public open/admission/close boundaries that must stay independent of the
//  real network adapter.
//

import Foundation
import XCTest
@testable import VolcengineTLSProducer

final class PublicBoundaryContractTests: XCTestCase {

    func testPublicOpenRequiresDestination() async {
        do {
            _ = try await Producer.open(
                configuration: .makeTesting(),
                credentials: .testing)
            XCTFail("expected public open without destination to fail")
        } catch let error as ProducerError {
            guard case .configuration(let reason) = error else {
                XCTFail("expected configuration error, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("destination"))
        } catch {
            XCTFail("expected ProducerError.configuration, got \(error)")
        }
    }

    func testPublicOpenRejectsUnsafeDestinations() async throws {
        let cases: [(Destination, String)] = [
            (
                Destination(
                    endpoint: "http://host.example.com",
                    region: "r",
                    projectID: "p",
                    topicID: "t"),
                "https"),
            (
                Destination(
                    endpoint: "https://user:pass@host.example.com",
                    region: "r",
                    projectID: "p",
                    topicID: "t"),
                "userinfo"),
            (
                Destination(
                    endpoint: "https://host.example.com#fragment",
                    region: "r",
                    projectID: "p",
                    topicID: "t"),
                "fragment"),
            (
                Destination(
                    endpoint: "https://host.example.com/base",
                    region: "r",
                    projectID: "p",
                    topicID: "t"),
                "path"),
            (
                Destination(
                    endpoint: "https://host.example.com?token=secret",
                    region: "r",
                    projectID: "p",
                    topicID: "t"),
                "query"),
        ]

        for (destination, reasonFragment) in cases {
            let configuration = try ProducerConfiguration(destination: destination)
            do {
                _ = try await Producer.open(
                    configuration: configuration,
                    credentials: .testing)
                XCTFail("expected unsafe destination to fail")
            } catch let error as ProducerError {
                guard case .configuration(let reason) = error else {
                    XCTFail("expected configuration error, got \(error)")
                    continue
                }
                XCTAssertTrue(
                    reason.contains(reasonFragment),
                    "reason '\(reason)' should contain '\(reasonFragment)'")
            } catch {
                XCTFail("expected ProducerError.configuration, got \(error)")
            }
        }
    }

    func testInjectedOpenRevalidatesPostInitMutationBeforeAdapter() async throws {
        var configuration = try ProducerConfiguration()
        configuration.batch.maxLogCount = 0
        let recording = RecordingAdapter()

        do {
            _ = try await Producer.open(
                adapter: recording,
                configuration: configuration,
                credentials: .testing)
            XCTFail("expected mutated configuration to fail")
        } catch let error as ProducerError {
            guard case .configuration(let reason) = error else {
                XCTFail("expected configuration error, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("maxLogCount"))
        } catch {
            XCTFail("expected ProducerError.configuration, got \(error)")
        }
        XCTAssertEqual(recording.openCallCount, 0)
    }

    func testOpenUsesSanitizedDefensiveURLSessionCopy() async throws {
        let source = URLSessionConfiguration.ephemeral
        let cache = URLCache(
            memoryCapacity: 1024,
            diskCapacity: 1024,
            diskPath: nil)
        source.urlCache = cache
        source.httpShouldSetCookies = true

        var configuration = try ProducerConfiguration()
        configuration.urlSessionConfiguration = source
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: configuration,
            credentials: .testing)

        let opened = try XCTUnwrap(recording.openedConfiguration)
        XCTAssertNil(opened.urlSessionConfiguration.urlCache)
        XCTAssertFalse(opened.urlSessionConfiguration.httpShouldSetCookies)
        XCTAssertIdentical(source.urlCache, cache)
        XCTAssertTrue(source.httpShouldSetCookies)

        try await producer.close(timeout: 1)
    }

    func testOpenAndUpdateCredentialsRejectEmptyAccessKeyOrSecret() async throws {
        let recording = RecordingAdapter()
        do {
            _ = try await Producer.open(
                adapter: recording,
                configuration: .makeTesting(),
                credentials: Credentials(
                    accessKeyID: "",
                    accessKeySecret: "secret"))
            XCTFail("expected empty access key to fail")
        } catch let error as ProducerError {
            guard case .configuration(let reason) = error else {
                XCTFail("expected configuration error, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("accessKeyID"))
        }
        XCTAssertEqual(recording.openCallCount, 0)

        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)
        XCTAssertThrowsError(
            try producer.updateCredentials(
                Credentials(accessKeyID: "ak", accessKeySecret: ""))) { error in
            guard case ProducerError.configuration(let reason) = error else {
                XCTFail("expected configuration error, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("accessKeySecret"))
        }
        XCTAssertTrue(recording.updateCredentialsCalls.isEmpty)
        try await producer.close(timeout: 1)
    }

    func testEmptyContentsRejectedBeforeAdapter() async throws {
        let recording = RecordingAdapter()
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        XCTAssertThrowsError(try producer.add(LogEvent())) { error in
            guard case ProducerError.invalidLog(let paths) = error else {
                XCTFail("expected invalidLog, got \(error)")
                return
            }
            XCTAssertEqual(paths, ["contents: must contain at least one field"])
        }
        XCTAssertTrue(recording.addCalls.isEmpty)
        try await producer.close(timeout: 1)
    }

    func testCloseFailureIsPropagatedAndCanBeRetried() async throws {
        let recording = RecordingAdapter()
        recording.closeErrors = [ProducerError.persistence("flush failed")]
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        do {
            try await producer.close(timeout: 1)
            XCTFail("expected close to fail")
        } catch {
            XCTAssertEqual(
                error as? ProducerError,
                .persistence("flush failed"))
        }
        XCTAssertEqual(recording.closeCallCount, 1)

        XCTAssertThrowsError(
            try producer.add(LogEvent(contents: ["k": .string("v")]))) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }
        XCTAssertThrowsError(try producer.updateCredentials(.testing)) { error in
            XCTAssertEqual(error as? ProducerError, .closed)
        }

        try await producer.close(timeout: 1)
        try await producer.close(timeout: 1)
        XCTAssertEqual(recording.closeCallCount, 2)
    }

    func testConcurrentCloseWaitersReceiveTheSameFailure() async throws {
        let recording = RecordingAdapter()
        recording.closeErrors = [ProducerError.timeout]
        recording.closeDelay = 0.1
        let producer = try await Producer.open(
            adapter: recording,
            configuration: .makeTesting(),
            credentials: .testing)

        let first = Task {
            await closeFailure(for: producer)
        }
        try await waitUntil { recording.closeCallCount == 1 }
        let second = Task {
            await closeFailure(for: producer)
        }

        let firstError = await first.value
        let secondError = await second.value
        XCTAssertEqual(firstError, .timeout)
        XCTAssertEqual(secondError, .timeout)
        XCTAssertEqual(firstError, secondError)
        XCTAssertEqual(recording.closeCallCount, 1)

        // The failed attempt leaves the producer retryable.
        try await producer.close(timeout: 1)
        XCTAssertEqual(recording.closeCallCount, 2)
    }
}

private func closeFailure(for producer: Producer) async -> ProducerError? {
    do {
        try await producer.close(timeout: 1)
        return nil
    } catch {
        return error as? ProducerError
    }
}
