// ProducerTestHarness.swift
// ProducerTestSupport
//
// Constructs a `Producer` backed by an injected (fake) `CoreAdapter`.
//
// Aligned with Worker A's landed Sources (2026-08-27): Producer exposes the
// internal injection entry point
// `Producer.open(adapter:configuration:credentials:onSendResult:)`
// (visible via @testable). The public `Producer.open(configuration:...)`
// wires the provisional BundledCoreAdapter and must not be used by
// BridgeTests.
//

import Foundation
@testable import VolcengineTLSProducer

public enum ProducerTestHarness {

    /// Opens a Producer backed by the given (fake) CoreAdapter.
    public static func makeProducer(
        configuration: ProducerConfiguration,
        credentials: Credentials,
        adapter: CoreAdapter,
        onSendResult: (@Sendable (SendResult) -> Void)? = nil
    ) async throws -> Producer {
        return try await Producer.open(
            adapter: adapter,
            configuration: configuration,
            credentials: credentials,
            onSendResult: onSendResult)
    }
}
