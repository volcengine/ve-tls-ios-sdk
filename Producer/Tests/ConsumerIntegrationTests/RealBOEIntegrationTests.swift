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

        func waitForCount(_ expected: Int, timeout: TimeInterval) async -> [SendResult] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let values = snapshot
                if values.count >= expected {
                    return values
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return snapshot
        }
    }

    private static func environmentValue(_ names: [String]) -> String? {
        let environment = ProcessInfo.processInfo.environment
        return names.lazy.compactMap { name in
            guard let value = environment[name], !value.isEmpty else { return nil }
            return value
        }.first
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

    /// Writes a deterministic, queryable dataset for the companion BOE
    /// SearchLogs/ConsumeLogs verifier. This test intentionally validates only
    /// producer admission and terminal batches; the external verifier owns
    /// service-side field, metadata, count, and duplicate assertions.
    func testRealBOEFieldFidelityAndBatching() async throws {
        let fixture = try Fixture.loadOrSkip()
        guard let runID = Self.environmentValue(["TLS_BOE_RUN_ID", "VE_TLS_RUN_ID"]) else {
            throw XCTSkip("set TLS_BOE_RUN_ID (or VE_TLS_RUN_ID) for the queryable dataset")
        }
        guard runID.range(of: #"^[a-z0-9_-]{8,96}$"#,
                          options: .regularExpression) != nil else {
            XCTFail("TLS_BOE_RUN_ID must match lowercase [a-z0-9_-]{8,96}")
            return
        }

        let logCount = 12
        let expectedBatchCount = 3
        let collector = ResultCollector()
        let configuration = try ProducerConfiguration(
            batch: BatchConfiguration(
                maxLogCount: 4,
                maxRawBytes: 1024 * 1024,
                linger: 30),
            sendConcurrency: 1,
            compression: .lz4,
            metadata: ProducerMetadata(
                source: "ios-boe-business",
                fileName: "producer-e2e.log",
                tags: ["sdk": "ios", "suite": "boe-business"]),
            automaticLifecycleHandling: false,
            destination: fixture.destination)
        let producer = try await Producer.open(
            configuration: configuration,
            credentials: fixture.credentials,
            onSendResult: { collector.append($0) })

        do {
            for sequence in 0..<logCount {
                let event = LogEvent(
                    hashKey: "00000000000000000000000000000000",
                    contents: [
                        "run_id": .string(runID),
                        "scenario": .string("field_fidelity"),
                        "seq": .signedInt(Int64(sequence)),
                        "field_string": .string("hello-中文-🙂-\(sequence)"),
                        "field_signed": .signedInt(Int64.min + Int64(sequence)),
                        "field_unsigned": .unsignedInt(UInt64.max - UInt64(sequence)),
                        "field_double": .double(12345.625 + Double(sequence)),
                        "field_bool": .bool(sequence.isMultiple(of: 2)),
                        "field_null": .null,
                        "field_array": .array([
                            .string("a\"b"), .signedInt(Int64(sequence)), .bool(true), .null,
                        ]),
                        "field_dictionary": .dictionary([
                            "a": .signedInt(Int64(sequence)),
                            "z": .string("line1\nline2\\tail"),
                        ]),
                        "field_utf8": .utf8Data(Data("raw-你好-\(sequence)".utf8)),
                        "field_empty": .string(""),
                    ])
                try producer.add(event, mode: .normal)
            }

            let results = await collector.waitForCount(expectedBatchCount, timeout: 60)
            let safeSummary = results.map { result in
                let status = result.status == .success ? "success" : "failure"
                return "\(status):\(result.error?.errorCode ?? "none"):requestID=\(!(result.requestID?.isEmpty ?? true))"
            }.joined(separator: ",")
            XCTAssertEqual(results.count, expectedBatchCount)
            XCTAssertTrue(results.allSatisfy { $0.status == .success }, safeSummary)
            XCTAssertTrue(results.allSatisfy { $0.error == nil }, safeSummary)
            XCTAssertTrue(results.allSatisfy { $0.rawBytes > 0 })
            XCTAssertTrue(results.allSatisfy { $0.compressedBytes > 0 })
            try await producer.close(timeout: 30)
            print("REAL_BOE_DATASET run_id=\(runID) logs=\(logCount) batches=\(expectedBatchCount)")
        } catch {
            try? await producer.close(timeout: 30)
            throw error
        }
    }

    /// The public contract follows the SLS half-open 128-bit range: all-zero
    /// is included and all-`f` is the excluded upper bound. The all-`f` local
    /// admission rejection is covered by contract tests; this opt-in case
    /// proves every representative valid boundary against the real service.
    func testRealBOEHashKeyHalfOpenBoundaries() async throws {
        let fixture = try Fixture.loadOrSkip()
        guard let baseRunID = Self.environmentValue(["TLS_BOE_RUN_ID", "VE_TLS_RUN_ID"]) else {
            throw XCTSkip("set TLS_BOE_RUN_ID (or VE_TLS_RUN_ID) for hash-key evidence")
        }
        let cases = [
            ("zero", "00000000000000000000000000000000"),
            ("lower_half", "7fffffffffffffffffffffffffffffff"),
            ("upper_half", "80000000000000000000000000000000"),
            ("max_inclusive", "fffffffffffffffffffffffffffffffe"),
        ]
        let collector = ResultCollector()
        let configuration = try ProducerConfiguration(
            batch: BatchConfiguration(maxLogCount: 1, maxRawBytes: 1024 * 1024, linger: 0),
            automaticLifecycleHandling: false,
            destination: fixture.destination)
        let producer = try await Producer.open(
            configuration: configuration,
            credentials: fixture.credentials,
            onSendResult: { collector.append($0) })

        do {
            for (index, item) in cases.enumerated() {
                try producer.add(
                    LogEvent(
                        hashKey: item.1,
                        contents: [
                            "run_id": .string("\(baseRunID)_hash_\(item.0)"),
                            "scenario": .string("hash_boundary"),
                            "seq": .signedInt(Int64(index)),
                            "hash_case": .string(item.0),
                        ]),
                    mode: .immediate)
            }
            let results = await collector.waitForCount(cases.count, timeout: 60)
            let safeSummary = zip(cases, results).map { pair in
                let (item, result) = pair
                let status = result.status == .success ? "success" : "failure"
                return "\(item.0):\(status):\(result.error?.errorCode ?? "none")"
            }.joined(separator: ",")
            XCTAssertEqual(results.count, cases.count, safeSummary)
            XCTAssertTrue(results.allSatisfy { $0.status == .success }, safeSummary)
            try await producer.close(timeout: 30)
        } catch {
            try? await producer.close(timeout: 30)
            throw error
        }
    }

    /// Sends one event whose public raw-field accounting is exactly the
    /// recommended 9.5 MiB ceiling, then proves a one-byte-larger event is
    /// rejected locally without producing another terminal callback.
    func testRealBOENearRecommendedLimitAndLocalOversizeRejection() async throws {
        let fixture = try Fixture.loadOrSkip()
        guard let runID = Self.environmentValue(["TLS_BOE_RUN_ID", "VE_TLS_RUN_ID"]) else {
            throw XCTSkip("set TLS_BOE_RUN_ID (or VE_TLS_RUN_ID) for large-payload evidence")
        }

        let scenario = "near_9_5_mib"
        let recommendedMaxRawBytes = 19 * 512 * 1024
        let fixedRawBytes =
            "run_id".utf8.count + runID.utf8.count +
            "scenario".utf8.count + scenario.utf8.count +
            "seq".utf8.count + 1 +
            "payload".utf8.count
        let payloadBytes = recommendedMaxRawBytes - fixedRawBytes
        XCTAssertGreaterThan(payloadBytes, 0)

        let collector = ResultCollector()
        let configuration = try ProducerConfiguration(
            batch: BatchConfiguration(
                maxLogCount: 1,
                maxRawBytes: recommendedMaxRawBytes,
                linger: 0),
            sendConcurrency: 1,
            compression: .lz4,
            requestTimeout: 60,
            metadata: ProducerMetadata(
                source: "ios-boe-large",
                fileName: "producer-large.log",
                tags: ["sdk": "ios", "suite": "boe-large"]),
            automaticLifecycleHandling: false,
            destination: fixture.destination)
        let producer = try await Producer.open(
            configuration: configuration,
            credentials: fixture.credentials,
            onSendResult: { collector.append($0) })

        do {
            let baseContents: [String: LogValue] = [
                "run_id": .string(runID),
                "scenario": .string(scenario),
                "seq": .signedInt(0),
                "payload": .string(String(repeating: "x", count: payloadBytes)),
            ]
            try producer.add(LogEvent(contents: baseContents), mode: .immediate)
            let results = await collector.waitForCount(1, timeout: 120)
            XCTAssertEqual(results.count, 1)
            let result = try XCTUnwrap(results.first)
            XCTAssertEqual(result.status, .success)
            XCTAssertNil(result.error)
            XCTAssertGreaterThan(result.rawBytes, 0)

            var oversizedContents = baseContents
            oversizedContents["payload"] = .string(
                String(repeating: "x", count: payloadBytes + 1))
            XCTAssertThrowsError(
                try producer.add(LogEvent(contents: oversizedContents), mode: .immediate)
            ) { error in
                XCTAssertEqual(error as? ProducerError, .singleLogTooLarge)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(
                collector.snapshot.count,
                1,
                "the locally rejected oversized event must not reach the transport")
            try await producer.close(timeout: 30)
            print("REAL_BOE_LARGE run_id=\(runID) raw_limit=\(recommendedMaxRawBytes)")
        } catch {
            try? await producer.close(timeout: 30)
            throw error
        }
    }

    /// A persistent `.retain` producer must suspend a BOE authentication
    /// rejection without a terminal callback, then deliver the same WAL entry
    /// exactly once after the complete credential group is corrected.
    func testRealBOEPersistentAuthRetainResumesAfterCredentialUpdate() async throws {
        let fixture = try Fixture.loadOrSkip()
        guard let runID = Self.environmentValue(["TLS_BOE_RUN_ID", "VE_TLS_RUN_ID"]) else {
            throw XCTSkip("set TLS_BOE_RUN_ID (or VE_TLS_RUN_ID) for auth-retain evidence")
        }
        let collector = ResultCollector()
        let producerID = "boe-auth-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"
        let configuration = try ProducerConfiguration(
            batch: BatchConfiguration(maxLogCount: 1, maxRawBytes: 1024 * 1024, linger: 0),
            sendConcurrency: 1,
            compression: .lz4,
            persistence: .sync,
            requestTimeout: 15,
            metadata: ProducerMetadata(source: "simulator-recovery"),
            unauthorizedPolicy: .retain,
            automaticLifecycleHandling: false,
            producerID: producerID,
            destination: fixture.destination)
        let invalidCredentials = Credentials(
            accessKeyID: fixture.credentials.accessKeyID,
            accessKeySecret: "intentionally-invalid-\(UUID().uuidString)",
            securityToken: fixture.credentials.securityToken)
        let producer = try await Producer.open(
            configuration: configuration,
            credentials: invalidCredentials,
            onSendResult: { collector.append($0) })

        do {
            try producer.add(
                LogEvent(contents: [
                    "run_id": .string(runID),
                    "scenario": .string("auth_retain_update"),
                    "seq": .signedInt(0),
                ]),
                mode: .immediate)

            // BOE authentication failures are non-retryable. A bounded pause
            // lets that first signed request complete while proving `.retain`
            // does not publish a premature terminal failure.
            try await Task.sleep(nanoseconds: 3_000_000_000)
            XCTAssertTrue(
                collector.snapshot.isEmpty,
                "retained BOE authentication failure must not be terminal")

            try producer.updateCredentials(fixture.credentials)
            let results = await collector.waitForCount(1, timeout: 60)
            XCTAssertEqual(results.count, 1)
            let result = try XCTUnwrap(results.first)
            XCTAssertEqual(result.status, .success)
            XCTAssertNil(result.error)
            try await producer.close(timeout: 30)
            print("REAL_BOE_AUTH_RETAIN run_id=\(runID) terminal_successes=1")
        } catch {
            try? await producer.close(timeout: 30)
            throw error
        }
    }
}
