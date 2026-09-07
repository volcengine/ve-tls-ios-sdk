// TestFixtures.swift
// BridgeTests/Support
//
// Shared configuration/value fixtures for BridgeTests.
//
// Public model used by these fixtures:
//   - ProducerConfiguration(batch:callbackQueue:) is a throwing initializer.
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
    private static func makeSet(_ suffix: String) -> Credentials {
        let values = ["ak-\(suffix)", "sk-\(suffix)", "session-\(suffix)"]
        return Credentials(
            accessKeyID: values[0],
            accessKeySecret: values[1],
            securityToken: values[2])
    }

    public static let setA = makeSet("A")
    public static let setB = makeSet("B")
    public static let setC = makeSet("C")
    public static let setD = makeSet("D")

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
