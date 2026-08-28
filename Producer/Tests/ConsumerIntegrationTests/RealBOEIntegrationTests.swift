//
//  RealBOEIntegrationTests.swift
//  ConsumerIntegrationTests
//
//  Opt-in, real-network evidence for the public Producer facade.
//
//  This file deliberately reads only the process environment. It never loads
//  `.real_boe_info.env` (or any other file), and it never prints endpoint
//  query values, credentials, tokens, or request bodies.
//

import Foundation
import XCTest
import VolcengineTLSProducer

/// Real BOE evidence is opt-in and must be reviewed before execution.
///
/// Required process environment:
///   TLS_RUN_REAL_BOE=1
///   TLS_BOE_ENDPOINT (or VE_TLS_ENDPOINT)
///   TLS_BOE_REGION (or VE_TLS_REGION)
///   TLS_BOE_TOPIC_ID (or VE_TLS_TOPIC_ID)
///   TLS_BOE_ACCESS_KEY_ID (or VE_TLS_ACCESS_KEY_ID)
///   TLS_BOE_ACCESS_KEY_SECRET (or VE_TLS_ACCESS_KEY_SECRET)
///
/// Optional:
///   TLS_BOE_PROJECT_ID (or VE_TLS_PROJECT_ID). The vendored Core retains
///     this metadata but does not use it for v0.3.1 wire routing.
///   TLS_BOE_SECURITY_TOKEN (or VE_TLS_SECURITY_TOKEN)
///   TLS_BOE_REQUIRE_REQUEST_ID=1 (or VE_TLS_REQUIRE_REQUEST_ID=1)
///
/// `TLS_BOE_REQUIRE_REQUEST_ID=1` should be set only when the BOE service
/// contract guarantees `x-tls-requestid` for a successful PutLogs response.
final class RealBOEIntegrationTests: XCTestCase {

    private struct Fixture {
        let destination: Destination
        let credentials: Credentials
        let requireRequestID: Bool

        static func loadOrSkip() throws -> Fixture {
            let environment = ProcessInfo.processInfo.environment
            guard environment["TLS_RUN_REAL_BOE"] == "1" ||
                    environment["VE_TLS_RUN_REAL_BOE"] == "1" else {
                throw XCTSkip(
                    "real BOE tests are opt-in; set TLS_RUN_REAL_BOE=1 after owner review")
            }

            let endpoint = value(in: environment,
                                 names: ["TLS_BOE_ENDPOINT", "VE_TLS_ENDPOINT"])
            let region = value(in: environment,
                               names: ["TLS_BOE_REGION", "VE_TLS_REGION"])
            let projectID = value(in: environment,
                                  names: ["TLS_BOE_PROJECT_ID", "VE_TLS_PROJECT_ID"])
                ?? "boe-metadata-only"
            let topicID = value(in: environment,
                                names: ["TLS_BOE_TOPIC_ID", "VE_TLS_TOPIC_ID"])
            let accessKeyID = value(in: environment,
                                    names: ["TLS_BOE_ACCESS_KEY_ID", "VE_TLS_ACCESS_KEY_ID"])
            let accessKeySecret = value(
                in: environment,
                names: ["TLS_BOE_ACCESS_KEY_SECRET", "VE_TLS_ACCESS_KEY_SECRET"])

            var missing: [String] = []
            if endpoint == nil { missing.append("TLS_BOE_ENDPOINT (or VE_TLS_ENDPOINT)") }
            if region == nil { missing.append("TLS_BOE_REGION (or VE_TLS_REGION)") }
            if topicID == nil { missing.append("TLS_BOE_TOPIC_ID (or VE_TLS_TOPIC_ID)") }
            if accessKeyID == nil {
                missing.append("TLS_BOE_ACCESS_KEY_ID (or VE_TLS_ACCESS_KEY_ID)")
            }
            if accessKeySecret == nil {
                missing.append("TLS_BOE_ACCESS_KEY_SECRET (or VE_TLS_ACCESS_KEY_SECRET)")
            }
            guard missing.isEmpty else {
                throw XCTSkip(
                    "real BOE test variables are incomplete: \(missing.joined(separator: ", "))")
            }

            // The destination and credentials are intentionally built only in
            // memory. ProducerConfiguration/Destination perform their normal
            // validation at the public open boundary.
            let destination = Destination(
                endpoint: endpoint!,
                region: region!,
                projectID: projectID,
                topicID: topicID!)
            let credentials = Credentials(
                accessKeyID: accessKeyID!,
                accessKeySecret: accessKeySecret!,
                securityToken: value(
                    in: environment,
                    names: ["TLS_BOE_SECURITY_TOKEN", "VE_TLS_SECURITY_TOKEN"]))
            let requireRequestID = value(
                in: environment,
                names: ["TLS_BOE_REQUIRE_REQUEST_ID", "VE_TLS_REQUIRE_REQUEST_ID"]) == "1"
            return Fixture(
                destination: destination,
                credentials: credentials,
                requireRequestID: requireRequestID)
        }

