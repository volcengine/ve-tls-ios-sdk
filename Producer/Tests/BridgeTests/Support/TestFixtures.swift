// TestFixtures.swift
// BridgeTests/Support
//
// Shared configuration/value fixtures for BridgeTests.
//
// Aligned with Worker A's landed Sources (2026-08-27):
//   - ProducerConfiguration(batch:callbackQueue:) is a throwing init; there
//     is NO destination field on the configuration (destinations flow via
//     Producer/FakeCoreAdapter.updateDestination).
//   - BatchConfiguration(maxLogCount:maxRawBytes:linger:).
//   - Credentials(accessKeyID:accessKeySecret:securityToken:) with an
//     optional securityToken.
//   - Destination(endpoint:region:projectID:topicID:).
//   - LogEvent(timestamp:contents:) with LogValue.string(_:).
//

import Foundation
@testable import VolcengineTLSProducer

public enum TestConfigurations {

    /// Builds a ProducerConfiguration with small, deterministic batch windows
    /// so tests can force sealing without waiting for the 3s default linger.
    public static func make(
        maxLogCount: Int = 1024,
        maxRawBytes: Int = 1_048_576,
        linger: TimeInterval = 3.0,
        callbackQueue: DispatchQueue = DispatchQueue(
            label: "com.volcengine.tls.producer.test.callback")
    ) throws -> ProducerConfiguration {
        return try ProducerConfiguration(
            batch: BatchConfiguration(
                maxLogCount: maxLogCount,
                maxRawBytes: maxRawBytes,
                linger: linger),
            callbackQueue: callbackQueue)
    }
}

public enum SampleCredentials {
    public static let setA = Credentials(
        accessKeyID: "ak-A", accessKeySecret: "sk-A", securityToken: "token-A")
    public static let setB = Credentials(
        accessKeyID: "ak-B", accessKeySecret: "sk-B", securityToken: "token-B")
    public static let setC = Credentials(
        accessKeyID: "ak-C", accessKeySecret: "sk-C", securityToken: "token-C")
    public static let setD = Credentials(
        accessKeyID: "ak-D", accessKeySecret: "sk-D", securityToken: "token-D")

    public static let allSets: [Credentials] = [setA, setB, setC, setD]

    /// Whole-group equality: a sealed batch must match one complete set,
    /// never a mix of AK from one set and SK/token from another.
    public static func isCoherentWholeGroup(_ credentials: Credentials) -> Bool {
        return allSets.contains {
            $0.accessKeyID == credentials.accessKeyID
                && $0.accessKeySecret == credentials.accessKeySecret
                && $0.securityToken == credentials.securityToken
        }
    }
}

public enum SampleDestinations {
    public static let beijing = Destination(
        endpoint: "https://tls-cn-beijing.volces.com",
        region: "cn-beijing",
        projectID: "project-a",
        topicID: "topic-a")
    public static let shanghai = Destination(
        endpoint: "https://tls-cn-shanghai.volces.com",
        region: "cn-shanghai",
        projectID: "project-b",
        topicID: "topic-b")
}

public enum SampleEvents {
    public static func make(key: String = "event",
                            value: String = "v",
                            timestamp: Date = Date()) -> LogEvent {
        return LogEvent(timestamp: timestamp, contents: [key: .string(value)])
    }
}