        private static func value(
            in environment: [String: String],
            names: [String]
        ) -> String? {
            for name in names {
                if let candidate = environment[name], !candidate.isEmpty {
                    return candidate
                }
            }
            return nil
        }
    }

    /// `SendResult` intentionally does not expose the raw HTTP status. The
    /// vendored C Core emits a successful terminal result only for HTTP 200,
    /// so `.success` plus a nil public error is the public API's 200 proof.
    private final class ResultCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [SendResult] = []

        func append(_ value: SendResult) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var snapshot: [SendResult] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// Sends one unique, non-sensitive event through the public API and waits
    /// for the one terminal callback. No real BOE request is made unless the
    /// explicit opt-in above is present in the test process environment.
    func testRealBOEPublicLifecycleAndHTTP200() async throws {
        let fixture = try Fixture.loadOrSkip()
        let collector = ResultCollector()
        let callbackDelivered = expectation(description: "real BOE terminal callback")
        callbackDelivered.assertForOverFulfill = false

        let configuration = try ProducerConfiguration(
            batch: BatchConfiguration(
                maxLogCount: 1,
                maxRawBytes: 1024 * 1024,
                linger: 0),
            requestTimeout: 15,
            automaticLifecycleHandling: false,
            destination: fixture.destination)

        let producer = try await Producer.open(
            configuration: configuration,
            credentials: fixture.credentials) { result in
                collector.append(result)
                callbackDelivered.fulfill()
            }

        do {
            // UUID makes the single event unique without embedding any
            // endpoint, credential, token, or user payload in test output.
            let event = LogEvent(contents: [
                "sdk_integration_test": .string("ios-simulator-real-boe"),
                "nonce": .string(UUID().uuidString.lowercased()),
            ])
            try producer.add(event, mode: .immediate)
            await fulfillment(of: [callbackDelivered], timeout: 45)

            let results = collector.snapshot
            XCTAssertEqual(
                results.count,
                1,
                "one accepted event must produce one terminal public callback")
            if let result = results.first {
                XCTAssertEqual(result.status, .success,
                               "the BOE PutLogs response must be HTTP 200")
                XCTAssertNil(result.error,
                             "a successful HTTP 200 callback must not carry a public error")
                if fixture.requireRequestID {
                    XCTAssertFalse(
                        result.requestID?.isEmpty ?? true,
                        "BOE request ID was required by the selected service contract")
                }
            }

            // Public close is part of this evidence boundary; success means
            // the producer completed its local shutdown within the bound.
            try await producer.close(timeout: 30)
        } catch {
            // Keep the opt-in test from leaving a sender alive after an
            // assertion-adjacent operational failure. The original error is
            // rethrown and remains the test result.
            try? await producer.close(timeout: 30)
            throw error
        }
    }

    /// Proves that a real BOE signature rejection is surfaced through the
    /// public error contract without retrying it into a different terminal
    /// classification. The deliberately invalid secret is generated in
    /// memory and is never printed or persisted.
    func testRealBOEInvalidSecretMapsToAuth() async throws {
        let fixture = try Fixture.loadOrSkip()
        let collector = ResultCollector()
        let callbackDelivered = expectation(description: "real BOE auth callback")
        callbackDelivered.assertForOverFulfill = false

        let configuration = try ProducerConfiguration(
            batch: BatchConfiguration(
                maxLogCount: 1,
                maxRawBytes: 1024 * 1024,
                linger: 0),
            requestTimeout: 15,
            automaticLifecycleHandling: false,
            destination: fixture.destination)
        let invalidCredentials = Credentials(
            accessKeyID: fixture.credentials.accessKeyID,
            accessKeySecret: "intentionally-invalid-\(UUID().uuidString)",
            securityToken: fixture.credentials.securityToken)
        let producer = try await Producer.open(
            configuration: configuration,
            credentials: invalidCredentials) { result in
                collector.append(result)
                callbackDelivered.fulfill()
            }

        do {
            try producer.add(
                LogEvent(contents: [
                    "sdk_integration_test": .string("ios-simulator-real-boe-auth"),
                    "nonce": .string(UUID().uuidString.lowercased()),
                ]),
                mode: .immediate)
            await fulfillment(of: [callbackDelivered], timeout: 45)
            try await producer.close(timeout: 30)

            let results = collector.snapshot
            XCTAssertEqual(
                results.count,
                1,
                "one accepted event must produce one terminal public callback")
            let result = try XCTUnwrap(results.first)
            XCTAssertEqual(result.status, .failure)
            XCTAssertEqual(result.error, .auth)
        } catch {
            try? await producer.close(timeout: 30)
            throw error
        }
    }
}
